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
import { IPositionRouter } from "../interfaces/IPositionRouter.sol";

/**
 * @title  PositionRouter: one fixed address for a writer's transfer, redeem and Bebop limit orders
 * @notice DEMO ONLY. Not audited, not deployed, outside the audit scope in `auditors-instructions.md`.
 *
 *         Every market is its own Option/Receipt clone pair, so an account whose call permissions are
 *         scoped by target address (a Safe behind a Zodiac Roles Modifier, say) would need a new
 *         permission for every series it writes. This router gives that account one fixed target.
 *
 *         {transfer} and {redeem} take a list of markets, validate that each belongs to
 *         {FACTORY}, then act on `msg.sender`'s own position only.
 *
 *         {createOrder} stores a limit order to sell freshly written options for at least a minimum
 *         USDC price per option, or to buy options back for at most a maximum. Anyone may then {submitOrder} a
 *         Bebop quote that fits it, with the router as taker. A sell mints the options from the
 *         account and the premium goes straight to the account. A buy pulls the USDC from the account
 *         and sends the options on to it, pair-burning them against its Receipts. The router holds
 *         tokens only inside that call.
 *
 *         Setup: approve collateral to the factory (the approval caps what all orders can write) and
 *         USDC to the router (it caps what buys can spend), then
 *         `factory.setPermissions(router, TRANSFER | MINT | BURN | REDEEM)`. With MINT, {transfer}
 *         writes and sends options to any `to`, so a Roles preset must pin `to`. With BURN, options
 *         anyone sends to the account through the router net against its Receipts.
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
    /// @notice Longest time to expiration an order's market may have.
    uint256 public constant MAX_TENOR = 30 days;
    /// @notice Longest post-expiry exercise window an order's market may have.
    uint256 public constant MAX_WINDOW = 1 hours;

    /// @notice Open limit orders by account and account-chosen nonce.
    mapping(address account => mapping(uint256 nonce => Order)) public orders;

    constructor(IFactory factory_, IBebopSettlement bebop_, address weth_, address usdc_) {
        FACTORY = factory_;
        BEBOP = bebop_;
        WETH = weth_;
        USDC = usdc_;
    }

    /// @notice For each `i`, send `amounts[i]` of the caller's `options[i]` to `to`. Needs
    ///         `Perm.TRANSFER`; with `Perm.MINT` too, any shortfall is minted from the caller's
    ///         collateral allowance and the caller keeps the Receipts.
    function transfer(IOption[] calldata options, address to, uint256[] calldata amounts) external nonReentrant {
        for (uint256 i; i < options.length; ++i) {
            _receiptOf(options[i]);
            options[i].transferFrom(msg.sender, to, amounts[i]);
        }
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
    ///         when USDC is the collateral), and fit {MAX_TENOR} and {MAX_WINDOW}.
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

        uint256 premium = Math.mulDiv(amount, price, 10 ** option.decimals(), isBuy ? Math.Rounding.Floor : Math.Rounding.Ceil);
        if (premium == 0) revert InvalidOrder();

        uint40 deadline = uint40(block.timestamp + duration);
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
    ///      to `account` and is measured there, so any fee counts against the premium.
    function _sell(
        address account,
        Order memory order,
        IBebopSettlement.SingleOrder calldata quote,
        IBebopSettlement.MakerSignature calldata makerSignature
    ) private returns (uint256 premium) {
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

    /// @dev The factory registers every Receipt it creates, and each Receipt names its Option, so a
    ///      registered Receipt that points back at `option` proves `option` is a factory market.
    function _receiptOf(IOption option) private view returns (IReceipt receipt) {
        receipt = option.receipt();
        if (!FACTORY.receipts(address(receipt)) || receipt.option() != address(option)) revert UnknownOption();
    }
}
