// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

/// @notice Parameters for {IFactory.createOption}.
/// @param collateral     Underlying collateral token (must differ from consideration).
/// @param consideration  Quote / consideration token.
/// @param expirationDate Unix expiration timestamp (must be in the future).
/// @param strike         Strike price, 18-decimal fixed point (consideration per collateral; for puts
///                       this should be the inverted `1e36 / humanStrike`). Must be non-zero, and when
///                       the consideration has more decimals than the collateral it must also satisfy
///                       `strike <= type(uint256).max / 10**(consDecimals - collDecimals)` — the bound
///                       that keeps the strike conversion from overflowing. Both reject with
///                       `InvalidValue`.
/// @param isPut          `true` for puts. **A label, not a mode.** The contract uses it only to
///                       invert the strike for display in `name()` and as a field of the registry
///                       key ({IFactory.optionKey}); settlement never reads it and always converts
///                       at `strike` exactly as stored. The put convention — swap the two tokens
///                       (collateral = the quote asset) and pass `strike = 1e36 / humanStrike` —
///                       is therefore an off-chain rule the contract cannot check: a put created
///                       with a human strike settles at that value while its name shows its
///                       reciprocal. The SDK / frontend must be the sole constructor of `strike`.
/// @param isEuro         `true` for European-style options (exercise barred pre-expiry; only the
///                       post-expiry window is exercisable). `false` for American.
/// @param windowSeconds  Length in seconds of the post-expiry exercise window. Taken LITERALLY —
///                       no contract-side default substitution, and {IFactory.DEFAULT_EXERCISE_WINDOW}
///                       is informational only (never applied). American options may pass `0` for
///                       "no post-expiry extension": the window collapses to the single instant
///                       `block.timestamp == expirationDate`, and one second later exercise reverts
///                       `ExerciseWindowClosed`. A struct built with a zero default (an omitted
///                       field in a script or SDK) silently produces exactly that market — and,
///                       since the window is part of the registry key, a different market from the
///                       one with the intended window. Set it explicitly.
///                       European options require `> 0` (else reverts with `InvalidValue`).
///                       The deadline never moves: if the chain's sequencer is down or censoring
///                       for the whole window, holders cannot exercise. On L2s, forced inclusion
///                       through L1 can take longer than the recommended 1-hour window.
///                       After `expirationDate + windowSeconds`, exercise reverts and the collateral
///                       leg of short-side redemption opens ({IReceipt.redeem}; its consideration
///                       leg is not gated on this boundary).
struct CreateParams {
    address collateral;
    address consideration;
    uint40 expirationDate;
    uint256 strike;
    bool isPut;
    bool isEuro;
    uint40 windowSeconds;
}

/// @title  IFactory — option pair deployer + transfer hub
/// @author Greek.fi
/// @notice Deploys Option + Receipt pairs from immutable templates (the Option is a bare EIP-1167
///         proxy; the Receipt is a clone-with-immutable-args carrying the pair's economic params),
///         serves as the single ERC20-allowance pull point for every option pair it creates, and holds
///         the per-(owner, operator) permission registry ({Perm} bitmasks: TRANSFER / MINT / BURN /
///         REDEEM / EXERCISE / TRANSFER_RECEIPT).
/// @dev    Implemented by the deployed `Factory`, which also inherits {Ownable}. {owner}'s reach
///         into the protocol is {setFee} (the default for new markets), {IReceipt.setFee} (future
///         redemptions in a live market), {IReceipt.sweep} (surplus above holder backing), and being
///         the payee of {IReceipt.collectFees}, plus pausing individual actions across all its markets.
///         It cannot withdraw holder backing, but can suspend exits without extending deadlines.
interface IFactory {
    /// @notice Emitted for every newly-created option. NOT emitted when get-or-create returns an
    ///         existing Option, so a market emits this exactly once, ever. The first seven fields
    ///         are the {CreateParams} as submitted (and as folded into {optionKey}).
    /// @param collateral     Collateral token.
    /// @param consideration  Consideration token.
    /// @param expirationDate Unix expiration timestamp.
    /// @param strike         Strike as stored (18-decimal fixed point; inverted for puts).
    /// @param isPut          Put label.
    /// @param isEuro         European flag.
    /// @param windowSeconds  Post-expiry exercise window length, as submitted.
    /// @param option         The deployed Option clone.
    /// @param receipt        The deployed Receipt clone paired with `option`.
    event OptionCreated(
        address indexed collateral,
        address indexed consideration,
        uint40 expirationDate,
        uint256 strike,
        bool isPut,
        bool isEuro,
        uint40 windowSeconds,
        address indexed option,
        address receipt
    );
    /// @notice Emitted whenever `owner`'s permission mask for `operator` changes ({setPermissions}
    ///         / {addPermissions}). `mask` is the full resulting mask, not a delta.
    /// @param owner    The account whose positions the mask governs (`msg.sender` of the call).
    /// @param operator The account granted (or, when equal to `owner`, the self entry).
    /// @param mask     The full mask now stored at `permissions(owner, operator)`.
    event PermissionsUpdated(address indexed owner, address indexed operator, uint256 mask);
    /// @notice Emitted on {setFee} — reports the new fee rate. Companion to `IReceipt.Fee`, which
    ///         reports the amount collected; both share the `Fee` name so fee events read uniformly
    ///         off-chain.
    /// @param feeBps The new rate in basis points, as stored in {feeBps}.
    event Fee(uint64 feeBps);

    /// @notice Emitted by pause/unpause with the full resulting action mask, including no-op calls.
    /// @param mask Paused {Pause} bits after the call.
    event PauseUpdated(uint256 mask);

    /// @notice One or more requested actions are paused across this Factory's markets.
    /// @param actions Intersection of the requested actions and {pausedActions}.
    error ActionPaused(uint256 actions);

    /// @notice Zero address supplied where a real one is required (either token at creation, the
    ///         permission `operator`) — and also raised by {transferFrom} when the caller is not a
    ///         Receipt this factory registered.
    error InvalidAddress();
    /// @notice Collateral and consideration were the same address (no real option pair).
    error InvalidTokens();
    /// @notice A value param is invalid: strike (zero, or over the decimals-gap bound stated on
    ///         `CreateParams.strike`), expiration, window, a token's `decimals()` above 36, a salt array in
    ///         {createOptions2} whose length does not match `params`, a permission mask carrying
    ///         bits outside `Perm.ALL`, a pause mask outside `Pause.ALL`, or a {setFee} above 1000 bps.
    error InvalidValue();
    /// @notice {createOption2} / {createOptions2} was given a CREATE2 salt but an economically-
    ///         identical Option already exists at an address that salt does not resolve to. Carries
    ///         the occupying address so the caller can either accept it (re-submit with zero salts,
    ///         or call {createOption}) or change the option's economic params. The mined salt is NOT
    ///         consumed by this revert — it stays usable on a different market.
    error OptionExists(address existing);
    /// @notice Token transferFrom delivered less than `amount` — fee-on-transfer / rebasing tokens are not supported.
    error FeeOnTransferNotSupported();
    /// @notice {Ownable.renounceOwnership} is disabled: an ownerless factory would strand every
    ///         accrued fee and sweepable balance in every Receipt it ever created. Transfer
    ///         ownership instead.
    error OwnershipNotRenounceable();

    /// @notice Receipt template clone. Per-option instances are clones-with-immutable-args of this —
    ///         an EIP-1167-style proxy with the pair's economic params appended to its runtime code,
    ///         so its init code (and CREATE2 address) differs per option.
    function RECEIPT_CLONE() external view returns (address);
    /// @notice Option template clone; per-option instances are bare EIP-1167 clones of this, with no
    ///         immutable args — every economic getter forwards to the paired Receipt.
    function OPTION_CLONE() external view returns (address);
    /// @notice Informational suggested-default window length (frontend convenience). The contract
    ///         does NOT consult this — `CreateParams.windowSeconds` is always taken literally.
    ///         Exposed so frontends can read the recommended 1 hour without hardcoding it.
    function DEFAULT_EXERCISE_WINDOW() external view returns (uint40);
    /// @notice The {Ownable} owner. Its reach into the protocol: {setFee} (≤ 10 %, used as the
    ///         default during market initialization; {IReceipt.setFee} can reprice a live market),
    ///         {IReceipt.sweep} (limited to surplus above holder backing) and receiving
    ///         {IReceipt.collectFees}. It also controls {pause} / {unpause} across every market and
    ///         can suspend exits. It cannot withdraw holder backing. `renounceOwnership` is disabled
    ///         ({OwnershipNotRenounceable}) because an ownerless factory would strand every accrued
    ///         fee and sweepable balance in every Receipt it ever created.
    /// @return The current owner; never `address(0)`.
    function owner() external view returns (address);
    /// @notice `true` if `rec` is a Receipt produced by this factory. Doubles as the auth gate for
    ///         {transferFrom} — only registered Receipts can pull collateral/consideration. Validate
    ///         an Option `opt` by checking `receipts(opt.receipt()) && IReceipt(opt.receipt()).option() == opt`.
    function receipts(address rec) external view returns (bool);
    /// @notice Canonical Option address for the params identified by `key` (see {optionKey}), or
    ///         `address(0)` if no such option exists. {createOption} is get-or-create against this
    ///         registry, so economically-identical markets are deduped and existence is queryable.
    ///         Write-once: an entry is never cleared or overwritten, so the canonical address for a
    ///         given key is fixed for the life of the factory.
    function optionFor(bytes32 key) external view returns (address);
    /// @notice Deterministic registry key for a set of economic params. Folds in all seven
    ///         {CreateParams} fields; differing in any field yields a different key (and therefore a
    ///         distinct option market).
    /// @param p The params to key; not validated, so a key exists for params {createOption} would reject.
    /// @return `keccak256(abi.encode(...))` of the seven fields in declaration order.
    function optionKey(CreateParams calldata p) external pure returns (bytes32);
    /// @notice `operator`'s permission bitmask over `owner`'s positions — see {Perm}: TRANSFER (1),
    ///         MINT (2), BURN (4), REDEEM (8), EXERCISE (16), TRANSFER_RECEIPT (32). The self entry
    ///         `permissions(account, account)` carries the account's auto-mint opt-in
    ///         (MINT = auto-mint on shortfall). Auto-burn reads `permissions(to, msg.sender)` — the
    ///         receiver's grant to the transfer's initiator — so the self entry applies there only
    ///         when the receiver is also the initiator.
    ///
    ///         To test a grant, mind ALL-vs-ANY — for a multi-bit mask they differ, and the wrong
    ///         one fails open:
    ///           holds every bit: `permissions(o, op) & mask == mask`
    ///           holds any bit:   `permissions(o, op) & mask != 0`
    function permissions(address owner, address operator) external view returns (uint256);
    /// @notice Protocol fee in basis points, skimmed from both legs (consideration and collateral)
    ///         of `IReceipt.redeem` only — never on exercise and never on pair-burn. This is the
    ///         default used to initialize newly-created Receipts; each Receipt stores its own mutable
    ///         rate and can be repriced by {IReceipt.setFee}. `0` means no fee. Accrued fees are paid
    ///         to {owner} via `IReceipt.collectFees`. Capped at 1000 (10%) by {setFee}.
    function feeBps() external view returns (uint64);

    /// @notice Create a new Option + Receipt pair per the given parameters, or return the existing
    ///         canonical Option if one with economically-identical params already exists
    ///         (get-or-create; see {optionFor}). Emits {OptionCreated} on a fresh deploy only — a
    ///         registry hit returns the existing address with no event, so a script waiting on
    ///         {OptionCreated} for a market that already exists waits forever. The struct-field checks
    ///         (strike non-zero, tokens, expiry, European window) run BEFORE the registry lookup, so
    ///         naming an existing market whose `expirationDate` has passed reverts `InvalidValue`
    ///         rather than returning it; use {optionFor} with {optionKey} for a pure lookup. The
    ///         token-dependent checks (`decimals() <= 36`, the strike bound) run only on a fresh
    ///         deploy, since a registry hit already passed them.
    ///
    ///         ⚠ `collateral` and `consideration` MUST be standard ERC-20 tokens with exact,
    ///         balance-preserving transfers. Fee-on-transfer and rebasing / elastic-supply tokens are
    ///         NOT supported and will corrupt the option's 1:1 accounting. There is no creation-time
    ///         guard against this — the caller is responsible for only pairing standard tokens.
    /// @param params See {CreateParams} for per-field semantics and validation.
    /// @return The canonical Option address — either freshly deployed, or the existing option if an
    ///         economically-identical one already exists.
    function createOption(CreateParams calldata params) external returns (address);
    /// @notice Batch form of {createOption}. Same ordering in → same ordering out. Get-or-create
    ///         applies per entry; entries are not isolated — one bad entry reverts the whole batch,
    ///         rolling back the entries already processed.
    /// @param params Array of {CreateParams}.
    /// @return Option addresses aligned with `params` — newly deployed or pre-existing.
    function createOptions(CreateParams[] calldata params) external returns (address[] memory);
    /// @notice CREATE2 form of {createOption}: the Option and Receipt clones land at addresses derived
    ///         from `optionSalt` / `receiptSalt`, allowing vanity addresses mined off-chain. Mine
    ///         `optionSalt` first — the Receipt's init code embeds the resulting Option address.
    ///         Supplying a non-zero salt makes the call STRICT: it returns the address you mined or
    ///         reverts {OptionExists} — it never silently returns a pre-existing Option at some other
    ///         address. The Receipt leg of that check is blunt: ANY non-zero `receiptSalt` against
    ///         an existing market reverts {OptionExists}, even when `optionSalt` resolves to the
    ///         existing Option (the Receipt address is not re-derived on-chain). Pass zero salts (or
    ///         use {createOption}) to accept the canonical Option; a zero salt means "don't mine
    ///         this one" and selects plain CREATE for that clone. Mine both salts or neither: with
    ///         `optionSalt == 0` the Option lands at the factory's next CREATE nonce, which any
    ///         earlier creation shifts, and because the Receipt's init code embeds that address a
    ///         mined `receiptSalt` then resolves to a different address than predicted, with no
    ///         on-chain check.
    ///
    ///         Salts are namespaced by the caller: the effective CREATE2 salt is
    ///         `keccak256(msg.sender ‖ salt)`, so a salt one account mines cannot be occupied by
    ///         another. Address prediction is done off-chain (the factory exposes no prediction
    ///         helper and no init-code-hash view):
    ///         `address = keccak256(0xff ‖ factory ‖ keccak256(deployer ‖ salt) ‖ keccak256(initCode))[12:]`,
    ///         where the Option's init code is the EIP-1167 proxy for {OPTION_CLONE} and the
    ///         Receipt's is the clone-with-immutable-args creation code for {RECEIPT_CLONE} with the
    ///         112-byte packed args appended — which embed the resulting Option address (so mine the
    ///         Option salt first).
    /// @param params      See {CreateParams} — identical semantics to {createOption}.
    /// @param optionSalt  CREATE2 salt for the Option clone, or `bytes32(0)` for plain CREATE.
    /// @param receiptSalt CREATE2 salt for the Receipt clone, or `bytes32(0)` for plain CREATE.
    /// @return The Option address: the freshly deployed clone, or the existing canonical Option when
    ///         the salts permit returning it (both zero, or `optionSalt` resolving to it with a zero
    ///         `receiptSalt`).
    function createOption2(CreateParams calldata params, bytes32 optionSalt, bytes32 receiptSalt) external returns (address);
    /// @notice Batch form of {createOption2}; salt arrays are positional and must match `params` length
    ///         (else {InvalidValue}). Each entry carries {createOption2}'s full strictness, and a revert
    ///         is not contained: one entry's {OptionExists} rolls back the WHOLE batch, including
    ///         entries already deployed. The salts are not consumed by such a revert. Check {optionFor}
    ///         against {optionKey} for every entry before submitting a large batch.
    /// @param params       Array of {CreateParams}.
    /// @param optionSalts  Option-clone CREATE2 salts, aligned with `params`.
    /// @param receiptSalts Receipt-clone CREATE2 salts, aligned with `params`.
    /// @return Option addresses aligned with `params` — newly deployed or pre-existing.
    function createOptions2(CreateParams[] calldata params, bytes32[] calldata optionSalts, bytes32[] calldata receiptSalts)
        external
        returns (address[] memory);
    /// @notice Pull `amount` of `token` from `from` to `to` via the token's ERC-20 allowance to the
    ///         factory. Only callable by Receipt clones this factory created (any other caller
    ///         reverts {InvalidAddress}). Reverts {FeeOnTransferNotSupported} if `to` receives less
    ///         than `amount`; a surplus is accepted.
    /// @param from   Token owner.
    /// @param to     Recipient (typically the calling Receipt contract).
    /// @param amount Token amount to transfer.
    /// @param token  Token to move.
    /// @return success Always `true` on success; reverts otherwise.
    function transferFrom(address from, address to, uint256 amount, address token) external returns (bool success);
    /// @notice Set `operator`'s permission mask over the caller's positions, overwriting any
    ///         previous mask (`0` revokes everything). Bits: `Perm.TRANSFER` (1), `Perm.MINT` (2),
    ///         `Perm.BURN` (4), `Perm.REDEEM` (8), `Perm.EXERCISE` (16), `Perm.TRANSFER_RECEIPT`
    ///         (32). Reverts {InvalidAddress} for a zero `operator` and {InvalidValue} on bits outside
    ///         `Perm.ALL`; see {Perm} for what each bit authorises and its risk profile. Emits
    ///         {PermissionsUpdated} with the stored mask, including when it is unchanged.
    ///         `operator == msg.sender` sets the caller's own automation opt-ins (auto-mint, and
    ///         auto-burn only on transfers the caller both receives and initiates). That self entry
    ///         goes through this same function with no distinct shape, so `setPermissions(self,
    ///         Perm.ALL)` is not a harmless self-initialisation: its `MINT` bit arms auto-mint and
    ///         removes the ERC-20 insufficient-balance revert on every transfer — see {Perm}.
    /// @param operator Address being granted (or, for the caller's own address, the automation opt-in).
    /// @param mask     Full replacement mask; must not contain bits outside `Perm.ALL`.
    function setPermissions(address operator, uint256 mask) external;
    /// @notice OR `mask` into `operator`'s existing permission mask (adds bits, never removes).
    ///         There is no `removePermissions`: the only revoke is `setPermissions(operator, 0)`
    ///         (or a full replacement mask via {setPermissions}). Reverts {InvalidAddress} for a zero
    ///         `operator` and {InvalidValue} on bits outside `Perm.ALL`. `mask == 0` is accepted as a
    ///         no-op that still emits {PermissionsUpdated} with the unchanged mask — do not read
    ///         that event as a revoke.
    /// @param operator Address being granted.
    /// @param mask     Bits to add; must not contain bits outside `Perm.ALL`. Zero is a no-op.
    function addPermissions(address operator, uint256 mask) external;

    /// @notice Global {Pause} bitmask, initially zero. Applies to all markets from this Factory.
    ///         Bits are MINT (1), EXERCISE (2), REDEEM (4), BURN (8), TRANSFER (16), CREATE (32),
    ///         EXPIRE (64); `Pause.ALL` is 127. These are independent of the {Perm} flags.
    function pausedActions() external view returns (uint256);
    /// @notice Add `mask` to the paused actions. Factory-owner-only; previous paused bits remain set.
    ///         Reverts {InvalidValue} for bits outside `Pause.ALL`. Zero is an emitting no-op.
    ///         MINT/BURN include transfer-time automation: a transfer that needs a paused leg
    ///         reverts atomically instead of skipping that leg. TRANSFER covers both token sides
    ///         but does not stop minting, exercise, pair-burn or redemption on its own.
    ///         CREATE also blocks get-or-create calls for existing markets. Empty creation batches
    ///         and redemption batches with no eligible holders can still succeed without an action.
    ///         Approvals, permission revocation, fees, sweep and ownership are never paused, except
    ///         that sweeping a Receipt's own tokens is a Receipt transfer and follows `TRANSFER`.
    ///         This gives the owner authority to suspend holder exits. Pausing does NOT extend
    ///         expiration or exercise deadlines: an exercise pause can outlast a holder's rights,
    ///         while redemption remains possible if its own bit is clear and its time gates pass.
    /// @param mask {Pause} bits to add, combined with `|`.
    function pause(uint256 mask) external;
    /// @notice Clear only the supplied paused actions. Factory-owner-only, with the same mask
    ///         validation and event as {pause}. Other paused bits remain set; zero is a no-op.
    /// @param mask {Pause} bits to clear.
    function unpause(uint256 mask) external;
    /// @notice Clear every paused action. Factory-owner-only; emits {PauseUpdated} with zero.
    function unpause() external;
    /// @notice Revert {ActionPaused} if any supplied action is paused. Shared read-only gate used
    ///         by the Factory and its Option/Receipt contracts; returns normally otherwise.
    /// @param actions Action bits to check. Bits absent from {pausedActions} have no effect.
    function checkNotPaused(uint256 actions) external view;
    /// @notice Set the protocol redeem fee in basis points. Owner-only (any other caller reverts
    ///         `OwnableUnauthorizedAccount`); reverts {InvalidValue} above 1000 (10%). Emits {Fee}. Applies only to options created AFTER the call: each
    ///         market initializes its Receipt's storage fee from the current {feeBps}; the Receipt
    ///         owner can later change that market's rate with {IReceipt.setFee}.
    /// @param bps New fee in basis points; `0` disables the fee.
    function setFee(uint64 bps) external;
}
