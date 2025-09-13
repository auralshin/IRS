// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IMarginManager {
    function isHealthy(address account) external view returns (bool);
}
