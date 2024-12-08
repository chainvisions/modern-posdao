// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

interface IERC20Hooks {
    function beforeTokenTransfer(address, address, uint256) external;
    function afterTokenTransfer(address, address, uint256) external;
}
