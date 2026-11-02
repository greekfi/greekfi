// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

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
 *         USDC premium. Anyone may then {submitOrder} a Bebop quote that fits it: the router mints the
 *         options from the account, sells them to the maker with itself as taker, and the premium goes
 *         straight to the account. The router holds the options only inside that call.
 *
 *         Setup: approve collateral to the factory (the approval caps what all orders can write), then
 *         `factory.setPermissions(router, TRANSFER | MINT | REDEEM)`. With MINT, {transfer}
 *         writes and sends options to any `to`, so a Roles preset must pin `to`.
 */
contract PositionRouter is IPositionRouter {
    /// @notice The factory whose markets this router accepts.
    IFactory public immutable FACTORY;
    /// @notice Bebop settlement contract that {submitOrder} settles on.
    IBebopSettlement public immutable BEBOP;
    /// @notice The two tokens an order's market may pair, and the premium token is {USDC}.
    address public immutable WETH;
    address public immutable USDC;

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
    function transfer(IOption[] calldata options, address to, uint256[] calldata amounts) external {
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
    ///         until `duration` seconds from now. The market must be European and pair {WETH} with
    ///         {USDC}.
    /// @param duration Lifetime of the order, for the Roles Modifier to cap.
    function createOrder(uint256 nonce, IOption option, uint256 amount, uint256 minPremium, uint32 duration) external {
        if (amount == 0 || minPremium == 0 || orders[msg.sender][nonce].amount != 0) revert InvalidOrder();

        IReceipt receipt = _receiptOf(option);
        address coll = address(receipt.collateral());
        address cons = address(receipt.consideration());
        if (!receipt.isEuro() || !((coll == WETH && cons == USDC) || (coll == USDC && cons == WETH))) revert MarketNotAllowed();

        uint40 deadline = uint40(block.timestamp + duration);
        orders[msg.sender][nonce] = Order(option, deadline, amount, minPremium);
        emit OrderCreated(msg.sender, nonce, option, amount, minPremium, deadline);
    }

    /// @notice Withdraw the caller's open order at `nonce`.
    function cancelOrder(uint256 nonce) external {
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
