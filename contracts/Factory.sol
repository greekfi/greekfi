// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import { Option } from "./Option.sol";
import { Receipt } from "./Receipt.sol";
import { ClonesWithImmutableArgs } from "clone/src/ClonesWithImmutableArgs.sol";
import { CreateParams } from "./interfaces/IFactory.sol";

using SafeERC20 for IERC20;

/**
 * @title  Factory — deployer, allowance hub, operator registry
 * @author Greek.fi
 * @notice The only on-chain contract users need to interact with to *create* options. Once deployed,
 *         every Option + Receipt pair runs off pre-compiled template clones, so creation is
 *         cheap and the factory is never an upgradeable rug vector (the templates are immutable).
 *
 *         The factory also plays three lasting roles post-creation:
 *
 *         1. **Single allowance point.** Users `approve(collateralToken, amount)` on the factory once,
 *            and any Option / Receipt pair created by this factory can pull from that allowance
 *            via {transferFrom}. No need to approve every new option individually.
 *
 *         2. **Operator registry.** {approveOperator} gives an address blanket authority to move
 *            any Option produced by this factory on your behalf — the ERC-1155-style "setApprovalForAll"
 *            pattern. Used by trading venues and aggregators.
 *
 *         3. **Auto-mint / auto-redeem opt-in.** {enableAutoMintBurn} flips a per-account flag that
 *            Option consults on transfer to auto-mint deficits and auto-redeem matched Option+Receipt
 *            on the receiving side.
 *
 *         ### Exercise window
 *
 *         There is no oracle. Settlement is purely time-gated:
 *
 *         - `isEuro = false` (American) — exercise allowed from creation through `exerciseDeadline`.
 *         - `isEuro = true`  (European) — exercise allowed only between `expirationDate` and
 *           `exerciseDeadline`.
 *
 *         `windowSeconds` on {CreateParams} sets how long after expiration the window stays open;
 *         it is taken literally — the contract NEVER substitutes a default. American options may
 *         pass `0` for "no post-expiry extension" (window collapses to `expirationDate`).
 *         European options must pass `windowSeconds > 0` (else `InvalidValue`). After
 *         `expirationDate + windowSeconds`, exercise reverts (for both flavours) and short-side
 *         redemption opens. {DEFAULT_EXERCISE_WINDOW} is an informational constant the frontend
 *         may use as a suggested default; the contract does not consult it.
 *
 *         ### Supported tokens (IMPORTANT)
 *
 *         Collateral and consideration MUST be standard ERC-20 tokens with **exact, balance-preserving
 *         transfers**. The protocol tracks balances 1:1 internally; any token whose `balanceOf` can
 *         diverge from the amounts actually moved will corrupt that accounting (deposits, redemptions,
 *         share/conversion math, and the solvency invariant). Non-standard mechanics are NOT supported:
 *
 *         - **Fee-on-transfer** (a cut is skimmed on transfer) — actively rejected: {transferFrom}
 *           checks the delivered balance delta and reverts {FeeOnTransferNotSupported} when a pull
 *           lands short, so options on such tokens cannot be minted or exercised.
 *         - **Rebasing / elastic-supply** (balances change with no transfer) — NOT detectable on-chain
 *           and NOT supported: the collateral/consideration held by a {Receipt} can silently drift
 *           from the recorded amounts, breaking redemption and solvency. There is no on-chain guard;
 *           such tokens must simply not be used.
 *
 *         Do NOT create an option whose collateral or consideration implements either behaviour — its
 *         accounting will not operate correctly. Frontends MUST surface this when users create options.
 */
contract Factory is Ownable, ReentrancyGuardTransient, IERC20Errors {
    /// @notice Template Receipt contract; per-option instances are EIP-1167 clones of this.
    address public immutable RECEIPT_CLONE;
    /// @notice Template Option contract; per-option instances are EIP-1167 clones of this.
    address public immutable OPTION_CLONE;
    /// @notice Informational suggested-default for the post-expiry exercise window. The contract
    ///         NEVER substitutes this value — `CreateParams.windowSeconds` is taken literally.
    ///         Exposed so frontends can read a canonical "8 hours" without hardcoding it.
    uint40 public constant DEFAULT_EXERCISE_WINDOW = 8 hours;

    /// @notice `true` if the address is a Receipt clone this factory created. Doubles as the auth
    ///         gate for {transferFrom} — only registered Receipts can pull from factory allowances.
    ///         Validate an Option by reading its `receipt()` and confirming
    ///         `factory.receipts(rec) && Receipt(rec).option() == opt`.
    mapping(address => bool) public receipts;

    /// @notice Canonical Option address for a given set of economic params, keyed by {optionKey}.
    ///         `address(0)` means no option with those params exists yet. {createOption} is
    ///         get-or-create: a second call with economically-identical params returns the existing
    ///         Option instead of deploying a duplicate, so identical markets stay canonical/deduped
    ///         and existence is queryable on-chain.
    mapping(bytes32 => address) public optionFor;

    /// @dev Per-token allowance table: `_allowances[token][owner] -> amount`.
    mapping(address => mapping(address => uint256)) private _allowances;

    /// @dev Operator approval table: `_approvedOperators[owner][operator] -> bool`.
    mapping(address => mapping(address => bool)) private _approvedOperators;

    /// @dev Exercise-allowance table: `_exerciseAllowed[holder][operator] -> bool`. Lets `operator`
    ///      burn `holder`'s options via the on-behalf {Option.exercise} overload.
    mapping(address => mapping(address => bool)) private _exerciseAllowed;

    /// @dev Redeem-allowance table: `_redeemAllowed[holder][redeemer] -> bool`. Lets `redeemer`
    ///      trigger {Receipt.redeemFor} on `holder`'s post-window position. Funds always go to
    ///      the holder — the redeemer is a pure trigger. Composability-safe: a Receipt sitting
    ///      inside an ERC4626 vault / Morpho market / multisig cannot be force-unwound by an
    ///      unauthorised third party.
    mapping(address => mapping(address => bool)) private _redeemAllowed;

    /// @notice Per-account opt-in for auto-mint on transfer and auto-redeem on receive in {Option}.
    mapping(address => bool) public autoMintBurn;

    /// @notice Thrown when a zero address is supplied where a real contract is required.
    error InvalidAddress();
    /// @notice Thrown when `collateral == consideration` (no real option pair).
    error InvalidTokens();
    /// @notice Thrown when a value param (strike, expiration, window) is invalid.
    error InvalidValue();
    /// @notice Thrown when a token's transferFrom delivers less than `amount` (fee-on-transfer / rebasing).
    error FeeOnTransferNotSupported();

    modifier nonZeroAddr(address addr) {
        if (addr == address(0)) revert InvalidAddress();
        _;
    }
    modifier nonZero(uint256 value) {
        if (value == 0) revert InvalidValue();
        _;
    }

    /// @notice Emitted for every newly-created option.
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
    /// @notice Emitted on {approveOperator}.
    event OperatorApproval(address indexed owner, address indexed operator, bool approved);
    /// @notice Emitted on {allowExercise}.
    event ExerciseApproval(address indexed holder, address indexed exercisor, bool allowed);
    /// @notice Emitted on {allowRedeem}.
    event RedeemApproval(address indexed holder, address indexed redeemer, bool allowed);
    /// @notice Emitted on {enableAutoMintBurn}.
    event AutoMintBurnUpdated(address indexed account, bool enabled);
    /// @notice Emitted on {approve} (factory-level allowance set by token owner).
    event Approval(address indexed token, address indexed owner, uint256 amount);

    /// @notice Deploys the Option and Receipt templates internally so they record this factory
    ///         as their immutable `factory` (used to gate `init` and skip per-clone storage).
    constructor() Ownable(msg.sender) {
        RECEIPT_CLONE = address(new Receipt("RCT", "RCT"));
        OPTION_CLONE = address(new Option("OPT", "OPT"));
    }

    // ============ OPTION CREATION ============

    /// @notice Deploy a new Option + Receipt pair. Emits {OptionCreated}.
    /// @dev    Option is an EIP-1167 clone; Receipt is a clone-with-immutable-args (per-option
    ///         strike, decimals, dates, etc. baked into the clone's runtime bytecode).
    ///
    ///         ⚠ `collateral` and `consideration` MUST be standard ERC-20 tokens with exact,
    ///         balance-preserving transfers. Fee-on-transfer and rebasing / elastic-supply tokens are
    ///         NOT supported and will corrupt the option's 1:1 accounting (see the contract-level
    ///         "Supported tokens" note). There is no creation-time guard against this — the caller is
    ///         responsible for only pairing standard tokens.
    /// @param p See {CreateParams}:
    ///          - `collateral`, `consideration`: ERC20 addresses; must differ. Standard ERC-20 only —
    ///            no fee-on-transfer or rebasing tokens.
    ///          - `expirationDate`: unix timestamp; must be in the future.
    ///          - `strike`: 18-decimal fixed point (consideration per collateral, inverted for puts).
    ///          - `isPut`: option flavour.
    ///          - `isEuro`: `true` for European (no pre-expiry exercise), `false` for American.
    ///          - `windowSeconds`: post-expiry exercise window length in seconds; taken literally
    ///            (no contract-side default). American allows `0` (no extension); European requires `> 0`.
    /// @return option_ The canonical {Option} address — either freshly deployed, or the existing
    ///         option if an economically-identical one already exists (get-or-create; see {optionFor}).
    function createOption(CreateParams memory p) public nonReentrant nonZero(p.strike) returns (address option_) {
        if (p.collateral == p.consideration) revert InvalidTokens();
        if (p.collateral == address(0) || p.consideration == address(0)) revert InvalidAddress();
        if (p.expirationDate <= block.timestamp) revert InvalidValue();
        // American: windowSeconds == 0 is valid (no post-expiry extension).
        // European: windowSeconds must be > 0; the frontend handles any "default 8h" UX.
        if (p.isEuro && p.windowSeconds == 0) revert InvalidValue();

        // Get-or-create: if an economically-identical option already exists, return it instead of
        // deploying a duplicate (no new clones, no `OptionCreated` event). The cheap address/time/euro
        // checks above run FIRST, so invalid or expired params revert rather than returning a stale
        // market. A registry hit means these tokens (and therefore their decimals) were already
        // validated at first creation, so we can short-circuit before the `decimals()` reads below.
        bytes32 key = optionKey(p);
        address existing = optionFor[key];
        if (existing != address(0)) return existing;

        uint8 collDec = IERC20Metadata(p.collateral).decimals();
        uint8 consDec = IERC20Metadata(p.consideration).decimals();
        // Defence-in-depth: `10**(consDec - collDec)` (or its inverse) is Receipt's scaling factor;
        // values above ~48 overflow uint256 inside `toConsideration`. Realistic tokens are ≤ 18.
        if (collDec > 36 || consDec > 36) revert InvalidValue();

        // GRK-3: reject strikes that would overflow `strike * numer` inside Receipt.toConsideration().
        // numer = 10**(consDec - collDec) when consDec > collDec, else 1 (no overflow possible).
        if (consDec > collDec) {
            uint256 numer = 10 ** (uint256(consDec) - uint256(collDec));
            if (p.strike > type(uint256).max / numer) revert InvalidValue();
        }

        // Deploy Option first so we know its address before baking Receipt's immutable args.
        option_ = Clones.clone(OPTION_CLONE);
        // Immutable-args layout (112 bytes packed, MUST match Receipt's _getArg* offsets):
        // strike[32] coll[20] cons[20] option[20] expirationDate[8] exerciseDeadline[8]
        // isPut[1] isEuro[1] collDec[1] consDec[1]. p.strike is uint256 → encodePacked emits 32B.
        bytes memory args = abi.encodePacked(
            p.strike,
            p.collateral,
            p.consideration,
            option_,
            uint64(p.expirationDate),
            uint64(uint64(p.expirationDate) + uint64(p.windowSeconds)),
            uint8(p.isPut ? 1 : 0),
            uint8(p.isEuro ? 1 : 0),
            collDec,
            consDec
        );
        address receipt_ = ClonesWithImmutableArgs.clone(RECEIPT_CLONE, args);

        Option(option_).init(receipt_);
        receipts[receipt_] = true;
        optionFor[key] = option_;
        emit OptionCreated(
            p.collateral, p.consideration, p.expirationDate, p.strike, p.isPut, p.isEuro, p.windowSeconds, option_, receipt_
        );
    }

    /// @notice Batch form of {createOption}. Same ordering in → same ordering out.
    /// @param params Array of {CreateParams}.
    /// @return result Array of newly-created Option addresses, aligned with `params`.
    function createOptions(CreateParams[] memory params) external returns (address[] memory result) {
        result = new address[](params.length);
        for (uint256 i = 0; i < params.length; i++) {
            result[i] = createOption(params[i]);
        }
    }

    /// @notice Deterministic registry key for a set of economic params. All seven {CreateParams}
    ///         fields are economic identity, so every one is folded into the hash — two params that
    ///         differ in any field produce different keys (and therefore distinct option markets).
    /// @dev    `public pure` so off-chain callers and tests can compute the key and look up
    ///         {optionFor} without a creation tx.
    /// @param p The {CreateParams} to key.
    /// @return The `keccak256` registry key.
    function optionKey(CreateParams memory p) public pure returns (bytes32) {
        return
            keccak256(abi.encode(p.collateral, p.consideration, p.expirationDate, p.strike, p.isPut, p.isEuro, p.windowSeconds));
    }

    // ============ CENTRALIZED TRANSFER ============

    /// @notice Pull `amount` of `token` from `from` to `to`. Only callable by Receipt clones
    ///         that this factory has created.
    /// @dev    Decrements `_allowances[token][from]` (unless it is `type(uint256).max`).
    ///         This is the mechanism by which a single user approval on the factory flows to every
    ///         option pair it creates, rather than requiring approvals on each Receipt clone.
    /// @param from   Token owner.
    /// @param to     Recipient (typically the calling Receipt contract).
    /// @param amount Token amount to transfer.
    /// @param token  Token to move.
    /// @return success Always `true` on success; reverts otherwise.
    function transferFrom(address from, address to, uint256 amount, address token) external nonReentrant returns (bool) {
        if (!receipts[msg.sender]) revert InvalidAddress();
        uint256 currentAllowance = _allowances[token][from];
        if (currentAllowance < amount) revert ERC20InsufficientAllowance(msg.sender, currentAllowance, amount);
        if (currentAllowance != type(uint256).max) {
            _allowances[token][from] = currentAllowance - amount;
        }
        uint256 balanceBefore = IERC20(token).balanceOf(to);
        IERC20(token).safeTransferFrom(from, to, amount);
        if (IERC20(token).balanceOf(to) - balanceBefore != amount) revert FeeOnTransferNotSupported();
        return true;
    }

    /// @notice Factory-level allowance lookup: how much of `token` can the factory pull from `owner_`?
    /// @param token  Token.
    /// @param owner_ Token owner.
    /// @return Current allowance.
    function allowance(address token, address owner_) public view returns (uint256) {
        return _allowances[token][owner_];
    }

    /// @notice Permit2-style allowance: caller authorises the factory to pull up to `amount` of
    ///         `token` (collateral or consideration) on their behalf when any Option / Receipt
    ///         pair created by this factory needs to move it. The user must also have granted the
    ///         underlying `token.approve(factory, ...)` so `safeTransferFrom` can land.
    /// @dev    The allowance fans out to every Receipt clone (gated by the `receipts[]` registry)
    ///         and is consumed by `mint`, `exercise`, and — if {enableAutoMintBurn} is `true` —
    ///         the auto-mint leg of Option transfers triggered by approved operators. Granting
    ///         a large allowance here while also holding active {approveOperator} grants with
    ///         {enableAutoMintBurn} on is functionally equivalent to a permit on the underlying
    ///         token in favour of those operators.
    /// @param token  ERC20 to be approved.
    /// @param amount Allowance to grant (use `type(uint256).max` for infinite, `0` to revoke).
    function approve(address token, uint256 amount) public nonZeroAddr(token) {
        _allowances[token][msg.sender] = amount;
        emit Approval(token, msg.sender, amount);
    }

    // ============ OPERATOR APPROVAL ============

    /// @notice Grant or revoke `operator` blanket authority to move any of the caller's Option tokens
    ///         across every option this factory has created (ERC-1155-style `setApprovalForAll`).
    /// @dev    **Intended for audited swap / trading-venue contracts** — Uniswap-style routers,
    ///         RFQ market makers, vault adapters, anything that needs to pull a holder's Option as
    ///         part of a settlement flow without requiring a per-option ERC20 `approve`. Approved
    ///         operators skip the per-transfer `_spendAllowance` step on {Option.transferFrom}.
    ///
    ///         An operator grant is deliberately equal in power to a per-option ERC-20 allowance
    ///         on the Option token — it differs only in scope: unbounded amount, every option pair
    ///         at once, and no `_spendAllowance` bookkeeping.
    ///
    ///         **⚠ Combination danger.** If the holder has also called {enableAutoMintBurn(true)},
    ///         an approved operator gains the right to *mint new Option positions* against the
    ///         holder's factory collateral allowance, not just move existing balance. Path:
    ///         operator calls `Option.transferFrom(holder, recipient, amount)` for an amount the
    ///         holder doesn't currently hold → auto-mint pulls collateral via `factory.transferFrom`
    ///         → minted Option lands at `recipient`. Functionally this combination is a permit on
    ///         collateral. The same promotion applies to plain ERC-20 spenders on the Option token
    ///         (capped at their allowance) — see {enableAutoMintBurn}. Only grant {approveOperator}
    ///         to entities you trust to also have minting rights over your collateral allowance —
    ///         i.e. audited protocol contracts, never EOAs and never unaudited integrations.
    ///
    ///         {approveOperator} does NOT grant exercise rights ({allowExercise} is separate) and
    ///         does NOT grant redeem rights ({allowRedeem} is separate). Defaults to `false`;
    ///         revoke by passing `approved = false`.
    /// @param operator Address being approved/revoked (must differ from `msg.sender`).
    /// @param approved `true` to grant, `false` to revoke.
    function approveOperator(address operator, bool approved) external nonZeroAddr(operator) {
        if (operator == msg.sender) revert InvalidAddress();
        _approvedOperators[msg.sender][operator] = approved;
        emit OperatorApproval(msg.sender, operator, approved);
    }

    /// @notice Is `operator` an approved operator for `owner_`?
    function approvedOperator(address owner_, address operator) external view returns (bool) {
        return _approvedOperators[owner_][operator];
    }

    /// @notice Authorise `exercisor` to exercise the caller's options on their behalf.
    /// @dev    Consumed by the on-behalf {Option.exercise(address,uint256)} overloads, which burn
    ///         the holder's option tokens, pull consideration from `exercisor`, and deliver the
    ///         collateral to `exercisor`. Distinct from {approveOperator}: that grants transfer
    ///         authority over the holder's option tokens, this grants the right to *consume* them
    ///         (burn). Defaults to `false`; revoke by passing `allowed = false`.
    /// @param exercisor Account being authorised (must differ from `msg.sender`).
    /// @param allowed   `true` to grant, `false` to revoke.
    function allowExercise(address exercisor, bool allowed) external nonZeroAddr(exercisor) {
        if (exercisor == msg.sender) revert InvalidAddress();
        _exerciseAllowed[msg.sender][exercisor] = allowed;
        emit ExerciseApproval(msg.sender, exercisor, allowed);
    }

    /// @notice Is `exercisor` authorised to burn `holder`'s options on their behalf? Set/cleared
    ///         only via {allowExercise} — independent of {approveOperator}, which grants transfer
    ///         (not burn) authority.
    function exerciseAllowed(address holder, address exercisor) external view returns (bool) {
        return _exerciseAllowed[holder][exercisor];
    }

    /// @notice Authorise `redeemer` to trigger post-window pro-rata redeem on the caller's behalf
    ///         via {Receipt.redeemFor}.
    /// @dev    Unlike {allowExercise}, this grant carries no value-extraction risk: the redeemer
    ///         can only burn the holder's receipts; the collateral / consideration payout always
    ///         goes to the holder. Use this to wire a keeper that sweeps dust post-window, or to
    ///         let a vault-management contract unwind its own positions via a worker.
    /// @param redeemer Account being authorised (must differ from `msg.sender`).
    /// @param allowed  `true` to grant, `false` to revoke.
    function allowRedeem(address redeemer, bool allowed) external nonZeroAddr(redeemer) {
        if (redeemer == msg.sender) revert InvalidAddress();
        _redeemAllowed[msg.sender][redeemer] = allowed;
        emit RedeemApproval(msg.sender, redeemer, allowed);
    }

    /// @notice Is `redeemer` authorised to trigger {Receipt.redeemFor} on behalf of `holder`?
    function redeemAllowed(address holder, address redeemer) external view returns (bool) {
        return _redeemAllowed[holder][redeemer];
    }

    /// @notice Opt in to {Option}'s auto-mint-on-send and auto-redeem-on-receive transfer behaviour.
    /// @dev    Quality-of-life flag for active holders. When `true`:
    ///         - On `Option.transfer` / `transferFrom` *from* the holder where balance is short,
    ///           the missing amount is auto-minted by pulling collateral via the factory's
    ///           allowance registry (saves a separate `mint` tx before sending).
    ///         - On `Option.transfer` / `transferFrom` *to* the holder where the holder already
    ///           holds the matching Receipt, the incoming Option is immediately pair-burned and
    ///           collateral is returned (avoids dangling matched positions).
    ///
    ///         **⚠ Combination danger.** This flag promotes *every* transfer right anyone holds
    ///         over your Option tokens into a *minting* right against your factory collateral
    ///         allowance. That covers factory-approved operators (unbounded — see the warning on
    ///         {approveOperator}) AND plain ERC-20 approvals on any Option token (e.g. to a DEX
    ///         router), each up to its approved amount — an allowance of `type(uint256).max` is
    ///         effectively unbounded. Approving an Option token while this flag is on does not just
    ///         let the spender take options you hold; it lets them pull your collateral to mint
    ///         options you don't. The flag is per-account and applies to every option pair this
    ///         factory has created. Treat it like a permit: enable it only while every outstanding
    ///         Option-token approval and operator grant is one you trust to also have minting
    ///         rights over your collateral, and prefer finite approvals to cap the exposure.
    ///
    ///         Defaults to `false`; revoke by passing `enabled = false`.
    /// @param enabled `true` to opt in, `false` to opt out.
    function enableAutoMintBurn(bool enabled) external {
        autoMintBurn[msg.sender] = enabled;
        emit AutoMintBurnUpdated(msg.sender, enabled);
    }
}
