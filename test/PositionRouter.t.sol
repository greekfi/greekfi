// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { CreateParams, IFactory } from "../contracts/interfaces/IFactory.sol";
import { IOption } from "../contracts/interfaces/IOption.sol";
import { IReceipt } from "../contracts/interfaces/IReceipt.sol";
import { IBebopSettlement } from "../contracts/interfaces/IBebopSettlement.sol";
import { IPriceFeed } from "../contracts/interfaces/IPriceFeed.sol";
import { IPositionRouter } from "../contracts/interfaces/IPositionRouter.sol";
import { PositionRouter } from "../contracts/periphery/PositionRouter.sol";
import { MockPriceFeed } from "./MockPriceFeed.sol";

/// @dev Claims a real market's Receipt as its own, to probe the router's back-pointer check.
contract FakeOption {
    address public immutable receipt;

    constructor(address receipt_) {
        receipt = receipt_;
    }
}

/// @notice The router's redeem and order book against the deployed v1.3 factory on a mainnet fork.
///         Spot comes from a mock feed pinned at $3,000 unless a test says otherwise.
contract PositionRouterTest is Test {
    IFactory constant FACTORY = IFactory(0x9999999999906A9a5B3CFB1151Ac6812B3042191); // v1.3
    address constant BEBOP = 0xbbbbbBB520d69a9775E85b458C58c648259FAD5F;
    IERC20 constant WETH = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IERC20 constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    /// @dev Chainlink ETH / USD.
    IPriceFeed constant CHAINLINK_ETH_USD = IPriceFeed(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419);

    // `Perm` bits from the v1.3 factory (greekfi/contracts c7200d4, contracts/Permissions.sol).
    uint256 constant TRANSFER = 1 << 0;
    uint256 constant MINT = 1 << 1;
    uint256 constant REDEEM = 1 << 3;
    uint256 constant ALL_ROUTER_BITS = TRANSFER | MINT | REDEEM;

    PositionRouter router;
    MockPriceFeed feed;
    IOption opt;
    IReceipt rct;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address mallory = makeAddr("mallory");

    function setUp() public {
        vm.createSelectFork(vm.envOr("ETH_RPC_URL", string("https://ethereum-rpc.publicnode.com")));
        feed = new MockPriceFeed();
        router = new PositionRouter(FACTORY, IBebopSettlement(BEBOP), address(WETH), address(USDC), feed);
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

    /// @notice One call redeems across two markets.
    function testFork_Redeem_SpansMarkets() public {
        _grant(alice, REDEEM);
        (IOption opt2, IReceipt rct2) = _newOption(3_500e18, false);
        uint256 wethBefore = WETH.balanceOf(alice);
        _mint(opt, alice, 10 ether);
        _mint(opt2, alice, 5 ether);

        vm.warp(rct.exerciseDeadline() + 1);
        vm.prank(alice);
        router.redeem(_opts(opt, opt2));

        assertEq(rct.balanceOf(alice) + rct2.balanceOf(alice), 0, "both redeemed");
        assertEq(WETH.balanceOf(alice), wethBefore, "all collateral back");
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

        vm.warp(rct.exerciseDeadline() + 1);
        vm.prank(mallory);
        router.redeem(_opts(opt));

        assertEq(opt.balanceOf(alice), 10 ether, "option untouched");
        assertEq(rct.balanceOf(alice), 10 ether, "receipt untouched");
    }

    /// @notice One foreign market anywhere in the list reverts the whole batch.
    function testFork_RejectsMarketsOutsideFactory() public {
        _grant(alice, REDEEM);
        _mint(opt, alice, 1 ether);
        IOption impostor = IOption(address(new FakeOption(address(rct))));
        IOption unregistered = IOption(address(new FakeOption(address(0xdead))));
        vm.warp(rct.exerciseDeadline() + 1);

        vm.startPrank(alice);
        vm.expectRevert(IPositionRouter.UnknownOption.selector);
        router.redeem(_opts(opt, impostor));
        vm.expectRevert(IPositionRouter.UnknownOption.selector);
        router.redeem(_opts(unregistered));
        vm.stopPrank();

        assertEq(rct.balanceOf(alice), 1 ether, "first leg rolled back");
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

        _order(1, euro, t, false, 1.5 ether, 100e6, 10 minutes, "");
        assertEq(_premium(1), 150e6, "1.5 options at 100 USDC");

        _order(2, euro, t, false, 1, 100e6, 10 minutes, "");
        assertEq(_premium(2), 1, "a 1-wei sell's floor rounds up");

        _order(3, euro, t, true, 1, 50e6, 10 minutes, invalid); // a 1-wei buy's cap rounds down to 0

        _order(4, euro, t, false, 1 ether, 0, 10 minutes, invalid);
    }

    function testFork_CreateOrder_RejectsDisallowedMarkets() public {
        (IOption longWindow,) = _newOption(3_000e18, true, 1 days, 2 hours);
        IOption impostor = IOption(address(new FakeOption(address(rct))));
        bytes memory notAllowed = abi.encodeWithSelector(IPositionRouter.MarketNotAllowed.selector);

        _sell(1, opt, _terms(opt), notAllowed); // American
        _sell(1, longWindow, _terms(longWindow), notAllowed);
        _sell(1, impostor, _terms(opt), abi.encodeWithSelector(IPositionRouter.UnknownOption.selector));
    }

    /// @notice Markets may expire up to MAX_TENOR (35 days) out.
    function testFork_CreateOrder_TenorUpTo35Days() public {
        (IOption at35,) = _newOption(3_000e18, true, 35 days, 1 hours);
        (IOption past35,) = _newOption(3_000e18, true, 35 days + 1, 1 hours);

        _sell(1, at35, _terms(at35), "");
        _sell(2, past35, _terms(past35), abi.encodeWithSelector(IPositionRouter.MarketNotAllowed.selector));
    }

    /// @notice An order may end up to EXPIRY_BUFFER (2 hours) after its market expires, and a market
    ///         that expired longer ago than that can't be ordered at all.
    function testFork_CreateOrder_EndsWithinBufferAfterExpiry() public {
        (IOption euro,) = _newOption(3_000e18, true); // expires in 1 day
        Terms memory t = _terms(euro);
        uint32 latest = uint32(1 days + router.EXPIRY_BUFFER());
        bytes memory outlives = abi.encodeWithSelector(IPositionRouter.OrderOutlivesMarket.selector);

        _order(1, euro, t, false, 1 ether, 100e6, latest, "");
        _order(2, euro, t, false, 1 ether, 100e6, latest + 1, outlives);

        vm.warp(t.expirationDate + 1);
        _order(3, euro, t, false, 1 ether, 100e6, uint32(router.EXPIRY_BUFFER() - 1), "");

        vm.warp(t.expirationDate + router.EXPIRY_BUFFER() + 1);
        _order(4, euro, t, false, 1 ether, 100e6, 0, outlives);
    }

    /// @notice A sell's price may not go below intrinsic value at spot ($3,000).
    function testFork_CreateOrder_SellFloorIsIntrinsic() public {
        bytes memory outOfBounds = abi.encodeWithSelector(IPositionRouter.PriceOutOfBounds.selector);
        (IOption itmCall,) = _newOption(2_500e18, true); // $500 in the money
        Terms memory t = _terms(itmCall);
        _order(1, itmCall, t, false, 1 ether, 500e6, 10 minutes, "");
        _order(2, itmCall, t, false, 1 ether, 500e6 - 1, 10 minutes, outOfBounds);

        // One put is on 1 USDC of collateral, i.e. 1/3,500 ETH: worth $500 / 3,500 in the money.
        IOption itmPut = _newPut(3_500e18);
        t = _terms(itmPut);
        uint256 intrinsic = uint256(500e6) * 1e6 / 3_500e6;
        _order(3, itmPut, t, false, 1e6, intrinsic, 10 minutes, "");
        _order(4, itmPut, t, false, 1e6, intrinsic - 1, 10 minutes, outOfBounds);

        // Out of the money, the floor is 0.
        (IOption otmCall,) = _newOption(3_500e18, true);
        (uint256 floor,) = router.priceBounds(otmCall);
        assertEq(floor, 0, "OTM call floor");
    }

    /// @notice A buy-back may pay at most intrinsic plus MAX_TIME_VALUE_BPS * sqrt(years) of spot:
    ///         about $62.81 for a 1-day at-the-money call at $3,000.
    function testFork_CreateOrder_BuyCapIsIntrinsicPlusTimeValue() public {
        bytes memory outOfBounds = abi.encodeWithSelector(IPositionRouter.PriceOutOfBounds.selector);
        (IOption atm,) = _newOption(3_000e18, true);
        (uint256 floor, uint256 cap) = router.priceBounds(atm);
        assertEq(floor, 0, "ATM floor");
        assertApproxEqAbs(cap, 62.81e6, 0.01e6, "1-day ATM cap");
        Terms memory t = _terms(atm);
        _order(1, atm, t, true, 1 ether, cap, 10 minutes, "");
        _order(2, atm, t, true, 1 ether, cap + 1, 10 minutes, outOfBounds);

        // $500 in the money: the cap rises by the intrinsic value and by the time value on its spot.
        (IOption itm,) = _newOption(2_500e18, true);
        (floor, cap) = router.priceBounds(itm);
        assertEq(floor, 500e6, "ITM floor");
        assertApproxEqAbs(cap, 562.81e6, 0.01e6, "1-day ITM cap");
    }

    /// @notice From expiry the time value is gone, so a buy-back pays at most intrinsic, and once the
    ///         exercise window closes the option is worth nothing and no buy-back can be priced.
    function testFork_CreateOrder_BuyCapAfterExpiry() public {
        (IOption itm,) = _newOption(2_500e18, true);
        Terms memory t = _terms(itm);

        vm.warp(t.expirationDate);
        (uint256 floor, uint256 cap) = router.priceBounds(itm);
        assertEq(cap, floor, "no time value at expiry");
        assertEq(cap, 500e6, "intrinsic in the window");
        _order(1, itm, t, true, 1 ether, 500e6, 10 minutes, "");
        _order(2, itm, t, true, 1 ether, 500e6 + 1, 10 minutes, abi.encodeWithSelector(IPositionRouter.PriceOutOfBounds.selector));

        vm.warp(t.expirationDate + t.windowSeconds + 1);
        (floor, cap) = router.priceBounds(itm);
        assertEq(floor + cap, 0, "worthless after the window");
        _order(3, itm, t, true, 1 ether, 1, 10 minutes, abi.encodeWithSelector(IPositionRouter.PriceOutOfBounds.selector));
    }

    /// @notice With spot at $3,000, a call's strike must sit in [$1,500, $4,500].
    function testFork_CreateOrder_CallStrikeWithinBand() public {
        bytes memory outOfRange = abi.encodeWithSelector(IPositionRouter.StrikeOutOfRange.selector);
        (IOption low,) = _newOption(1_500e18, true);
        (IOption high,) = _newOption(4_500e18, true);
        (IOption tooLow,) = _newOption(1_499e18, true);
        (IOption tooHigh,) = _newOption(4_501e18, true);

        _order(1, low, _terms(low), false, 1 ether, 1_500e6, 10 minutes, ""); // at its $1,500 intrinsic
        _sell(2, high, _terms(high), "");
        _sell(3, tooLow, _terms(tooLow), outOfRange);
        _sell(4, tooHigh, _terms(tooHigh), outOfRange);
    }

    /// @notice A put's stored strike is inverted, so the band applies to `1e36 / strike`.
    function testFork_CreateOrder_PutStrikeWithinBand() public {
        IOption inBand = _newPut(2_000e18);
        IOption outOfBand = _newPut(1_400e18);

        _sell(1, inBand, _terms(inBand), "");
        _sell(2, outOfBand, _terms(outOfBand), abi.encodeWithSelector(IPositionRouter.StrikeOutOfRange.selector));
    }

    /// @notice The band moves with spot.
    function testFork_CreateOrder_BandFollowsSpot() public {
        (IOption euro,) = _newOption(3_000e18, true);
        feed.set(7_000e8); // band is now [$3,500, $10,500]

        _sell(1, euro, _terms(euro), abi.encodeWithSelector(IPositionRouter.StrikeOutOfRange.selector));
    }

    function testFork_CreateOrder_RejectsBadOraclePrice() public {
        (IOption euro,) = _newOption(3_000e18, true);
        bytes memory stale = abi.encodeWithSelector(IPositionRouter.StalePrice.selector);

        feed.setAge(router.ORACLE_MAX_AGE());
        _sell(1, euro, _terms(euro), "");

        feed.setAge(router.ORACLE_MAX_AGE() + 1);
        _sell(2, euro, _terms(euro), stale);

        feed.setAge(0);
        feed.set(0);
        _sell(3, euro, _terms(euro), stale);
    }

    /// @notice Against the live Chainlink ETH / USD feed: a strike at spot passes, one at twice
    ///         spot does not.
    function testFork_CreateOrder_LiveChainlinkFeed() public {
        router = new PositionRouter(FACTORY, IBebopSettlement(BEBOP), address(WETH), address(USDC), CHAINLINK_ETH_USD);
        (, int256 answer,,,) = CHAINLINK_ETH_USD.latestRoundData();
        uint256 spot = uint256(answer) / 1e8 * 1e18; // whole dollars, 18 decimals
        (IOption atSpot,) = _newOption(spot, true);
        (IOption twiceSpot,) = _newOption(2 * spot, true);

        _sell(1, atSpot, _terms(atSpot), "");
        _sell(2, twiceSpot, _terms(twiceSpot), abi.encodeWithSelector(IPositionRouter.StrikeOutOfRange.selector));
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
        _order(nonce, option, t, false, 1 ether, 100e6, 10 minutes, err);
    }

    function _order(
        uint256 nonce,
        IOption option,
        Terms memory t,
        bool isBuy,
        uint256 amount,
        uint256 price,
        uint32 duration,
        bytes memory err
    ) internal {
        if (err.length != 0) vm.expectRevert(err);
        vm.prank(alice);
        router.createOrder(nonce, option, t.strike, t.expirationDate, t.isPut, t.isEuro, t.windowSeconds, isBuy, amount, price, duration);
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

    /// @dev A European cash-secured put at `humanStrike` USD per ETH.
    function _newPut(uint256 humanStrike) internal returns (IOption) {
        return IOption(
            FACTORY.createOption(
                CreateParams({
                    collateral: address(USDC),
                    consideration: address(WETH),
                    expirationDate: uint40(block.timestamp + 1 days),
                    strike: 1e36 / humanStrike,
                    isPut: true,
                    isEuro: true,
                    windowSeconds: 1 hours
                })
            )
        );
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
}
