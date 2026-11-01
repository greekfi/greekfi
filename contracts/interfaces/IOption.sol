// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { IReceipt } from "./IReceipt.sol";
import { IFactory } from "./IFactory.sol";

/// @notice Minimal ERC20 metadata bundle. Appears inside {OptionInfo}, i.e. in the {IOption.details}
///         return — {IOption.balancesOf} returns raw amounts and carries no metadata.
/// @param address_ Token contract address.
/// @param name     Token name.
/// @param symbol   Token symbol.
/// @param decimals Token decimals.
struct TokenData {
    address address_;
    string name;
    string symbol;
    uint8 decimals;
}

/// @notice All balances relevant to a single option pair for an address (used by dashboards / scripts).
/// @param collateral     Balance of the underlying collateral token.
/// @param consideration  Balance of the consideration token.
/// @param option         Balance of the long-side Option ERC20.
/// @param receipt        Balance of the short-side Receipt ERC20.
struct Balances {
    uint256 collateral;
    uint256 consideration;
    uint256 option;
    uint256 receipt;
}

/// @notice One-shot descriptor for a single option, returned by {IOption.details}.
/// @param option            Option contract address.
/// @param receipt           Paired Receipt contract address.
/// @param collateral        Collateral token metadata.
/// @param consideration     Consideration token metadata.
/// @param expiration        Unix expiration timestamp.
/// @param strike            18-decimal fixed-point strike price (consideration per collateral), as
///                          stored: still inverted for puts.
/// @param isPut             `true` for puts.
/// @param isEuro            `true` for European options (no pre-expiry exercise).
/// @param exerciseDeadline  Unix timestamp at which the post-expiry exercise window closes.
struct OptionInfo {
    address option;
    address receipt;
    TokenData collateral;
    TokenData consideration;
    uint256 expiration;
    uint256 strike;
    bool isPut;
    bool isEuro;
    uint64 exerciseDeadline;
}

/// @title  IOption — long-side option token interface
/// @author Greek.fi
/// @notice ERC20 with option-specific extensions. Exercise is allowed pre-expiry (American only) and
///         during the post-expiry window `[expirationDate, exerciseDeadline]`, where
///         `exerciseDeadline = expirationDate + windowSeconds`. Both boundaries are INCLUSIVE, so
///         exercise at `block.timestamp == exerciseDeadline` still succeeds. Only *exercise* ends at
///         the deadline: transfer and pair {burn} are NOT deadline-gated, so a matched Option+Receipt
///         pair can be unwound 1:1 back into collateral after it. After the deadline the short-side
///         exits are {IReceipt.redeem} (cons-first FCFS) and pair {burn}, and the long side can still
///         be transferred, pair-burned, or destroyed by its holder via {expire}.
///
///         The Factory owner can pause any of these actions across every market ({IFactory.pause}).
///         A paused action reverts {IFactory.ActionPaused}, and a pause never extends a deadline:
///         an `EXERCISE` pause that spans `exerciseDeadline` ends the exercise right.
///
///         Minting stops earlier than everything else: {mint} is barred from `expirationDate` onwards.
///
///         ⚠ Because pair {burn} outlives the exercise window, a post-deadline long is NOT
///         worthless: paired with a Receipt it redeems collateral 1:1, so it retains market value
///         to short holders and lets them take the collateral leg without queueing through the
///         cons-first FCFS schedule documented in {IReceipt.redeem}.
/// @dev    Implemented by the deployed `Option` and inherited from {IERC20Metadata}, so the standard
///         ERC20 members not restated here (`approve`, `allowance`, `totalSupply`, `balanceOf`, the
///         ERC20 events) behave normally. `Option` also exposes the immutable `FACTORY()`, of which
///         {factory} is the plain-address form.
interface IOption is IERC20Metadata {
    /// @notice Emitted when new options are minted against fresh collateral — by either {mint}
    ///         overload or by the auto-mint leg of the transfer hook, which routes through the same
    ///         internal mint. A matching {IReceipt} is always minted to `holder` alongside.
    /// @param longOption  The Option contract (always the emitter).
    /// @param caller      The account that initiated the mint, including an auto-minting transfer.
    /// @param holder      The account credited with the new tokens, and the account whose
    ///                    collateral is pulled to back them.
    /// @param amount      Collateral-denominated amount (same decimals as the collateral token).
    event Mint(address longOption, address indexed caller, address indexed holder, uint256 amount);

    /// @notice Emitted after matched Option and Receipt tokens are burned and collateral is returned.
    /// @param caller The account that initiated the burn, including an auto-burning transfer.
    /// @param holder The account whose matched pair was burned and who received the collateral.
    /// @param amount Option and Receipt units burned, equal to collateral units returned.
    event PairBurned(address indexed caller, address indexed holder, uint256 amount);

    /// @notice Emitted once per exercised holder — by {exerciseFor(address,uint256)}, by the
    ///         {exercise} overloads that delegate to it, and once per processed entry of the batch
    ///         {exerciseFor(address[],uint256[])}.
    /// @param longOption  The Option contract (always the emitter).
    /// @param caller      Indexed account that initiated the exercise: it pays the consideration and
    ///                    receives the collateral. Equal to `holder` only on the self-exercise paths.
    /// @param holder      Indexed account whose options were burned. Receives nothing on-chain when
    ///                    `caller != holder`.
    /// @param amount      Collateral units delivered to `caller` (consideration collected from
    ///                    `caller` is {IReceipt.toConsideration}`(amount, true)`, rounded up).
    event Exercise(address longOption, address indexed caller, address indexed holder, uint256 amount);

    /// @notice Emitted **only** by an explicit {expire} call — the sole site that emits this event.
    ///         An option passing `exerciseDeadline` emits nothing on its own; expiry is a timestamp
    ///         comparison, not a transaction. Indexers must not treat this as "the option expired",
    ///         only as "a holder burned their own unwanted long tokens".
    /// @param longOption  The Option contract (always the emitter).
    /// @param caller      The account that called {expire} — always the holder themselves ({expire}
    ///                    is self-service only).
    /// @param holder      Indexed account whose options were burned. Equal to `caller`.
    /// @param amount      Amount of options burned.
    event Expire(address longOption, address caller, address indexed holder, uint256 amount);

    /// @notice Minting attempted at or after `expirationDate` — no new collateral can be committed
    ///         once the option expires. Minting is the only path this gates (the gate tests `>=`),
    ///         but it is reached from both {mint} overloads AND from the auto-mint leg of the
    ///         transfer hook — so an over-balance transfer from `expirationDate` onwards reverts
    ///         with this even though plain transfers have no time gate.
    error ContractExpired();
    /// @notice Zero-amount mutation rejected — both {mint} overloads, {exerciseFor(address,uint256)},
    ///         {burn(address,uint256)} and {expire} — also raised by {init} for a zero `receipt_`.
    ///         The batch {exerciseFor(address[],uint256[])} skips zero entries instead of reverting.
    error ZeroValue();
    /// @notice Exercise attempted past the exercise-window boundary (`block.timestamp >
    ///         exerciseDeadline`; the boundary itself is still in-window). Transfers and pair
    ///         {burn} are NOT gated on the deadline and never produce this error.
    error ExerciseWindowClosed();
    /// @notice Batch `exerciseFor` given `holders`/`amounts` arrays of unequal length. This is its
    ///         only throw site on the long side.
    error InvalidValue();
    /// @notice Pre-expiry exercise attempted on a European option. Past-deadline exercise raises
    ///         {ExerciseWindowClosed} instead, for both flavours.
    error InvalidExercise();
    /// @notice `init` called twice (or on the template itself, which carries the `0xdead` sentinel).
    error AlreadyInitialized();
    /// @notice Caller lacks the `Perm` bit the target's factory permission mask would need to grant
    ///         (mint / burn / exercise on someone else's position), called {expire} on someone
    ///         else's position (self-service only — no permission bit reaches it), or called {init}
    ///         without being the factory. The batch {exerciseFor(address[],uint256[])} skips such
    ///         entries instead of reverting.
    error Unauthorized();
    /// @notice {expire} called on or before `exerciseDeadline` — the option is still live.
    error NotYetExpired();

    /// @notice Paired short-side {IReceipt} contract that holds the collateral and handles
    ///         settlement math. The pairing is permanent — set once by {init}, no setter, no
    ///         upgrade path.
    function receipt() external view returns (IReceipt);

    /// @notice One-time initialisation of a freshly-cloned Option, called by the factory before the
    ///         clone is handed out. Reverts {AlreadyInitialized} if the receipt is already set,
    ///         {Unauthorized} if the caller is not the factory, and {ZeroValue} on a zero `receipt_`.
    /// @param receipt_ Address of the paired {IReceipt} contract — immutable for this option.
    function init(address receipt_) external;

    /// @notice ERC20 name in the form `OPT[E/A]-<P|C>-<coll>-<cons>-<strike>-<YYYY-MM-DD>`. The `OPTE-`
    ///         prefix flags European options, `OPTA-` American, and the date is the UTC day of
    ///         `expirationDate`, not of `exerciseDeadline`. For puts the displayed strike is the
    ///         human-readable form (`1e36 / strike`), not the stored inverse. If either token
    ///         implements ERC-8056/BEP-677 scaled UI amounts, the displayed strike uses its current
    ///         UI multiplier; tokens without that interface use 1x. `P` / `C` renders the
    ///         creator-set {isPut} label, which the Factory does not check against the token order or
    ///         strike, and the name omits the exercise window and time of day. Identify markets by
    ///         address or {IFactory.optionKey}, not by name.
    function name() external view returns (string memory);
    /// @notice ERC20 symbol — same as {name}. Matching name/symbol keeps wallets and explorers in sync.
    function symbol() external view returns (string memory);
    /// @notice ERC20 decimals — matches `collateral.decimals()`, so 1 option token ↔ 1 collateral unit.
    function decimals() external view returns (uint8);
    /// @notice The {IFactory} that created this option.
    function factory() external view returns (IFactory);
    /// @notice Underlying collateral token (e.g. WETH for a WETH/USDC call).
    function collateral() external view returns (address);
    /// @notice Consideration / quote token (e.g. USDC for a WETH/USDC call).
    function consideration() external view returns (address);
    /// @notice Unix expiration timestamp.
    function expirationDate() external view returns (uint40);
    /// @notice Unix timestamp at which the post-expiry exercise window closes.
    function exerciseDeadline() external view returns (uint64);
    /// @notice Strike price (18-decimal fixed point, consideration per collateral; inverted for puts).
    function strike() external view returns (uint256);
    /// @notice `true` if this is a put. A label only: it inverts the strike for display in {name}
    ///         and is part of the factory registry key, and nothing else — every settlement path
    ///         converts at {strike} exactly as stored and never reads this flag. Whether a market is
    ///         "really" a put is the creator's off-chain convention (tokens swapped, `strike =
    ///         1e36 / humanStrike`), unchecked on-chain; see `CreateParams.isPut` in {IFactory}.
    function isPut() external view returns (bool);
    /// @notice `true` if European-style (exercise only allowed in the post-expiry window). `false`
    ///         for American, which is exercisable at any time up to and including `exerciseDeadline`.
    function isEuro() external view returns (bool);
    /// @notice All four balances that matter for this option in one call: collateral token,
    ///         consideration token, long option, short receipt.
    /// @param account Address to query.
    /// @return A {Balances} struct of raw `balanceOf` reads, each in its own token's decimals.
    function balancesOf(address account) external view returns (Balances memory);
    /// @notice Full option descriptor — addresses, token metadata, strike, expiry, deadline.
    ///         Convenient one-shot read for frontends.
    /// @return An {OptionInfo} struct. The economic fields are sourced from the paired {IReceipt}
    ///         (the token metadata is read live from the two token contracts), so the `strike`
    ///         returned is the raw 18-decimal value, still inverted for puts.
    function details() external view returns (OptionInfo memory);

    /// @notice Mint `amount` option tokens to the caller, collateralised 1:1 with the underlying.
    ///         The caller receives the matching {IReceipt} too — minting always opens both legs —
    ///         and pays the collateral out of their ERC-20 allowance to the factory. Reverts
    ///         {ContractExpired} at or after `expirationDate` and {ZeroValue} on a zero `amount`;
    ///         the collateral pull reverts with the token's own allowance/balance error or
    ///         {IFactory.FeeOnTransferNotSupported}. Emits {Mint}.
    /// @param amount Collateral-denominated mint amount; this token shares the collateral's decimals.
    function mint(uint256 amount) external;
    /// @notice Mint `amount` options on behalf of `account`: `account` pays the collateral and receives
    ///         both the Option and the Receipt — the caller receives nothing. Caller must be `account`
    ///         or hold `Perm.MINT` in `account`'s factory permission mask, else {Unauthorized};
    ///         without that gate any address holding a non-zero factory allowance could be
    ///         force-minted into unwanted positions. The authorisation check runs before the {ContractExpired} /
    ///         {ZeroValue} gates of {mint(uint256)}, which apply here too. Emits {Mint}.
    /// @param account Recipient of both Option and Receipt tokens. Pays the collateral.
    /// @param amount  Collateral-denominated mint amount.
    function mint(address account, uint256 amount) external;
    /// @notice ERC20 transfer override — runs the auto-mint / auto-burn hooks, so this is NOT a plain
    ///         ERC-20 transfer: it may mint against the caller's collateral or net options out at the
    ///         receiver. Not gated on the clock — the long token circulates past `exerciseDeadline`,
    ///         so holders can sell to keepers or to shorts unwinding via pair {burn}. Reverts
    ///         {IFactory.ActionPaused} while `TRANSFER` is paused, or while `MINT` / `BURN` is paused
    ///         and the auto-mint / auto-burn leg fires. Auto-mint fires on `Perm.MINT` in `permissions(from, msg.sender)`;
    ///         auto-burn on `Perm.BURN` in `permissions(to, msg.sender)` — the receiver's grant to
    ///         the initiator, NOT the sender's row. The two are not symmetric. An `amount` above
    ///         `from`'s balance reverts `ERC20InsufficientBalance` without the MINT bit; with it, the
    ///         shortfall is minted ({Mint}), or the call reverts {ContractExpired} from
    ///         `expirationDate` onwards. An auto-burn emits {PairBurned} from this Option; the paired
    ///         Receipt emits nothing.
    ///
    ///         ⚠ **Balance deltas are not `amount`.** When auto-burn fires, `to`'s option balance
    ///         rises by `amount - min(receipt.balanceOf(to), amount)` and `to` receives the
    ///         difference in collateral instead — and `receipt.balanceOf(to)` is a plain ERC-20
    ///         balance any third party can inflate by sending Receipt tokens to `to`, so the netted
    ///         size is not under the receiver's control. When auto-mint fires, `from` is charged
    ///         collateral for the shortfall and left holding Receipts. Integrators (vaults, routers,
    ///         AMMs) that hold a `BURN` grant to any initiator must read balances back after an
    ///         inbound transfer rather than assume `balanceAfter - balanceBefore == amount`. See
    ///         {IReceipt.redeemFor} for the full reasoning.
    /// @param to     Receiver, and the account whose Receipt balance auto-burn may net against.
    /// @param amount Options to move (collateral decimals); may exceed the caller's balance only
    ///               under the caller's own MINT self entry.
    /// @return Always `true`; every failure reverts.
    function transfer(address to, uint256 amount) external returns (bool);
    /// @notice ERC20 transferFrom override — same hooks (and the same balance-delta caveat) as
    ///         {transfer}, with the same pause checks. The ERC20 allowance is skipped entirely when
    ///         `msg.sender` is `from` itself (unlike vanilla OZ ERC20, which would spend a
    ///         self-approval) or holds `Perm.TRANSFER` in `from`'s factory permission mask (a
    ///         blanket approval across every option this factory has created or will create);
    ///         otherwise it is spent as usual.
    /// @param from   Token owner, and the account charged for any auto-minted shortfall.
    /// @param to     Receiver, and the account whose Receipt balance auto-burn may net against.
    /// @param amount Options to move (collateral decimals).
    /// @return Always `true`; every failure reverts.
    function transferFrom(address from, address to, uint256 amount) external returns (bool);

    /// @notice Exercise the caller's full Option balance: pay consideration, receive collateral —
    ///         safe self-exercise (the caller pays AND receives). Reverts {ZeroValue} when the caller
    ///         holds nothing and the window is open — the window checks ({InvalidExercise},
    ///         {ExerciseWindowClosed}) run first and take precedence. The balance is read at call
    ///         time, so this exercises everything held including unsolicited transfers. For a
    ///         deadline-sensitive exercise, use {exercise(uint256)} with a fixed amount so an added
    ///         balance cannot increase the required consideration and revert the call.
    function exercise() external;
    /// @notice Exercise `amount` of the caller's Options — safe self-exercise (the caller pays AND
    ///         receives). Same gates and reverts as {exerciseFor(address,uint256)} with
    ///         `holder = msg.sender`. Emits {Exercise}.
    /// @param amount Collateral units to receive. Consideration paid is
    ///               {IReceipt.toConsideration}`(amount, true)` (strike rate, rounded up), pulled
    ///               from the caller's ERC-20 allowance to the factory.
    function exercise(uint256 amount) external;
    /// @notice **Dangerous keeper path.** Burn `amount` of `holder`'s Options; the caller pays the
    ///         consideration AND receives the collateral. The holder gets nothing on-chain. Use this
    ///         only when (a) the caller is a contract that will deliver the holder's economic surplus
    ///         off-band (e.g. a keeper that pays the strike from its own balance and pays the holder
    ///         at least a spread the holder set on-chain; see {Option.exerciseFor}), or (b) the holder
    ///         explicitly intends to gift the exercise value to the caller.
    ///
    ///         Authorisation: the caller must be `holder` themselves or hold `Perm.EXERCISE` in the
    ///         holder's factory permission mask. **Granting EXERCISE to a non-trusted operator is
    ///         equivalent to giving them a withdrawal right over your ITM value.** `Perm.TRANSFER`
    ///         does not gate this function, but it is not a weaker grant: an operator holding
    ///         TRANSFER can move your longs to itself and exercise them as their own holder,
    ///         reaching the same ITM value by a different route. Both bits are custody-grade —
    ///         grant either only to a deployed, audited contract whose code you have read, never to
    ///         an EOA and never to an upgradeable proxy you do not control.
    ///
    ///         Allowed any time exercise itself is allowed (pre-expiry for American, plus the
    ///         post-expiry window through `exerciseDeadline` for both flavours). Reverts {ZeroValue}
    ///         on a zero `amount`, {Unauthorized} without the grant, and `ERC20InsufficientBalance`
    ///         if `holder` does not hold `amount` — this path never partially fills. The
    ///         consideration pull reverts with the consideration token's own allowance/balance
    ///         error or {IFactory.FeeOnTransferNotSupported}. Emits {Exercise}.
    /// @param holder Option holder whose tokens will be burned. Receives nothing on-chain.
    /// @param amount Collateral units to exercise. Consideration collected from the caller is
    ///               {IReceipt.toConsideration}`(amount, true)` (strike rate, rounded up); the
    ///               caller receives the `amount` of collateral.
    /// @return Collateral units exercised. Always exactly `amount` — the call reverts rather than
    ///         partially filling, so the value is informational for on-chain callers.
    function exerciseFor(address holder, uint256 amount) external returns (uint256);
    /// @notice Batch variant of {exerciseFor(address,uint256)}. Same dangerous semantics — the caller
    ///         pays consideration and receives collateral for every holder. Exercises `amounts[i]` of
    ///         `holders[i]` and emits one {Exercise} per processed entry.
    ///
    ///         Three classes of entry are skipped rather than reverting, so one stale row cannot
    ///         grief the sweep for everyone else: a zero `amounts[i]`, an `amounts[i]` greater than
    ///         `balanceOf(holders[i])` (a holder who has since sold), and a holder who has not
    ///         granted the caller `Perm.EXERCISE`. A batch in which every entry is skipped — an
    ///         empty array included — succeeds as a no-op. Skipping is the ONLY containment:
    ///         {InvalidValue} on a length mismatch, the window checks, and anything that makes the
    ///         Receipt-side exercise revert — notably the caller's own consideration balance or
    ///         factory allowance running out partway down the list — abort the whole batch and roll
    ///         back the holders already processed.
    /// @param holders Option holders whose options will be exercised.
    /// @param amounts Per-holder collateral amounts to exercise; must align 1:1 with `holders`
    ///                (unequal lengths revert {InvalidValue}).
    function exerciseFor(address[] calldata holders, uint256[] calldata amounts) external;

    /// @notice Pair-burn matched Option + Receipt to recover collateral. Shorthand for
    ///         `burn(msg.sender, amount)`. No time gate — pair-burn nets both sides 1:1 so
    ///         it needs neither the exercise window nor the clock: it stays open past
    ///         `expirationDate` and past `exerciseDeadline`, alongside {IReceipt.redeem} /
    ///         {IReceipt.redeemFor} as a post-window short-side exit. The caller must hold at least
    ///         `amount` of BOTH sides; `amount` of each is burned and `amount` of collateral is
    ///         returned, with no fee. Reverts {IFactory.ActionPaused} while `BURN` is paused,
    ///         {ZeroValue} on a zero `amount`, and
    ///         `ERC20InsufficientBalance` (raised on the Option first, then the Receipt) when
    ///         either side is short. Emits {PairBurned} from this Option; the paired Receipt emits
    ///         nothing.
    /// @param amount Collateral-denominated amount to burn from each side.
    function burn(uint256 amount) external;
    /// @notice Pair-burn `amount` of `account`'s matched Option + Receipt; collateral returns to
    ///         `account`. No timing gate — valid at any timestamp, before and after expiry, while
    ///         `BURN` is not paused. Caller
    ///         must be `account` or hold `Perm.BURN` in `account`'s factory permission mask, else
    ///         {Unauthorized}. Trigger-only grant — the recovered collateral always goes to
    ///         `account`, never to the caller, so a BURN operator can unwind a holder's matched
    ///         position but not extract value from it (it can still choose the *moment*). The
    ///         {ZeroValue} check runs before the authorisation check; balance and event behaviour
    ///         are as in {burn(uint256)}.
    /// @param account Holder of the matched Option + Receipt pair, and recipient of the collateral.
    /// @param amount  Collateral-denominated amount to burn from each side.
    function burn(address account, uint256 amount) external;
    /// @notice Burn the caller's own expired long tokens (post-`exerciseDeadline` cleanup). Only
    ///         callable strictly after `exerciseDeadline`. Post-deadline a long can no longer be
    ///         exercised, but it still transfers and still pair-burns against a matching Receipt —
    ///         it is NOT worthless, which is why this is **self-service only**: `msg.sender` must be
    ///         `holder`, and no permission bit reaches here (an operator destroying a long would
    ///         strip the holder's collateral claim instead of returning it via
    ///         {burn(address,uint256)}). Long side only — leaves the Receipt and collateral pool
    ///         untouched. Reverts {ZeroValue} on a zero `amount`, {Unauthorized} for any caller
    ///         other than `holder`, and {NotYetExpired} on or before the deadline, checked in that
    ///         order, so the authorisation check runs BEFORE the timestamp check. Emits {Expire}.
    /// @param holder Address of the long option holder. Must be `msg.sender`.
    /// @param amount Amount of long option tokens to burn. Above the holder's balance reverts
    ///               `ERC20InsufficientBalance`.
    function expire(address holder, uint256 amount) external;
}
