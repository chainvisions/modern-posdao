// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {RedBlackTreeLib} from "@solady/contracts/utils/RedBlackTreeLib.sol";
import {Ownable} from "@solady/contracts/auth/Ownable.sol";

/// @title Transaction Priority
/// @author Chainvisions
/// @notice A contract for tracking transaction destinations and whitelisted senders
/// for handling exclusive transaction priority and gas prices for certain network interactions.
/// Mostly related to validator/signer interactions with the POSDAO contracts.

contract TxPriority is Ownable {
    using RedBlackTreeLib for *;

    /// @notice Data structure for tracking priority destination related info.
    struct Destination {
        /// @notice Target address of the destination. Either contract or EOA.
        address target;
        /// @notice Priority function signature of the destination. Can be `0x00000000` if an EOA.
        bytes4 fnSignature;
        /// @notice Minimum base fee for the transaction destination.
        uint256 value;
    }

    /// @notice Total amount of priority weights set for transactions.
    uint256 public weightsCount;

    /// @notice Target destination for a specific priority weight.
    mapping(uint256 => Destination) public destinationByWeight;

    /// @notice Weights for a specific destination and function signature.
    mapping(address => mapping(bytes4 => uint256)) public weightByDestination;

    /// @dev A sorted tree of weights for transaction destinations.
    RedBlackTreeLib.Tree internal _weightsTree;

    /// @dev An array of senders that are whitelisted to have priority txs.
    address[] internal _sendersWhitelist; // an array of whitelisted senders

    /// @dev An array of destinations for tracking their exclusive minimum base fee.
    Destination[] internal _minBaseFees; // an array of min gas price rules

    /// @dev Index at `_minBaseFees` for a specific destination and function signature.
    mapping(address => mapping(bytes4 => uint256)) internal _minBaseFeeIndex;

    event PrioritySet(address indexed target, bytes4 indexed fnSignature, uint256 weight);
    event SendersWhitelistSet(address[] whitelist);
    event MinGasPriceSet(address indexed target, bytes4 indexed fnSignature, uint256 minGasPrice);

    /// @notice TxPriority constructor.
    /// @param _owner Owner of the contract. Leave empty for `msg.sender`.
    constructor(address _owner) {
        _setOwner(_owner == address(0) ? msg.sender : _owner);
    }

    /// @notice Sets the priority for a specific transaction destination.
    /// @param _target Address to set the priority for transactions to.
    /// @param _fnSignature Signature of the function sent to `_target` that shoudl be prioritized.
    /// Transfers to EOAs can also be given priority by setting the function signature to `0x00000000`.
    /// @param _weight Weight of the priority for transactions to the specific destination.
    function setPriority(address _target, bytes4 _fnSignature, uint256 _weight) external onlyOwner {
        require(_target != address(0), "target cannot be 0");
        require(_weight != 0, "weight cannot be 0");
        uint256 foundWeight = weightByDestination[_target][_fnSignature];
        if (foundWeight != 0) {
            // Destination already exists in the tree
            if (foundWeight == _weight) {
                emit PrioritySet(_target, _fnSignature, _weight);
                return; // nothing changes, return
            }
            // Remove existing destination from the tree
            _weightsTree.remove(foundWeight);
            delete destinationByWeight[foundWeight];
        } else {
            // This is a new destination, increment counter
            weightsCount = weightsCount + 1;
        }
        _weightsTree.insert(_weight);
        destinationByWeight[_weight] = Destination(_target, _fnSignature, _weight);
        weightByDestination[_target][_fnSignature] = _weight;
        emit PrioritySet(_target, _fnSignature, _weight);
    }

    /// @notice Removes a specific transaction target destination / specific function from the priority list.
    /// @param _target Target contract/address to remove from the priority list.
    /// @param _fnSignature Target function signature to remove from priority.
    function removePriority(address _target, bytes4 _fnSignature) external onlyOwner {
        uint256 foundWeight = weightByDestination[_target][_fnSignature];
        require(foundWeight != 0, "destination does not exist"); // destination should exist

        _weightsTree.remove(foundWeight);

        delete weightByDestination[_target][_fnSignature];
        delete destinationByWeight[foundWeight];
        weightsCount = weightsCount - 1;

        emit PrioritySet(_target, _fnSignature, 0);
    }

    /// @notice Adds a list of senders to the transaction priority whitelist.
    /// @param _whitelist Array of senders to set as whitelisted for priority.
    function setSendersWhitelist(address[] calldata _whitelist) external onlyOwner {
        _sendersWhitelist = _whitelist;
        emit SendersWhitelistSet(_whitelist);
    }

    /// @notice Sets the minimum base fee for gas prices when sent to a specific transaction destination.
    /// @param _target Target destination to set the minimum base fee for.
    /// @param _fnSignature Function signature to set the exclusive base fee for. Can be `0x00000000` for EOA transfers.
    /// @param _minBaseFee Minimum base fee for sending transactions with the signature `_fnSignature` to `_target`.
    function setMinGasPrice(address _target, bytes4 _fnSignature, uint256 _minBaseFee) external onlyOwner {
        require(_target != address(0), "target cannot be 0");
        require(_minBaseFee != 0, "minGasPrice cannot be 0");

        uint256 index = _minBaseFeeIndex[_target][_fnSignature];

        if (
            _minBaseFees.length > index && _minBaseFees[index].target == _target
                && _minBaseFees[index].fnSignature == _fnSignature
        ) {
            _minBaseFees[index].value = _minBaseFee;
        } else {
            _minBaseFeeIndex[_target][_fnSignature] = _minBaseFees.length;
            _minBaseFees.push(Destination(_target, _fnSignature, _minBaseFee));
        }

        emit MinGasPriceSet(_target, _fnSignature, _minBaseFee);
    }

    /// @notice Removes the exclusive minimum base fee for a specific transaction destination.
    /// @param _target Target to remove the exclusive price for.
    /// @param _fnSignature Function signature
    function removeMinGasPrice(address _target, bytes4 _fnSignature) external onlyOwner {
        uint256 index = _minBaseFeeIndex[_target][_fnSignature];

        if (
            _minBaseFees.length > index && _minBaseFees[index].target == _target
                && _minBaseFees[index].fnSignature == _fnSignature
        ) {
            Destination memory last = _minBaseFees[_minBaseFees.length - 1];
            _minBaseFees[index] = last;
            _minBaseFeeIndex[last.target][last.fnSignature] = index;
            _minBaseFeeIndex[_target][_fnSignature] = 0;
            _minBaseFees.pop();
            emit MinGasPriceSet(_target, _fnSignature, 0);
        } else {
            revert("not found");
        }
    }

    /// @notice Fetches the list of prioritized transaction destinations sorted by their weight (desc).
    /// @return weights The array of weights sorted in DESC order.
    function getPriorities() external view returns (Destination[] memory weights) {
        weights = new Destination[](weightsCount);
        uint256 weight = _weightsTree.last().value();
        uint256 i;

        while (weight != 0) {
            require(i < weightsCount);
            weights[i++] = destinationByWeight[weight];
            weight = _weightsTree.find(weight).prev().value();
        }
    }

    /// @notice Returns the array of whitelisted senders from storage.
    /// @return The whitelist stored at `_sendersWhitelist` in an array of addresses.
    function getSendersWhitelist() external view returns (address[] memory) {
        return (_sendersWhitelist);
    }

    /// @notice Returns the array of fixed gas prices set for specific tx destinations.
    /// @return An array of the `Destination[]` type containing each set destination.
    function getMinBaseFees() external view returns (Destination[] memory) {
        return (_minBaseFees);
    }
}
