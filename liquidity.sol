// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC20 {
    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) external returns (bool);

    function transfer(address recipient, uint256 amount)
        external
        returns (bool);

    function balanceOf(address account) external view returns (uint256);
}

interface IWETH {
    function deposit() external payable;

    function transfer(address dst, uint256 wad) external returns (bool);

    function balanceOf(address to) external view returns (uint256);

    function transferFrom(
        address from,
        address to,
        uint256 value
    ) external returns (bool);

    function withdraw(uint256 wad) external;
}

contract EthUsdtPool {
    uint256 public totalLiquidity;
    IERC20 public token0;
    address public WETH;

    receive() external payable {}

    mapping(address => uint256) public userToMint;

    constructor(address _PBMC, address _WETH) {
        token0 = IERC20(_PBMC);
        WETH = _WETH;
    }

    bytes4 private constant SELECTOR =
        bytes4(keccak256(bytes("transfer(address,uint256)")));
    uint256 public reserveA;
    uint256 public reserveB;

    function safeTransferFrom(
        // address token,
        address from,
        address to,
        uint256 value
    ) internal {
        // bytes4(keccak256(bytes('transferFrom(address,address,uint256)')));
        (bool success, bytes memory data) = address(token0).call(
            abi.encodeWithSelector(0x23b872dd, from, to, value)
        );
        require(
            success && (data.length == 0 || abi.decode(data, (bool))),
            "TransferHelper::transferFrom: transferFrom failed"
        );
    }

    function _safeTransfer(
        address token,
        address to,
        uint256 value
    ) private {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(SELECTOR, to, value)
        );
        require(
            success && (data.length == 0 || abi.decode(data, (bool))),
            "UniswapV2: TRANSFER_FAILED"
        );
    }

    function safeTransferETH(address to, uint256 value) internal {
        (bool success, ) = to.call{value: value}(new bytes(0));
        require(success, "safeTransferETH: ETH transfer failed");
    }

    function safeTransfer(address to, uint256 value) internal {
        // bytes4(keccak256(bytes('transfer(address,uint256)')));
        (bool success, bytes memory data) = address(token0).call(
            abi.encodeWithSelector(0xa9059cbb, to, value)
        );
        require(
            success && (data.length == 0 || abi.decode(data, (bool))),
            "TransferHelper::safeTransfer: transfer failed"
        );
    }

    function addLiquidityETH(uint256 amountTokenDesired) external payable {
        uint256 amountToken;
        uint256 amountETH;

        (amountToken, amountETH) = _addLiquidity(amountTokenDesired, msg.value);

        // Transfer token from sender to this contract
        safeTransferFrom(msg.sender, address(this), amountToken);
        // token0.transferFrom(msg.sender, address(this), amountToken);

        // Deposit ETH and get WETH
        IWETH(WETH).deposit{value: amountETH}();

        // Transfer WETH from sender to this contract
        IWETH(WETH).transfer(address(this), amountETH);

        // Mint LP tokens
        mint(msg.sender);
        // Update reserves
        reserveA = token0.balanceOf(address(this));
        reserveB = IWETH(WETH).balanceOf(address(this));

        // Refund excess ETH, if any
        if (msg.value > amountETH) {
            // safeTransferETH(to, msg.value - amountETH);
            payable(msg.sender).transfer(msg.value - amountETH);
        }
    }

    function _addLiquidity(uint256 amountADesired, uint256 amountBDesired)
        internal
        view
        returns (uint256 amountA, uint256 amountB)
    {
        if (reserveA == 0 && reserveB == 0) {
            (amountA, amountB) = (amountADesired, amountBDesired);
        } else {
            uint256 amountBOptimal = (amountADesired * reserveB) / reserveA;
            if (amountBOptimal <= amountBDesired) {
                require(amountBOptimal <= amountBDesired, "Invalid amountb");

                (amountA, amountB) = (amountADesired, amountBOptimal);
            } else {
                uint256 amountAOptimal = (amountBDesired * reserveA) / reserveB;
                require(amountAOptimal <= amountADesired, "Invalid amountA");
                (amountA, amountB) = (amountAOptimal, amountBDesired);
            }
        }
    }

    function mint(address to) internal returns (uint256 liquidity) {
        (uint256 _reserveA, uint256 _reserveB) = getReserve();
        uint256 balance0 = token0.balanceOf(address(this));
        uint256 balance1 = IWETH(WETH).balanceOf(address(this));
        uint256 amount0 = balance0 - _reserveA;
        uint256 amount1 = balance1 - _reserveB;

        uint256 _totalLiquidity = totalLiquidity; // gas savings, must be defined here since totalSupply can update in _mintFee
        if (_totalLiquidity == 0) {
            liquidity = sqrt(amount0 * amount1);
        } else {
            liquidity = min(
                (amount0 * _totalLiquidity) / _reserveA,
                (amount1 * _totalLiquidity) / _reserveB
            );
        }
        require(liquidity > 0, "INSUFFICIENT_LIQUIDITY_MINTED");
        userToMint[to] += liquidity;
        totalLiquidity += liquidity;
    }

    function removeLiquidityETH(uint256 liquidity, address to)
        public
        returns (uint256 amountToken, uint256 amountETH)
    {
        userToMint[address(this)] += liquidity;
        userToMint[msg.sender] -= liquidity;
        (amountToken, amountETH) = burn();
        safeTransfer(to, amountToken);
        // token0.transfer(to, amountToken);
        IWETH(WETH).withdraw(amountETH);
        safeTransferETH(to, amountETH);
        reserveA = token0.balanceOf(address(this));
        reserveB = IWETH(WETH).balanceOf(address(this));
    }

    function burn() internal returns (uint256 amountToken, uint256 amountETH) {
        uint256 balanceToken = token0.balanceOf(address(this));
        uint256 balanceETH = IWETH(WETH).balanceOf(address(this));
        uint256 liquidity = userToMint[address(this)];

        uint256 _totalLiquidity = totalLiquidity;
        amountToken = (liquidity * balanceToken) / _totalLiquidity;
        amountETH = (liquidity * balanceETH) / _totalLiquidity;
        require(
            amountToken > 0 && amountETH > 0,
            "INSUFFICIENT_LIQUIDITY_BURNED"
        );

        userToMint[address(this)] -= liquidity;
        totalLiquidity -= liquidity;

        // _safeTransfer(address(token0), to, amountToken);
        // _safeTransfer(WETH, to, amountETH);
        // token0.transfer(to, amountToken);
        // IWETH(WETH).transfer(to, amountToken);
    }

    function swapTokensForExactETH(
        uint256 amountOut,
        uint256 amountInMax,
        address to
    ) external {
        // require(path[path.length - 1] == WETH, 'UniswapV2Router: INVALID_PATH');
        require(amountOut > 0, "INSUFFICIENT_OUTPUT_AMOUNT");
        require(reserveA > 0 && reserveB > 0, "INSUFFICIENT_LIQUIDITY");
        uint256 reserveIn = reserveA;
        uint256 reserveOut = reserveB;
        uint256 numerator = (reserveIn * amountOut * 1000);
        uint256 denominator = (reserveOut - amountOut) * (997);
        uint256 amountIn = (numerator / denominator) + (1);

        require(amountIn <= amountInMax, "EXCESSIVE_ETH_AMOUNT");
        safeTransferFrom(msg.sender, address(this), amountIn);
        IWETH(WETH).withdraw(amountOut);
        safeTransferETH(to, amountOut);
        swap(amountIn, amountOut);
    }

    // function _swap(uint[] memory amounts, address[] memory path, address _to) internal virtual {
    //     for (uint i; i < path.length - 1; i++) {
    //         (address input, address output) = (path[i], path[i + 1]);
    //         (address token0,) = UniswapV2Library.sortTokens(input, output);
    //         uint amountOut = amounts[i + 1];
    //         (uint amount0Out, uint amount1Out) = input == token0 ? (uint(0), amountOut) : (amountOut, uint(0));
    //         address to = i < path.length - 2 ? UniswapV2Library.pairFor(factory, output, path[i + 2]) : _to;
    //         IUniswapV2Pair(UniswapV2Library.pairFor(factory, input, output)).swap(
    //             amount0Out, amount1Out, to, new bytes(0)
    //         );
    //     }
    // }
    function swap(
        uint256 amount0Out,
        uint256 amount1Out
        // address to,
        // bytes calldata data
    ) internal {
        require(
            amount0Out > 0 || amount1Out > 0,
            "UniswapV2: INSUFFICIENT_OUTPUT_AMOUNT"
        );
        (uint256 _reserve0, uint256 _reserve1) = getReserve(); // gas savings
        require(
            amount0Out < _reserve0 && amount1Out < _reserve1,
            "UniswapV2: INSUFFICIENT_LIQUIDITY"
        );
        
        {
            // scope for _token{0,1}, avoids stack too deep errors
            // address _token0 = address(token0);
            // address _token1 = WETH;
            // require(to != _token0 && to != _token1, "UniswapV2: INVALID_TO");
            // if (amount0Out > 0) _safeTransfer(_token0, to, amount0Out); // optimistically transfer tokens
            // if (amount1Out > 0) _safeTransfer(_token1, to, amount1Out); // optimistically transfer tokens
            // if (data.length > 0) IUniswapV2Callee(to).uniswapV2Call(msg.sender, amount0Out, amount1Out, data); //idk what it deos
            reserveA = IERC20(token0).balanceOf(address(this));
            reserveB = IWETH(WETH).balanceOf(address(this));
        }
        // uint amount0In = balance0 > _reserve0 - amount0Out ? balance0 - (_reserve0 - amount0Out) : 0;
        // uint amount1In = balance1 > _reserve1 - amount1Out ? balance1 - (_reserve1 - amount1Out) : 0;
        // require(amount0In > 0 || amount1In > 0, 'UniswapV2: INSUFFICIENT_INPUT_AMOUNT');
        // {
            // scope for reserve{0,1}Adjusted, avoids stack too deep errors
            // uint balance0Adjusted = ((balance0 * 1000) - (amount0In * 3));
            // uint balance1Adjusted = ((balance1 * 1000) - (amount1In * 3));
            // require(balance0Adjusted.mul(balance1Adjusted) >= uint(_reserve0).mul(_reserve1).mul(1000**2), 'UniswapV2: K');
        // }
        // reserveA = (balance0);
        // reserveB = (balance1);
    }

    function getReserve()
        public
        view
        returns (uint256 _reserveA, uint256 _reserveB)
    {
        _reserveA = reserveA;
        _reserveB = reserveB;
    }

    function sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }

    function min(uint256 x, uint256 y) internal pure returns (uint256 z) {
        z = x < y ? x : y;
    }
}

// adding lquidity(PBMC)
//u1= eth/pbmc 1/200- [before] 1000000---- [after] =999800    totliq= 14142135623
//u2= eth/pbmc 1/200- [before] 1000000---- [after] =999800    totliq= 14142135623


//reserves 400/2000000000000000000
//after swap=442/1900000000000000000

//u3=  => amount out =>100000000000000000
          //amountmax => 200
