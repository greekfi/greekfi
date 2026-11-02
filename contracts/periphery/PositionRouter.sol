// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IFactory } from "../interfaces/IFactory.sol";
import { IOption } from "../interfaces/IOption.sol";
import { IReceipt } from "../interfaces/IReceipt.sol";
import { IBebopSettlement } from "../interfaces/IBebopSettlement.sol";

/**
 * @title  PositionRouter: one fixed address for a writer's mint, burn, transfer, redeem and Bebop limit orders
 * @notice DEMO ONLY. Not audited, not deployed, outside the audit scope in `auditors-instructions.md`.
 *
 *         Every market is its own Option/Receipt clone pair, so an account whose call permissions are
 *         scoped by target address (a Safe behind a Zodiac Roles Modifier, say) would need a new
 *         permission for every series it writes. This router gives that account one fixed target.
 *
 *         {mint}, {burn}, {transfer} and {redeem} take a list of markets, validate that each belongs to
 *         {FACTORY}, then act on `msg.sender`'s own position only.
 *
 *         {createOrder} stores a limit order to sell freshly written options for at least a minimum
 *         USDC premium. Anyone may then {submitOrder} a Bebop quote that fits it: the router mints the
 *         options from the account, sells them to the maker with itself as taker, and the premium goes
 *         straight to the account. The router holds the options only inside that call.
 *
 *         Setup: approve collateral to the factory (the approval caps what all orders can write), then
 *         `factory.setPermissions(router, TRANSFER | MINT | BURN | REDEEM)`. With MINT, {transfer}
 *         writes and sends options to any `to`, so a Roles preset must pin `to`.
 */
contract PositionRouter {
    struct Order {
        IOption option;
        uint40 deadline;
        uint256 amount;
        uint256 minPremium;
    }

    /// @notice The factory whose markets this router accepts.
    IFactory public immutable FACTORY;
    /// @notice Bebop settlement contract that {submitOrder} settles on.
    IBebopSettlement public immutable BEBOP;
    /// @notice The two tokens an order's market may pair, and the premium token is {USDC}.
    address public immutable WETH;
    address public immutable USDC;
    /// @notice Longest time to expiration an order's market may have.
    uint256 public immutable MAX_TENOR;
    /// @notice Longest post-expiry exercise window an order's market may have.
    uint256 public immutable MAX_WINDOW;

    /// @notice Open limit orders by account and account-chosen nonce.
    mapping(address account => mapping(uint256 nonce => Order)) public orders;

    /// @notice `option` was not created by {FACTORY}.
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

    constructor(IFactory factory_, IBebopSettlement bebop_, address weth_, address usdc_, uint256 maxTenor_, uint256 maxWindow_) {
        FACTORY = factory_;
        BEBOP = bebop_;
        WETH = weth_;
        USDC = usdc_;
        MAX_TENOR = maxTenor_;
        MAX_WINDOW = maxWindow_;
    }

    /// @notice For each `i`, mint `amounts[i]` of `options[i]` for the caller, paid from the caller's
    ///         factory collateral allowance. The caller receives both the Option and the Receipt.
    ///         Needs `Perm.MINT`.
    function mint(IOption[] calldata options, uint256[] calldata amounts) external {
        if (options.length != amounts.length) revert LengthMismatch();
        for (uint256 i; i < options.length; ++i) {
            _receiptOf(options[i]);
            options[i].mint(msg.sender, amounts[i]);
        }
    }

    /// @notice For each `i`, pair-burn `amounts[i]` of the caller's matched Option + Receipt in
    ///         `options[i]`'s market; collateral returns to the caller. Needs `Perm.BURN`.
    function burn(IOption[] calldata options, uint256[] calldata amounts) external {
        if (options.length != amounts.length) revert LengthMismatch();
        for (uint256 i; i < options.length; ++i) {
            _receiptOf(options[i]);
            options[i].burn(msg.sender, amounts[i]);
        }
    }

    /// @notice For each `i`, send `amounts[i]` of the caller's `options[i]` to `to`. Needs
    ///         `Perm.TRANSFER`; with `Perm.MINT` too, any shortfall is minted from the caller's
    ///         collateral allowance and the caller keeps the Receipts.
    function transfer(IOption[] calldata options, address to, uint256[] calldata amounts) external {
        if (options.length != amounts.length) revert LengthMismatch();
        for (uint256 i; i < options.length; ++i) {
            _receiptOf(options[i]);
            options[i].transferFrom(msg.sender, to, amounts[i]);
        }
    }

    /// @notice Redeem the caller's full Receipt balance in each of `options`' markets; proceeds go
    ///         to the caller. Needs `Perm.REDEEM`. Without the grant {IReceipt.redeemFor} skips the
    ///         caller silently and this call succeeds having done nothing. Any market whose
    ///         redemption reverts reverts the whole batch.
    function redeem(IOption[] calldata options) external {
        address[] memory holders = new address[](1);
        holders[0] = msg.sender;
        for (uint256 i; i < options.length; ++i) {
            _receiptOf(options[i]).redeemFor(holders);
        }
    }

    /// @notice Offer to write and sell `amount` of `option` for at least `minPremium` USDC in total,
    ///         until `duration` seconds from now. The market must be European, pair {WETH} with {USDC},
    ///         and fit {MAX_TENOR} and {MAX_WINDOW}.
    /// @param duration Lifetime of the order, for the Roles Modifier to cap.
    function createOrder(uint256 nonce, IOption option, uint256 amount, uint256 minPremium, uint32 duration) external {
        if (amount == 0 || minPremium == 0 || orders[msg.sender][nonce].amount != 0) revert InvalidOrder();

        IReceipt receipt = _receiptOf(option);
        address coll = address(receipt.collateral());
        address cons = address(receipt.consideration());
        if (
            !receipt.isEuro() || receipt.expirationDate() > block.timestamp + MAX_TENOR
                || receipt.exerciseDeadline() - receipt.expirationDate() > MAX_WINDOW
                || !((coll == WETH && cons == USDC) || (coll == USDC && cons == WETH))
        ) revert MarketNotAllowed();

        uint40 deadline = uint40(block.timestamp + duration);
        orders[msg.sender][nonce] = Order(option, deadline, amount, minPremium);
        emit OrderCreated(msg.sender, nonce, option, amount, minPremium, deadline);
    }

    /// @notice Withdraw the caller's open order at `nonce`.
    function cancelOrder(uint256 nonce) external {
        if (orders[msg.sender][nonce].amount == 0) revert UnknownOrder();
        delete orders[msg.sender][nonce];
        emit OrderCancelled(msg.sender, nonce);
    }

    /// @notice Fill `account`'s order at `nonce` with a Bebop quote, all or nothing. Callable by
    ///         anyone. The quote must name this router as taker and `account` as receiver, sell
    ///         exactly the order's option and amount for USDC, and pay `account` at least the order's
    ///         minimum premium after any fee.
    function submitOrder(
        address account,
        uint256 nonce,
        IBebopSettlement.SingleOrder calldata quote,
        IBebopSettlement.MakerSignature calldata makerSignature
    ) external {
        Order memory order = orders[account][nonce];
        if (order.amount == 0) revert UnknownOrder();
        if (block.timestamp > order.deadline) revert OrderExpired();
        if (
            quote.taker_address != address(this) || quote.receiver != account || quote.taker_token != address(order.option)
                || quote.taker_amount != order.amount || quote.maker_token != USDC || quote.packed_commands != 0
        ) revert QuoteMismatch();
        delete orders[account][nonce];

        uint256 usdcBefore = IERC20(USDC).balanceOf(account);
        order.option.transferFrom(account, address(this), order.amount);
        order.option.approve(address(BEBOP), order.amount);
        BEBOP.swapSingle(quote, makerSignature, 0);

        uint256 premium = IERC20(USDC).balanceOf(account) - usdcBefore;
        if (premium < order.minPremium) revert PremiumTooLow();
        emit OrderFilled(account, nonce, quote.maker_address, premium);
    }

    /// @dev The factory registers every Receipt it creates, and each Receipt names its Option, so a
    ///      registered Receipt that points back at `option` proves `option` is a factory market.
    function _receiptOf(IOption option) private view returns (IReceipt receipt) {
        receipt = option.receipt();
        if (!FACTORY.receipts(address(receipt)) || receipt.option() != address(option)) revert UnknownOption();
    }
}
