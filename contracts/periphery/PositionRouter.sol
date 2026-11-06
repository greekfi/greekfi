// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
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
 *         when the order is created and again when a sell fills. Every order's price is checked
 *         against the option's value at spot, when the order is created and again at fill: a sell
 *         may not go below intrinsic value, and a buy-back may not pay more than intrinsic plus the
 *         time-value "tent" (see {priceBounds}).
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
    /// @dev One whole USDC in base units.
    uint256 private immutable USDC_UNIT;

    /// @notice Longest time to expiration an order's market may have.
    uint256 public constant MAX_TENOR = 35 days;
    /// @notice Longest post-expiry exercise window an order's market may have.
    uint256 public constant MAX_WINDOW = 1 hours;
    /// @notice An order's deadline may fall at most this long after its market expires. Sells stop
    ///         filling at expiry anyway, since the Option refuses to mint from then on; buy-backs
    ///         (pair-burns) can still fill until the deadline.
    uint256 public constant EXPIRY_BUFFER = 2 hours;
    /// @notice Widest an order's strike may sit from spot, in basis points of spot (50%).
    uint256 public constant STRIKE_BAND_BPS = 5_000;
    /// @notice Oldest {ORACLE} answer the router accepts. The ETH / USD feed's heartbeat is 1 hour.
    uint256 public constant ORACLE_MAX_AGE = 2 hours;
    /// @notice The buy-back cap's time-value tent, as a share of spot (18 decimals), T in years and
    ///         d = |K - S| / sqrt(K S):
    ///
    ///             tent = (TENT_PEAK + TENT_PEAK_SLOPE sqrt(T)) / (1 + d / (4 (TENT_WIDTH + TENT_WIDTH_SLOPE sqrt(T))))^4
    ///
    ///         Fitted so every Deribit ETH mark from Aug 2025 to Mar 2026 (14.9M, strikes within 50%
    ///         of spot, up to 35 days) sits under it with at least 1.08x room, and every Derive and Rysk
    ///         fill passes (greek research repo, `buyback-cap/`). 3.8% of spot at the strike at
    ///         expiry, 5.4% at 1 day, 12.9% at 35 days; it falls off with distance from the strike.
    uint256 public constant TENT_PEAK = 0.038e18;
    uint256 public constant TENT_PEAK_SLOPE = 0.3e18;
    uint256 public constant TENT_WIDTH = 0.066e18;
    uint256 public constant TENT_WIDTH_SLOPE = 0.49e18;
    /// @notice The buy-back cap prices intrinsic value at spot moved this far in the option's favour,
    ///         so a lagging {ORACLE} cannot block a fair buy-back of an in-the-money option. The
    ///         ETH / USD feed updates on a 0.5% deviation.
    uint256 public constant ORACLE_TOLERANCE_BPS = 50;

    /// @notice Open limit orders by account and account-chosen nonce.
    mapping(address account => mapping(uint256 nonce => Order)) public orders;

    constructor(IFactory factory_, IBebopSettlement bebop_, address weth_, address usdc_, IPriceFeed oracle_) {
        FACTORY = factory_;
        BEBOP = bebop_;
        WETH = weth_;
        USDC = usdc_;
        ORACLE = oracle_;
        ORACLE_SCALE = 10 ** (18 - oracle_.decimals());
        USDC_UNIT = 10 ** IERC20Metadata(usdc_).decimals();
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
    ///         when USDC is the collateral), fit {MAX_TENOR} and {MAX_WINDOW}, expire no more than
    ///         {EXPIRY_BUFFER} before the order's deadline, and have its strike within
    ///         {STRIKE_BAND_BPS} of spot. `price` must sit within {priceBounds} at spot now: at least
    ///         intrinsic value for a sell, at most intrinsic plus the time-value tent for a buy.
    ///         {submitOrder} checks the fill's own price against the same bounds at fill time.
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
        // Fixed for the order's life: no fill comes after `deadline`, so none comes later than this after expiry.
        if (deadline > uint256(expirationDate) + EXPIRY_BUFFER) revert OrderOutlivesMarket();

        uint256 spot = _spot();
        _checkStrike(strike, isPut, spot);
        (uint256 minSellPrice, uint256 maxBuyPrice) = _priceBounds(strike, isPut, expirationDate, windowSeconds, spot);
        if (isBuy ? price > maxBuyPrice : price < minSellPrice) revert PriceOutOfBounds();

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
    ///      position that has moved far from spot can still be closed. The premium received must
    ///      also cover intrinsic value at today's spot.
    function _sell(
        address account,
        Order memory order,
        IBebopSettlement.SingleOrder calldata quote,
        IBebopSettlement.MakerSignature calldata makerSignature
    ) private returns (uint256 premium) {
        uint256 spot = _spot();
        _checkStrike(order.option.strike(), order.option.isPut(), spot);

        // Read after the mint: a put's collateral is USDC too, and must not count against the premium.
        order.option.transferFrom(account, address(this), order.amount);
        uint256 usdcBefore = IERC20(USDC).balanceOf(account);
        order.option.approve(address(BEBOP), order.amount);
        BEBOP.swapSingle(quote, makerSignature, 0);

        premium = IERC20(USDC).balanceOf(account) - usdcBefore;
        if (premium < order.premium) revert PremiumTooLow();
        (uint256 minSellPrice,) = _boundsOf(order.option, spot);
        if (premium < Math.mulDiv(order.amount, minSellPrice, 10 ** order.option.decimals(), Math.Rounding.Ceil)) {
            revert PriceOutOfBounds();
        }
    }

    /// @dev Pulls the quoted USDC from `account`, buys the options into the router and sends them on.
    ///      With `Perm.BURN` from `account`, that send pair-burns them against its Receipts and the
    ///      collateral returns to `account` in the same call. The premium paid may not exceed
    ///      {priceBounds}' cap at today's spot, so this needs a fresh {ORACLE} answer too.
    function _buy(
        address account,
        Order memory order,
        IBebopSettlement.SingleOrder calldata quote,
        IBebopSettlement.MakerSignature calldata makerSignature
    ) private returns (uint256 premium) {
        premium = quote.taker_amount;
        if (premium > order.premium) revert PremiumTooHigh();
        (, uint256 maxBuyPrice) = _boundsOf(order.option, _spot());
        if (premium > Math.mulDiv(order.amount, maxBuyPrice, 10 ** order.option.decimals())) revert PriceOutOfBounds();
        IERC20(USDC).safeTransferFrom(account, address(this), premium);
        IERC20(USDC).forceApprove(address(BEBOP), premium);

        uint256 held = order.option.balanceOf(address(this));
        BEBOP.swapSingle(quote, makerSignature, 0);
        // A partner fee would come out of the options delivered.
        if (order.option.balanceOf(address(this)) - held < order.amount) revert QuoteMismatch();
        order.option.transfer(account, order.amount);
    }

    /// @notice The price range {createOrder} accepts for `option` right now, in USDC base units per
    ///         whole option: a sell's `price` must be at least `minSellPrice` (intrinsic value at
    ///         spot), a buy's at most `maxBuyPrice` (intrinsic, with {ORACLE_TOLERANCE_BPS}, plus the
    ///         {TENT_PEAK} time-value tent).
    ///         Both are 0 once the exercise window has closed.
    function priceBounds(IOption option) external view returns (uint256 minSellPrice, uint256 maxBuyPrice) {
        _receiptOf(option);
        return _boundsOf(option, _spot());
    }

    /// @dev {_priceBounds} for a market already known to be the factory's.
    function _boundsOf(IOption option, uint256 spot) private view returns (uint256, uint256) {
        uint40 expirationDate = option.expirationDate();
        return _priceBounds(option.strike(), option.isPut(), expirationDate, uint40(option.exerciseDeadline() - expirationDate), spot);
    }

    /// @dev Values one whole option at `spot` in USDC base units. A call is on 1 WETH. A put is on
    ///      1 USDC of collateral, exercised by paying `1 / humanStrike` WETH, so its value per ETH of
    ///      underlying is divided by `humanStrike`. The sell floor is intrinsic value at `spot`. The
    ///      buy cap is intrinsic at spot moved {ORACLE_TOLERANCE_BPS} in the option's favour, plus
    ///      `spot` times the {_tent}. After the exercise window the option is worth nothing.
    function _priceBounds(uint256 strike, bool isPut, uint40 expirationDate, uint40 windowSeconds, uint256 spot)
        private
        view
        returns (uint256 intrinsic, uint256 cap)
    {
        if (block.timestamp > uint256(expirationDate) + windowSeconds) return (0, 0);
        uint256 humanStrike = isPut ? 1e36 / strike : strike;
        // USD per ETH of underlying (18 decimals) to USDC base units per option.
        uint256 per = isPut ? humanStrike : 1e18;
        intrinsic = Math.mulDiv(_itm(spot, humanStrike, isPut), USDC_UNIT, per);

        uint256 favoured = isPut ? spot * (10_000 - ORACLE_TOLERANCE_BPS) / 10_000 : spot * (10_000 + ORACLE_TOLERANCE_BPS) / 10_000;
        uint256 timeValue = Math.mulDiv(spot, _tent(humanStrike, spot, expirationDate), 1e18);
        cap = Math.mulDiv(_itm(favoured, humanStrike, isPut) + timeValue, USDC_UNIT, per);
    }

    /// @dev In-the-money amount per ETH of underlying, 18 decimals.
    function _itm(uint256 spot, uint256 humanStrike, bool isPut) private pure returns (uint256) {
        return isPut ? (humanStrike > spot ? humanStrike - spot : 0) : (spot > humanStrike ? spot - humanStrike : 0);
    }

    /// @dev Time value the buy cap allows, as a share of spot (18 decimals): the {TENT_PEAK} tent at
    ///      `humanStrike`'s distance from `spot` and the time left to `expirationDate` (none after).
    ///      `1 / (1 + d / 4w)` is computed as `4w / (4w + d)`.
    function _tent(uint256 humanStrike, uint256 spot, uint40 expirationDate) private view returns (uint256) {
        uint256 timeLeft = block.timestamp < expirationDate ? expirationDate - block.timestamp : 0;
        uint256 sqrtYears = Math.sqrt(timeLeft * 1e36 / 365 days); // 18 decimals
        uint256 peak = TENT_PEAK + Math.mulDiv(TENT_PEAK_SLOPE, sqrtYears, 1e18);
        uint256 width4 = 4 * (TENT_WIDTH + Math.mulDiv(TENT_WIDTH_SLOPE, sqrtYears, 1e18));
        uint256 gap = humanStrike > spot ? humanStrike - spot : spot - humanStrike;
        uint256 d = Math.mulDiv(gap, 1e18, Math.sqrt(humanStrike * spot));
        uint256 q = Math.mulDiv(width4, 1e18, width4 + d);
        q = q * q / 1e18;
        return Math.mulDiv(peak, q * q, 1e36);
    }

    /// @dev The {ORACLE} spot as USD per ETH, 18 decimals. Reverts on a non-positive or stale answer.
    function _spot() private view returns (uint256) {
        (, int256 answer,, uint256 updatedAt,) = ORACLE.latestRoundData();
        if (answer <= 0 || block.timestamp - updatedAt > ORACLE_MAX_AGE) revert StalePrice();
        return uint256(answer) * ORACLE_SCALE;
    }

    /// @dev Reverts unless the market's strike, as USD per ETH, is within {STRIKE_BAND_BPS} of
    ///      `spot`. A put stores `1e36 / humanStrike`, so it is inverted back first.
    function _checkStrike(uint256 strike, bool isPut, uint256 spot) private pure {
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
