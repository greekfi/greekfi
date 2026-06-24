// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { IERC20, ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { Receipt } from "./Receipt.sol";
import { TokenData, Balances, OptionInfo } from "./interfaces/IOption.sol";
import { OptionUtils } from "./OptionUtils.sol";

/// @dev Narrow view of {Factory} used by {Option} for auto-mint/auto-burn lookups
///      and operator (ERC1155-style blanket allowance) checks on transfers.
interface IFactory {
    function approvedOperator(address owner, address operator) external view returns (bool);
    function autoMintBurn(address account) external view returns (bool);
    function exerciseAllowed(address holder, address exercisor) external view returns (bool);
}

/**
 * @title  Option — long-side ERC20
 * @author Greek.fi
 * @notice One half of a Greek option pair. Holding this token grants the *right* (not obligation)
 *         to buy the collateral at the strike price — a standard call — or, for puts, the right
 *         to sell. Its paired {Receipt} contract holds the short side of the same option.
 *
 *         Settlement is purely time-gated, no oracle is consulted at any point. Two flavours
 *         coexist, chosen at creation by `isEuro`:
 *
 *         | Mode      | `isEuro` | Pre-expiry exercise | In-window exercise | Post-window      |
 *         | --------- | -------- | ------------------- | ------------------ | ---------------- |
 *         | American  | `false`  | allowed             | allowed            | short pro-rata   |
 *         | European  | `true`   | reverts             | allowed            | short pro-rata   |
 *
 *         The exercise window is `[expirationDate, exerciseDeadline)` where
 *         `exerciseDeadline = expirationDate + windowSeconds` (default 8 hours, settable per
 *         option). The holder decides off-chain whether ITM is profitable and pays strike to
 *         exercise; the protocol just enforces timing and the 1:1 collateral invariant.
 *         Pair `burn` (matched long+short burn) is available **pre-expiration only**: once the
 *         option enters settlement, the only exits are `exercise` (window) and pro-rata `redeem`
 *         (post-window).
 *
 *         ### Auto-mint / auto-burn
 *
 *         Addresses that have opted in via `factory.enableAutoMintBurn(true)` get two
 *         transfer-time conveniences:
 *
 *         - **Auto-mint** — if the sender tries to transfer more `Option` than they hold,
 *           the contract pulls enough collateral from the sender and mints the deficit.
 *         - **Auto-burn** — if the receiver already holds the matching {Receipt} ("short")
 *           token, incoming `Option` is immediately burned pair-wise, returning collateral.
 *
 *         Both behaviours are opt-in per-account and make it possible to treat `Option` and
 *         its underlying collateral as interchangeable for power users (e.g. vaults).
 *
 *         ### Supported tokens
 *
 *         Standard ERC-20 collateral/consideration only, with exact, balance-preserving transfers.
 *         Fee-on-transfer and rebasing / elastic-supply tokens are NOT supported — they break the
 *         protocol's 1:1 accounting (deposits, exercise, redemption, solvency). See {Factory} and
 *         {Receipt} for the full policy.
 *
 * @dev    Deployed once as a template; the factory produces per-option instances via
 *         EIP-1167 minimal proxy clones. `init()` is used instead of a constructor.
 */
contract Option is ERC20, ReentrancyGuardTransient {
    /// @notice Paired short-side ERC20 (collateral receipt) that holds the collateral and handles
    ///         settlement math. Doubles as the {init} guard — non-zero means initialised.
    Receipt public receipt;

    /// @notice Factory that created this option. Set in the template constructor (= the factory
    ///         that deployed it) and inherited by every clone via the template's runtime bytecode.
    IFactory public immutable FACTORY;

    /// @notice Emitted when new options are minted against fresh collateral.
    /// @param longOption  The Option contract (always `address(this)`).
    /// @param holder      The account credited with the new tokens.
    /// @param amount      Collateral-denominated amount (same decimals as the collateral token).
    event Mint(address longOption, address holder, uint256 amount);

    /// @notice Emitted when an option is exercised.
    /// @param longOption  The Option contract (always `address(this)`).
    /// @param caller      The account that initiated the exercise.
    /// @param holder      The account whose options were burned.
    /// @param amount      Collateral units delivered (consideration paid is `toConsideration(amount, true)`, ceil).
    event Exercise(address longOption, address caller, address holder, uint256 amount);

    /// @notice Emitted when a holder burns expired (post-deadline) long option tokens via {expire}.
    /// @param longOption  The Option contract (always `address(this)`).
    /// @param caller      The account that initiated the expiration (always the holder).
    /// @param holder      The account whose options were burned (== `caller`).
    /// @param amount      Amount of options burned.
    event Expire(address longOption, address caller, address holder, uint256 amount);

    /// @notice Thrown when a call that requires a live option is made after expiration.
    error ContractExpired();
    /// @notice Thrown when `amount == 0`.
    error ZeroValue();
    /// @notice Thrown when batch `exerciseFor` is given `holders`/`amounts` arrays of unequal length.
    error InvalidValue();
    /// @notice Thrown when exercise is attempted after `exerciseDeadline`.
    error ExerciseWindowClosed();
    /// @notice Thrown when pre-expiry exercise is attempted on a European option.
    error InvalidExercise();
    /// @notice Thrown when {init} is called on a clone that has already been initialised, or on
    ///         the template (whose `receipt` is set to a sentinel by the constructor).
    error AlreadyInitialized();
    /// @notice Thrown when {init} is called by anyone other than the factory.
    error Unauthorized();
    /// @notice Thrown when {expire} is called on or before `exerciseDeadline` (the option is still live).
    error NotYetExpired();

    /// @dev Blocks `mint_` once the option has expired — no new options past expiration.
    modifier notExpired() {
        if (block.timestamp >= expirationDate()) revert ContractExpired();
        _;
    }

    /// @dev Blocks transfer paths once the exercise window has closed; the long token remains
    ///      circulating throughout the window so holders can still sell to keepers.
    ///      `block.timestamp == exerciseDeadline` is still IN-window — boundary is inclusive.
    modifier beforeDeadline() {
        if (block.timestamp > receipt.exerciseDeadline()) revert ExerciseWindowClosed();
        _;
    }

    /// @dev Gates exercise paths. European reverts pre-expiry with the specific reason; both
    ///      flavours revert with `ExerciseWindowClosed` past `exerciseDeadline`.
    modifier canExercise() {
        if (isEuro() && block.timestamp < expirationDate()) revert InvalidExercise();
        if (block.timestamp > receipt.exerciseDeadline()) revert ExerciseWindowClosed();
        _;
    }

    /// @dev Rejects zero-amount mutations to keep accounting clean and events meaningful.
    modifier nonZero(uint256 amount) {
        if (amount == 0) revert ZeroValue();
        _;
    }

    /// @notice Template constructor. Never called for user-facing instances; each clone goes
    ///         through {init} instead. Sets `receipt` to a non-zero sentinel so the template
    ///         itself fails the {init} guard.
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {
        FACTORY = IFactory(msg.sender);
        receipt = Receipt(address(0xdead));
    }

    /// @notice Initialises a freshly-cloned Option. Called exactly once by the factory.
    /// @param receipt_ Address of the paired {Receipt} contract — immutable for this option.
    function init(address receipt_) public {
        if (address(receipt) != address(0)) revert AlreadyInitialized();
        if (msg.sender != address(FACTORY)) revert Unauthorized();
        if (receipt_ == address(0)) revert ZeroValue();
        receipt = Receipt(receipt_);
    }

    // ============ VIEWS ============

    /// @notice Address of the {Factory} that created this option. Read from the paired Receipt.
    function factory() public view returns (address) {
        return address(FACTORY);
    }

    /// @notice Underlying collateral token (e.g. WETH for a WETH/USDC call).
    function collateral() public view returns (address) {
        return address(receipt.collateral());
    }

    /// @notice Consideration / quote token (e.g. USDC for a WETH/USDC call).
    function consideration() public view returns (address) {
        return address(receipt.consideration());
    }

    /// @notice Unix timestamp at which the option expires.
    function expirationDate() public view returns (uint40) {
        return receipt.expirationDate();
    }

    /// @notice Unix timestamp at which the post-expiry exercise window closes.
    function exerciseDeadline() public view returns (uint64) {
        return receipt.exerciseDeadline();
    }

    /// @notice Strike price in 18-decimal fixed point, encoded as "consideration per collateral".
    /// @dev For puts, this stores the *inverse* of the human-readable strike (see {name} for display).
    function strike() public view returns (uint256) {
        return receipt.strike();
    }

    /// @notice `true` if this is a put option; `false` for calls.
    function isPut() public view returns (bool) {
        return receipt.isPut();
    }

    /// @notice `true` for European-style options (exercise barred pre-expiry; only the post-expiry
    ///         window is exercisable). `false` for American (any time before `exerciseDeadline`).
    function isEuro() public view returns (bool) {
        return receipt.isEuro();
    }

    /// @notice Option token shares the collateral's decimals so 1 option token ↔ 1 collateral unit.
    function decimals() public view override returns (uint8) {
        return IERC20Metadata(collateral()).decimals();
    }

    /// @notice Human-readable token name in the form `OPT[E/A]-<coll>-<cons>-<strike>-<YYYY-MM-DD>`.
    ///         The `OPTE-` prefix flags European options, `OPTA-` flags American options.
    /// @dev For puts the displayed strike is inverted back (`1e36 / strike`) to the human form.
    function name() public view override returns (string memory) {
        uint256 strike_ = isPut() && strike() > 0 ? (1e36 / strike()) : strike();
        return OptionUtils.name(
            isEuro() ? "OPTE" : "OPTA",
            IERC20Metadata(collateral()).symbol(),
            IERC20Metadata(consideration()).symbol(),
            strike_,
            expirationDate()
        );
    }

    /// @notice Same as {name}. Matching name/symbol keeps wallets and explorers in sync.
    function symbol() public view override returns (string memory) {
        return name();
    }

    // ============ MINT ============

    /// @notice Mint `amount` option tokens to the caller, collateralised 1:1 with the underlying.
    function mint(uint256 amount) public nonReentrant {
        mint_(msg.sender, amount);
    }

    /// @notice Mint `amount` option tokens to `account`. Collateral is pulled from `account` via
    ///         the factory's centralised allowance, so the caller must be `account` itself or a
    ///         factory-approved operator for `account` — otherwise any address holding a non-zero
    ///         factory allowance could be force-minted into unwanted positions.
    /// @param account Recipient of both `Option` and `Receipt` tokens. Pays the collateral.
    /// @param amount  Collateral-denominated mint amount.
    function mint(address account, uint256 amount) public nonReentrant {
        if (msg.sender != account && !FACTORY.approvedOperator(account, msg.sender)) revert Unauthorized();
        mint_(account, amount);
    }

    /// @dev Internal mint path shared by `mint` and auto-mint-on-transfer.
    function mint_(address account, uint256 amount) internal notExpired nonZero(amount) {
        receipt.mint(account, amount);
        _mint(account, amount);
        emit Mint(address(this), account, amount);
    }

    // ============ TRANSFER (auto-mint + auto-burn) ============

    /// @dev Auto-mint (sender) + auto-burn (receiver) hook around the underlying ERC20 transfer.
    ///      Both legs are gated on each party's `autoMintBurn` opt-in held on the factory.
    ///      Not an override of OZ's `_transfer` (which is non-virtual) — callable from the public
    ///      transfer paths only, so mint/burn don't trigger it.
    ///
    ///      **⚠ Operator-mint surface.** The auto-mint branch keys on `from`'s opt-in flag, not on
    ///      whether `msg.sender == from`. When `from` has both granted `factory.approveOperator`
    ///      to some operator AND opted into `factory.enableAutoMintBurn`, the operator can call
    ///      `Option.transferFrom(from, recipient, amount)` for an amount `from` doesn't currently
    ///      hold — auto-mint then pulls `from`'s factory collateral allowance to manufacture the
    ///      missing balance. Combined, the two grants are equivalent to a permit on `from`'s
    ///      collateral. The Factory NatSpec on {approveOperator} and {enableAutoMintBurn} warns
    ///      about this loudly; the surface lives here.
    function _settledTransfer(address from, address to, uint256 value) internal {
        uint256 balance = balanceOf(from);
        if (balance < value) {
            if (!FACTORY.autoMintBurn(from)) revert ERC20InsufficientBalance(from, balance, value);
            mint_(from, value - balance);
        }

        _transfer(from, to, value);

        if (FACTORY.autoMintBurn(to)) {
            uint256 receiptBal = receipt.balanceOf(to);
            if (receiptBal > 0) {
                _burn(to, Math.min(receiptBal, value));
                receipt.burn(to, Math.min(receiptBal, value));
            }
        }
    }

    /// @inheritdoc ERC20
    /// @dev Overridden to run the auto-mint / auto-burn hook. Reverts post-expiry —
    ///      the long token stops circulating once expiration passes.
    function transfer(address to, uint256 amount) public override beforeDeadline nonReentrant returns (bool) {
        _settledTransfer(msg.sender, to, amount);
        return true;
    }

    /// @inheritdoc ERC20
    /// @dev Skips `_spendAllowance` when `msg.sender` is a factory-approved operator for `from`
    ///      (ERC-1155 style blanket approval across every option in the protocol).
    function transferFrom(address from, address to, uint256 amount) public override beforeDeadline nonReentrant returns (bool) {
        if (msg.sender != from && !FACTORY.approvedOperator(from, msg.sender)) {
            _spendAllowance(from, msg.sender, amount);
        }
        _settledTransfer(from, to, amount);
        return true;
    }

    // ============ EXERCISE ============
    /// @notice Exercise all of the caller's own options: pay consideration, receive collateral.
    /// @dev    Self-exercise — the safe path. Delegates to {exerciseFor} with `holder = msg.sender`,
    ///         so msg.sender pays AND msg.sender receives (no dangerous asymmetry).
    function exercise() public {
        exerciseFor(msg.sender, balanceOf(msg.sender));
    }

    /// @notice Exercise `amount` of the caller's own options: pay consideration, receive collateral.
    /// @dev    Self-exercise — the safe path. Delegates to {exerciseFor} with `holder = msg.sender`,
    ///         so msg.sender pays AND msg.sender receives (no dangerous asymmetry).
    /// @param amount Collateral units to receive. Consideration paid = `ceil(amount * strike)`.
    function exercise(uint256 amount) public {
        exerciseFor(msg.sender, amount);
    }

    /// @notice **Dangerous keeper path** — burn `amount` of `holder`'s options; `msg.sender` pays
    ///         the consideration and receives the collateral. The holder gets nothing on-chain.
    ///         Use this only when:
    ///         (a) `msg.sender` is a contract that will deliver the holder's economic surplus
    ///             off-band (e.g. a flash-loan router that sells the collateral, repays the
    ///             flash loan with the consideration cost, and pays the holder the spread), or
    ///         (b) the holder explicitly intends to gift the exercise value to `msg.sender`.
    ///
    ///         Authorisation: `msg.sender` must be `holder` themselves or have been authorised
    ///         via `factory.allowExercise(msg.sender, true)`. **Authorising a non-trusted
    ///         exercisor is equivalent to giving them a withdrawal right over your ITM value.**
    ///         `factory.approveOperator` does NOT grant exercise rights — it gates ERC20
    ///         transfer of option tokens only.
    ///
    ///         Allowed any time exercise itself is allowed (pre-expiry for American, plus the
    ///         post-expiry window for both flavours).
    ///
    ///         Example (a) — flash-loan keeper that pays the holder the ITM spread:
    ///
    ///         ```solidity
    ///         // Keeper contract (audited, allowlisted off-chain). Holder authorises once:
    ///         //   factory.allowExercise(address(keeper), true);
    ///         contract FlashExerciseKeeper is IERC3156FlashBorrower {
    ///             function settle(Option opt, address holder, uint256 amount, uint256 minSurplus)
    ///                 external
    ///             {
    ///                 // 1. Flash-borrow `ceil(amount * strike)` of consideration from any provider
    ///                 //    (Aave / Maker / Morpho). The callback is `onFlashLoan` below.
    ///                 bytes memory cb = abi.encode(opt, holder, amount, minSurplus);
    ///                 IReceipt r = IReceipt(opt.receipt());
    ///                 IERC20 cons = r.consideration();
    ///                 uint256 strikeCost = r.toConsideration(amount, true);
    ///                 IERC3156FlashLender(lender).flashLoan(this, address(cons), strikeCost, cb);
    ///             }
    ///
    ///             function onFlashLoan(address, address, uint256 loaned, uint256 fee, bytes calldata data)
    ///                 external returns (bytes32)
    ///             {
    ///                 (Option opt, address holder, uint256 amount, uint256 minSurplus) =
    ///                     abi.decode(data, (Option, address, uint256, uint256));
    ///
    ///                 // 2. Approve the factory to pull the consideration we just borrowed.
    ///                 IReceipt r = IReceipt(opt.receipt());
    ///                 IERC20(r.consideration()).approve(factory, loaned);
    ///                 factory.approve(address(r.consideration()), loaned);
    ///
    ///                 // 3. Exercise on behalf of the holder. Collateral lands here.
    ///                 opt.exerciseFor(holder, amount);
    ///
    ///                 // 4. Swap collateral → consideration on a DEX (router omitted for brevity).
    ///                 uint256 proceeds = dex.swapExactIn(address(r.collateral()), address(r.consideration()), amount);
    ///
    ///                 // 5. Repay the flash loan + fee.
    ///                 IERC20(r.consideration()).approve(lender, loaned + fee);
    ///
    ///                 // 6. Pay the holder the surplus on-chain. Enforce a floor so the holder is
    ///                 //    never settled at a worse price than they asked for.
    ///                 uint256 surplus = proceeds - loaned - fee;
    ///                 if (surplus < minSurplus) revert SlippageExceeded();
    ///                 IERC20(r.consideration()).transfer(holder, surplus);
    ///
    ///                 return keccak256("ERC3156FlashBorrower.onFlashLoan");
    ///             }
    ///         }
    ///         ```
    ///
    ///         The holder bears no smart-contract risk beyond trusting `FlashExerciseKeeper` not
    ///         to revert on step 6 — which is why `allowExercise` should only ever be granted to
    ///         a deployed, audited keeper address, never an EOA.
    /// @param holder Option holder whose tokens will be burned.
    /// @param amount Collateral units to exercise.
    /// @return The amount of collateral units actually exercised (== `amount` on success).
    function exerciseFor(address holder, uint256 amount) public canExercise nonReentrant nonZero(amount) returns (uint256) {
        if (msg.sender != holder && !FACTORY.exerciseAllowed(holder, msg.sender)) {
            revert Unauthorized();
        }
        _burn(holder, amount);
        receipt.exercise(msg.sender, amount);
        emit Exercise(address(this), msg.sender, holder, amount);
        return amount;
    }

    /// @notice Batch variant of {exerciseFor(address,uint256)}. Same dangerous semantics — the
    ///         caller pays consideration and receives collateral for every holder. Exercises
    ///         `amounts[i]` of `holders[i]`. Entries that fail the per-holder allowance check or
    ///         carry a zero amount are skipped rather than reverting, so a stale or unauthorised
    ///         address in the holder list does not abort the sweep. An `amounts[i]` greater than the
    ///         holder's balance is also skipped (rather than reverting the whole call), so a holder
    ///         who has since reduced their balance cannot grief the sweep for everyone else.
    /// @param holders Option holders whose options will be exercised.
    /// @param amounts Per-holder collateral amounts to exercise; must align 1:1 with `holders`.
    function exerciseFor(address[] calldata holders, uint256[] calldata amounts) external canExercise nonReentrant {
        if (holders.length != amounts.length) revert InvalidValue();
        for (uint256 i = 0; i < holders.length; i++) {
            address h = holders[i];
            uint256 a = amounts[i];
            if (a == 0 || balanceOf(h) < a) continue;
            if (msg.sender != h && !FACTORY.exerciseAllowed(h, msg.sender)) continue;
            _burn(h, a);
            receipt.exercise(msg.sender, a);
            emit Exercise(address(this), msg.sender, h, a);
        }
    }

    // ============ PAIR burn (open until exerciseDeadline) ============

    /// @notice Burn matched `Option` + `Receipt` pairs to recover the underlying collateral.
    /// @dev    Available up to and including `exerciseDeadline` (boundary inclusive — same as
    ///         transfer/exercise). Pair-burn nets both sides 1:1 so it does not require the
    ///         exercise window to be closed. Once `block.timestamp > exerciseDeadline`, short-side
    ///         exits must route through `Receipt._redeem`. Caller must hold both sides in equal amount.
    /// @param amount Collateral-denominated amount to burn from each side.
    function burn(uint256 amount) public nonReentrant nonZero(amount) beforeDeadline {
        _burn(msg.sender, amount);
        receipt.burn(msg.sender, amount);
    }

    /// @notice Burn your own expired long option tokens to clean up dust.
    /// @dev    Only callable strictly after `exerciseDeadline`. Past the deadline an unexercised
    ///         long token is inert — it can no longer be exercised ({canExercise}), transferred or
    ///         pair-burned ({beforeDeadline}) — so it would otherwise sit in the holder's wallet
    ///         forever. This burns the long side only; it touches neither collateral nor the paired
    ///         `Receipt`, so it has no effect on the redemption pool or the solvency invariant
    ///         (short-side collateral is recovered separately via `Receipt.redeem`). Reverts with
    ///         `NotYetExpired` on or before the deadline — use {burn} or {exercise} while live.
    /// @param amount Amount of long option tokens to burn.
    function expire(uint256 amount) public nonReentrant nonZero(amount) {
        if (block.timestamp <= exerciseDeadline()) revert NotYetExpired();
        _burn(msg.sender, amount);
        emit Expire(address(this), msg.sender, msg.sender, amount);
    }

    // ============ QUERY ============

    /// @notice All four balances that matter for this option in one call.
    /// @param account Address to query.
    /// @return A {Balances} struct: collateral token, consideration token, long option, short receipt.
    function balancesOf(address account) public view returns (Balances memory) {
        return OptionUtils.balancesOf(address(receipt), account);
    }

    /// @notice Full option descriptor — addresses, token metadata, strike, expiry, deadline.
    ///         Convenient one-shot read for frontends.
    function details() public view returns (OptionInfo memory) {
        return OptionUtils.details(address(receipt));
    }
}
