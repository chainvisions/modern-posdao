// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IRandomAuRa {
    function clearCommit(uint256) external;
    function initialize(uint256, address, bool) external;
    function onFinishCollectRound() external;
    function collectRoundLength() external view returns (uint256);
    function commitHashCallable(address, bytes32) external view returns (bool);
    function currentSeed() external view returns (uint256);
    function revealNumberCallable(address, uint256) external view returns (bool);
}
