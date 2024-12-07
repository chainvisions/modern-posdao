// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@solidstate/contracts/interfaces/IERC20.sol";
import {Ownable} from "@solady/contracts/auth/Ownable.sol";
import {SafeTransferLib} from "@solady/contracts/utils/SafeTransferLib.sol";
import {IBlockRewardAuRa} from "../interfaces/IBlockRewardAuRa.sol";
import {IRandomAuRa} from "../interfaces/IRandomAuRa.sol";
import {IStakingAuRa} from "../interfaces/IStakingAuRa.sol";
import {IValidatorSetAuRa} from "../interfaces/IValidatorSetAuRa.sol";
import {BlockRewardStorage, ExtraReceiverQueue} from "./storage/BlockRewardStorage.sol";

/// @title Block Reward Base (AuRa)
/// @author Chainvisions
/// @author Modified from POA Network's POSDAO implementation (https://github.com/poanetwork/posdao-contracts/blob/master/contracts/base/BlockRewardAuRaBase.sol)
/// @notice Handles the creation and distribution of POSDAO block rewards.

abstract contract BlockRewardAuRaBase is Ownable, IBlockRewardAuRa {
    /// @dev Ensures the caller is the `erc-to-native` bridge contract address.
    modifier onlyErcToNativeBridge() {
        require(BlockRewardStorage.layout().ercToNativeBridgeAllowed[msg.sender]);
        _;
    }

    /// @dev Ensures the `initialize` function was called before.
    modifier onlyInitialized() {
        require(isInitialized());
        _;
    }

    /// @dev Ensures the caller is the SYSTEM_ADDRESS.
    /// See https://openethereum.github.io/Block-Reward-Contract.html
    modifier onlySystem() {
        require(msg.sender == 0xffffFFFfFFffffffffffffffFfFFFfffFFFfFFfE);
        _;
    }

    /// @dev Ensures the caller is the StakingAuRa contract address.
    modifier onlyStakingContract() {
        require(msg.sender == address(BlockRewardStorage.layout().validatorSetContract.stakingContract()));
        _;
    }

    /// @dev Ensures the caller is the ValidatorSetAuRa contract address.
    modifier onlyValidatorSetContract() {
        require(msg.sender == address(BlockRewardStorage.layout().validatorSetContract));
        _;
    }

    // =============================================== Setters ========================================================

    /// @dev An alias for `addBridgeNativeRewardReceivers`
    /// (for backward compatibility with the previous bridge contract).
    function addBridgeNativeFeeReceivers(uint256 _amount) external {
        addBridgeNativeRewardReceivers(_amount);
    }

    /// @dev Called by the `erc-to-native` bridge contract when a portion of the bridge fee/reward should be minted
    /// and distributed to participants (validators and their delegators) in native coins. The specified amount
    /// is used by the `_distributeRewards` function.
    /// @param _amount The fee/reward amount distributed to participants.
    function addBridgeNativeRewardReceivers(uint256 _amount) public onlyErcToNativeBridge {
        BlockRewardStorage.Layout storage $ = BlockRewardStorage.layout();
        require(_amount != 0);
        $.bridgeNativeReward += _amount;
        emit BridgeNativeRewardAdded(_amount, $.bridgeNativeReward, msg.sender);
    }

    /// @dev Called by the `erc-to-native` bridge contract when the bridge needs to mint a specified amount of native
    /// coins for a specified address using the `reward` function.
    /// @param _amount The amount of native coins which must be minted for the `_receiver` address.
    /// @param _receiver The address for which the `_amount` of native coins must be minted.
    function addExtraReceiver(uint256 _amount, address _receiver) external onlyErcToNativeBridge {
        require(_amount != 0);
        require(BlockRewardStorage.layout().queueERInitialized);
        _enqueueExtraReceiver(_amount, _receiver, msg.sender);
        emit AddedReceiver(_amount, _receiver, msg.sender);
    }

    /// @dev Called by the `ValidatorSetAuRa.finalizeChange` to clear the values in
    /// the `blocksCreated` mapping for the current staking epoch and a new validator set.
    function clearBlocksCreated() external onlyValidatorSetContract {
        BlockRewardStorage.Layout storage $ = BlockRewardStorage.layout();
        IStakingAuRa stakingContract = IStakingAuRa($.validatorSetContract.stakingContract());
        uint256 stakingEpoch = stakingContract.stakingEpoch();
        uint256[] memory validators = $.validatorSetContract.getValidatorsIds();
        for (uint256 i = 0; i < validators.length; i++) {
            $.blocksCreated[stakingEpoch][validators[i]] = 0;
        }
    }

    /// @dev Initializes the contract at network startup.
    /// Can only be called by the constructor of the `InitializerAuRa` contract or owner.
    /// @param _validatorSet The address of the `ValidatorSetAuRa` contract.
    /// @param _prevBlockReward The address of the previous BlockReward contract
    /// (for statistics migration purposes).
    function initialize(address _validatorSet, address _prevBlockReward) external {
        BlockRewardStorage.Layout storage $ = BlockRewardStorage.layout();
        require(_getCurrentBlockNumber() == 0 || msg.sender == owner());
        require(!isInitialized());
        require(_validatorSet != address(0));
        $.validatorSetContract = IValidatorSetAuRa(_validatorSet);
        $.validatorMinRewardPercent[0] = VALIDATOR_MIN_REWARD_PERCENT;
        $.prevBlockRewardContract = IBlockRewardAuRa(_prevBlockReward);
    }

    /// @dev Called by the validator's node when producing and closing a block,
    /// see https://openethereum.github.io/Block-Reward-Contract.html.
    /// This function performs all of the automatic operations needed for controlling numbers revealing by validators,
    /// accumulating block producing statistics, starting a new staking epoch, snapshotting staking amounts
    /// for the upcoming staking epoch, rewards distributing at the end of a staking epoch, and minting
    /// native coins needed for the `erc-to-native` bridge.
    /// The function has unlimited gas (according to OpenEthereum and/or Nethermind client code).
    function reward(address[] calldata benefactors, uint16[] calldata kind)
        external
        onlySystem
        returns (address[] memory receiversNative, uint256[] memory rewardsNative)
    {
        BlockRewardStorage.Layout storage $ = BlockRewardStorage.layout();
        if (benefactors.length != kind.length || benefactors.length != 1 || kind[0] != 0) {
            return (new address[](0), new uint256[](0));
        }

        // Check if the validator is existed
        if ($.validatorSetContract == IValidatorSetAuRa(address(0))) {
            return (new address[](0), new uint256[](0));
        }

        // Check the current validators at the end of each collection round whether
        // they revealed their numbers, and remove a validator as a malicious if needed
        IRandomAuRa($.validatorSetContract.randomContract()).onFinishCollectRound();

        // Initialize the extra receivers queue
        if (!$.queueERInitialized) {
            $.queueERFirst = 1;
            $.queueERLast = 0;
            $.queueERInitialized = true;

            // Migrate minting statistics for erc-to-native bridges
            // from the `_prevBlockRewardContract`
            _migrateMintingStatistics();
        }

        uint256 bridgeQueueLimit = 100;
        IStakingAuRa stakingContract = IStakingAuRa($.validatorSetContract.stakingContract());
        uint256 stakingEpoch = stakingContract.stakingEpoch();
        uint256 stakingEpochEndBlock = stakingContract.stakingEpochEndBlock();
        uint256 nativeTotalRewardAmount = 0;

        if ($.validatorSetContract.validatorSetApplyBlock() != 0) {
            if (stakingEpoch != 0 && !$.validatorSetContract.isValidatorBanned(benefactors[0])) {
                // Accumulate blocks producing statistics for each of the
                // active validators during the current staking epoch. This
                // statistics is used by the `_distributeRewards` function
                uint256 poolId = $.validatorSetContract.idByMiningAddress(benefactors[0]);
                $.blocksCreated[stakingEpoch][poolId]++;
            }
        }

        if (_getCurrentBlockNumber() == stakingEpochEndBlock) {
            // Distribute rewards among validator pools
            if (stakingEpoch != 0) {
                nativeTotalRewardAmount = _distributeRewards(stakingContract, stakingEpoch, stakingEpochEndBlock);
            }

            // Choose new validators
            $.validatorSetContract.newValidatorSet();

            // Snapshot total amounts staked into the pools
            uint256 i;
            uint256 nextStakingEpoch = stakingEpoch + 1;
            uint256[] memory miningPoolIds;

            // We need to remember the total staked amounts for the pending pool ids
            // for the possible case when these pending ids are finalized
            // by the `ValidatorSetAuRa.finalizeChange` function and thus become validators
            miningPoolIds = $.validatorSetContract.getPendingValidatorsIds();
            for (i = 0; i < miningPoolIds.length; i++) {
                _snapshotPoolStakeAmounts(stakingContract, nextStakingEpoch, miningPoolIds[i]);
            }

            // We need to remember the total staked amounts for the current validators
            // for the possible case when these validators continue to be validators
            // throughout the upcoming staking epoch (if the new validator set is not finalized
            // for some reason)
            miningPoolIds = $.validatorSetContract.getValidatorsIds();
            for (i = 0; i < miningPoolIds.length; i++) {
                _snapshotPoolStakeAmounts(stakingContract, nextStakingEpoch, miningPoolIds[i]);
            }

            // We need to remember the total staked amounts for the ids currently
            // being finalized but not yet finalized (i.e. the `InitiateChange` event is emitted
            // for them but not yet handled by validator nodes thus the `ValidatorSetAuRa.finalizeChange`
            // function is not called yet) for the possible case when these ids finally
            // become validators on the upcoming staking epoch
            miningPoolIds = $.validatorSetContract.validatorsToBeFinalizedIds();
            for (i = 0; i < miningPoolIds.length; i++) {
                _snapshotPoolStakeAmounts(stakingContract, nextStakingEpoch, miningPoolIds[i]);
            }

            // Remember validator's min reward percent for the upcoming staking epoch
            $.validatorMinRewardPercent[nextStakingEpoch] = VALIDATOR_MIN_REWARD_PERCENT;

            // Pause bridge for this block
            bridgeQueueLimit = 0;
        }

        // Mint native coins if needed
        return _mintNativeCoins(nativeTotalRewardAmount, bridgeQueueLimit);
    }

    /// @dev Sets the array of `erc-to-native` bridge addresses which are allowed to call some of the functions with
    /// the `onlyErcToNativeBridge` modifier. This setter can only be called by the `owner`.
    /// @param _bridgesAllowed The array of bridge addresses.
    function setErcToNativeBridgesAllowed(address[] calldata _bridgesAllowed) external onlyOwner onlyInitialized {
        BlockRewardStorage.Layout storage $ = BlockRewardStorage.layout();
        uint256 i;

        for (i; i < $.ercToNativeBridgesAllowed.length;) {
            $.ercToNativeBridgeAllowed[$.ercToNativeBridgesAllowed[i]] = false;
            // forgefmt: disable-next-line
            unchecked { ++i; }
        }

        $.ercToNativeBridgesAllowed = _bridgesAllowed;

        for (i = 0; i < _bridgesAllowed.length;) {
            $.ercToNativeBridgeAllowed[_bridgesAllowed[i]] = true;
            // forgefmt: disable-next-line
            unchecked { ++i; }
        }
    }

    // =============================================== Getters ========================================================

    /// @dev Returns an identifier for the bridge contract so that the latter could
    /// ensure it works with the BlockReward contract.
    function blockRewardContractId() public pure returns (bytes4) {
        return 0x0d35a7ca; // bytes4(keccak256("blockReward"))
    }

    /// @dev Calculates the current total reward in native coins which is going to be distributed
    /// among validator pools once the current staking epoch finishes. Its value can differ
    /// from block to block since the reward can increase in time due to bridge's fees.
    /// Used by the `_distributeNativeRewards` internal function but can also be used by
    /// any external user.
    /// @param _stakingContract The address of StakingAuRa contract.
    /// @param _stakingEpoch The number of the current staking epoch.
    /// @param _totalRewardShareNum The value returned by the `_rewardShareNumDenom` internal function.
    /// Ignored if the `_totalRewardShareDenom` param is zero.
    /// @param _totalRewardShareDenom The value returned by the `_rewardShareNumDenom` internal function.
    /// Set it to zero to calculate `_totalRewardShareNum` and `_totalRewardShareDenom` automatically.
    /// @param _validators The array of the current validators. Leave it empty to get the array automatically.
    /// @return `uint256 rewardToDistribute` - The current total reward in native coins to distribute.
    /// `uint256 totalReward` - The current total reward in native coins. Can be greater or equal
    /// to `rewardToDistribute` depending on chain's health (how soon validator set change was finalized after
    /// beginning of staking epoch). Usually equals to `rewardToDistribute`.
    /// Used internally by the `_distributeNativeRewards` function.
    function currentNativeRewardToDistribute(
        IStakingAuRa _stakingContract,
        uint256 _stakingEpoch,
        uint256 _totalRewardShareNum,
        uint256 _totalRewardShareDenom,
        uint256[] memory _validators
    ) public view returns (uint256, uint256) {
        return _currentRewardToDistribute(
            _getTotalNativeReward(_stakingEpoch, _validators),
            _stakingContract,
            _totalRewardShareNum,
            _totalRewardShareDenom
        );
    }

    /// @dev Calculates and returns an array of validator pool rewards. Each returned item represents a pool reward
    /// for each corresponding item returned by `ValidatorSetAuRa.getValidators` getter.
    /// Used by the `_distributeNativeRewards` and `_distributeTokenRewards` internal functions
    /// but can also be used by any external user.
    /// @param _rewardToDistribute The amount to distribute calculated by the `currentNativeRewardToDistribute`
    /// or `currentTokenRewardToDistribute` functions.
    /// @param _blocksCreatedShareNum The array returned by the `_blocksShareNumDenom` internal function.
    /// Ignored if `_blocksCreatedShareDenom` is zero.
    /// @param _blocksCreatedShareDenom The value returned by the `_blocksShareNumDenom` internal function.
    /// Set it to zero to calculate `_blocksCreatedShareNum` and `_blocksCreatedShareDenom` automatically.
    /// @param _stakingEpoch The number of the current staking epoch.
    function currentPoolRewards(
        uint256 _rewardToDistribute,
        uint256[] memory _blocksCreatedShareNum,
        uint256 _blocksCreatedShareDenom,
        uint256 _stakingEpoch
    ) public view returns (uint256[] memory) {
        uint256[] memory poolRewards;
        if (_blocksCreatedShareDenom == 0) {
            (_blocksCreatedShareNum, _blocksCreatedShareDenom) = _blocksShareNumDenom(_stakingEpoch, new uint256[](0));
        }
        if (_rewardToDistribute == 0 || _blocksCreatedShareDenom == 0) {
            poolRewards = new uint256[](0);
        } else {
            poolRewards = new uint256[](_blocksCreatedShareNum.length);
            for (uint256 i; i < _blocksCreatedShareNum.length;) {
                poolRewards[i] = _rewardToDistribute * _blocksCreatedShareNum[i] / _blocksCreatedShareDenom;
                // forgefmt: disable-next-line
                unchecked { ++i; }
            }
        }
        return poolRewards;
    }

    /// @dev Returns an array of epoch numbers for which the specified pool got a non-zero reward.
    function epochsPoolGotRewardFor(uint256 _poolId) public view returns (uint256[] memory) {
        return BlockRewardStorage.layout().epochsPoolGotRewardFor[_poolId];
    }

    /// @dev Returns the array of `erc-to-native` bridge addresses set by the `setErcToNativeBridgesAllowed` setter.
    function ercToNativeBridgesAllowed() public view returns (address[] memory) {
        return BlockRewardStorage.layout().ercToNativeBridgesAllowed;
    }

    /// @dev Returns the current size of the address queue created by the `addExtraReceiver` function.
    function extraReceiversQueueSize() public view returns (uint256) {
        BlockRewardStorage.Layout storage $ = BlockRewardStorage.layout();
        return $.queueERLast + 1 - $.queueERFirst;
    }

    /// @dev Returns a boolean flag indicating if the `initialize` function has been called.
    function isInitialized() public view returns (bool) {
        return BlockRewardStorage.layout().validatorSetContract != IValidatorSetAuRa(address(0));
    }

    /// @dev Prevents sending tokens directly to the `BlockRewardAuRa` contract address
    /// by the `ERC677BridgeTokenRewardable.transferAndCall` function.
    function onTokenTransfer(address, uint256, bytes memory) public pure returns (bool) {
        revert();
    }

    /// @dev Returns an array of epoch numbers for which the specified staker
    /// can claim a reward from the specified pool by the `StakingAuRa.claimReward` function.
    /// @param _poolStakingAddress The pool staking address.
    /// @param _staker The staker's address (delegator or candidate/validator).
    function epochsToClaimRewardFrom(address _poolStakingAddress, address _staker)
        public
        view
        returns (uint256[] memory epochsToClaimFrom)
    {
        BlockRewardStorage.Layout storage $ = BlockRewardStorage.layout();
        uint256 poolId = $.validatorSetContract.idByStakingAddress(_poolStakingAddress);

        require(_poolStakingAddress != address(0));
        require(_staker != address(0));
        require(poolId != 0);

        IStakingAuRa stakingContract = IStakingAuRa($.validatorSetContract.stakingContract());
        address delegatorOrZero = (_staker != _poolStakingAddress) ? _staker : address(0);
        uint256 firstEpoch;
        uint256 lastEpoch;

        if (delegatorOrZero != address(0)) {
            // if this is a delegator
            firstEpoch = stakingContract.stakeFirstEpoch(poolId, delegatorOrZero);
            if (firstEpoch == 0) {
                return (new uint256[](0));
            }
            lastEpoch = stakingContract.stakeLastEpoch(poolId, delegatorOrZero);
        }

        uint256[] storage epochs = $.epochsPoolGotRewardFor[poolId];
        uint256 length = epochs.length;

        uint256[] memory tmp = new uint256[](length);
        uint256 tmpLength = 0;
        uint256 i;

        for (i; i < length;) {
            uint256 epoch = epochs[i];
            if (delegatorOrZero != address(0)) {
                // if this is a delegator
                if (epoch < firstEpoch) {
                    // If the delegator staked for the first time before
                    // the `epoch`, skip this staking epoch
                    continue;
                }
                if (lastEpoch <= epoch && lastEpoch != 0) {
                    // If the delegator withdrew all their stake before the `epoch`,
                    // don't check this and following epochs since it makes no sense
                    break;
                }
            }
            if (!stakingContract.rewardWasTaken(poolId, delegatorOrZero, epoch)) {
                tmp[tmpLength++] = epoch;
            }

            // forgefmt: disable-next-line
            unchecked { ++i; }
        }

        epochsToClaimFrom = new uint256[](tmpLength);
        for (i; i < tmpLength;) {
            epochsToClaimFrom[i] = tmp[i];
            // forgefmt: disable-next-line
            unchecked { ++i; }
        }
    }

    /// @dev Returns the reward coefficient for the specified validator. The given value should be divided by 10000
    /// to get the value of the reward percent (since EVM doesn't support float values). If the specified pool id
    /// is an id of a candidate that is not about to be a validator on the current staking epoch,
    /// the potentially possible reward coefficient is returned.
    /// @param _poolId The id of the validator/candidate pool for which the getter must return the coefficient.
    function validatorRewardPercent(uint256 _poolId) public view returns (uint256) {
        BlockRewardStorage.Layout storage $ = BlockRewardStorage.layout();
        IStakingAuRa stakingContract = IStakingAuRa($.validatorSetContract.stakingContract());
        uint256 stakingEpoch = stakingContract.stakingEpoch();

        if (stakingEpoch == 0) {
            // No one gets a reward for the initial staking epoch, so we return zero
            return 0;
        }

        if ($.validatorSetContract.isValidatorById(_poolId)) {
            // For the validator we return the coefficient based on
            // snapshotted total amounts
            return validatorShare(
                stakingEpoch,
                $.snapshotPoolValidatorStakeAmount[stakingEpoch][_poolId],
                $.snapshotPoolTotalStakeAmount[stakingEpoch][_poolId],
                REWARD_PERCENT_MULTIPLIER
            );
        }

        if ($.validatorSetContract.validatorSetApplyBlock() == 0) {
            // For the candidate that is about to be a validator on the current
            // staking epoch we return the coefficient based on snapshotted total amounts

            uint256[] memory poolIds;
            uint256 i;

            poolIds = $.validatorSetContract.getPendingValidatorsIds();
            for (i; i < poolIds.length;) {
                if (_poolId == poolIds[i]) {
                    return validatorShare(
                        stakingEpoch,
                        $.snapshotPoolValidatorStakeAmount[stakingEpoch][_poolId],
                        $.snapshotPoolTotalStakeAmount[stakingEpoch][_poolId],
                        REWARD_PERCENT_MULTIPLIER
                    );
                }
                // forgefmt: disable-next-line
                unchecked { ++i; }
            }

            poolIds = $.validatorSetContract.validatorsToBeFinalizedIds();
            for (i = 0; i < poolIds.length;) {
                if (_poolId == poolIds[i]) {
                    return validatorShare(
                        stakingEpoch,
                        $.snapshotPoolValidatorStakeAmount[stakingEpoch][_poolId],
                        $.snapshotPoolTotalStakeAmount[stakingEpoch][_poolId],
                        REWARD_PERCENT_MULTIPLIER
                    );
                }
                // forgefmt: disable-next-line
                unchecked { ++i; }
            }
        }

        // For the candidate that is not about to be a validator on the current staking epoch,
        // we return the potentially possible reward coefficient
        return validatorShare(
            stakingEpoch,
            stakingContract.stakeAmount(_poolId, address(0)),
            stakingContract.stakeAmountTotal(_poolId),
            REWARD_PERCENT_MULTIPLIER
        );
    }

    /// @dev Calculates delegator's share for the given pool reward amount and the specified staking epoch.
    /// Used by the `StakingAuRa.claimReward` function.
    /// @param _stakingEpoch The number of staking epoch.
    /// @param _delegatorStaked The amount staked by a delegator.
    /// @param _validatorStaked The amount staked by a validator.
    /// @param _totalStaked The total amount staked by a validator and their delegators.
    /// @param _poolReward The value of pool reward.
    function delegatorShare(
        uint256 _stakingEpoch,
        uint256 _delegatorStaked,
        uint256 _validatorStaked,
        uint256 _totalStaked,
        uint256 _poolReward
    ) public view returns (uint256) {
        if (_delegatorStaked == 0 || _validatorStaked == 0 || _totalStaked == 0) {
            return 0;
        }
        uint256 share = 0;
        uint256 delegatorsStaked = _totalStaked >= _validatorStaked ? _totalStaked - _validatorStaked : 0;
        if (delegatorsStaked == 0) {
            return 0;
        }
        uint256 validatorMinPercent = BlockRewardStorage.layout().validatorMinRewardPercent[_stakingEpoch];
        if (_validatorStaked * (100 - validatorMinPercent) > delegatorsStaked * validatorMinPercent) {
            // Validator has more than validatorMinPercent %
            share = _poolReward * _delegatorStaked / _totalStaked;
        } else {
            // Validator has validatorMinPercent %
            share = _poolReward * _delegatorStaked * (100 - validatorMinPercent) / (delegatorsStaked * 100);
        }
        return share;
    }

    /// @dev Calculates validator's share for the given pool reward amount and the specified staking epoch.
    /// Used by the `validatorRewardPercent` and `StakingAuRa.claimReward` functions.
    /// @param _stakingEpoch The number of staking epoch.
    /// @param _validatorStaked The amount staked by a validator.
    /// @param _totalStaked The total amount staked by a validator and their delegators.
    /// @param _poolReward The value of pool reward.
    function validatorShare(uint256 _stakingEpoch, uint256 _validatorStaked, uint256 _totalStaked, uint256 _poolReward)
        public
        view
        returns (uint256)
    {
        if (_validatorStaked == 0 || _totalStaked == 0) {
            return 0;
        }
        uint256 share = 0;
        uint256 delegatorsStaked = _totalStaked >= _validatorStaked ? _totalStaked - _validatorStaked : 0;
        uint256 validatorMinPercent = BlockRewardStorage.layout().validatorMinRewardPercent[_stakingEpoch];
        if (_validatorStaked * (100 - validatorMinPercent) > delegatorsStaked * validatorMinPercent) {
            // Validator has more than validatorMinPercent %
            share = _poolReward * _validatorStaked / _totalStaked;
        } else {
            // Validator has validatorMinPercent %
            share = _poolReward * validatorMinPercent / 100;
        }
        return share;
    }

    // ============================================== Internal ========================================================

    uint256 internal constant VALIDATOR_MIN_REWARD_PERCENT = 0; // 0%
    uint256 internal constant REWARD_PERCENT_MULTIPLIER = 1000000;

    function _coinInflationAmount(uint256, uint256[] memory) internal view virtual returns (uint256);

    /// @dev Calculates the current total reward to distribute among validator pools
    /// once the current staking epoch finishes. Based on the `_totalReward` value calculated
    /// by `_getTotalNativeReward` or `_getTotalTokenReward` functions.
    /// Used by the `currentNativeRewardToDistribute` and `currentTokenRewardToDistribute` functions.
    /// @param _totalReward The total reward calculated by `_getTotalNativeReward`
    /// or `_getTotalTokenReward` internal function.
    /// @param _stakingContract The address of StakingAuRa contract.
    /// @param _totalRewardShareNum The value returned by the `_rewardShareNumDenom` internal function.
    /// Ignored if the `_totalRewardShareDenom` param is zero.
    /// @param _totalRewardShareDenom The value returned by the `_rewardShareNumDenom` internal function.
    /// Set it to zero to calculate `_totalRewardShareNum` and `_totalRewardShareDenom` automatically.
    /// @return `uint256 rewardToDistribute` - The current total reward to distribute.
    /// `uint256 totalReward` - Duplicates the `_totalReward` input parameter.
    function _currentRewardToDistribute(
        uint256 _totalReward,
        IStakingAuRa _stakingContract,
        uint256 _totalRewardShareNum,
        uint256 _totalRewardShareDenom
    ) internal view returns (uint256, uint256) {
        if (_totalRewardShareDenom == 0) {
            (_totalRewardShareNum, _totalRewardShareDenom) =
                _rewardShareNumDenom(_stakingContract, _stakingContract.stakingEpochEndBlock());
        }

        uint256 rewardToDistribute =
            _totalRewardShareDenom != 0 ? _totalReward * _totalRewardShareNum / _totalRewardShareDenom : 0;

        return (rewardToDistribute, _totalReward);
    }

    /// @dev Distributes rewards in native coins among pools at the latest block of a staking epoch.
    /// This function is called by the `_distributeRewards` function.
    /// @param _stakingContract The address of the StakingAuRa contract.
    /// @param _stakingEpoch The number of the current staking epoch.
    /// @param _totalRewardShareNum Numerator of the total reward share.
    /// @param _totalRewardShareDenom Denominator of the total reward share.
    /// @param _validators The array of the current validators (their pool ids).
    /// @param _blocksCreatedShareNum Numerators of blockCreated share for each of the validators.
    /// @param _blocksCreatedShareDenom Denominator of blockCreated share.
    /// @return Returns the amount of native coins which need to be minted.
    function _distributeNativeRewards(
        IStakingAuRa _stakingContract,
        uint256 _stakingEpoch,
        uint256 _totalRewardShareNum,
        uint256 _totalRewardShareDenom,
        uint256[] memory _validators,
        uint256[] memory _blocksCreatedShareNum,
        uint256 _blocksCreatedShareDenom
    ) internal returns (uint256) {
        BlockRewardStorage.Layout storage $ = BlockRewardStorage.layout();
        (uint256 rewardToDistribute, uint256 totalReward) = currentNativeRewardToDistribute(
            _stakingContract, _stakingEpoch, _totalRewardShareNum, _totalRewardShareDenom, _validators
        );

        if (totalReward == 0) {
            return 0;
        }

        $.bridgeNativeReward = 0;
        uint256 distributedAmount = 0;
        uint256[] memory poolReward =
            currentPoolRewards(rewardToDistribute, _blocksCreatedShareNum, _blocksCreatedShareDenom, _stakingEpoch);
        if (poolReward.length == _validators.length) {
            for (uint256 i; i < _validators.length;) {
                uint256 poolId = _validators[i];
                $.epochPoolNativeReward[_stakingEpoch][poolId] = poolReward[i];
                distributedAmount += poolReward[i];
                if (poolReward[i] != 0) {
                    $.epochsPoolGotRewardFor[poolId].push(_stakingEpoch);
                }
                // forgefmt: disable-next-line
                unchecked { ++i; }
            }
        }

        $.nativeRewardUndistributed = totalReward - distributedAmount;

        return distributedAmount;
    }

    function _distributeTokenRewards(address, uint256, uint256, uint256, uint256[] memory, uint256[] memory, uint256)
        internal
        virtual;

    /// @dev Calculates the current total reward in native coins.
    /// Used by the `currentNativeRewardToDistribute` function.
    /// @param _stakingEpoch The number of the current staking epoch.
    /// @param _validators The array of the current validators.
    /// Can be empty to retrieve the array automatically inside
    /// the `_inflationAmount` internal function.
    function _getTotalNativeReward(uint256 _stakingEpoch, uint256[] memory _validators)
        internal
        view
        returns (uint256 totalReward)
    {
        BlockRewardStorage.Layout storage $ = BlockRewardStorage.layout();
        totalReward =
            $.bridgeNativeReward + $.nativeRewardUndistributed + _coinInflationAmount(_stakingEpoch, _validators);
    }

    /// @dev Calculates and returns values which define a share of total reward
    /// needed to be distributed among validator pools at the end of staking epoch.
    /// Used by the `_currentRewardToDistribute` and `_distributeRewards` functions.
    /// When validators behave correctly, it returns 100% share of total reward.
    /// When, e.g. validators finalized a new validator set at the middle of staking epoch
    /// for some reason, the share will be 50%. And so on.
    /// @param _stakingContract The address of the StakingAuRa contract.
    /// @param _stakingEpochEndBlock The latest block of the current staking epoch
    /// returned by the `StakingAuRa.stakingEpochEndBlock` getter.
    /// @return `uint256 totalRewardShareNum` - numerator of the share.
    /// `uint256 totalRewardShareDenom` - denominator of the share.
    function _rewardShareNumDenom(IStakingAuRa _stakingContract, uint256 _stakingEpochEndBlock)
        internal
        view
        returns (uint256, uint256)
    {
        BlockRewardStorage.Layout storage $ = BlockRewardStorage.layout();
        uint256 totalRewardShareNum = 0;
        uint256 totalRewardShareDenom = 1;
        uint256 realFinalizeBlock = $.validatorSetContract.validatorSetApplyBlock();
        if (realFinalizeBlock != 0) {
            uint256 idealFinalizeBlock =
                _stakingContract.stakingEpochStartBlock() + $.validatorSetContract.MAX_VALIDATORS() * 2 / 3 + 1;

            if (realFinalizeBlock < idealFinalizeBlock) {
                realFinalizeBlock = idealFinalizeBlock;
            }

            totalRewardShareNum = _stakingEpochEndBlock - realFinalizeBlock + 1;
            totalRewardShareDenom = _stakingEpochEndBlock - idealFinalizeBlock + 1;
        }
        return (totalRewardShareNum, totalRewardShareDenom);
    }

    /// @dev Calculates and returns values defining a share of the total number of created blocks
    /// during the current staking epoch for each validator.
    /// Used by the `currentPoolRewards` and `_distributeRewards` functions to determine
    /// a pool reward for each validator depending on how many blocks the validator created
    /// during the current staking epoch.
    /// @param _stakingEpoch The number of the current staking epoch.
    /// @param _validators The array of the current validators. Leave it empty to get the array automatically.
    /// @return `uint256[] blocksCreatedShareNum` - array of numerators of the share for each validator.
    /// Each item corresponds to the item of the array returned by the `ValidatorSetAuRa.getValidators` getter.
    /// `uint256 blocksCreatedShareDenom` - denominator for the shares.
    function _blocksShareNumDenom(uint256 _stakingEpoch, uint256[] memory _validators)
        internal
        view
        returns (uint256[] memory, uint256)
    {
        BlockRewardStorage.Layout storage $ = BlockRewardStorage.layout();
        if (_validators.length == 0) {
            _validators = $.validatorSetContract.getValidatorsIds();
        }
        uint256[] memory blocksCreatedShareNum = new uint256[](_validators.length);
        uint256 blocksCreatedShareDenom = 0;
        for (uint256 i; i < _validators.length;) {
            uint256 poolId = _validators[i];
            if (
                $.snapshotPoolValidatorStakeAmount[_stakingEpoch][poolId] != 0
                    && !$.validatorSetContract.isValidatorIdBanned(poolId)
            ) {
                blocksCreatedShareNum[i] = $.blocksCreated[_stakingEpoch][poolId];
            } else {
                blocksCreatedShareNum[i] = 0;
            }
            blocksCreatedShareDenom += blocksCreatedShareNum[i];

            // forgefmt: disable-next-line
            unchecked { ++i; }
        }
        return (blocksCreatedShareNum, blocksCreatedShareDenom);
    }

    /// @dev Distributes rewards among pools at the latest block of a staking epoch.
    /// This function is called by the `reward` function.
    /// @param _stakingContract The address of the StakingAuRa contract.
    /// @param _stakingEpoch The number of the current staking epoch.
    /// @param _stakingEpochEndBlock The number of the latest block of the current staking epoch.
    /// @return nativeTotalRewardAmount Returns the reward amount in native coins needed to be minted
    /// and accrued to the balance of this contract.
    function _distributeRewards(IStakingAuRa _stakingContract, uint256 _stakingEpoch, uint256 _stakingEpochEndBlock)
        internal
        returns (uint256 nativeTotalRewardAmount)
    {
        uint256[] memory validators = BlockRewardStorage.layout().validatorSetContract.getValidatorsIds();

        // Determine shares
        (uint256 totalRewardShareNum, uint256 totalRewardShareDenom) =
            _rewardShareNumDenom(_stakingContract, _stakingEpochEndBlock);
        (uint256[] memory blocksCreatedShareNum, uint256 blocksCreatedShareDenom) =
            _blocksShareNumDenom(_stakingEpoch, validators);

        // Distribute native coins among pools
        nativeTotalRewardAmount = _distributeNativeRewards(
            _stakingContract,
            _stakingEpoch,
            totalRewardShareNum,
            totalRewardShareDenom,
            validators,
            blocksCreatedShareNum,
            blocksCreatedShareDenom
        );

        // Distribute ERC tokens among pools
        _distributeTokenRewards(
            address(_stakingContract),
            _stakingEpoch,
            totalRewardShareNum,
            totalRewardShareDenom,
            validators,
            blocksCreatedShareNum,
            blocksCreatedShareDenom
        );
    }

    /// @dev Copies the minting statistics from the previous BlockReward contract
    /// for the `mintedTotally` and `mintedTotallyByBridge` getters.
    /// Called only once by the `reward` function.
    function _migrateMintingStatistics() internal {
        BlockRewardStorage.Layout storage $ = BlockRewardStorage.layout();
        if ($.prevBlockRewardContract == IBlockRewardAuRa(address(0))) {
            return;
        }
        for (uint256 i; i < $.ercToNativeBridgesAllowed.length;) {
            address bridge = $.ercToNativeBridgesAllowed[i];
            $.mintedTotallyByBridge[bridge] = $.prevBlockRewardContract.mintedTotallyByBridge(bridge);
            // forgefmt: disable-next-line
            unchecked { ++i ;}
        }
        if ($.ercToNativeBridgesAllowed.length != 0) {
            $.mintedTotally = $.prevBlockRewardContract.mintedTotally();
        }
    }

    /// @dev Returns the current block number. Needed mostly for unit tests.
    function _getCurrentBlockNumber() internal view returns (uint256) {
        return block.number;
    }

    /// @dev Calculates and returns inflation amount based on the specified
    /// staking epoch, validator set, and inflation rate.
    /// Used by `_coinInflationAmount` and `_distributeTokenRewards` functions.
    /// @param _stakingEpoch The number of the current staking epoch.
    /// @param _validators The array of the current validators (their pool ids).
    /// If empty, the function gets the array itself with ValidatorSetAuRa.getValidatorsIds().
    /// @param _inflationRate Inflation rate.
    function _inflationAmount(uint256 _stakingEpoch, uint256[] memory _validators, uint256 _inflationRate)
        internal
        view
        returns (uint256)
    {
        BlockRewardStorage.Layout storage $ = BlockRewardStorage.layout();
        if (_inflationRate == 0) return 0;
        if (_validators.length == 0) {
            _validators = $.validatorSetContract.getValidatorsIds();
        }
        uint256 snapshotTotalStakeAmount = 0;
        for (uint256 i; i < _validators.length;) {
            snapshotTotalStakeAmount += $.snapshotPoolTotalStakeAmount[_stakingEpoch][_validators[i]];
            // forgefmt: disable-next-line
            unchecked { ++i; }
        }
        return snapshotTotalStakeAmount * _inflationRate / 1 ether;
    }

    /// @dev Joins two native coin receiver elements into a single set and returns the result
    /// to the `reward` function: the first element comes from the `erc-to-native` bridge fee distribution,
    /// the second - from the `erc-to-native` bridge when native coins are minted for the specified addresses.
    /// Dequeues the addresses enqueued with the `addExtraReceiver` function by the `erc-to-native` bridge.
    /// Accumulates minting statistics for the `erc-to-native` bridges.
    /// @param _nativeTotalRewardAmount The native coins amount which should be accrued to the balance
    /// of this contract (as a total reward for the finished staking epoch).
    /// @param _queueLimit Max number of addresses which can be dequeued from the queue formed by the
    /// `addExtraReceiver` function.
    function _mintNativeCoins(uint256 _nativeTotalRewardAmount, uint256 _queueLimit)
        internal
        returns (address[] memory receivers, uint256[] memory rewards)
    {
        uint256 extraLength = extraReceiversQueueSize();

        if (extraLength > _queueLimit) {
            extraLength = _queueLimit;
        }

        bool totalRewardNotEmpty = _nativeTotalRewardAmount != 0;

        receivers = new address[](extraLength + (totalRewardNotEmpty ? 1 : 0));
        rewards = new uint256[](receivers.length);

        for (uint256 i; i < extraLength;) {
            (uint256 amount, address receiver, address bridge) = _dequeueExtraReceiver();
            receivers[i] = receiver;
            rewards[i] = amount;
            _setMinted(amount, receiver, bridge);
            // forgefmt: disable-next-line
            unchecked { ++i; }
        }

        if (totalRewardNotEmpty) {
            receivers[extraLength] = address(this);
            rewards[extraLength] = _nativeTotalRewardAmount;
        }

        emit MintedNative(receivers, rewards);

        return (receivers, rewards);
    }

    /// @dev Dequeues the information about the native coins receiver enqueued with the `addExtraReceiver`
    /// function by the `erc-to-native` bridge. This function is used by `_mintNativeCoins`.
    /// @return amount - The amount to be minted for the `receiver` address.
    /// receiver - The address for which the `amount` is minted.
    /// bridge - The address of the bridge contract which called the `addExtraReceiver` function.
    function _dequeueExtraReceiver() internal returns (uint256 amount, address receiver, address bridge) {
        BlockRewardStorage.Layout storage $ = BlockRewardStorage.layout();
        uint256 queueFirst = $.queueERFirst;
        uint256 queueLast = $.queueERLast;

        if (queueLast < queueFirst) {
            amount = 0;
            receiver = address(0);
            bridge = address(0);
        } else {
            amount = $.queueER[queueFirst].amount;
            receiver = $.queueER[queueFirst].receiver;
            bridge = $.queueER[queueFirst].bridge;
            delete $.queueER[queueFirst];
            $.queueERFirst++;
        }
    }

    /// @dev Enqueues the information about the receiver of native coins which must be minted for the
    /// specified `erc-to-native` bridge. This function is used by the `addExtraReceiver` function.
    /// @param _amount The amount of native coins which must be minted for the `_receiver` address.
    /// @param _receiver The address for which the `_amount` of native coins must be minted.
    /// @param _bridge The address of the bridge contract which requested the minting of native coins.
    function _enqueueExtraReceiver(uint256 _amount, address _receiver, address _bridge) internal {
        BlockRewardStorage.Layout storage $ = BlockRewardStorage.layout();
        uint256 queueLast = $.queueERLast + 1;
        $.queueER[queueLast] = ExtraReceiverQueue({amount: _amount, bridge: _bridge, receiver: _receiver});
        $.queueERLast = queueLast;
    }

    /// @dev Accumulates minting statistics for the `erc-to-native` bridge.
    /// This function is used by the `_mintNativeCoins` function.
    /// @param _amount The amount minted for the `_account` address.
    /// @param _account The address for which the `_amount` is minted.
    /// @param _bridge The address of the bridge contract which called the `addExtraReceiver` function.
    function _setMinted(uint256 _amount, address _account, address _bridge) internal {
        BlockRewardStorage.Layout storage $ = BlockRewardStorage.layout();
        uint256 blockNumber = _getCurrentBlockNumber();
        $.mintedForAccountInBlock[_account][blockNumber] = _amount;
        $.mintedForAccount[_account] += _amount;
        $.mintedInBlock[blockNumber] += _amount;
        $.mintedTotallyByBridge[_bridge] += _amount;
        $.mintedTotally += _amount;
    }

    /// @dev Makes snapshots of total amount staked into the specified pool
    /// before the specified staking epoch. Used by the `reward` function.
    /// @param _stakingContract The address of the `StakingAuRa` contract.
    /// @param _stakingEpoch The number of upcoming staking epoch.
    /// @param _poolId An id of the pool.
    function _snapshotPoolStakeAmounts(IStakingAuRa _stakingContract, uint256 _stakingEpoch, uint256 _poolId)
        internal
    {
        BlockRewardStorage.Layout storage $ = BlockRewardStorage.layout();
        if ($.snapshotPoolTotalStakeAmount[_stakingEpoch][_poolId] != 0) {
            return;
        }
        uint256 totalAmount = _stakingContract.stakeAmountTotal(_poolId);
        if (totalAmount == 0) {
            return;
        }
        $.snapshotPoolTotalStakeAmount[_stakingEpoch][_poolId] = totalAmount;
        $.snapshotPoolValidatorStakeAmount[_stakingEpoch][_poolId] = _stakingContract.stakeAmount(_poolId, address(0));
    }
}