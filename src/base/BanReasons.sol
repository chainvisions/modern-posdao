// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

library BanReasons {
    uint256 internal constant UNREVEALED = 1;
    uint256 internal constant SPAM = 2;
    uint256 internal constant MALICIOUS = 3;
    uint256 internal constant OFTEN_BLOCK_DELAYS = 4;
    uint256 internal constant OFTEN_BLOCK_SKIPS = 5;
    uint256 internal constant OFTEN_REVEAL_SKIPS = 6;
}
