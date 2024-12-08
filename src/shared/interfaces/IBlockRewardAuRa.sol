// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IBlockRewardAuRa {
    /// @notice Emitted by the `addExtraReceiver` function.
    /// @param amount The amount of native coins which must be minted for the `receiver` by the `erc-to-native`
    /// `bridge` with the `reward` function.
    /// @param receiver The address for which the `amount` of native coins must be minted.
    /// @param bridge The bridge address which called the `addExtraReceiver` function.
    event AddedReceiver(uint256 amount, address indexed receiver, address indexed bridge);

    /// @notice Emitted by the `addBridgeNativeRewardReceivers` function.
    /// @param amount The fee/reward amount in native coins passed to the
    /// `addBridgeNativeRewardReceivers` function as a parameter.
    /// @param cumulativeAmount The value of `bridgeNativeReward` state variable
    /// after adding the `amount` to it.
    /// @param bridge The bridge address which called the `addBridgeNativeRewardReceivers` function.
    event BridgeNativeRewardAdded(uint256 amount, uint256 cumulativeAmount, address indexed bridge);

    /// @notice Emitted by the `_mintNativeCoins` function which is called by the `reward` function.
    /// This event is only used by the unit tests because the `reward` function cannot emit events.
    /// @param receivers The array of receiver addresses for which native coins are minted. The length of this
    /// array is equal to the length of the `rewards` array.
    /// @param rewards The array of amounts minted for the relevant `receivers`. The length of this array
    /// is equal to the length of the `receivers` array.
    event MintedNative(address[] receivers, uint256[] rewards);

    function clearBlocksCreated() external;
    function initialize(address, address) external;
    function epochsPoolGotRewardFor(uint256) external view returns (uint256[] memory);
    function mintedTotally() external view returns (uint256);
    function mintedTotallyByBridge(address) external view returns (uint256);
}
