pragma solidity ^0.8.28;

interface IFlashLoanRecipient {
    /**
     * @dev When `flashLoan` is called on the Vault, it invokes the `receiveFlashLoan` hook on the recipient.
     *
     * At the time of the call, the Vault will have transferred `amounts` for `tokens` to the recipient. Before this
     * call returns, the recipient must have transferred `amounts` plus `feeAmounts` for each token back to the
     * Vault, or else the entire flash loan will revert.
     *
     * `userData` is the same value passed in the `IVault.flashLoan` call.
     */
    function receiveFlashLoan(
        IERC20[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory userData
    ) external;
}

// from balancer
interface IAsset {
    // solhint-disable-previous-line no-empty-blocks
}

interface IBalancer {
    function flashLoan(IFlashLoanRecipient recipient, IERC20[] memory tokens, uint256[] memory amounts, bytes memory userData) external;

    function swap(
        SingleSwap memory singleSwap,
        FundManagement memory funds,
        uint256 limit,
        uint256 deadline
    ) external payable returns (uint256);

    struct SingleSwap {
        bytes32 poolId;
        SwapKind kind;
        IAsset assetIn;
        IAsset assetOut;
        uint256 amount;
        bytes userData;
    }

    struct FundManagement {
        address sender;
        bool fromInternalBalance;
        address payable recipient;
        bool toInternalBalance;
    }

    enum SwapKind { GIVEN_IN, GIVEN_OUT }
}

interface IMorphoBase {
    /// @notice Executes a flash loan.
    /// @dev Flash loans have access to the whole balance of the contract (the liquidity and deposited collateral of all
    /// markets combined, plus donations).
    /// @dev Warning: Not ERC-3156 compliant but compatibility is easily reached:
    /// - `flashFee` is zero.
    /// - `maxFlashLoan` is the token's balance of this contract.
    /// - The receiver of `assets` is the caller.
    /// @param token The token to flash loan.
    /// @param assets The amount of assets to flash loan.
    /// @param data Arbitrary data to pass to the `onMorphoFlashLoan` callback.
    function flashLoan(address token, uint256 assets, bytes calldata data) external;
}

/// @title IMorphoFlashLoanCallback
/// @notice Interface that users willing to use `flashLoan`'s callback must implement.
interface IMorphoFlashLoanCallback {
    /// @notice Callback called when a flash loan occurs.
    /// @dev The callback is called only if data is not empty.
    /// @param assets The amount of assets that was flash loaned.
    /// @param data Arbitrary data passed to the `flashLoan` function.
    function onMorphoFlashLoan(uint256 assets, bytes calldata data) external;
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

contract RocketpoolExitArbitrageBalancer is IMorphoFlashLoanCallback {
    IWETH public constant wETH = IWETH(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IRETH public constant rETH = IRETH(0xae78736Cd615f374D3085123A210448E74Fc6393);

    IMorphoBase constant morpho = IMorphoBase(0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb);
    IBalancer private balancerVault = IBalancer(0xBA12222222228d8Ba445958a75a0704d566BF2C8);   
    bytes32 immutable balancerPoolId;

    
    event Arbitrage(address indexed caller, address indexed receiver, address flashloanProvider, uint256 amount, uint256 profit);

    constructor(bytes32 _balancerPoolId) {
        balancerPoolId = _balancerPoolId;
    }

    receive () external payable {}

    /// @notice Distributes minipools and executes an arbitrage operation using Balancer.
    /// @param _minProfit The minimum amount of profit to keep, otherwise revert
    /// @param _receiver The address to receive the profit
    /// @dev Emits an {Arbitrage} event.
    function arb(uint256 _minProfit, address _receiver) external returns (uint256) {
        uint256 availableETH = rETH.getTotalCollateral();
        morpho.flashLoan(address(wETH), availableETH, "");

        uint256 profit = address(this).balance;
        require(profit >= _minProfit, "Profit too low");
        (bool success, ) = payable(_receiver).call{value: profit}("");
        require(success, "Transfer failed.");

        // check if any ERC20 token are left in the contract
        if (wETH.balanceOf(address(this)) > 0) wETH.transfer(_receiver, wETH.balanceOf(address(this)));
        if (rETH.balanceOf(address(this)) > 0) rETH.transfer(_receiver, rETH.balanceOf(address(this)));

        emit Arbitrage(msg.sender, _receiver, address(balancerVault), availableETH, profit);
        return profit;
    }
    
    /// @notice Callback called when a flash loan occurs.
    /// @dev The callback is called only if data is not empty.
    /// @param _amountWethBorrowed The amount of assets that was flash loaned.
    function onMorphoFlashLoan(uint256 _amountWethBorrowed, bytes calldata) external override {
        // Get the amount of rETH we need to burn
        uint256 rethPossibleToBurn = rETH.getRethValue(_amountWethBorrowed);        

        // Swap WETH to rETH
        IBalancer.SingleSwap memory singleSwap = IBalancer.SingleSwap({
            poolId: balancerPoolId,
            kind: IBalancer.SwapKind.GIVEN_OUT,
            assetIn: IAsset(address(wETH)),
            assetOut: IAsset(address(rETH)),
            amount: rethPossibleToBurn,
            userData: ""
        });
        IBalancer.FundManagement memory funds = IBalancer.FundManagement({
            sender: address(this),
            fromInternalBalance: false,
            recipient: payable(address(this)),
            toInternalBalance: false
        });

        wETH.approve(address(balancerVault), _amountWethBorrowed);    
        balancerVault.swap(
            singleSwap,
            funds,
            _amountWethBorrowed,
            block.timestamp
        );

        // Burn the rETH
        rETH.burn(rethPossibleToBurn);

        // Approve rETH on Morpho
        wETH.deposit{value: _amountWethBorrowed - wETH.balanceOf(address(this))}();
        wETH.approve(address(morpho), _amountWethBorrowed);
    }
}