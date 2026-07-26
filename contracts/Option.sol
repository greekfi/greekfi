// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { IERC20, ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { Receipt } from "./Receipt.sol";
import { TokenData, Balances, OptionInfo } from "./interfaces/IOption.sol";
import { OptionUtils } from "./OptionUtils.sol";
import { Perm } from "./Permissions.sol";

/// @dev Narrow view of {Factory} used by {Option} for permission-mask lookups on transfer,
///      mint, burn and exercise paths. The mask is a bitfield of {Perm} flags; the self entry
///      `permissions(account, account)` carries the account's auto-mint / auto-burn opt-ins.
interface IFactory {
    function permissions(address owner, address operator) external view returns (uint256);
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
 *         | Mode      | `isEuro` | Pre-expiry exercise | In-window exercise | Post-window short exit |
 *         | --------- | -------- | ------------------- | ------------------ | ---------------------- |
 *         | American  | `false`  | allowed             | allowed            | `redeem` — cons-first FCFS |
 *         | European  | `true`   | reverts             | allowed            | `redeem` — cons-first FCFS |
 *
 *         Short-side settlement is **NOT pro-rata**. `Receipt.redeem` pays consideration first, on a
 *         first-come-first-served basis, and only then collateral 1:1 — so redemption *order*
 *         decides which asset a writer ends up with. See {Receipt.redeem} for the full semantics
 *         and the writer strategy that follows from it.
 *
 *         The exercise window is `[expirationDate, exerciseDeadline]` (deadline inclusive) where
 *         `exerciseDeadline = expirationDate + windowSeconds`. `windowSeconds` is set per option
 *         at creation and taken literally — the contract applies no default
 *         ({Factory.DEFAULT_EXERCISE_WINDOW} = 8 hours is informational, for frontends). The
 *         holder decides off-chain whether ITM is profitable and pays strike to exercise; the
 *         protocol just enforces timing and the 1:1 collateral invariant.
 *         Pair `burn` (matched long+short burn) is available up to and including
 *         `exerciseDeadline`; once the window closes, the remaining exits are `redeem`
 *         (short side, cons-first FCFS) and `expire` (long-side dust burn).
 *
 *         ### Auto-mint / auto-burn
 *
 *         Addresses that have opted in via their self entry in the factory permission table
 *         (`factory.setPermissions(self, Perm.MINT | Perm.BURN)`) get two transfer-time
 *         conveniences:
 *
 *         - **Auto-mint** — if the sender tries to transfer more `Option` than they hold,
 *           the contract pulls enough collateral from the sender and mints the deficit.
 *         - **Auto-burn** — if the receiver already holds the matching {Receipt} ("short")
 *           token, incoming `Option` is immediately burned pair-wise, returning collateral.
 *
 *         Both behaviours are opt-in per-account and make it possible to treat `Option` and
 *         its underlying collateral as interchangeable for power users (e.g. vaults).
 *
 *         Neither is risk-free, and the risks differ. `MINT` on self removes the ERC-20 safety net:
 *         a transfer larger than your balance no longer reverts, it silently pulls your collateral
 *         and opens a new short. `BURN` is scoped per counterparty rather than blanket — the
 *         auto-burn leg reads `permissions(to, msg.sender)`, so your own transfers use your self
 *         entry, and an inbound transfer only nets if you granted `BURN` to that sender
 *         (see {_settledTransfer}).
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

    /// @notice Emitted **only** by an explicit {expire} call — the sole site that emits this event.
    ///         An option passing `exerciseDeadline` emits nothing on its own; expiry is a timestamp
    ///         comparison, not a transaction. Indexers must not treat this as "the option expired",
    ///         only as "someone burned already-worthless long tokens".
    /// @param longOption  The Option contract (always `address(this)`).
    /// @param caller      The account that called {expire} — the holder themselves, or an operator
    ///                    holding `Perm.BURN` in the holder's factory permission mask.
    /// @param holder      The account whose options were burned.
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

    /// @dev Authorisation predicate for acting on `owner_`'s position: true when `operator` is
    ///      neither `owner_` themselves nor holds `perm` in `owner_`'s factory permission mask.
    ///      Argument order mirrors the registry it wraps (`permissions[owner][operator]`).
    ///
    ///      **Authorisation only — do NOT use this for the auto-mint / auto-burn legs of
    ///      {_settledTransfer}.** Those read the *self* entry as an opt-in, and the
    ///      `operator != owner_` bypass here would silently turn "did this account opt in?" into
    ///      "is this account acting on itself?", enabling the automation for every account rather
    ///      than the ones that asked for it. Those two sites spell the lookup out deliberately.
    function notAuthorized(address owner_, address operator, uint256 perm) internal view returns (bool) {
        return operator != owner_ && FACTORY.permissions(owner_, operator) & perm == 0;
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
    ///         the factory's centralised allowance, so the caller must be `account` itself or hold
    ///         `Perm.MINT` in `account`'s factory permission mask — otherwise any address holding
    ///         a non-zero factory allowance could be force-minted into unwanted positions.
    /// @dev    `Perm.MINT` is an explicit, single-purpose grant: it lets the operator pull the
    ///         holder's factory collateral allowance into new positions (functionally a permit on
    ///         collateral). It is NOT implied by `Perm.TRANSFER` or any other bit.
    /// @param account Recipient of both `Option` and `Receipt` tokens. Pays the collateral.
    /// @param amount  Collateral-denominated mint amount.
    function mint(address account, uint256 amount) public nonReentrant {
        if (notAuthorized(account, msg.sender, Perm.MINT)) revert Unauthorized();
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
    ///      Both legs are gated on {Perm} bits held on the factory: MINT for the sender's
    ///      auto-mint leg, the receiver's self BURN bit for the auto-burn leg.
    ///      Not an override of OZ's `_transfer` (which is non-virtual) — callable from the public
    ///      transfer paths only, so mint/burn don't trigger it.
    ///
    ///      **⚠ Operator-mint surface.** The auto-mint branch requires `Perm.MINT` in
    ///      `permissions(from, msg.sender)` — the self entry when `from` sends their own tokens
    ///      (the holder's auto-mint opt-in), the operator's explicit MINT grant otherwise.
    ///      A bare ERC-20 spender (plain `approve` on this option token) can never reach auto-mint:
    ///      a dangling option-token allowance spends existing balance only, it is not a claim on
    ///      `from`'s collateral. An operator holding `Perm.MINT` can transfer amounts `from`
    ///      doesn't hold — auto-mint pulls `from`'s collateral allowance to manufacture the
    ///      missing balance, which is why {Perm} documents MINT as a permit on collateral.
    ///
    ///      The auto-burn leg keys on `Perm.BURN` in `permissions(to, msg.sender)` — the **receiver's**
    ///      grant to whoever initiated the transfer. Consent is therefore per-counterparty, and it
    ///      always belongs to the account whose position is unwound:
    ///
    ///      - `to` moving their own tokens (`msg.sender == to`) resolves to the self entry
    ///        `permissions(to, to)` — the account's own auto-burn opt-in, unchanged.
    ///      - a third party sending to `to` must hold `Perm.BURN` in `to`'s row, i.e. `to` explicitly
    ///        authorised that sender to net incoming options against their short.
    ///
    ///      Deliberately NOT keyed on the self entry alone. That would let any bystander force an
    ///      opted-in account to unwind its matched position at a moment of the bystander's choosing,
    ///      contradicting the composability guarantee {Receipt.redeemFor} makes. The price of the
    ///      stricter rule is that auto-burn no longer fires for arbitrary senders: an account that
    ///      wants incoming options netted must name the venues it accepts them from.
    function _settledTransfer(address from, address to, uint256 value) internal {
        uint256 balance = balanceOf(from);
        if (balance < value) {
            // Spelled out, NOT {notAuthorized}: there is deliberately no `from == msg.sender`
            // bypass. When the sender moves their own tokens this reads the self entry, which is
            // the holder's auto-mint OPT-IN — bypassing it would arm auto-mint for everyone.
            if (FACTORY.permissions(from, msg.sender) & Perm.MINT == 0) {
                revert ERC20InsufficientBalance(from, balance, value);
            }
            mint_(from, value - balance);
        }

        _transfer(from, to, value);

        // Spelled out, NOT {notAuthorized}: there must be no `msg.sender == to` bypass here. When
        // the receiver moves their own tokens this reads their self entry, which is the auto-burn
        // OPT-IN; the helper would treat acting-on-yourself as consent and net every self-transfer
        // whether or not the account asked for it.
        if (FACTORY.permissions(to, msg.sender) & Perm.BURN != 0) {
            uint256 receiptBal = receipt.balanceOf(to);
            if (receiptBal > 0) {
                _burn(to, Math.min(receiptBal, value));
                receipt.burn(to, Math.min(receiptBal, value));
            }
        }
    }

    /// @inheritdoc ERC20
    /// @dev Overridden to run the auto-mint / auto-burn hook. Reverts once the exercise window
    ///      closes (`block.timestamp > exerciseDeadline`) — the long token keeps circulating
    ///      through the window so holders can still sell to keepers.
    function transfer(address to, uint256 amount) public override beforeDeadline nonReentrant returns (bool) {
        _settledTransfer(msg.sender, to, amount);
        return true;
    }

    /// @inheritdoc ERC20
    /// @dev Skips `_spendAllowance` when `msg.sender` holds `Perm.TRANSFER` in `from`'s factory
    ///      permission mask (blanket approval across every option in the protocol).
    function transferFrom(address from, address to, uint256 amount) public override beforeDeadline nonReentrant returns (bool) {
        if (notAuthorized(from, msg.sender, Perm.TRANSFER)) _spendAllowance(from, msg.sender, amount);
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
    ///         Authorisation: `msg.sender` must be `holder` themselves or hold `Perm.EXERCISE`
    ///         in the holder's factory permission mask (`factory.setPermissions(keeper,
    ///         Perm.EXERCISE)`). **Granting EXERCISE to a non-trusted operator is equivalent to
    ///         giving them a withdrawal right over your ITM value.** `Perm.TRANSFER` does not gate
    ///         *this function*, but it is not a weaker grant: an operator holding TRANSFER can move
    ///         your longs to itself and exercise them as their own holder, reaching the same ITM
    ///         value by a different route. Both bits are custody-grade — see {Perm}.
    ///
    ///         Allowed any time exercise itself is allowed (pre-expiry for American, plus the
    ///         post-expiry window for both flavours).
    ///
    ///         Example (a) — flash-loan keeper that pays the holder the ITM spread:
    ///
    ///         ```solidity
    ///         // Keeper contract (audited, allowlisted off-chain). Holder authorises once:
    ///         //   factory.setPermissions(address(keeper), Perm.EXERCISE);
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
    ///         to revert on step 6 — which is why `Perm.EXERCISE` should only ever be granted to
    ///         a deployed, audited keeper address, never an EOA.
    /// @param holder Option holder whose tokens will be burned.
    /// @param amount Collateral units to exercise.
    /// @return The amount of collateral units actually exercised (== `amount` on success).
    function exerciseFor(address holder, uint256 amount) public canExercise nonReentrant nonZero(amount) returns (uint256) {
        if (notAuthorized(holder, msg.sender, Perm.EXERCISE)) revert Unauthorized();
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
            if (notAuthorized(h, msg.sender, Perm.EXERCISE)) continue;
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
    function burn(uint256 amount) public {
        burn(msg.sender, amount);
    }

    /// @notice Burn `amount` matched `Option` + `Receipt` pairs held by `account`, returning the
    ///         underlying collateral to `account`.
    /// @dev    Same timing rules as {burn(uint256)}. The caller must be `account` itself or hold
    ///         `Perm.BURN` in `account`'s factory permission mask. Trigger-only grant: the
    ///         recovered collateral always goes to `account` (via `Receipt.burn`), never to the
    ///         caller, so a BURN operator can unwind a holder's matched position but not extract
    ///         value from it.
    /// @param account Holder of the matched Option + Receipt pair.
    /// @param amount  Collateral-denominated amount to burn from each side.
    function burn(address account, uint256 amount) public nonReentrant nonZero(amount) beforeDeadline {
        if (notAuthorized(account, msg.sender, Perm.BURN)) revert Unauthorized();
        _burn(account, amount);
        receipt.burn(account, amount);
    }

    /// @notice Burn expired long option tokens to clean up dust.
    /// @dev    Only callable strictly after `exerciseDeadline`. Past the deadline an unexercised
    ///         long token is inert — it can no longer be exercised ({canExercise}), transferred or
    ///         pair-burned ({beforeDeadline}) — so it would otherwise sit in the holder's wallet
    ///         forever. This burns the long side only; it touches neither collateral nor the paired
    ///         `Receipt`, so it has no effect on the redemption pool or the solvency invariant
    ///         (short-side collateral is recovered separately via `Receipt.redeem`). Reverts with
    ///         `NotYetExpired` on or before the deadline — use {burn} or {exercise} while live.
    ///         Caller must be `holder` or hold `Perm.BURN` in the holder's factory permission mask
    ///         (reverts `Unauthorized` otherwise) — BURN, not EXERCISE, because this is a pure
    ///         cleanup burn: the tokens are already worthless, so a keeper gains nothing here.
    /// @param holder Address of the long option holder.
    /// @param amount Amount of long option tokens to burn.
    function expire(address holder, uint256 amount) public nonReentrant nonZero(amount) {
        if (notAuthorized(holder, msg.sender, Perm.BURN)) revert Unauthorized();
        if (block.timestamp <= exerciseDeadline()) revert NotYetExpired();
        _burn(holder, amount);
        emit Expire(address(this), msg.sender, holder, amount);
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
