// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import { IOption } from "./IOption.sol";

/// @notice Types, errors and events of the PositionRouter demo.
interface IPositionRouter {
    /// @param isBuy   Buy `amount` options back instead of writing and selling them.
    /// @param premium Total USDC: the least a sell receives, or the most a buy pays. Set at creation
    ///                from the per-option price.
    struct Order {
        IOption option;
        uint40 deadline;
        bool isBuy;
        uint256 amount;
        uint256 premium;
    }

    /// @notice `option` was not created by the router's factory.
    error UnknownOption();
    /// @notice The terms passed to {createOrder} are not `option`'s own.
    error TermsMismatch();
    /// @notice The order's market breaks the order rules.
    error MarketNotAllowed();
    /// @notice Zero amount or total premium, or the nonce already holds an open order.
    error InvalidOrder();
    /// @notice The order's deadline falls more than `EXPIRY_BUFFER` after its market's expiry.
    error OrderOutlivesMarket();
    /// @notice The market's strike is more than `STRIKE_BAND_BPS` from the oracle's spot price.
    error StrikeOutOfRange();
    /// @notice A sell's price is below the option's intrinsic value at spot, or a buy's is above
    ///         intrinsic plus the time-value tent. See `priceBounds`. Checked on the
    ///         order's price at creation and on the fill's price at fill.
    error PriceOutOfBounds();
    /// @notice The oracle's answer is non-positive or older than `ORACLE_MAX_AGE`.
    error StalePrice();
    /// @notice No open order at this account and nonce.
    error UnknownOrder();
    /// @notice The order's deadline has passed.
    error OrderExpired();
    /// @notice The quote does not trade exactly this order's option and amount for USDC with the router.
    error QuoteMismatch();
    /// @notice A sell paid the account less USDC than the order's premium.
    error PremiumTooLow();
    /// @notice A buy would pay more USDC than the order's premium.
    error PremiumTooHigh();

    event OrderCreated(
        address indexed account, uint256 indexed nonce, IOption option, bool isBuy, uint256 amount, uint256 premium, uint40 deadline
    );
    event OrderCancelled(address indexed account, uint256 indexed nonce);
    event OrderFilled(address indexed account, uint256 indexed nonce, address indexed maker, uint256 premium);
}
