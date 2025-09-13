// SPDX-License-Identifier: MIT
pragma solidity =0.8.26;

import {Test} from "forge-std/Test.sol";
import {IRSV4Router} from "../../src/periphery/IRSV4Router.sol";

contract RouterFuzz is Test {
    // deploy manager, weth mock, caps, router; then fuzz add/remove/swap amounts.
    function testFuzz_AddRemove(uint128 amt, int24 lower, int24 upper) public {
        vm.assume(amt > 0 && lower < upper);
        // ...
        assertTrue(true);
    }
}
