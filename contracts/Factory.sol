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
import { Perm } from "./Permissions.sol";

using SafeERC20 for IERC20;

/**
 * @title  Factory — deployer, transfer hub, permission registry
 * @author Greek.fi
 * @notice The only on-chain contract users need to interact with to *create* options. Once deployed,
 *         every Option + Receipt pair runs off pre-compiled template clones, so creation is
 *         cheap and the factory is never an upgradeable rug vector (the templates are immutable).
 *
 *         The factory also plays two lasting roles post-creation:
 *
 *         1. **Single allowance point.** Users `approve(factory, amount)` on the *token* once
 *            (standard ERC-20 approval), and any Option / Receipt pair created by this factory can
 *            pull from that allowance via {transferFrom}. No need to approve every new option
 *            individually — the token allowance to the factory is the sole gate.
 *
 *         2. **Permission registry.** {setPermissions} / {addPermissions} maintain a per-
 *            (owner, operator) bitmask of {Perm} flags — TRANSFER, MINT, BURN, REDEEM, EXERCISE —
 *            covering every option this factory has created. One row replaces the ERC-1155-style
 *            "setApprovalForAll" plus per-action allowances. The self entry
 *            `permissions[account][account]` holds the account's own automation opt-ins:
 *            MINT = auto-mint on transfer shortfall, BURN = auto-burn on receive.
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
 *         - **Tokens whose transfers can stop working** (pausable, blocklist/blacklist, or any token
 *           that becomes non-transferable after some date) — NOT supported, and there is no rescue.
 *           Every exit path (`burn`, `exercise`, `redeem`) ends in a `safeTransfer`, so if either leg
 *           becomes non-transferable the pair's funds are stuck permanently; {Receipt.sweep} cannot
 *           help, because it requires `totalSupply() == 0` and that requires the very redemptions
 *           that are now reverting. Note the consideration leg is redeemed FIRST, so a frozen
 *           *consideration* token also blocks withdrawal of perfectly good collateral.
 *           Concretely: **a Greek `Option` token is not valid collateral** for another Greek option —
 *           `Option.transfer` reverts permanently once its own `exerciseDeadline` passes.
 *
 *         Choosing the token pair is the creator's responsibility. `createOption` is permissionless
 *         and validates only that the two tokens differ, are non-zero, and expose `decimals() <= 36`;
 *         it cannot and does not check transfer semantics. Frontends MUST surface this at creation.
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
    ///         gate for {transferFrom} — only registered Receipts can pull collateral/consideration.
    ///         Validate an Option by reading its `receipt()` and confirming
    ///         `factory.receipts(rec) && Receipt(rec).option() == opt`.
    mapping(address => bool) public receipts;

    /// @notice Canonical Option address for a given set of economic params, keyed by {optionKey}.
    ///         `address(0)` means no option with those params exists yet. {createOption} is
    ///         get-or-create: a second call with economically-identical params returns the existing
    ///         Option instead of deploying a duplicate, so identical markets stay canonical/deduped
    ///         and existence is queryable on-chain.
    mapping(bytes32 => address) public optionFor;

    /// @notice Permission table: `permissions[owner][operator] -> bitmask` of {Perm} flags.
    ///         One row per (owner, operator) pair covering every option this factory created:
    ///         TRANSFER (1), MINT (2), BURN (4), REDEEM (8), EXERCISE (16). The self entry
    ///         `permissions[account][account]` holds the account's own automation opt-ins
    ///         (MINT = auto-mint on shortfall, BURN = auto-burn on receive). See {Perm} for
    ///         the full semantics and risk notes per bit.
    mapping(address => mapping(address => uint256)) public permissions;

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
    /// @notice Emitted whenever `owner`'s permission mask for `operator` changes ({setPermissions}
    ///         / {addPermissions}). `mask` is the full resulting mask, not a delta.
    event PermissionsUpdated(address indexed owner, address indexed operator, uint256 mask);

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
        bytes memory args = _receiptArgs(p, option_, collDec, consDec);
        address receipt_ = ClonesWithImmutableArgs.clone(RECEIPT_CLONE, args);

        Option(option_).init(receipt_);
        receipts[receipt_] = true;
        optionFor[key] = option_;
        emit OptionCreated(
            p.collateral, p.consideration, p.expirationDate, p.strike, p.isPut, p.isEuro, p.windowSeconds, option_, receipt_
        );
    }

    /// @dev Builds the Receipt's packed immutable args.
    ///      Immutable-args layout (112 bytes packed, MUST match Receipt's _getArg* offsets):
    ///      strike[32] coll[20] cons[20] option[20] expirationDate[8] exerciseDeadline[8]
    ///      isPut[1] isEuro[1] collDec[1] consDec[1]. p.strike is uint256 → encodePacked emits 32B.
    function _receiptArgs(CreateParams memory p, address option_, uint8 collDec, uint8 consDec)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(
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
    /// @dev    Authorisation and accounting ride entirely on the underlying ERC-20 allowance:
    ///         `from` grants `token.approve(factory, amount)` once and every Receipt clone this
    ///         factory created can pull against it (gated here by the `receipts[]` registry).
    ///         `safeTransferFrom` decrements that allowance normally (or leaves it untouched at
    ///         `type(uint256).max`). A balance-delta check rejects fee-on-transfer / short-delivery
    ///         tokens, which would otherwise corrupt the 1:1 collateral accounting.
    /// @param from   Token owner.
    /// @param to     Recipient (typically the calling Receipt contract).
    /// @param amount Token amount to transfer.
    /// @param token  Token to move.
    /// @return success Always `true` on success; reverts otherwise.
    function transferFrom(address from, address to, uint256 amount, address token) external nonReentrant returns (bool) {
        if (!receipts[msg.sender]) revert InvalidAddress();
        uint256 balanceBefore = IERC20(token).balanceOf(to);
        IERC20(token).safeTransferFrom(from, to, amount);
        if (IERC20(token).balanceOf(to) - balanceBefore != amount) revert FeeOnTransferNotSupported();
        return true;
    }

    // ============ PERMISSIONS ============

    /// @notice Set `operator`'s permission mask over the caller's positions, overwriting any
    ///         previous mask. `0` revokes everything. Bits: `Perm.TRANSFER` (1), `Perm.MINT` (2),
    ///         `Perm.BURN` (4), `Perm.REDEEM` (8), `Perm.EXERCISE` (16) — see {Perm} for what each
    ///         bit authorises and its risk profile.
    /// @dev    **Intended for audited swap / keeper / vault contracts.** Each bit is an independent
    ///         grant; nothing is implied by another bit. In particular:
    ///         - `MINT` lets the operator pull the caller's factory collateral allowance to mint
    ///           new positions — functionally a permit on collateral. Never grant to EOAs or
    ///           unaudited integrations.
    ///         - `EXERCISE` lets the operator burn the caller's options, pay the consideration and
    ///           keep the collateral — a withdrawal right over the caller's ITM value.
    ///         - `TRANSFER` is full custody of the caller's long positions: the operator can move
    ///           them to itself and exercise them as their own holder, taking the ITM value without
    ///           ever needing `EXERCISE`. Alongside `MINT` it also reaches auto-mint, so it is not
    ///           limited to balance the caller actually holds.
    ///         - `BURN` / `REDEEM` return their proceeds to the caller, but the operator picks the
    ///           moment — and for `REDEEM` the moment determines which leg the caller is settled
    ///           into, and can strand them in a naked long. Neither is risk-free.
    ///
    ///         `operator == msg.sender` is the **self entry**: `MINT` opts into auto-mint on
    ///         transfer shortfall, `BURN` opts into auto-burn on receive (see {Perm}); the other
    ///         bits are meaningless on self (self action is always allowed directly).
    /// @param operator Address being granted (or, for the caller's own address, the automation opt-in).
    /// @param mask     Full replacement mask; must not contain bits outside `Perm.ALL`.
    function setPermissions(address operator, uint256 mask) external nonZeroAddr(operator) {
        if (mask & ~Perm.ALL != 0) revert InvalidValue();
        permissions[msg.sender][operator] = mask;
        emit PermissionsUpdated(msg.sender, operator, mask);
    }

    /// @notice OR `mask` into `operator`'s existing permission mask (adds bits, never removes).
    ///         Use {setPermissions} to remove bits or revoke outright.
    /// @param operator Address being granted.
    /// @param mask     Bits to add; must not contain bits outside `Perm.ALL`.
    function addPermissions(address operator, uint256 mask) external nonZeroAddr(operator) {
        if (mask & ~Perm.ALL != 0) revert InvalidValue();
        uint256 updated = permissions[msg.sender][operator] | mask;
        permissions[msg.sender][operator] = updated;
        emit PermissionsUpdated(msg.sender, operator, updated);
    }
}
