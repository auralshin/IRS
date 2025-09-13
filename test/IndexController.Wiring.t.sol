// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {EthBaseIndex} from "../src/oracles/EthBaseIndex.sol";

// Minimal controller that proxies "set params" into EthBaseIndex.
// Your real IRSController will have richer logic & roles.
contract IRSControllerLike {
    function setOracleParams(EthBaseIndex idx, uint256 alphaPPM, uint256 maxDevPPM, uint64 maxStale) external {
        // This must be authorized by the index (owner or controller).
        idx.setParams(alphaPPM, maxDevPPM, maxStale);
    }

    function wireIndex(EthBaseIndex idx) external {
        // Your implementation should set itself as controller on the index.
        idx.setController(address(this));
    }
}

contract IndexController_Wiring is Test {
    EthBaseIndex index;
    IRSControllerLike controller;

    address admin = address(this);

    function setUp() public {
        address[] memory sources = new address[](0);
        index = new EthBaseIndex(
            admin,           // owner/admin
            200_000,         // alphaPPM
            200_000,         // maxDeviationPPM
            3600,            // maxStale
            sources
        );
        controller = new IRSControllerLike();
    }

    function test_setOracleParams_reverts_then_succeeds_after_wiring() public {
        // 1) Without wiring, controller is not authorized → expect revert
    vm.expectRevert(); // depends on your revert string; generic is fine
    controller.setOracleParams(index, 150_000, 150_000, uint64(7200));

    // 2) Wire the controller by calling setController as the admin
    vm.prank(admin);
    index.setController(address(controller));

        // 3) Now should succeed
    controller.setOracleParams(index, 150_000, 150_000, uint64(7200));

    // Optional: read back params & assert
    assertEq(index.alphaPPM(), 150_000);
    assertEq(index.maxDeviationPPM(), 150_000);
    assertEq(index.maxStale(), uint64(7200));
    }
}
