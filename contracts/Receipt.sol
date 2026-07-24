// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { IERC20, ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { Clone } from "clone/src/Clone.sol";

using SafeERC20 for IERC20;

import { TokenData } from "./interfaces/IOption.sol";
import { OptionUtils } from "./OptionUtils.sol";
import { Perm } from "./Permissions.sol";

/// @dev Narrow view of {Factory} used by {Receipt} to pull collateral/consideration tokens via the
///      factory's centralised allowance registry.
interface IFactory {
    function transferFrom(address from, address to, uint256 amount, address token) external;
    function permissions(address owner, address operator) external view returns (uint256);
    function owner() external view returns (address);
}

/**
 * @title  Receipt — short-side ERC20 (collateral receipt)
 * @author Greek.fi
 * @notice The short side of a Greek option pair. Holding this token is a receipt for the
 *         collateral you deposited when minting: you received the premium (off-chain) and now
 *         bear the obligation of the exercise payoff. It holds all collateral for the pair and
 *         receives the consideration paid on exercise.
 *
 *         No oracle is consulted at any point. Settlement is purely time-gated:
 *
 *         | Mode      | `isEuro` | Pre-expiry exercise | In-window exercise | Post-window short exit                |
 *         | --------- | -------- | ------------------- | ------------------ | ------------------------------------- |
 *         | American  | `false`  | allowed             | allowed            | `redeem` (cons-first, then coll 1:1)  |
 *         | European  | `true`   | reverts             | allowed            | `redeem` (cons-first, then coll 1:1)  |
 *
 *         The exercise window closes for everyone at `exerciseDeadline = expirationDate + windowSeconds`.
 *         Pair-redeem (`burn`, called by Option) stays available pre-deadline.
 *
 *         ### Rounding
 *
 *         - Collections from users (exercise): round UP (`toConsideration(amount, true)`).
 *         - Payouts to users (redeem): round DOWN (floor).
 *
 *         ### Supported tokens
 *
 *         This contract physically holds every collateral and consideration token for the pair and
 *         tracks them 1:1 against its accounting, so the collateral/consideration MUST be standard
 *         ERC-20 tokens with exact, balance-preserving transfers. Fee-on-transfer and rebasing /
 *         elastic-supply tokens are NOT supported: any drift between `balanceOf` and the recorded
 *         amounts breaks the redemption math and the solvency invariant. Fee-on-transfer pulls are
 *         rejected at {Factory.transferFrom}; rebasing is undetectable on-chain and must be avoided
 *         at option-creation time. See {Factory} for the full token policy.
 *
 * @dev    Deployed once as a template; per-option instances are clones produced by
 *         `ClonesWithImmutableArgs`. Every per-option value (strike, collateral, consideration,
 *         expirationDate, exerciseDeadline, isPut, isEuro, decimals, option) is appended to the
 *         clone's runtime bytecode at deploy time and read via `Clone._getArg*` helpers
 *         (CALLDATALOAD, ~3 gas). There is no `init` function — the clone is fully configured
 *         the moment its bytecode is written.
 *
 *         ### Immutable args layout (packed, 112 bytes)
 *           offset  0   strike            uint256  (32B)
 *           offset 32   collateral        address  (20B)
 *           offset 52   consideration     address  (20B)
 *           offset 72   option            address  (20B)
 *           offset 92   expirationDate    uint64   (8B, holds a uint40)
 *           offset 100  exerciseDeadline  uint64   (8B, = expirationDate + windowSeconds; can exceed uint40)
 *           offset 108  isPut             uint8    (1B, 0 or 1)
 *           offset 109  isEuro            uint8    (1B, 0 or 1)
 *           offset 110  decimals      uint8    (1B)
 *           offset 111  consDecimals      uint8    (1B)
 */
contract Receipt is ERC20, ReentrancyGuardTransient, Clone {
    /// @notice Factory that created this option, used to pull tokens through its Permit2-style
    ///         allowance registry. Set in the template constructor (= the factory that deployed
    ///         it) and inherited by every clone via the template's runtime bytecode.
    IFactory public immutable factory;

    /// @notice Receipt-units the consideration pool can still back at strike rate. Incremented on
    ///         {exercise} (cons inflow) and decremented by the cons leg of {_redeem} (cons payout);
    ///         the collateral leg of redeem leaves it untouched. Equal to (total exercised − total
    ///         cons-redeemed), and never underflows — the cons leg caps its payout at this value.
    ///         Denominated in receipt/collateral units (the cons equivalent is `toConsideration`).
    uint256 public consBacked;

    /// @notice Decimal basis of the strike — fixed at 18 and independent of token decimals.
    uint8 public constant STRIKEDEC = 18;

    /// @notice Thrown when a privileged path is called by anyone other than the paired {Option}.
    error UnauthorizedCaller();
    /// @notice Thrown when a pre-expiry-only path (mint) runs after expiration.
    error ContractExpired();
    /// @notice Thrown on `amount == 0` (or any derived zero-amount the invariant requires to be positive).
    error ZeroValue();
    /// @notice Thrown when exercise is attempted after `exerciseDeadline`.
    error ExerciseWindowClosed();
    /// @notice Thrown when a post-window-only path is called before the window closes.
    error ExerciseWindowOpen();
    /// @notice Thrown when short-side redemption is attempted on a European option before its
    ///         exercise window opens (`block.timestamp < expirationDate`). Mirrors the long-side
    ///         European pre-expiry guard so the revert reason states the schedule explicitly.
    error BeforeExerciseWindow();
    /// @notice Thrown when {sweep} is called while receipts are still outstanding.
    error OutstandingReceipts();
    /// @notice Thrown when neither the consideration nor the collateral pool can fully fund the
    ///         requested redemption — caller should split into smaller amounts.
    error InsufficientPool();

    /// @notice Emitted on every path that returns collateral or consideration to a user.
    /// @param option The paired Option contract.
    /// @param token  The token actually transferred out (`collateral` or `consideration`).
    /// @param holder Recipient of the payout.
    /// @param amount Token units sent.
    event Redeemed(address option, address token, address holder, uint256 amount);

    /// @dev Restricts a privileged call to the paired {Option} contract only.
    modifier onlyOption() {
        if (msg.sender != option()) revert UnauthorizedCaller();
        _;
    }

    /// @dev Rejects zero-amount mutations.
    modifier nonZero(uint256 amount) {
        if (amount == 0) revert ZeroValue();
        _;
    }

    /// @notice Template constructor. Never called for user-facing instances; clones are produced
    ///         by `ClonesWithImmutableArgs.clone(template, args)` and never delegate the
    ///         constructor. `factory` is captured from the deployer (the Factory that deployed
    ///         the template) so every clone-via-delegatecall reads the same FACTORY immutable.
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {
        factory = IFactory(msg.sender);
    }

    // ============ IMMUTABLE-ARG GETTERS ============

    /// @notice Strike price, 18-decimal fixed point (consideration per collateral; inverted for puts).
    function strike() public pure returns (uint256) {
        return _getArgUint256(0);
    }

    /// @notice Underlying collateral token (e.g. WETH). All collateral sits here.
    function collateral() public pure returns (IERC20) {
        return IERC20(_getArgAddress(32));
    }

    function col() internal pure returns (IERC20Metadata) {
        return IERC20Metadata(_getArgAddress(32));
    }

    /// @notice Consideration / quote token (e.g. USDC). Accrues here from exercise payments.
    function consideration() public pure returns (IERC20) {
        return IERC20(_getArgAddress(52));
    }

    function con() internal pure returns (IERC20Metadata) {
        return IERC20Metadata(_getArgAddress(52));
    }

    /// @notice The paired {Option} contract. Only this address can call mint / burn / exercise.
    function option() public pure returns (address) {
        return _getArgAddress(72);
    }

    /// @notice Unix timestamp at which the option expires.
    function expirationDate() public pure returns (uint40) {
        return uint40(_getArgUint64(92));
    }

    /// @notice Unix timestamp at which the post-expiry exercise window closes.
    /// @dev    Returned as `uint64`: the stored value is `expirationDate + windowSeconds`,
    ///         and that sum can exceed `type(uint40).max` even though each operand is uint40,
    ///         so reading the full 64-bit slot avoids silently truncating the deadline.
    function exerciseDeadline() public pure returns (uint64) {
        return _getArgUint64(100);
    }

    /// @notice `true` if put, `false` if call.
    function isPut() public pure returns (bool) {
        return _getArgUint8(108) != 0;
    }

    /// @notice `true` if European-style.
    function isEuro() public pure returns (bool) {
        return _getArgUint8(109) != 0;
    }

    /// @notice Cached `collateral.decimals()` used in conversion math.
    function decimals() public pure override returns (uint8) {
        return _getArgUint8(110);
    }

    /// @notice Cached `consideration.decimals()` used in conversion math.
    function consDecimals() public pure returns (uint8) {
        return _getArgUint8(111);
    }

    // ============ MINT ============

    /// @notice Mint `amount` Receipt tokens to `account`, pulling the matching amount of
    ///         underlying collateral through the factory's allowance registry.
    /// @dev    Only callable by the paired {Option} contract.
    /// @param account Recipient of the newly-minted Receipt tokens.
    /// @param amount  Collateral-denominated amount.
    function mint(address account, uint256 amount) public onlyOption nonReentrant {
        factory.transferFrom(account, address(this), amount, address(collateral()));
        _mint(account, amount);
    }

    // ============ PAIR BURN (called by Option) ============

    /// @notice Burn matched Option + Receipt pair, return collateral. Only callable by Option.
    /// @dev    Trusts Option's own gating: direct `Option.burn` enforces `notExpired`
    ///         (pre-expiration only), while the auto-burn leg of `Option._settledTransfer` runs
    ///         under `beforeDeadline` (pre-`exerciseDeadline`). Once everyone is post-settlement,
    ///         all short-side exits must go through `_redeem`.
    /// @param account Recipient of the collateral.
    /// @param amount  Amount of Receipt tokens to burn.
    function burn(address account, uint256 amount) public onlyOption nonReentrant {
        _burn(account, amount);
        collateral().safeTransfer(account, amount);
        emit Redeemed(option(), address(collateral()), account, amount);
    }

    // ============ EXERCISE ============

    /// @notice Exercise path invoked by Option. `account` both pays the consideration and receives
    ///         the collateral — the two sides are coupled at this boundary so Receipt never has to
    ///         settle "pay-for-someone-else" semantics. Option enforces the matching authorisation
    ///         (self-exercise or the holder's `Perm.EXERCISE` grant) before calling.
    /// @param account The address paying consideration and receiving collateral.
    /// @param amount  Collateral units to deliver; consideration collected is `ceil(amount * strike)`.
    function exercise(address account, uint256 amount) public onlyOption nonReentrant {
        uint256 consAmount = toConsideration(amount, true);
        if (consAmount == 0) revert ZeroValue();
        factory.transferFrom(account, address(this), consAmount, address(consideration()));
        consBacked += amount;
        collateral().safeTransfer(account, amount);
    }

    // ============ REDEEM ============

    /// @notice Redeem the caller's full Receipt balance.
    /// @dev    Cons-first, FCFS: pays up to `consBacked` receipt-units from the
    ///         consideration pool at strike rate, callable any time the pool can cover them.
    ///         Any uncovered remainder is paid 1:1 in collateral **only after** `exerciseDeadline`;
    ///         pre-window, uncovered receipts stay in the caller's balance for later redemption.
    ///
    ///         The cons leg mirrors the equity-options "buy to close at strike" convention:
    ///         the writer sources consideration from previously-exercised counterparties sitting
    ///         in the pool. FCFS by design — a short who redeems early captures the cons premium
    ///         earlier exercisers paid in, leaving later post-window redeemers with collateral.
    ///         That asymmetry is intentional: it lets shorts lock in the strike-rate exchange
    ///         the moment the pool can fund it, rather than waiting for the window to close.
    function redeem() public nonReentrant {
        _redeem(msg.sender, balanceOf(msg.sender));
    }

    /// @notice Redeem `amount` of the caller's Receipt. Same semantics as {redeem}.
    function redeem(uint256 amount) public nonReentrant {
        _redeem(msg.sender, amount);
    }

    function _redeem(address account, uint256 amount_) internal nonZero(amount_) {
        // GRK-8: European options settle only in the post-expiry window. The long side enforces this
        // in Option.canExercise; mirror it here so a pre-expiry European redemption reverts with an
        // explicit reason (rather than the indirect ExerciseWindowOpen from empty-pool state).
        if (isEuro() && block.timestamp < expirationDate()) revert BeforeExerciseWindow();
        uint256 amount = amount_ > consBacked ? consBacked : amount_;
        uint256 remaining = block.timestamp > exerciseDeadline() ? amount_ - amount : 0;
        uint256 consAmount = toConsideration(amount, false);
        // Nothing cons-backed AND collateral leg gated off → pre-window with empty pool.
        // Dust amounts (amount > 0 but consAmount floors to 0) fall through to burn + skip transfers.
        if (amount == 0 && remaining == 0) revert ExerciseWindowOpen();
        consBacked -= amount;

        if (amount > 0 && consideration().balanceOf(address(this)) < consAmount) revert InsufficientPool();
        if (remaining > 0 && collateral().balanceOf(address(this)) < remaining) revert InsufficientPool();

        _burn(account, amount + remaining);

        if (consAmount > 0) {
            consideration().safeTransfer(account, consAmount);
            emit Redeemed(option(), address(consideration()), account, consAmount);
        }
        if (remaining > 0) {
            collateral().safeTransfer(account, remaining);
            emit Redeemed(option(), address(collateral()), account, remaining);
        }
    }

    // ============ DUST SWEEP ============

    /// @notice Sweep any residual `token` balance held by this Receipt to `to`. Callable only by
    ///         the factory owner, and only once every receipt has been burned (`totalSupply == 0`),
    ///         so this can never short the redemption pool — it strictly cleans up rounding
    ///         residue, post-redemption donations, or stray ERC20s sent here by accident.
    /// @param token ERC20 to drain. Typically the option's collateral or consideration.
    /// @param to    Recipient of the swept balance.
    function sweep(address token, address to) external nonReentrant {
        if (msg.sender != factory.owner()) revert UnauthorizedCaller();
        if (to == address(0)) revert ZeroValue();
        if (totalSupply() != 0) revert OutstandingReceipts();

        uint256 tokenBal = IERC20(token).balanceOf(address(this));

        if (tokenBal > 0) {
            IERC20(token).safeTransfer(to, tokenBal);
            emit Redeemed(option(), token, to, tokenBal);
        }
    }

    // ============ BATCH REDEEM (KEEPER-GATED) ============

    /// @notice Keeper-triggered batch redeem. For each holder where the caller holds `Perm.REDEEM`
    ///         in the holder's factory permission mask (or `msg.sender == holder`), the
    ///         holder's full balance is redeemed under {redeem} semantics (cons-first; mix only
    ///         post-window). The resulting collateral / consideration go to the **holder** —
    ///         never to the caller. Unauthorised and zero-balance holders are skipped silently
    ///         so a single stale entry doesn't brick the batch.
    ///
    ///         Composability-safe by design: a Receipt held inside an ERC4626 vault, Morpho
    ///         market, or multisig CANNOT be force-unwound by an unauthorised third party
    ///         (the previous permissionless `redeem(address)` variants were removed for exactly
    ///         this reason — they let any caller change a vault's collateral balance out from
    ///         under it).
    /// @param  holders Holders whose receipts to redeem in full.
    function redeemFor(address[] calldata holders) external nonReentrant {
        for (uint256 i = 0; i < holders.length; i++) {
            address h = holders[i];
            if (msg.sender != h && factory.permissions(h, msg.sender) & Perm.REDEEM == 0) continue;
            if (balanceOf(h) == 0) continue;
            _redeem(h, balanceOf(h));
        }
    }

    // ============ CONVERSIONS ============

    function numer() internal pure returns (uint256) {
        return consDecimals() > decimals() ? 10 ** (consDecimals() - decimals()) : 1;
    }

    function denom() internal pure returns (uint256) {
        return consDecimals() > decimals() ? 1 : 10 ** (decimals() - consDecimals());
    }

    function toConsideration(uint256 amount, bool round) public pure returns (uint256) {
        if (!round) return Math.mulDiv(amount, strike() * numer(), (10 ** STRIKEDEC) * denom());
        return Math.mulDiv(amount, strike() * numer(), (10 ** STRIKEDEC) * denom(), Math.Rounding.Ceil);
    }

    /// @notice Convert a consideration amount to the matching collateral-denominated receipt count.
    /// @dev    Floors by design. No longer used internally — `_redeem` now tracks cons-backed
    ///         receipt-units via the `consBacked` counter — but exposed for off-chain
    ///         indexers and invariant tests that need the inverse of {toConsideration}.
    function toCollateral(uint256 consAmount) public pure returns (uint256) {
        return Math.mulDiv(consAmount, denom() * (10 ** STRIKEDEC), strike() * numer());
    }

    // ============ METADATA ============

    function name() public view override returns (string memory) {
        uint256 strike_ = isPut() ? (1e36 / strike()) : strike();
        return OptionUtils.name(isEuro() ? "RCTE" : "RCT", col().symbol(), con().symbol(), strike_, expirationDate());
    }

    function symbol() public view override returns (string memory) {
        return name();
    }
}
