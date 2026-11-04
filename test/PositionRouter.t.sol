// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { CreateParams, IFactory } from "../contracts/interfaces/IFactory.sol";
import { IOption } from "../contracts/interfaces/IOption.sol";
import { IReceipt } from "../contracts/interfaces/IReceipt.sol";
import { IBebopSettlement } from "../contracts/interfaces/IBebopSettlement.sol";
import { IPositionRouter } from "../contracts/interfaces/IPositionRouter.sol";
import { PositionRouter } from "../contracts/periphery/PositionRouter.sol";

/// @dev Claims a real market's Receipt as its own, to probe the router's back-pointer check.
contract FakeOption {
    address public immutable receipt;

    constructor(address receipt_) {
        receipt = receipt_;
    }
}

/// @notice The router's transfer / redeem and order book against the deployed v1.3 factory on a mainnet fork.
contract PositionRouterTest is Test {
    IFactory constant FACTORY = IFactory(0x9999999999906A9a5B3CFB1151Ac6812B3042191); // v1.3
    address constant BEBOP = 0xbbbbbBB520d69a9775E85b458C58c648259FAD5F;
    IERC20 constant WETH = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IERC20 constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);

    // `Perm` bits from the v1.3 factory (greekfi/contracts c7200d4, contracts/Permissions.sol).
    uint256 constant TRANSFER = 1 << 0;
    uint256 constant MINT = 1 << 1;
    uint256 constant REDEEM = 1 << 3;
    uint256 constant ALL_ROUTER_BITS = TRANSFER | MINT | REDEEM;

    PositionRouter router;
    IOption opt;
    IReceipt rct;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address mallory = makeAddr("mallory");

    function setUp() public {
        vm.createSelectFork(vm.envOr("ETH_RPC_URL", string("https://ethereum-rpc.publicnode.com")));
        router = new PositionRouter(FACTORY, IBebopSettlement(BEBOP), address(WETH), address(USDC));
        (opt, rct) = _newOption(3_000e18, false);

        address[3] memory who = [alice, bob, mallory];
        for (uint256 i; i < who.length; ++i) {
            deal(address(WETH), who[i], 100 ether);
            deal(address(USDC), who[i], 1_000_000e6);
            vm.startPrank(who[i]);
            WETH.approve(address(FACTORY), type(uint256).max);
            USDC.approve(address(FACTORY), type(uint256).max);
            vm.stopPrank();
        }
    }

    function testFork_Transfer_MintsShortfallAndKeepsReceipts() public {
        _grant(alice, TRANSFER | MINT);
        _mint(opt, alice, 4 ether);

        vm.prank(alice);
        router.transfer(_opts(opt), bob, _amts(10 ether));

        assertEq(opt.balanceOf(bob), 10 ether, "bob holds the options");
        assertEq(opt.balanceOf(alice), 0, "alice sent her own first");
        assertEq(rct.balanceOf(alice), 10 ether, "alice keeps every receipt");
    }

    /// @notice One call writes and sends across two markets; one later call redeems both.
    function testFork_Batch_SpansMarkets() public {
        _grant(alice, ALL_ROUTER_BITS);
        (IOption opt2, IReceipt rct2) = _newOption(3_500e18, false);
        uint256 wethBefore = WETH.balanceOf(alice);

        vm.prank(alice);
        router.transfer(_opts(opt, opt2), bob, _amts(10 ether, 5 ether));

        assertEq(opt.balanceOf(bob) + opt2.balanceOf(bob), 15 ether, "bob holds both");
        assertEq(wethBefore - WETH.balanceOf(alice), 15 ether, "collateral locked");

        vm.warp(rct.exerciseDeadline() + 1);
        vm.prank(alice);
        router.redeem(_opts(opt, opt2));

        assertEq(rct.balanceOf(alice) + rct2.balanceOf(alice), 0, "both redeemed");
        assertEq(WETH.balanceOf(alice), wethBefore, "all collateral back");
    }

    function testFork_Transfer_RequiresGrant() public {
        _mint(opt, alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("ERC20InsufficientAllowance(address,uint256,uint256)", address(router), 0, 1 ether));
        router.transfer(_opts(opt), bob, _amts(1 ether));
    }

    function testFork_Redeem_PaysCallerAfterPartialExercise() public {
        _grant(alice, REDEEM);
        _mint(opt, alice, 10 ether);
        vm.prank(alice);
        require(opt.transfer(bob, 4 ether));
        vm.prank(bob);
        opt.exercise(4 ether);

        vm.warp(rct.exerciseDeadline() + 1);
        uint256 wethBefore = WETH.balanceOf(alice);
        uint256 usdcBefore = USDC.balanceOf(alice);

        vm.prank(alice);
        router.redeem(_opts(opt));

        assertEq(rct.balanceOf(alice), 0, "receipt redeemed");
        assertEq(USDC.balanceOf(alice) - usdcBefore, 12_000e6, "strike proceeds");
        assertEq(WETH.balanceOf(alice) - wethBefore, 6 ether, "unexercised collateral");
    }

    function testFork_Redeem_WithoutGrantIsSilentNoOp() public {
        _mint(opt, alice, 10 ether);
        vm.warp(rct.exerciseDeadline() + 1);

        vm.prank(alice);
        router.redeem(_opts(opt));

        assertEq(rct.balanceOf(alice), 10 ether, "nothing redeemed");
    }

    /// @notice A third party calling the router acts only on itself, even when the victim has
    ///         granted the router every bit it uses.
    function testFork_ThirdPartyCannotTouchGrantorPosition() public {
        _grant(alice, ALL_ROUTER_BITS);
        _mint(opt, alice, 10 ether);

        vm.prank(mallory);
        // mallory never granted the router, so it can only ever reach mallory's own tokens.
        vm.expectRevert(abi.encodeWithSignature("ERC20InsufficientAllowance(address,uint256,uint256)", address(router), 0, 1 ether));
        router.transfer(_opts(opt), mallory, _amts(1 ether));

        vm.warp(rct.exerciseDeadline() + 1);
        vm.prank(mallory);
        router.redeem(_opts(opt));

        assertEq(opt.balanceOf(alice), 10 ether, "option untouched");
        assertEq(rct.balanceOf(alice), 10 ether, "receipt untouched");
    }

    /// @notice One foreign market anywhere in the list reverts the whole batch.
    function testFork_RejectsMarketsOutsideFactory() public {
        _grant(alice, ALL_ROUTER_BITS);
        IOption impostor = IOption(address(new FakeOption(address(rct))));
        IOption unregistered = IOption(address(new FakeOption(address(0xdead))));

        vm.startPrank(alice);
        vm.expectRevert(IPositionRouter.UnknownOption.selector);
        router.transfer(_opts(opt, impostor), bob, _amts(1 ether, 1 ether));
        vm.expectRevert(IPositionRouter.UnknownOption.selector);
        router.redeem(_opts(unregistered));
        vm.stopPrank();

        assertEq(opt.balanceOf(bob), 0, "first leg rolled back");
    }

    function testFork_CreateOrder_StoresAndCancels() public {
        (IOption euro,) = _newOption(3_000e18, true);

        _sell(7, euro, _terms(euro), "");
        (IOption stored, uint40 deadline, bool isBuy, uint256 amount, uint256 premium) = router.orders(alice, 7);
        assertEq(address(stored), address(euro), "option");
        assertEq(deadline, block.timestamp + 10 minutes, "deadline");
        assertEq(amount, 1 ether, "amount");
        assertFalse(isBuy, "sell");
        assertEq(premium, 100e6, "premium");

        _sell(7, euro, _terms(euro), abi.encodeWithSelector(IPositionRouter.InvalidOrder.selector));

        vm.prank(alice);
        router.cancelOrder(7);
        (,,, amount,) = router.orders(alice, 7);
        assertEq(amount, 0, "cancelled");
    }

    /// @notice The total is the per-option price times the size, rounded in the account's favour,
    ///         so a dust order can't sell for nothing or buy for a full cap (the old H-01 path).
    function testFork_CreateOrder_PricesPerOption() public {
        (IOption euro,) = _newOption(3_000e18, true);
        Terms memory t = _terms(euro);
        bytes memory invalid = abi.encodeWithSelector(IPositionRouter.InvalidOrder.selector);

        _order(1, euro, t, false, 1.5 ether, 100e6, "");
        assertEq(_premium(1), 150e6, "1.5 options at 100 USDC");

        _order(2, euro, t, false, 1, 100e6, "");
        assertEq(_premium(2), 1, "a 1-wei sell's floor rounds up");

        _order(3, euro, t, true, 1, 100e6, invalid); // a 1-wei buy's cap rounds down to 0

        _order(4, euro, t, false, 1 ether, 0, invalid);
    }

    function testFork_CreateOrder_RejectsDisallowedMarkets() public {
        (IOption longDated,) = _newOption(3_000e18, true, 31 days, 1 hours);
        (IOption longWindow,) = _newOption(3_000e18, true, 1 days, 2 hours);
        IOption impostor = IOption(address(new FakeOption(address(rct))));
        bytes memory notAllowed = abi.encodeWithSelector(IPositionRouter.MarketNotAllowed.selector);

        _sell(1, opt, _terms(opt), notAllowed); // American
        _sell(1, longDated, _terms(longDated), notAllowed);
        _sell(1, longWindow, _terms(longWindow), notAllowed);
        _sell(1, impostor, _terms(opt), abi.encodeWithSelector(IPositionRouter.UnknownOption.selector));
    }

    /// @notice Each restated term must be the market's own.
    function testFork_CreateOrder_RejectsWrongTerms() public {
        (IOption euro,) = _newOption(3_000e18, true);
        bytes memory mismatch = abi.encodeWithSelector(IPositionRouter.TermsMismatch.selector);

        Terms memory t = _terms(euro);
        t.strike = 1;
        _sell(1, euro, t, mismatch);
        t = _terms(euro);
        t.expirationDate += 1;
        _sell(1, euro, t, mismatch);
        t = _terms(euro);
        t.isPut = true;
        _sell(1, euro, t, mismatch);
        t = _terms(euro);
        t.isEuro = false;
        _sell(1, euro, t, mismatch);
        t = _terms(euro);
        t.windowSeconds -= 1;
        _sell(1, euro, t, mismatch);
    }

    /// @notice The factory lets a WETH-collateral call carry `isPut = true`. With a put-range strike
    ///         (`1e36 / 2_500e18`) it is a $0.0004 call, so the router refuses the label.
    function testFork_CreateOrder_RejectsMislabeledPut() public {
        IOption mislabeled = IOption(
            FACTORY.createOption(
                CreateParams({
                    collateral: address(WETH),
                    consideration: address(USDC),
                    expirationDate: uint40(block.timestamp + 1 days),
                    strike: 1e36 / 2_500e18,
                    isPut: true,
                    isEuro: true,
                    windowSeconds: 1 hours
                })
            )
        );
        _sell(1, mislabeled, _terms(mislabeled), abi.encodeWithSelector(IPositionRouter.MarketNotAllowed.selector));
    }

    struct Terms {
        uint256 strike;
        uint40 expirationDate;
        bool isPut;
        bool isEuro;
        uint40 windowSeconds;
    }

    function _terms(IOption option) internal view returns (Terms memory t) {
        t = Terms(option.strike(), option.expirationDate(), option.isPut(), option.isEuro(), 0);
        t.windowSeconds = uint40(option.exerciseDeadline() - t.expirationDate);
    }

    /// @dev Alice offers to sell 1 option at 100 USDC for 10 minutes, expecting `err` if non-empty.
    function _sell(uint256 nonce, IOption option, Terms memory t, bytes memory err) internal {
        _order(nonce, option, t, false, 1 ether, 100e6, err);
    }

    function _order(uint256 nonce, IOption option, Terms memory t, bool isBuy, uint256 amount, uint256 price, bytes memory err) internal {
        if (err.length != 0) vm.expectRevert(err);
        vm.prank(alice);
        router.createOrder(nonce, option, t.strike, t.expirationDate, t.isPut, t.isEuro, t.windowSeconds, isBuy, amount, price, 10 minutes);
    }

    function _premium(uint256 nonce) internal view returns (uint256 premium) {
        (,,,, premium) = router.orders(alice, nonce);
    }

    function _newOption(uint256 strike, bool isEuro) internal returns (IOption option, IReceipt receipt) {
        return _newOption(strike, isEuro, 1 days, 1 hours);
    }

    function _newOption(uint256 strike, bool isEuro, uint256 tenor, uint40 window) internal returns (IOption option, IReceipt receipt) {
        option = IOption(
            FACTORY.createOption(
                CreateParams({
                    collateral: address(WETH),
                    consideration: address(USDC),
                    expirationDate: uint40(block.timestamp + tenor),
                    strike: strike,
                    isPut: false,
                    isEuro: isEuro,
                    windowSeconds: window
                })
            )
        );
        receipt = option.receipt();
    }

    function _mint(IOption option, address who, uint256 amount) internal {
        vm.prank(who);
        option.mint(amount);
    }

    function _grant(address owner, uint256 mask) internal {
        vm.prank(owner);
        FACTORY.setPermissions(address(router), mask);
    }

    function _opts(IOption a) internal pure returns (IOption[] memory list) {
        list = new IOption[](1);
        list[0] = a;
    }

    function _opts(IOption a, IOption b) internal pure returns (IOption[] memory list) {
        list = new IOption[](2);
        (list[0], list[1]) = (a, b);
    }

    function _amts(uint256 a) internal pure returns (uint256[] memory list) {
        list = new uint256[](1);
        list[0] = a;
    }

    function _amts(uint256 a, uint256 b) internal pure returns (uint256[] memory list) {
        list = new uint256[](2);
        (list[0], list[1]) = (a, b);
    }
}
