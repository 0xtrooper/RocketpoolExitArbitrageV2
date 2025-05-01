// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {RocketpoolExitArbitrageBalancer} from "../src/BalancerArb.sol";
import {RocketpoolExitArbitrageUniswap} from "../src/UniswapArb.sol";

contract RocketpoolExitArbitrageTest is Test {
    RocketpoolExitArbitrageUniswap public exitArbUniswap;
    RocketpoolExitArbitrageBalancer public exitArbBalancer;

    address rETH = 0xae78736Cd615f374D3085123A210448E74Fc6393;

    address uniswapPoolAddress = 0x553e9C493678d8606d6a5ba284643dB2110Df823;
    bytes32 private balancerPoolId = 0x1e19cf2d73a72ef1332c882f20534b6519be0276000200000000000000000112 ; // see: https://balancer.fi/pools/ethereum/v2/__balancerPoolId__

    receive () external payable {}

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));

        exitArbUniswap = new RocketpoolExitArbitrageUniswap(uniswapPoolAddress);
        exitArbBalancer = new RocketpoolExitArbitrageBalancer(balancerPoolId);

        // send 24 ETH to the rETH contract
        (bool success, ) = rETH.call{value: 24 ether}("");
        require(success, "rETH call failed");
    }

    modifier profitLogger() {
        uint256 initialBalance = address(this).balance;
        _;
        uint256 finalBalance = address(this).balance;
        console.log("Profit: %s", finalBalance - initialBalance);        
    }

    function test_UniswapArbitrage() public profitLogger {
        exitArbUniswap.arb(0, address(this));
    }

    function test_UniswapArbitrageMinPofit() public {
        vm.expectRevert();
        exitArbUniswap.arb(24 ether, address(this));
    }

    function test_BalancerArbitrage() public profitLogger {
        exitArbBalancer.arb(0, address(this));
    }

    function test_BalancerArbitrageMinPofit() public {
        vm.expectRevert();
        exitArbBalancer.arb(24 ether, address(this));
    }
}
