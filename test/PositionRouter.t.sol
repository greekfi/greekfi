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

        vm.startPrank(alice);
        router.createOrder(7, euro, 1 ether, 100e6, 10 minutes);
        (IOption stored, uint40 deadline, uint256 amount, uint256 minPremium) = router.orders(alice, 7);
        assertEq(address(stored), address(euro), "option");
        assertEq(deadline, block.timestamp + 10 minutes, "deadline");
        assertEq(amount, 1 ether, "amount");
        assertEq(minPremium, 100e6, "min premium");

        vm.expectRevert(IPositionRouter.InvalidOrder.selector);
        router.createOrder(7, euro, 1 ether, 100e6, 10 minutes);

        router.cancelOrder(7);
        (,, amount,) = router.orders(alice, 7);
        assertEq(amount, 0, "cancelled");
        vm.stopPrank();
    }

    function testFork_CreateOrder_RejectsDisallowedMarkets() public {
        IOption impostor = IOption(address(new FakeOption(address(rct))));

        vm.startPrank(alice);
        vm.expectRevert(IPositionRouter.MarketNotAllowed.selector);
        router.createOrder(1, opt, 1 ether, 100e6, 10 minutes); // American
        vm.expectRevert(IPositionRouter.UnknownOption.selector);
        router.createOrder(1, impostor, 1 ether, 100e6, 10 minutes);
        vm.stopPrank();
    }

    function _newOption(uint256 strike, bool isEuro) internal returns (IOption option, IReceipt receipt) {
        option = IOption(
            FACTORY.createOption(
                CreateParams({
                    collateral: address(WETH),
                    consideration: address(USDC),
                    expirationDate: uint40(block.timestamp + 1 days),
                    strike: strike,
                    isPut: false,
                    isEuro: isEuro,
                    windowSeconds: 1 hours
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
