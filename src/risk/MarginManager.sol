// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IMarginManager} from "../interfaces/IMarginManager.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract MarginManager is IMarginManager, Ownable {
    mapping(address => bool) public whitelist;

    constructor(address admin) Ownable(admin) {}

    function setWhitelisted(address who, bool ok) external onlyOwner {
        whitelist[who] = ok;
    }

    function isHealthy(address account) external view returns (bool) {
        return whitelist[account];
    }
}