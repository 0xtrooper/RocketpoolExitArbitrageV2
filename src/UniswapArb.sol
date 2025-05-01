pragma solidity ^0.8.28;

interface IUniswap {
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);
}

interface IUniswapV3SwapCallbackReceiver {
    /// @notice Called to `msg.sender` after executing a swap via IUniswapV3Pool#swap.
    /// @dev In the implementation you must pay the pool tokens owed for the swap.
    /// The caller of this method must be checked to be a UniswapV3Pool deployed by the canonical UniswapV3Factory.
    /// amount0Delta and amount1Delta can both be 0 if no tokens were swapped.
    /// @param amount0Delta The amount of token0 that was sent (negative) or must be received (positive) by the pool by
    /// the end of the swap. If positive, the callback must send that amount of token0 to the pool.
    /// @param amount1Delta The amount of token1 that was sent (negative) or must be received (positive) by the pool by
    /// the end of the swap. If positive, the callback must send that amount of token1 to the pool.
    /// @param data Any data passed through by the caller via the IUniswapV3PoolActions#swap call
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external;
}

interface IERC20 {
    function transfer(address recipient, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);    
}

interface IWETH is IERC20 {
    function deposit() external payable;
    function withdraw(uint wad) external;
}

interface IRETH is IERC20 {
    function burn(uint256 _rethAmount) external;

    function getTotalCollateral() external view returns (uint256);
    function getEthValue(uint256 _rethAmount) external view returns (uint256);
    function getRethValue(uint256 _ethAmount) external view returns (uint256);
}

contract RocketpoolExitArbitrageUniswap is IUniswapV3SwapCallbackReceiver {
    IWETH public constant wETH = IWETH(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IRETH public constant rETH = IRETH(0xae78736Cd615f374D3085123A210448E74Fc6393);
    IUniswap public immutable uniswapPool;

    uint160 internal constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;
    
    event Arbitrage(address indexed caller, address indexed receiver, address flashloanProvider, uint256 amount, uint256 profit);

    constructor(address _uniswapPoolAddress) {
        uniswapPool = IUniswap(_uniswapPoolAddress);
    }

    receive () external payable {}

    /// @notice Distributes minipools and executes an arbitrage operation using Uniswap V3.
    /// @param _minProfit The minimum amount of profit to keep, otherwise revert
    /// @param _receiver The address to receive the profit
    /// @dev Emits an {Arbitrage} event.
    function arb(uint256 _minProfit, address _receiver) external returns (uint256) {
        uint256 availableETH = rETH.getTotalCollateral();
        uint256 rethPossibleToBurn = rETH.getRethValue(availableETH);
        uniswapPool.swap(address(this), false, -int256(rethPossibleToBurn), MAX_SQRT_RATIO - 1, bytes(""));

        uint256 profit = address(this).balance;
        require(profit >= _minProfit, "Profit too low");
        (bool success, ) = payable(_receiver).call{value: profit}("");
        require(success, "Transfer failed.");

        // check if any ERC20 token are left in the contract
        if (wETH.balanceOf(address(this)) > 0) wETH.transfer(_receiver, wETH.balanceOf(address(this)));
        if (rETH.balanceOf(address(this)) > 0) rETH.transfer(_receiver, rETH.balanceOf(address(this)));

        emit Arbitrage(msg.sender, _receiver, address(uniswapPool), availableETH, profit);
        return profit;
    }

    // see: https://github.com/Uniswap/v3-core/blob/main/contracts/interfaces/callback/IUniswapV3SwapCallback.sol
    /// @notice Called to `msg.sender` after executing a swap via IUniswapV3Pool#swap.
    /// @dev In the implementation you must pay the pool tokens owed for the swap.
    /// @param _amountRETHDelta The amount of rETH that was sent (negative) or must be received (positive) by the pool by
    /// the end of the swap. If positive, the callback must send that amount of token0 to the pool.
    /// @param _amountWETHDelta The amount of WETH that was sent (negative) or must be received (positive) by the pool by
    /// the end of the swap. If positive, the callback must send that amount of token1 to the pool.
    function uniswapV3SwapCallback(
        int256 _amountRETHDelta, // token0
        int256 _amountWETHDelta, // token1
        bytes calldata
    ) external override {
        require(_amountRETHDelta < 0, "rETH must be sent to the pool");
        require(_amountWETHDelta > 0, "WETH must be received from the pool");

        // 1st: burn rETH, receive ETH
        rETH.burn(uint256(-_amountRETHDelta));

        // 2nd: wrap the amount due to the pool, keep the profit in ETH
        wETH.deposit{value: uint256(_amountWETHDelta)}();

        // 3rd: Repay the pool to complete the swap
        wETH.transfer(msg.sender, uint256(_amountWETHDelta));
    }
}