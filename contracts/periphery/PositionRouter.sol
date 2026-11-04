// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import { IFactory } from "../interfaces/IFactory.sol";
import { IOption } from "../interfaces/IOption.sol";
import { IReceipt } from "../interfaces/IReceipt.sol";
import { IBebopSettlement } from "../interfaces/IBebopSettlement.sol";
import { IPriceFeed } from "../interfaces/IPriceFeed.sol";
import { IPositionRouter } from "../interfaces/IPositionRouter.sol";

/**
 * @title  PositionRouter: one fixed address for a writer's redeem and Bebop limit orders
 * @notice DEMO ONLY. Not audited, not deployed, outside the audit scope in `auditors-instructions.md`.
 *
 *         Every market is its own Option/Receipt clone pair, so an account whose call permissions are
 *         scoped by target address (a Safe behind a Zodiac Roles Modifier, say) would need a new
 *         permission for every series it writes. This router gives that account one fixed target.
 *
 *         {redeem} takes a list of markets, validates that each belongs to {FACTORY}, then redeems
 *         `msg.sender`'s own Receipts only.
 *
 *         {createOrder} stores a limit order to sell freshly written options for at least a minimum
 *         USDC price per option, or to buy options back for at most a maximum. Anyone may then
 *         {submitOrder} a Bebop quote that fits it, with the router as taker. A sell mints the options
 *         from the account and the premium goes straight to the account. A buy pulls the USDC from the
 *         account and sends the options on to it, pair-burning them against its Receipts. The router
 *         holds tokens only inside that call.
 *
 *         Every order's strike must sit within {STRIKE_BAND_BPS} of the {ORACLE} spot price, checked
 *         when the order is created and again when a sell fills.
 *
 *         Setup: approve collateral to the factory (the approval caps what all orders can write) and
 *         USDC to the router (it caps what buys can spend), then
 *         `factory.setPermissions(router, TRANSFER | MINT | BURN | REDEEM)`. The router uses
 *         `TRANSFER | MINT` only to write the options a filled sell order delivers. With BURN, options a
 *         buy order delivers net against the account's Receipts.
 */
contract PositionRouter is IPositionRouter, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /// @notice The factory whose markets this router accepts.
    IFactory public immutable FACTORY;
    /// @notice Bebop settlement contract that {submitOrder} settles on.
    IBebopSettlement public immutable BEBOP;
    /// @notice The two tokens an order's market may pair, and the premium token is {USDC}.
    address public immutable WETH;
    address public immutable USDC;
    /// @notice ETH / USD price feed for the strike band. USD stands in for USDC; at a ±50% band a
    ///         USDC depeg would have to be extreme to matter.
    IPriceFeed public immutable ORACLE;
    /// @dev Scales an {ORACLE} answer to 18 decimals, the strike's scale.
    uint256 private immutable ORACLE_SCALE;

    /// @notice Longest time to expiration an order's market may have.
    uint256 public constant MAX_TENOR = 35 days;
    /// @notice Longest post-expiry exercise window an order's market may have.
    uint256 public constant MAX_WINDOW = 1 hours;
    /// @notice Widest an order's strike may sit from spot, in basis points of spot (50%).
    uint256 public constant STRIKE_BAND_BPS = 5_000;
    /// @notice Oldest {ORACLE} answer the router accepts. The ETH / USD feed's heartbeat is 1 hour.
    uint256 public constant ORACLE_MAX_AGE = 2 hours;

    /// @notice Open limit orders by account and account-chosen nonce.
    mapping(address account => mapping(uint256 nonce => Order)) public orders;

    constructor(IFactory factory_, IBebopSettlement bebop_, address weth_, address usdc_, IPriceFeed oracle_) {
        FACTORY = factory_;
        BEBOP = bebop_;
        WETH = weth_;
        USDC = usdc_;
        ORACLE = oracle_;
        ORACLE_SCALE = 10 ** (18 - oracle_.decimals());
    }

    /// @notice Redeem the caller's full Receipt balance in each of `options`' markets; proceeds go
    ///         to the caller. Needs `Perm.REDEEM`. Without the grant {IReceipt.redeemFor} skips the
    ///         caller silently and this call succeeds having done nothing. Any market whose
    ///         redemption reverts reverts the whole batch.
    function redeem(IOption[] calldata options) external nonReentrant {
        address[] memory holders = new address[](1);
        holders[0] = msg.sender;
        for (uint256 i; i < options.length; ++i) {
            _receiptOf(options[i]).redeemFor(holders);
        }
    }

    /// @notice Offer to write and sell `amount` of `option` for at least `price` USDC per option, or
    ///         with `isBuy` to buy `amount` back for at most `price` per option, until `duration`
    ///         seconds from now. The market must be European, pair {WETH} with {USDC} (a put exactly
    ///         when USDC is the collateral), fit {MAX_TENOR} and {MAX_WINDOW}, not expire before the
    ///         order's deadline, and have its strike within {STRIKE_BAND_BPS} of spot.
    ///
    ///         `strike` through `windowSeconds` restate `option`'s terms and must match them exactly.
    ///         They are in the calldata so the Roles Modifier can pin or bound them; the router
    ///         checks them against the market. A put's `strike` is the inverted `1e36 / humanStrike`,
    ///         so its bounds invert too.
    /// @param price    USDC base units per whole option (`10 ** option.decimals()` units): a sell's
    ///                 floor or a buy's cap, for the Roles Modifier to bound. The stored total rounds in
    ///                 the account's favour, up for a sell and down for a buy.
    /// @param duration Lifetime of the order, for the Roles Modifier to cap.
    function createOrder(
        uint256 nonce,
        IOption option,
        uint256 strike,
        uint40 expirationDate,
        bool isPut,
        bool isEuro,
        uint40 windowSeconds,
        bool isBuy,
        uint256 amount,
        uint256 price,
        uint32 duration
    ) external {
        if (amount == 0 || orders[msg.sender][nonce].amount != 0) revert InvalidOrder();

        IReceipt receipt = _receiptOf(option);
        if (
            receipt.strike() != strike || receipt.expirationDate() != expirationDate || receipt.isPut() != isPut
                || receipt.isEuro() != isEuro || receipt.exerciseDeadline() - expirationDate != windowSeconds
        ) revert TermsMismatch();

        address coll = address(receipt.collateral());
        address cons = address(receipt.consideration());
        // `isPut` is only a label in the factory; tie it to the collateral so the side Roles pins is real.
        if (
            !isEuro || expirationDate > block.timestamp + MAX_TENOR || windowSeconds > MAX_WINDOW || isPut != (coll == USDC)
                || !((coll == WETH && cons == USDC) || (coll == USDC && cons == WETH))
        ) revert MarketNotAllowed();

        uint40 deadline = uint40(block.timestamp + duration);
        // No fill comes after `deadline`, so none comes after expiry either.
        if (deadline > expirationDate) revert OrderOutlivesMarket();

        _checkStrike(strike, isPut);

        uint256 premium = Math.mulDiv(amount, price, 10 ** option.decimals(), isBuy ? Math.Rounding.Floor : Math.Rounding.Ceil);
        if (premium == 0) revert InvalidOrder();

        orders[msg.sender][nonce] = Order(option, deadline, isBuy, amount, premium);
        emit OrderCreated(msg.sender, nonce, option, isBuy, amount, premium, deadline);
    }

    /// @notice Withdraw the caller's open order at `nonce`.
    function cancelOrder(uint256 nonce) external {
        delete orders[msg.sender][nonce];
        emit OrderCancelled(msg.sender, nonce);
    }

    /// @notice Fill `account`'s order at `nonce` with a Bebop quote, all or nothing. Callable by
    ///         anyone. The quote names this router as taker and trades exactly the order's option and
    ///         amount for USDC. A sell pays `account` directly; a buy delivers to the router, which
    ///         passes the options on to `account`.
    function submitOrder(
        address account,
        uint256 nonce,
        IBebopSettlement.SingleOrder calldata quote,
        IBebopSettlement.MakerSignature calldata makerSignature
    ) external nonReentrant {
        Order memory order = orders[account][nonce];
        if (order.amount == 0) revert UnknownOrder();
        if (block.timestamp > order.deadline) revert OrderExpired();
        (address paid, address bought, uint256 size, address receiver) = order.isBuy
            ? (USDC, address(order.option), quote.maker_amount, address(this))
            : (address(order.option), USDC, quote.taker_amount, account);
        if (
            quote.taker_address != address(this) || quote.taker_token != paid || quote.maker_token != bought || size != order.amount
                || quote.receiver != receiver || quote.packed_commands != 0
        ) revert QuoteMismatch();
        delete orders[account][nonce];

        uint256 premium = order.isBuy ? _buy(account, order, quote, makerSignature) : _sell(account, order, quote, makerSignature);
        emit OrderFilled(account, nonce, quote.maker_address, premium);
    }

    /// @dev Mints the options from `account` into the router and sells them; the USDC goes straight
    ///      to `account` and is measured there, so any fee counts against the premium. Re-checks the
    ///      strike band, since spot may have moved while the order rested. Buy-backs skip it, so a
    ///      position that has moved far from spot can still be closed.
    function _sell(
        address account,
        Order memory order,
        IBebopSettlement.SingleOrder calldata quote,
        IBebopSettlement.MakerSignature calldata makerSignature
    ) private returns (uint256 premium) {
        _checkStrike(order.option.strike(), order.option.isPut());

        // Read after the mint: a put's collateral is USDC too, and must not count against the premium.
        order.option.transferFrom(account, address(this), order.amount);
        uint256 usdcBefore = IERC20(USDC).balanceOf(account);
        order.option.approve(address(BEBOP), order.amount);
        BEBOP.swapSingle(quote, makerSignature, 0);

        premium = IERC20(USDC).balanceOf(account) - usdcBefore;
        if (premium < order.premium) revert PremiumTooLow();
    }

    /// @dev Pulls the quoted USDC from `account`, buys the options into the router and sends them on.
    ///      With `Perm.BURN` from `account`, that send pair-burns them against its Receipts and the
    ///      collateral returns to `account` in the same call.
    function _buy(
        address account,
        Order memory order,
        IBebopSettlement.SingleOrder calldata quote,
        IBebopSettlement.MakerSignature calldata makerSignature
    ) private returns (uint256 premium) {
        premium = quote.taker_amount;
        if (premium > order.premium) revert PremiumTooHigh();
        IERC20(USDC).safeTransferFrom(account, address(this), premium);
        IERC20(USDC).forceApprove(address(BEBOP), premium);

        uint256 held = order.option.balanceOf(address(this));
        BEBOP.swapSingle(quote, makerSignature, 0);
        // A partner fee would come out of the options delivered.
        if (order.option.balanceOf(address(this)) - held < order.amount) revert QuoteMismatch();
        order.option.transfer(account, order.amount);
    }

    /// @dev Reverts unless the market's strike, as USD per ETH, is within {STRIKE_BAND_BPS} of the
    ///      {ORACLE} spot. A put stores `1e36 / humanStrike`, so it is inverted back first.
    function _checkStrike(uint256 strike, bool isPut) private view {
        (, int256 answer,, uint256 updatedAt,) = ORACLE.latestRoundData();
        if (answer <= 0 || block.timestamp - updatedAt > ORACLE_MAX_AGE) revert StalePrice();
        uint256 spot = uint256(answer) * ORACLE_SCALE;
        uint256 humanStrike = isPut ? 1e36 / strike : strike;
        uint256 band = spot * STRIKE_BAND_BPS / 10_000;
        if (humanStrike < spot - band || humanStrike > spot + band) revert StrikeOutOfRange();
    }

    /// @dev The factory registers every Receipt it creates, and each Receipt names its Option, so a
    ///      registered Receipt that points back at `option` proves `option` is a factory market.
    function _receiptOf(IOption option) private view returns (IReceipt receipt) {
        receipt = option.receipt();
        if (!FACTORY.receipts(address(receipt)) || receipt.option() != address(option)) revert UnknownOption();
    }
}
