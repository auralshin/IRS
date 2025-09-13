// SPDX-License-Identifier: MIT
pragma solidity =0.8.26;

interface IWETH9 {
    function deposit() external payable;

    function withdraw(uint256) external;

    function approve(address, uint256) external returns (bool);

    function transfer(address, uint256) external returns (bool);
}
