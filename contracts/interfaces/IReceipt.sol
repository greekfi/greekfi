// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { IFactory } from "./IFactory.sol";

/// @title  IReceipt — short-side token interface (collateral receipt)
/// @author Greek.fi
/// @notice ERC20 extension for the short-side position: holds the pair's underlying collateral,
///         receives the consideration paid on exercise, and settles redemptions.
///
///         Redemption is consideration-first and **never pro-rata**. The consideration leg pays at
///         strike rate, first-come-first-served, whenever the pool can fund it — that leg is NOT
///         gated on the exercise window closing (European options only wait for `expirationDate`).
///         Only the 1:1 collateral leg for any uncovered remainder waits for
///         `block.timestamp > exerciseDeadline`. Redemption order therefore decides which asset a
///         writer ends up holding — see {redeem}.
///
///         The exercise window is `[expirationDate, exerciseDeadline]` where
///         `exerciseDeadline = expirationDate + windowSeconds`. The deadline itself is still
///         IN-window: exercise fails only once `block.timestamp > exerciseDeadline`, and the
///         collateral leg of {redeem} opens strictly after that instant. Pair-burn ({burn}, called
///         by the paired Option) is NOT deadline-gated, so post-window it coexists with {redeem} as
///         a second collateral exit for shorts who also hold (or acquire) the matching longs. The
///         Factory owner can pause it (`BURN`), along with transfers and redemption, through
///         {IFactory.pause}; a paused action reverts {IFactory.ActionPaused}.
/// @dev    Implemented by the deployed `Receipt` and inherited from {IERC20Metadata}, so the standard
///         ERC20 members not restated here behave normally.
interface IReceipt is IERC20Metadata {
    /// @notice Emitted once per redemption, after the Receipt burn and both net payouts.
    /// @param caller Account that initiated the redemption.
    /// @param holder Account whose Receipt tokens were burned and who received the payouts.
    /// @param rtBurned Actual Receipt units burned, which can be less than the requested amount while
    ///                 the collateral leg is closed.
    /// @param collateralPaid Net collateral paid, in raw collateral-token units.
    /// @param considerationPaid Net consideration paid, in raw consideration-token units.
    event Redeemed(address indexed caller, address indexed holder, uint256 rtBurned, uint256 collateralPaid, uint256 considerationPaid);

    /// @notice Emitted when the factory owner withdraws a positive non-fee portion of a surplus balance.
    /// @param caller Indexed factory owner that initiated the sweep.
    /// @param recipient Indexed account that received the tokens.
    /// @param token Indexed ERC20 withdrawn.
    /// @param amount Raw non-fee token units included in the transfer. If {FeeCleared} is emitted in
    ///               the same call, the ERC20 transfer amount is the sum of both events' `amount`s.
    ///               A fee-only transfer emits {FeeCleared} without this event.
    event Swept(address indexed caller, address indexed recipient, address indexed token, uint256 amount);

    /// @notice Emitted when {sweep} resets accrued redeem fees for `token` to the 1-wei floor.
    /// @param token Indexed token whose fee tally was reset.
    /// @param amount Accrued fee amount cleared, excluding the retained 1-wei floor.
    event FeeCleared(address indexed token, uint256 amount);

    /// @notice Emitted when accrued redeem fees for `token` are paid out to the factory owner via
    ///         {collectFees}. Distinct from {Redeemed} (holder payouts) so fee flow is separable
    ///         off-chain. The companion `IFactory.Fee` reports the fee rate on `setFee`.
    /// @param token  The token collected (collateral or consideration).
    /// @param to     Recipient of the fee (always the factory owner).
    /// @param amount Fee amount paid out.
    event Fee(address indexed token, address indexed to, uint256 amount);

    /// @notice Emitted when the factory owner changes this market's redeem fee.
    /// @param feeBps New fee in basis points.
    event FeeUpdated(uint64 feeBps);

    /// @notice Caller is not the paired Option (or, for {sweep}, not the factory owner).
    error UnauthorizedCaller();
    /// @notice Redeem fee exceeded the 1000 bps (10%) maximum.
    error InvalidFee();
    /// @notice Never thrown by Receipt itself — the pre-expiry mint gate lives in the paired
    ///         Option. Declared for ABI/tooling parity.
    error ContractExpired();
    /// @notice Zero-amount (or derived-zero) mutation rejected: a zero redeem amount, an exercise whose
    ///         consideration comes to zero (defensive — the collection rounds UP, so any non-zero
    ///         `amount` yields at least one atom), or a {sweep} to the zero address.
    error ZeroValue();
    /// @notice Never thrown by Receipt itself — the exercise-deadline gate lives in the paired
    ///         Option. Declared for ABI/tooling parity.
    error ExerciseWindowClosed();
    /// @notice Post-window-only path called while the exercise window is still open.
    error ExerciseWindowOpen();
    /// @notice Short-side redemption attempted on a European option before its exercise window opens
    ///         (`block.timestamp < expirationDate`). Mirrors the long-side European pre-expiry guard
    ///         so the revert reason states the schedule explicitly.
    error BeforeExerciseWindow();
    /// @notice The consideration or collateral pool cannot fully fund its leg of the requested
    ///         redemption. Both branches are defensive: neither can fire for a caller redeeming at
    ///         most their own balance. What does reach this error is an over-sized request: past
    ///         `exerciseDeadline`, an amount exceeding `totalSupply()` (plus any donated or
    ///         fee-accrued collateral)
    ///         reverts here rather than with `ERC20InsufficientBalance`, because the pool check runs
    ///         before the burn. Redeem no more than `balanceOf(you)`; splitting into smaller amounts
    ///         is not a remedy for anything else.
    error InsufficientPool();

    /// @notice Strike price (18-decimal fixed point, consideration per collateral; inverted for puts).
    function strike() external view returns (uint256);
    /// @notice Underlying collateral token (e.g. WETH). All collateral sits here.
    function collateral() external view returns (IERC20);
    /// @notice Consideration / quote token (e.g. USDC). Accrues here from exercise payments.
    function consideration() external view returns (IERC20);
    /// @notice Unix timestamp at which the option expires and the post-expiry exercise window opens
    ///         (uint40). Minting stops strictly before this instant, and for a European option both
    ///         exercise and the consideration leg of {redeem} open at it.
    function expirationDate() external view returns (uint40);
    /// @notice Unix timestamp at which the post-expiry exercise window closes (uint64: the
    ///         expiration + window sum can exceed uint40).
    function exerciseDeadline() external view returns (uint64);
    /// @notice `true` if this is a put. A label only: it drives the strike inversion in {name} and
    ///         is part of the registry key, and nothing else — settlement ({toConsideration},
    ///         {exercise}, {redeem}) uses {strike} as stored and never reads this flag. See
    ///         {IOption.isPut}.
    function isPut() external view returns (bool);
    /// @notice `true` if European-style (exercise only allowed in the post-expiry window).
    function isEuro() external view returns (bool);
    /// @notice This Receipt's own ERC-20 decimals: the cached `collateral.decimals()`, so one receipt
    ///         unit is exactly one collateral unit. Also the collateral side of the conversion scaling.
    function decimals() external view returns (uint8);
    /// @notice Cached `consideration.decimals()` used in conversion math.
    function consDecimals() external view returns (uint8);
    /// @notice This market's redeem fee in basis points. Initialized from `Factory.feeBps()` at
    ///         creation and mutable by the Factory owner. Applied to both legs of {redeem}; never to
    ///         exercise or pair burn. Each non-zero fee rounds up to a whole raw token unit, so
    ///         splitting a redemption into dust amounts cannot avoid the fee.
    function feeBps() external view returns (uint64);

    /// @notice Set this market's redeem fee. Callable by the creating Factory during deployment or
    ///         by the current Factory owner afterward. Reverts {InvalidFee} above 1000 bps (10%).
    ///         No timelock is applied.
    function setFee(uint64 feeBps_) external;
    /// @notice Decimal basis of the strike (always 18).
    function STRIKEDEC() external view returns (uint8);
    /// @notice Receipt-units the consideration pool can still back at strike rate. Incremented on
    ///         {exercise} (cons inflow) and decremented by the cons leg of redemption (cons payout);
    ///         the collateral leg of {redeem} leaves it untouched. Equal to (total exercised − total
    ///         cons-redeemed), and never underflows — the cons leg caps its payout at this value.
    ///         Denominated in receipt/collateral units (the cons equivalent is {toConsideration}).
    function consBacked() external view returns (uint256);
    /// @notice Redeem fee accrued for `token` (collateral or consideration) awaiting collection via
    ///         {collectFees}. Real pending fee is `feeAccrued(token) - 1` once the 1-wei gas floor
    ///         is set — see the implementation for the accounting.
    function feeAccrued(address token) external view returns (uint256);

    /// @notice ERC20 name in the form `RCT[E]-<P|C>-<coll>-<cons>-<strike>-<YYYY-MM-DD>`. The `RCTE-`
    ///         prefix flags European options, `RCT-` American — note this differs from
    ///         {IOption.name}, which spells its flavours `OPTE-` / `OPTA-`. For puts the displayed
    ///         strike is the human-readable form (`1e36 / strike`), not the stored inverse. If either
    ///         token implements ERC-8056/BEP-677 scaled UI amounts, the displayed strike uses its
    ///         current UI multiplier; tokens without that interface use 1x. `P` / `C` renders the
    ///         creator-set {isPut} label, which the Factory does not check against the token order or
    ///         strike, and the name omits the exercise window and time of day. Identify markets by
    ///         address or {IFactory.optionKey}, not by name.
    function name() external view returns (string memory);
    /// @notice ERC20 symbol — same as {name}. Matching name/symbol keeps wallets and explorers in sync.
    function symbol() external view returns (string memory);
    /// @notice Paired Option contract — the only address authorised to call {mint}/{burn}/{exercise}.
    function option() external view returns (address);
    /// @notice The {IFactory} that created this pair, used to pull tokens against their ERC-20
    ///         allowance to it. Its {IFactory.owner} is the {sweep} authority.
    function factory() external view returns (IFactory);
    /// @notice Strike-rate conversion of a collateral-denominated (equivalently receipt-denominated)
    ///         amount into the consideration due for it. `round=true` rounds UP (used when collecting
    ///         consideration on exercise); `round=false` floors (used for payouts) — that pairing
    ///         (ceil in, floor out) is what keeps the consideration pool able to fund every
    ///         redemption it is asked for.
    /// @param amount Collateral units.
    /// @param round  `true` rounds up, `false` floors.
    /// @return Consideration units, in the consideration token's own decimals.
    function toConsideration(uint256 amount, bool round) external pure returns (uint256);
    /// @notice Inverse of {toConsideration} — how much collateral a given consideration amount is worth
    ///         (floor by design). Not used internally — exposed for off-chain indexers and
    ///         invariant tests.
    function toCollateral(uint256 consAmount) external pure returns (uint256);

    /// @notice ERC20 transferFrom override. The per-option ERC-20 allowance is skipped entirely when
    ///         `msg.sender` is `from` itself or holds `Perm.TRANSFER_RECEIPT` in `from`'s factory
    ///         permission mask — a blanket approval over the owner's receipts across every option
    ///         this factory has created or will create; otherwise the allowance is spent as usual.
    ///         The short-side mirror of {IOption.transferFrom}'s `Perm.TRANSFER` skip, minus the
    ///         hooks: no auto-mint / auto-burn leg and no deadline gate — a plain balance move,
    ///         stopped only while `TRANSFER` is paused ({IFactory.ActionPaused}). Moving receipts moves the settlement claim itself ({redeem} pays the
    ///         *holder*), which is why the bit is custody-grade — see {Perm}.
    function transferFrom(address from, address to, uint256 amount) external returns (bool);

    /// @notice Mint `amount` Receipt tokens to `account` (Option-only), pulling the matching amount
    ///         of underlying collateral from `account` via the factory (against `account`'s ERC-20
    ///         allowance to it).
    /// @param account Recipient of the newly-minted Receipt tokens, and the address the collateral is
    ///                pulled from — never the Option-level caller.
    /// @param amount  Collateral-denominated amount.
    function mint(address account, uint256 amount) external;
    /// @notice Pair-burn helper (Option-only): burns `amount` receipts and returns `amount` collateral
    ///         to `account`. Not deadline-gated on either side — the paired Option's two call sites
    ///         (direct `burn` and the auto-burn transfer leg) both stay open past `exerciseDeadline`,
    ///         so post-window it coexists with {redeem} as a second collateral exit. Reverts
    ///         {IFactory.ActionPaused} while `BURN` is paused.
    /// @param account Holder whose receipts are burned, and recipient of the collateral — never the
    ///                Option-level caller, so a `Perm.BURN` operator cannot redirect the proceeds.
    /// @param amount  Amount of Receipt tokens to burn.
    function burn(address account, uint256 amount) external;
    /// @notice Exercise path invoked by the paired Option (Option-only). `account` is both the
    ///         consideration payer and the collateral recipient — the two sides are coupled at this
    ///         boundary, and for a keeper call `account` is NOT the holder whose long tokens were
    ///         burned (the Option contract forwards its own `msg.sender` here).
    /// @param account The address paying consideration and receiving collateral.
    /// @param amount  Collateral units to deliver; consideration collected is `ceil(amount * strike)`,
    ///                and {consBacked} rises by `amount` (receipt units, not consideration units).
    ///                This contract emits NO event for that — neither for the `consBacked` change
    ///                nor for the collateral leaving — so {IOption.Exercise} on the paired Option
    ///                is the event to index (its `amount` is the same `amount`).
    function exercise(address account, uint256 amount) external;

    /// @notice Redeem the caller's full Receipt balance. Cons-first, FCFS: pays up to {consBacked}
    ///         receipt-units from the consideration pool at strike rate, callable any time the pool
    ///         can cover them (European: reverts {BeforeExerciseWindow} before `expirationDate`).
    ///         Any uncovered remainder is paid 1:1 in collateral **only after** `exerciseDeadline`;
    ///         pre-window, uncovered receipts stay in the caller's balance for later redemption.
    ///         With nothing cons-backed and the collateral leg still shut, the call reverts
    ///         {ExerciseWindowOpen} — pre-window redemption of an unexercised option is not possible.
    ///
    ///         The cons leg mirrors the equity-options "buy to close at strike" convention: the
    ///         writer sources consideration from previously-exercised counterparties sitting in the
    ///         pool. FCFS by design — a short who redeems early captures the cons premium earlier
    ///         exercisers paid in, leaving later post-window redeemers with collateral. That
    ///         asymmetry is intentional: it lets shorts lock in the strike-rate exchange the moment
    ///         the pool can fund it, rather than waiting for the window to close.
    ///
    ///         ### Dust: a floored consideration payout still burns the receipts
    ///
    ///         The consideration leg pays `floor(amount * strike)`. When that floors to ZERO — the
    ///         receipts being redeemed are worth less than one consideration atom — they are burned
    ///         and {consBacked} is still decremented, while NOTHING is transferred. And it is
    ///         forced: the legs are not selectable, so while `consBacked > 0` a redeemer cannot skip
    ///         the consideration leg to reach the collateral one. Redeeming a dust balance therefore
    ///         destroys it for no payout. The loss is bounded — what is destroyed is worth strictly
    ///         less than one consideration atom at the strike price — but it is real, and a caller
    ///         who splits a balance into dust-sized calls repeats it once per call. Redeem in
    ///         amounts that convert to at least one atom.
    ///
    ///         ### American options: the consideration pool can be taken by a fresh mint (read
    ///         this if you write American)
    ///
    ///         The queue is keyed on a current receipt balance and nothing else — receipts carry no
    ///         mint timestamp and no assignment tag. For an American option the mint window
    ///         (`block.timestamp < expirationDate`), exercise and this consideration leg all
    ///         overlap. So after ANY pre-expiry exercise, while `consBacked > 0`, anyone can do
    ///         `Option.mint(N)` then `redeem(N)` in one transaction: deposit `N` collateral, take
    ///         `min(N, consBacked)` receipt-units of consideration at strike rate (net of {feeBps}),
    ///         and keep `N` freshly minted longs for no premium. Run as a same-block back-run of the
    ///         exercise it is atomic, and **proactive redemption by the assigned writer cannot beat
    ///         it** — the writer's own redeem lands in the same race, one transaction later. The
    ///         back-runner is weakly profitable at any spot (it has swapped collateral for
    ///         consideration at strike and holds free longs against the writer's collateral), so
    ///         every pre-expiry exercise on an American market is an opportunity of this shape
    ///         regardless of where spot goes afterwards. What the writer loses is the assignment
    ///         windfall of that exercise: their receipts back collateral again and are re-exposed to
    ///         the back-runner's longs, so their worst case is the short payoff they originally sold,
    ///         not principal. European options are structurally immune: minting stops at
    ///         `expirationDate` and neither exercise nor this leg opens before it, so the two windows
    ///         never overlap.
    ///
    ///         This is the cons-first FCFS design, documented rather than fixed, and it is the
    ///         residual risk of writing American on this protocol. There is no on-chain mitigation.
    ///         Writers who want an exit that does not depend on redemption order should hold (or buy
    ///         back) the matching longs and pair-burn ({IOption.burn}), which is never queued but can
    ///         be paused like every other action; writers who manage a position
    ///         should monitor {consBacked} and {IOption.Exercise} and treat a pre-expiry assignment
    ///         as final only once their own redeem has settled.
    function redeem() external;
    /// @notice Redeem `amount` of the caller's receipts. Same cons-first semantics as {redeem},
    ///         dust rule included.
    /// @param amount Receipt units to redeem. Before `exerciseDeadline`, the call burns and pays
    ///               `min(amount, consBacked)`; if that value exceeds the caller's balance, the burn
    ///               reverts `ERC20InsufficientBalance`. After the deadline, the call attempts to
    ///               burn the full `amount`, so any over-balance request reaches the same ERC-20
    ///               error unless a defensive pool-balance check reverts {InsufficientPool} first.
    ///               Integrators should bound `amount` by the caller's current balance.
    function redeem(uint256 amount) external;
    /// @notice Keeper-gated batch redeem. For each holder where the caller holds `Perm.REDEEM` in
    ///         the holder's factory permission mask (or `msg.sender == holder`), the holder's full
    ///         balance is redeemed under {redeem} semantics (cons-first; mix only post-window). The
    ///         resulting collateral / consideration go to the **holder** — never to the caller.
    ///         Unauthorised and zero-balance holders are skipped silently so a single stale entry
    ///         doesn't brick the batch.
    ///
    ///         Composability-safe by design: a Receipt held inside an ERC4626 vault, Morpho market,
    ///         or multisig CANNOT be force-redeemed by an unauthorised third party.
    ///
    ///         **Reverts are NOT contained.** Only unauthorised and zero-balance holders are
    ///         skipped. Anything that makes the redemption itself revert — {ExerciseWindowOpen}
    ///         when the consideration pool is empty pre-window, {BeforeExerciseWindow} on a
    ///         European option, or the defensive {InsufficientPool} — aborts the WHOLE batch and
    ///         rolls back the holders already processed. Because the cons leg is FCFS, the pool
    ///         empties partway down any long list, so a pre-window batch reverting is the ordinary
    ///         outcome rather than an edge case. Callers should size batches accordingly, or call
    ///         {redeem} per holder if partial progress matters.
    ///
    ///         Dust is not skipped, and is the one way this can destroy value: a holder whose
    ///         balance converts to zero consideration is burned for no payout, exactly as in
    ///         {redeem}. A keeper sweeping a long holder list pre-window will do that to every dust
    ///         holder on it.
    /// @param holders Holders whose receipts to redeem in full.
    function redeemFor(address[] calldata holders) external;
    /// @notice Factory-owner surplus drain. Collateral and consideration move only above the holder
    ///         backing required by {totalSupply} and {consBacked}; accrued fees are surplus and may
    ///         leave in the same transfer. A foreign token has no holder claim, so its whole balance
    ///         may move. When accrued fees leave, {feeAccrued} is capped at the 1-wei floor and
    ///         {FeeCleared} reports the fee portion excluding that floor. {Swept} reports a positive
    ///         non-fee portion and is omitted when that portion is zero. The emitted amounts sum to the
    ///         single ERC20 transfer. The 1-wei fee floor remains in both storage and the token balance.
    ///         The reserve is matched by token address, so tokens that share or alias another token's
    ///         balance ledger are unsupported: sweeping such an address can move the backing of the
    ///         pair token it aliases. Call {collectFees} first to route fees to the factory owner
    ///         instead. A zero sweepable balance is a no-op with no event.
    /// @param token ERC20 to sweep.
    /// @param to    Recipient of the swept balance. Chosen by the factory owner; must be non-zero.
    function sweep(address token, address to) external;
    /// @notice Pay the accrued redeem fee for a single `token` to the factory owner, leaving a 1-wei
    ///         gas floor. Call once per token (`collateral` and `consideration`) — per-token so one
    ///         token's transfer reverting can never strand the other's fee. Permissionless — funds
    ///         always go to the factory owner regardless of caller, so a keeper can poke it but no one
    ///         can redirect the fee. `token`s other than the pair's two are a harmless no-op (they
    ///         never accrue). Accrued fees are pure surplus, never part of the backing the outstanding
    ///         receipts require. Paid to `factory.owner()`
    ///         at call time; the factory cannot be renounced, so there is always a payee.
    /// @param token The token to collect (`collateral` or `consideration`).
    function collectFees(address token) external;
}
