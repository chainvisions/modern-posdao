// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IBlockRewardAuRa} from "../../interfaces/IBlockRewardAuRa.sol";
import {IValidatorSetAuRa} from "../../interfaces/IValidatorSetAuRa.sol";

struct ExtraReceiverQueue {
    uint256 amount;
    address bridge;
    address receiver;
}

library BlockRewardStorage {
    struct Layout {
        address[] ercToNativeBridgesAllowed;
        IBlockRewardAuRa prevBlockRewardContract;
        bool queueERInitialized;
        uint256 queueERFirst;
        uint256 queueERLast;
        uint256 bridgeNativeReward;
        uint256 mintedTotally;
        uint256 nativeRewardUndistributed;
        IValidatorSetAuRa validatorSetContract;
        mapping(uint256 => uint256[]) epochsPoolGotRewardFor;
        mapping(address => bool) ercToNativeBridgeAllowed;
        mapping(uint256 => ExtraReceiverQueue) queueER;
        mapping(uint256 => mapping(uint256 => uint256)) epochPoolNativeReward;
        mapping(address => uint256) mintedForAccount;
        mapping(address => mapping(uint256 => uint256)) mintedForAccountInBlock;
        mapping(uint256 => uint256) mintedInBlock;
        mapping(uint256 => mapping(uint256 => uint256)) blocksCreated;
        mapping(address => uint256) mintedTotallyByBridge;
        mapping(uint256 => mapping(uint256 => uint256)) snapshotPoolTotalStakeAmount;
        mapping(uint256 => mapping(uint256 => uint256)) snapshotPoolValidatorStakeAmount;
        mapping(uint256 => uint256) validatorMinRewardPercent;
    }

    /// @dev Slot to store the block reward logic storage at.
    bytes32 internal constant BLOCK_REWARD_SLOT = keccak256("posdao.contracts.base.storage.BlockReward");

    function layout() internal pure returns (Layout storage $) {
        bytes32 slot = BLOCK_REWARD_SLOT;
        assembly {
            $.slot := slot
        }
    }
}
