// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { CreateParams, IFactory } from "../contracts/interfaces/IFactory.sol";
import { IOption } from "../contracts/interfaces/IOption.sol";
import { IBebopSettlement } from "../contracts/interfaces/IBebopSettlement.sol";
import { ISafe } from "../contracts/interfaces/ISafe.sol";
import { PositionRouter } from "../contracts/periphery/PositionRouter.sol";

/// @notice Mainnet-fork proof that the ENS Endowment Safe can pre-sign a Bebop order through its Roles
///         Modifier and the router, and that a maker can then settle it alone: the option mints just in
///         time, the premium lands in the Safe, and the router redeems the Receipts after expiry.
contract PositionRouterBebopTest is Test {
    IFactory constant FACTORY = IFactory(0x9999999999906A9a5B3CFB1151Ac6812B3042191); // v1.3
    address constant BEBOP = 0xbbbbbBB520d69a9775E85b458C58c648259FAD5F;
    IERC20 constant WETH = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IERC20 constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    /// @dev endowment.ensdao.eth (Safe 1.3.0, CompatibilityFallbackHandler).
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
    uint8 constant DELEGATECALL = 1;

    PositionRouter router;
    IOption option;
    address maker;

    function setUp() public {
        vm.createSelectFork(vm.envOr("ETH_RPC_URL", string("https://ethereum-rpc.publicnode.com")));

        router = new PositionRouter(FACTORY, IBebopSettlement(BEBOP), address(WETH), address(USDC), 30 days, 1 hours);
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
        FACTORY.setPermissions(BEBOP, TRANSFER | MINT);
        FACTORY.setPermissions(address(router), REDEEM);
        vm.stopPrank();

        maker = vm.addr(MAKER_KEY);
        deal(address(USDC), maker, 10 * PREMIUM);
        vm.prank(maker);
        USDC.approve(BEBOP, type(uint256).max);
    }

    function testFork_SignedOrderSettlesAndRedeems() public {
        IBebopSettlement.SingleOrder memory order = _order(PREMIUM);
        assertTrue(_fromRoles(abi.encodeCall(router.signOrder, (order, PREMIUM, 30 minutes))), "sign");

        uint256 wethBefore = WETH.balanceOf(SAFE);
        uint256 usdcBefore = USDC.balanceOf(SAFE);
        _settle(order, false);

        assertEq(option.balanceOf(maker), AMOUNT, "maker holds the options");
        assertEq(option.receipt().balanceOf(SAFE), AMOUNT, "safe holds the receipts");
        assertEq(USDC.balanceOf(SAFE) - usdcBefore, PREMIUM, "premium to safe");
        assertEq(wethBefore - WETH.balanceOf(SAFE), AMOUNT, "collateral locked");

        vm.warp(option.receipt().exerciseDeadline() + 1);
        vm.prank(SAFE);
        IOption[] memory options = new IOption[](1);
        options[0] = option;
        router.redeem(options);
        assertEq(option.receipt().balanceOf(SAFE), 0, "receipts redeemed");
        assertEq(WETH.balanceOf(SAFE), wethBefore, "unexercised collateral back");
    }

    function testFork_MakerMayRaisePremium() public {
        assertTrue(_fromRoles(abi.encodeCall(router.signOrder, (_order(PREMIUM), PREMIUM, 30 minutes))), "sign");
        uint256 usdcBefore = USDC.balanceOf(SAFE);

        _settle(_order(PREMIUM + 1), false);

        assertEq(USDC.balanceOf(SAFE) - usdcBefore, PREMIUM + 1, "improved premium");
    }

    function testFork_UnsignedOrderReverts() public {
        IBebopSettlement.SingleOrder memory order = _order(PREMIUM);
        _settle(order, true);
    }

    function testFork_ChangedOrderReverts() public {
        IBebopSettlement.SingleOrder memory order = _order(PREMIUM);
        assertTrue(_fromRoles(abi.encodeCall(router.signOrder, (order, PREMIUM, 30 minutes))), "sign");

        order.receiver = maker;
        _settle(order, true);
    }

    function testFork_UnsignOrderRevokes() public {
        IBebopSettlement.SingleOrder memory order = _order(PREMIUM);
        assertTrue(_fromRoles(abi.encodeCall(router.signOrder, (order, PREMIUM, 30 minutes))), "sign");
        assertTrue(_fromRoles(abi.encodeCall(router.unsignOrder, (order, PREMIUM))), "unsign");

        _settle(order, true);
    }

    function testFork_SignOrderRefusesForeignReceiver() public {
        IBebopSettlement.SingleOrder memory order = _order(PREMIUM);
        order.receiver = maker;
        assertFalse(_fromRoles(abi.encodeCall(router.signOrder, (order, PREMIUM, 30 minutes))), "sign must fail");
    }

    /// @notice The submitter picks the fill size; the premium scales pro-rata, and the first fill of
    ///         any size spends the maker nonce, so the rest of the order can never fill.
    function testFork_PartialFillSpendsTheOrder() public {
        IBebopSettlement.SingleOrder memory order = _order(PREMIUM);
        assertTrue(_fromRoles(abi.encodeCall(router.signOrder, (order, PREMIUM, 30 minutes))), "sign");
        uint256 usdcBefore = USDC.balanceOf(SAFE);

        _settleFill(order, 4 ether);

        assertEq(option.balanceOf(maker), 4 ether, "partial fill");
        assertEq(USDC.balanceOf(SAFE) - usdcBefore, PREMIUM * 4 / 10, "pro-rata premium");
        _settleExpectingRevert(order, 0, abi.encodeWithSignature("InvalidNonce()"));
    }

    /// @notice The Safe's WETH approval to the factory caps what any number of pre-signed orders can
    ///         mint. setUp approves exactly AMOUNT, so two orders of AMOUNT each fill 4 + 6 and a
    ///         third order cannot mint anything.
    function testFork_ApprovalCapsPreSignedOrders() public {
        IBebopSettlement.SingleOrder memory first = _order(PREMIUM, 1);
        IBebopSettlement.SingleOrder memory second = _order(PREMIUM, 2);
        IBebopSettlement.SingleOrder memory third = _order(PREMIUM, 3);
        assertTrue(_fromRoles(abi.encodeCall(router.signOrder, (first, PREMIUM, 30 minutes))), "sign 1");
        assertTrue(_fromRoles(abi.encodeCall(router.signOrder, (second, PREMIUM, 30 minutes))), "sign 2");
        assertTrue(_fromRoles(abi.encodeCall(router.signOrder, (third, PREMIUM, 30 minutes))), "sign 3");
        uint256 usdcBefore = USDC.balanceOf(SAFE);

        _settleFill(first, 4 ether);
        _settleFill(second, 6 ether);
        // The auto-mint's WETH pull fails on the spent approval; Bebop wraps it.
        _settleExpectingRevert(third, 1 ether, bytes("SafeERC20: low-level call failed"));

        assertEq(option.balanceOf(maker), AMOUNT, "filled up to the approval");
        assertEq(USDC.balanceOf(SAFE) - usdcBefore, PREMIUM, "premium for the whole amount");
        assertEq(WETH.allowance(SAFE, address(FACTORY)), 0, "approval spent");
    }

    function _order(uint256 makerAmount) internal view returns (IBebopSettlement.SingleOrder memory) {
        return _order(makerAmount, 1);
    }

    function _order(uint256 makerAmount, uint256 nonce) internal view returns (IBebopSettlement.SingleOrder memory) {
        return IBebopSettlement.SingleOrder({
            expiry: block.timestamp + 30 minutes,
            taker_address: SAFE,
            maker_address: maker,
            maker_nonce: nonce,
            taker_token: address(option),
            maker_token: address(USDC),
            taker_amount: AMOUNT,
            maker_amount: makerAmount,
            receiver: SAFE,
            packed_commands: 0,
            flags: 1 // taker signature type: EIP-1271
        });
    }

    /// @dev What the Roles Modifier does for kpk: have the Safe DELEGATECALL the router.
    function _fromRoles(bytes memory data) internal returns (bool) {
        vm.prank(ROLES);
        return ISafe(SAFE).execTransactionFromModule(address(router), 0, data, DELEGATECALL);
    }

    /// @dev The maker signs its own side and submits a full fill; the Safe's taker signature is the
    ///      empty bytes. Without a matching `signedMessages` entry the Safe's fallback handler reverts
    ///      the whole settlement with "Hash not approved".
    function _settle(IBebopSettlement.SingleOrder memory order, bool expectUnapproved) internal {
        if (expectUnapproved) _settleExpectingRevert(order, 0, bytes("Hash not approved"));
        else _settleFill(order, 0);
    }

    /// @dev `filled` is the submitter's choice and in neither signature; 0 means the full order.
    function _settleFill(IBebopSettlement.SingleOrder memory order, uint256 filled) internal {
        bytes memory makerSig = _makerSig(order);
        vm.prank(maker);
        _submit(order, makerSig, filled);
    }

    function _settleExpectingRevert(IBebopSettlement.SingleOrder memory order, uint256 filled, bytes memory reason) internal {
        bytes memory makerSig = _makerSig(order);
        vm.expectRevert(reason);
        vm.prank(maker);
        _submit(order, makerSig, filled);
    }

    function _makerSig(IBebopSettlement.SingleOrder memory order) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(MAKER_KEY, IBebopSettlement(BEBOP).hashSingleOrder(order, 0, 0, 0));
        return abi.encodePacked(r, s, v);
    }

    function _submit(IBebopSettlement.SingleOrder memory order, bytes memory makerSig, uint256 filled) internal {
        IBebopSettlement(BEBOP)
            .settleSingle(
                order,
                IBebopSettlement.MakerSignature(makerSig, 0),
                filled,
                IBebopSettlement.OldSingleQuote(false, PREMIUM, order.maker_nonce),
                ""
            );
    }
}
