// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {EthBaseIndex} from "../src/oracles/EthBaseIndex.sol";
import {MarginManager} from "../src/risk/MarginManager.sol";
import {IRSPoolFactory} from "../src/factory/IRSPoolFactory.sol";
import {console2} from "forge-std/console2.sol";

contract DeployAll is Script {
    function run() external {
        vm.startBroadcast();

        IPoolManager manager = IPoolManager(vm.envAddress("POOL_MANAGER"));

        EthBaseIndex base = new EthBaseIndex(msg.sender, 95e9);
        MarginManager margin = new MarginManager(msg.sender);

        IRSPoolFactory factory = new IRSPoolFactory(manager);

        vm.stopBroadcast();

        console2.log("Deployed:");
        console2.log("PoolManager: %s", address(manager));
        console2.log("EthBaseIndex: %s", address(base));
        console2.log("MarginManager: %s", address(margin));
        console2.log("IRSPoolFactory: %s", address(factory));
    }
}
