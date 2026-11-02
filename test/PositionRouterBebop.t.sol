// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { CreateParams, IFactory } from "../contracts/interfaces/IFactory.sol";
import { IOption } from "../contracts/interfaces/IOption.sol";
import { IBebopSettlement } from "../contracts/interfaces/IBebopSettlement.sol";
import { ISafe } from "../contracts/interfaces/ISafe.sol";
import { IPositionRouter } from "../contracts/interfaces/IPositionRouter.sol";
import { PositionRouter } from "../contracts/periphery/PositionRouter.sol";

/// @notice Mainnet-fork proof that the ENS Endowment Safe can post a limit order through its Roles
///         Modifier, and that anyone can later fill it with a fresh Bebop quote: the option mints just
///         in time, the premium lands in the Safe, and the router redeems the Receipts after expiry.
contract PositionRouterBebopTest is Test {
    IFactory constant FACTORY = IFactory(0x9999999999906A9a5B3CFB1151Ac6812B3042191); // v1.3
    address constant BEBOP = 0xbbbbbBB520d69a9775E85b458C58c648259FAD5F;
    IERC20 constant WETH = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IERC20 constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    /// @dev endowment.ensdao.eth (Safe 1.3.0).
    address constant SAFE = 0x4F2083f5fBede34C2714aFfb3105539775f7FE64;
    /// @dev Roles Modifier v2.1.1, an enabled module on SAFE. Stands in for kpk's MANAGER role.
    address constant ROLES = 0xa23BEBFD3628D6Dd7B0638c147db11d9B6FaBD59;

    // `Perm` bits from the v1.3 factory (greekfi/contracts c7200d4, contracts/Permissions.sol).
    uint256 constant TRANSFER = 1 << 0;
    uint256 constant MINT = 1 << 1;
    uint256 constant REDEEM = 1 << 3;

    uint256 constant MAKER_KEY = 0xBEB0;
    uint256 constant AMOUNT = 10 ether;
    uint256 constant PREMIUM = 1_000e6;
    uint256 constant NONCE = 1;

    PositionRouter router;
    IOption option;
    address maker;
    address keeper = makeAddr("keeper");

    function setUp() public {
        vm.createSelectFork(vm.envOr("ETH_RPC_URL", string("https://ethereum-rpc.publicnode.com")));

        router = new PositionRouter(FACTORY, IBebopSettlement(BEBOP), address(WETH), address(USDC));
        option = IOption(
            FACTORY.createOption(
                CreateParams({
                    collateral: address(WETH),
                    consideration: address(USDC),
                    expirationDate: uint40(block.timestamp + 7 days),
                    strike: 3_000e18,
                    isPut: false,
                    isEuro: true,
                    windowSeconds: 1 hours
                })
            )
        );

        // The one-off setup the permissions vote would grant, done directly here.
        deal(address(WETH), SAFE, WETH.balanceOf(SAFE) + AMOUNT);
        vm.startPrank(SAFE);
        WETH.approve(address(FACTORY), AMOUNT);
        FACTORY.setPermissions(address(router), TRANSFER | MINT | REDEEM);
        vm.stopPrank();

        maker = vm.addr(MAKER_KEY);
        deal(address(USDC), maker, 10 * PREMIUM);
        vm.prank(maker);
        USDC.approve(BEBOP, type(uint256).max);
    }

    function testFork_OrderFillsAndRedeems() public {
        _createOrder(NONCE, PREMIUM, 1 days);
        // Long after any quote kpk could have seen, a fresh one fills the order.
        vm.warp(block.timestamp + 12 hours);

        uint256 wethBefore = WETH.balanceOf(SAFE);
        uint256 usdcBefore = USDC.balanceOf(SAFE);
        _submit(NONCE, _quote(PREMIUM));

        assertEq(option.balanceOf(maker), AMOUNT, "maker holds the options");
        assertEq(option.receipt().balanceOf(SAFE), AMOUNT, "safe holds the receipts");
        assertEq(USDC.balanceOf(SAFE) - usdcBefore, PREMIUM, "premium to safe");
        assertEq(wethBefore - WETH.balanceOf(SAFE), AMOUNT, "collateral locked");
        assertEq(option.balanceOf(address(router)), 0, "router holds nothing");
        (,, uint256 open,) = router.orders(SAFE, NONCE);
        assertEq(open, 0, "order spent");

        vm.warp(option.receipt().exerciseDeadline() + 1);
        IOption[] memory options = new IOption[](1);
        options[0] = option;
        vm.prank(SAFE);
        router.redeem(options);
        assertEq(option.receipt().balanceOf(SAFE), 0, "receipts redeemed");
        assertEq(WETH.balanceOf(SAFE), wethBefore, "unexercised collateral back");
    }

    function testFork_MakerMayPayMore() public {
        _createOrder(NONCE, PREMIUM, 1 days);
        uint256 usdcBefore = USDC.balanceOf(SAFE);

        _submit(NONCE, _quote(PREMIUM + 1));

        assertEq(USDC.balanceOf(SAFE) - usdcBefore, PREMIUM + 1, "improved premium");
    }

    function testFork_PremiumBelowMinimumReverts() public {
        _createOrder(NONCE, PREMIUM, 1 days);
        _submitExpectingRevert(NONCE, _quote(PREMIUM - 1), abi.encodeWithSelector(IPositionRouter.PremiumTooLow.selector));
    }

    /// @notice A quote must sell exactly the stored order to the router and pay the Safe: no partial
    ///         size, no other receiver, no other taker.
    function testFork_MismatchedQuotesRevert() public {
        _createOrder(NONCE, PREMIUM, 1 days);
        bytes memory mismatch = abi.encodeWithSelector(IPositionRouter.QuoteMismatch.selector);

        IBebopSettlement.SingleOrder memory quote = _quote(PREMIUM);
        quote.taker_amount = AMOUNT / 1e9;
        _submitExpectingRevert(NONCE, quote, mismatch);

        quote = _quote(PREMIUM);
        quote.receiver = maker;
        _submitExpectingRevert(NONCE, quote, mismatch);

        quote = _quote(PREMIUM);
        quote.taker_address = keeper;
        _submitExpectingRevert(NONCE, quote, mismatch);
    }

    function testFork_OrderFillsOnce() public {
        _createOrder(NONCE, PREMIUM, 1 days);
        _submit(NONCE, _quote(PREMIUM));

        IBebopSettlement.SingleOrder memory again = _quote(PREMIUM);
        again.maker_nonce = 2;
        _submitExpectingRevert(NONCE, again, abi.encodeWithSelector(IPositionRouter.UnknownOrder.selector));
    }

    function testFork_CancelledOrderCannotFill() public {
        _createOrder(NONCE, PREMIUM, 1 days);
        assertTrue(_fromRoles(abi.encodeCall(router.cancelOrder, (NONCE))), "cancel");

        _submitExpectingRevert(NONCE, _quote(PREMIUM), abi.encodeWithSelector(IPositionRouter.UnknownOrder.selector));
    }

    function testFork_ExpiredOrderCannotFill() public {
        _createOrder(NONCE, PREMIUM, 1 hours);
        vm.warp(block.timestamp + 1 hours + 1);

        _submitExpectingRevert(NONCE, _quote(PREMIUM), abi.encodeWithSelector(IPositionRouter.OrderExpired.selector));
    }

    /// @notice The Safe's WETH approval to the factory caps what all its orders can write: setUp
    ///         approves exactly AMOUNT, so a second order of AMOUNT cannot mint.
    function testFork_ApprovalCapsOrders() public {
        _createOrder(1, PREMIUM, 1 days);
        _createOrder(2, PREMIUM, 1 days);

        _submit(1, _quote(PREMIUM));
        IBebopSettlement.SingleOrder memory second = _quote(PREMIUM);
        second.maker_nonce = 2;
        _submitExpectingRevert(2, second, "");

        assertEq(option.balanceOf(maker), AMOUNT, "filled up to the approval");
        assertEq(WETH.allowance(SAFE, address(FACTORY)), 0, "approval spent");
    }

    function _createOrder(uint256 nonce, uint256 minPremium, uint32 duration) internal {
        assertTrue(_fromRoles(abi.encodeCall(router.createOrder, (nonce, option, AMOUNT, minPremium, duration))), "create");
    }

    /// @dev What the Roles Modifier does for kpk: have the Safe CALL the router.
    function _fromRoles(bytes memory data) internal returns (bool) {
        vm.prank(ROLES);
        return ISafe(SAFE).execTransactionFromModule(address(router), 0, data, 0);
    }

    /// @dev A fresh RFQ quote with the router as taker and the Safe as receiver.
    function _quote(uint256 makerAmount) internal view returns (IBebopSettlement.SingleOrder memory) {
        return IBebopSettlement.SingleOrder({
            expiry: block.timestamp + 1 minutes,
            taker_address: address(router),
            maker_address: maker,
            maker_nonce: 1,
            taker_token: address(option),
            maker_token: address(USDC),
            taker_amount: AMOUNT,
            maker_amount: makerAmount,
            receiver: SAFE,
            packed_commands: 0,
            flags: 0
        });
    }

    function _makerSig(IBebopSettlement.SingleOrder memory quote) internal view returns (IBebopSettlement.MakerSignature memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(MAKER_KEY, IBebopSettlement(BEBOP).hashSingleOrder(quote, 0, 0, 0));
        return IBebopSettlement.MakerSignature(abi.encodePacked(r, s, v), 0);
    }

    /// @dev A keeper with no tie to the Safe or the maker submits.
    function _submit(uint256 nonce, IBebopSettlement.SingleOrder memory quote) internal {
        IBebopSettlement.MakerSignature memory sig = _makerSig(quote);
        vm.prank(keeper);
        router.submitOrder(SAFE, nonce, quote, sig);
    }

    function _submitExpectingRevert(uint256 nonce, IBebopSettlement.SingleOrder memory quote, bytes memory reason) internal {
        IBebopSettlement.MakerSignature memory sig = _makerSig(quote);
        vm.expectRevert(reason);
        vm.prank(keeper);
        router.submitOrder(SAFE, nonce, quote, sig);
    }
}
