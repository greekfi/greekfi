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

    struct OldSingleQuote {
        bool useOldAmount;
        uint256 makerAmount;
        uint256 makerNonce;
    }

    /// @notice EIP-712 hash of `order` without `flags`. With non-zero `updatedMakerAmount` /
    ///         `updatedMakerNonce` those replace the order's own fields; this is the hash a taker
    ///         signs for {settleSingle}.
    function hashSingleOrder(SingleOrder calldata order, uint64 partnerId, uint256 updatedMakerAmount, uint256 updatedMakerNonce)
        external
        view
        returns (bytes32);

    /// @notice Maker-executed single order. When `msg.sender` is not the taker, `takerSignature` must
    ///         validate against `hashSingleOrder(order, partnerId, takerQuoteInfo.makerAmount,
    ///         takerQuoteInfo.makerNonce)`.
    function settleSingle(
        SingleOrder calldata order,
        MakerSignature calldata makerSignature,
        uint256 filledTakerAmount,
        OldSingleQuote calldata takerQuoteInfo,
        bytes calldata takerSignature
    ) external payable;
}
