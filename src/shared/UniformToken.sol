// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {ERC20} from "@solady/contracts/tokens/ERC20.sol";
import {Ownable} from "@solady/contracts/auth/Ownable.sol";
import {LibBitmap} from "@solady/contracts/utils/LibBitmap.sol";
import {LibString} from "@solady/contracts/utils/LibString.sol";
import {LibCall} from "@solady/contracts/utils/LibCall.sol";
import {IERC20Hooks} from "./interfaces/IERC20Hooks.sol";

/// @title Uniform Token
/// @author Chainvisions
/// @notice An ERC20 implementation designed for a combination of standard uniformity and composability.
/// @dev This is a contract designed to be deployable via a precompiled factory contract in an attempt to
/// create a complete standardization of ERC20. This design is inspired by Solana's SPL with the goal to create
/// tokens that share the same implementation instead of the network being filled with a variety of different implementations.
/// this is to protect the security of smart contracts on the network and prevent any potential catastrophic bugs as a result of
/// weird ERC20 implementations. With this design, the token uses the same ERC20 invariant as every other token contract, but is
/// specifically extendable by the means of a proxy-like delegatecall pattern for handling hooks and other extensions of the logic.

contract UniformToken is ERC20, Ownable {
    using LibBitmap for LibBitmap.Bitmap;
    using LibCall for address;

    error NotExtendable();

    error NoImplementation();

    /// @notice Data structure for storing `UniformToken` related state (not ERC20 state).
    struct TokenStorage {
        /// @notice The logic contract for handling hooks and extensions.
        address logic;
        /// @notice The bitmap used for storing hooks related flags.
        LibBitmap.Bitmap map;
    }

    /// @dev Internal immutable variable for storing the token name.
    bytes32 internal immutable NAME;

    /// @dev Internal immutable variable for storing the token symbol.
    bytes32 internal immutable SYMBOL;

    /// @dev Internal immutable variable for storing the token decimals.
    uint8 internal immutable DECIMALS;

    /// @dev The storage slot used to store specific token related flags.
    bytes32 internal constant TOKEN_STORAGE_SLOT = keccak256("posdao.contracts.shared.storage.UniformToken");

    /// @notice Uniform Token constructor.
    constructor(bytes32 _name, bytes32 _symbol, uint8 _decimals) {
        NAME = _name;
        SYMBOL = _symbol;
        DECIMALS = _decimals;
        _setOwner(msg.sender);
    }

    fallback() external payable virtual {
        bool canDelegate = tokenStorage().map.get(3);
        address logic = tokenStorage().logic;

        if (!canDelegate) revert NotExtendable();
        if (logic == address(0)) revert NoImplementation();

        assembly {
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), logic, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())

            switch result
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }

    receive() external payable {}

    /// @notice Sets the current smart contract logic.
    /// @param _logic Logic smart contract to delegate to.
    function setLogic(address _logic) external onlyOwner {
        tokenStorage().logic = _logic;
    }

    /// @notice Toggles a specific feature flag on the token contract.
    /// @param _index Index of the feature flag to toggle.
    /// @param _value Value of the flag, determines whether it is enabled or not.
    function setFlag(uint256 _index, bool _value) external onlyOwner {
        _value ? tokenStorage().map.set(_index) : tokenStorage().map.unset(_index);
    }

    /// @notice Name of the token. Must fit within 32 bytes or else it'll break.
    /// @return String representing the token's name. Converted from bytes32.
    function name() public view override returns (string memory) {
        return LibString.toString(uint256(NAME));
    }

    /// @notice Symbol of the token. Must fit within 32 bytes or else it'll break.
    /// @return String representing the token's symbol. Converted from bytes32.
    function symbol() public view override returns (string memory) {
        return LibString.toString(uint256(SYMBOL));
    }

    /// @notice Decimals of the token.
    /// @return The decimal precision of the token.
    function decimals() public view override returns (uint8) {
        return DECIMALS;
    }

    /// @dev `beforeTokenTransfer` hook, used for executing logic before a transfer occurs.
    /// @param _from Address sending tokens in the transfer.
    /// @param _to Recipient of the tokens.
    /// @param _amount Amount of tokens being sent.
    function _beforeTokenTransfer(address _from, address _to, uint256 _amount) internal override {
        TokenStorage storage $ = tokenStorage();
        bool useHook = $.map.get(0);
        if (useHook) {
            $.logic.delegateCallContract(
                abi.encodeWithSelector(IERC20Hooks.beforeTokenTransfer.selector, _from, _to, _amount)
            );
        }
    }

    /// @dev `afterTokenTransfer` hook, used for executing logic before a transfer occurs.
    /// @param _from Address sending tokens in the transfer.
    /// @param _to Recipient of the tokens.
    /// @param _amount Amount of tokens being sent.
    function _afterTokenTransfer(address _from, address _to, uint256 _amount) internal override {
        TokenStorage storage $ = tokenStorage();
        bool useHook = $.map.get(1);
        if (useHook) {
            $.logic.delegateCallContract(
                abi.encodeWithSelector(IERC20Hooks.afterTokenTransfer.selector, _from, _to, _amount)
            );
        }
    }

    /// @dev Private method used for accessing the token storage. Avoids potential collision issues.
    /// @return $ The pointer to `TokenStorage` in storage.
    function tokenStorage() private pure returns (TokenStorage storage $) {
        bytes32 slot = TOKEN_STORAGE_SLOT;
        assembly {
            $.slot := slot
        }
    }
}
