// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

/// @notice The slice of Bebop's settlement contract (`0xbbbbbBB520d69a9775E85b458C58c648259FAD5F`)
///         that the PositionRouter and its tests use.
interface IBebopSettlement {
    struct SingleOrder {
        uint256 expiry;
        address taker_address;
        address maker_address;
        uint256 maker_nonce;
        address taker_token;
        address maker_token;
        uint256 taker_amount;
        uint256 maker_amount;
        address receiver;
        uint256 packed_commands;
        uint256 flags;
    }

    struct MakerSignature {
        bytes signatureBytes;
        uint256 flags;
    }

    /// @notice EIP-712 hash of `order` without `flags`. With zero `updatedMakerAmount` /
    ///         `updatedMakerNonce` this is the hash a maker signs.
    function hashSingleOrder(SingleOrder calldata order, uint64 partnerId, uint256 updatedMakerAmount, uint256 updatedMakerNonce)
        external
        view
        returns (bytes32);

    /// @notice Taker-executed single order: `msg.sender` must be `order.taker_address`. Pulls
    ///         `filledTakerAmount` of the taker token (0 means all of `taker_amount`) and pays the
    ///         maker amount, pro rata, to `order.receiver`.
    function swapSingle(SingleOrder calldata order, MakerSignature calldata makerSignature, uint256 filledTakerAmount) external payable;
}
