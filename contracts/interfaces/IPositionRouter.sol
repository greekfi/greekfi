// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import { IOption } from "./IOption.sol";

/// @notice Errors and events of the PositionRouter demo.
interface IPositionRouter {
    /// @notice `option` was not created by the router's factory.
    error UnknownOption();
    /// @notice `options` and `amounts` differ in length.
    error LengthMismatch();
    /// @notice The order's market breaks the order rules.
    error MarketNotAllowed();
    /// @notice Zero amount or premium, or the nonce already holds an open order.
    error InvalidOrder();
    /// @notice No open order at this account and nonce.
    error UnknownOrder();
    /// @notice The order's deadline has passed.
    error OrderExpired();
    /// @notice The quote does not sell exactly this order to the router for USDC paid to the account.
    error QuoteMismatch();
    /// @notice The account received less USDC than the order's minimum premium.
    error PremiumTooLow();

    event OrderCreated(address indexed account, uint256 indexed nonce, IOption option, uint256 amount, uint256 minPremium, uint40 deadline);
    event OrderCancelled(address indexed account, uint256 indexed nonce);
    event OrderFilled(address indexed account, uint256 indexed nonce, address indexed maker, uint256 premium);
}
