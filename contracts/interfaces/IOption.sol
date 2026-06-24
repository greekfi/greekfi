// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @notice Minimal ERC20 metadata bundle returned by {IOption.balancesOf} and {IOption.details}.
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
/// @param strike            18-decimal fixed-point strike price (consideration per collateral).
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
/// @notice ERC20 with option-specific extensions. Exercise is allowed pre-expiry (American only)
///         and during the post-expiry window (`exerciseDeadline = expirationDate + windowSeconds`),
///         after which only short-side redemption is permitted. Pair-burn is valid up to and
///         including `exerciseDeadline` (boundary inclusive).
interface IOption {
    /// @notice Emitted on {IOption.mint}.
    event Mint(address longOption, address holder, uint256 amount);
    /// @notice Emitted on any `exercise*` path. `caller` is the consideration payer and (for the
    ///         dangerous `exerciseFor` overloads) the collateral recipient; `holder`'s options are
    ///         burned.
    event Exercise(address longOption, address caller, address holder, uint256 amount);

    /// @notice A path that requires a live option was called after expiration.
    error ContractExpired();
    /// @notice Zero-amount mutation rejected.
    error ZeroValue();
    /// @notice Exercise / transfer / burn attempted past the exercise-window boundary.
    error ExerciseWindowClosed();
    /// @notice Pre-expiry exercise attempted on a European option, or other window violation.
    error InvalidExercise();
    /// @notice `init` called twice (or on the template itself, which carries the `0xdead` sentinel).
    error AlreadyInitialized();
    /// @notice Caller is not authorised for the requested operation.
    error Unauthorized();

    /// @notice Paired short-side Receipt contract.
    function receipt() external view returns (address);
    /// @notice One-time initialisation (factory-only for clones).
    function init(address receipt_) external;

    /// @notice ERC20 name (rendered `OPT[A|E]-coll-cons-strike-YYYY-MM-DD`).
    function name() external view returns (string memory);
    /// @notice ERC20 symbol (matches `name`).
    function symbol() external view returns (string memory);
    /// @notice ERC20 decimals (matches `collateral.decimals()`).
    function decimals() external view returns (uint8);
    /// @notice Address of the Factory that created this option.
    function factory() external view returns (address);
    /// @notice Underlying collateral token.
    function collateral() external view returns (address);
    /// @notice Consideration / quote token.
    function consideration() external view returns (address);
    /// @notice Unix expiration timestamp.
    function expirationDate() external view returns (uint40);
    /// @notice Unix timestamp at which the post-expiry exercise window closes.
    function exerciseDeadline() external view returns (uint64);
    /// @notice Strike price (18-decimal fixed point; inverted for puts).
    function strike() external view returns (uint256);
    /// @notice `true` if this is a put.
    function isPut() external view returns (bool);
    /// @notice `true` if European-style (exercise only allowed in the post-expiry window).
    function isEuro() external view returns (bool);
    /// @notice ERC20 balance.
    function balanceOf(address account) external view returns (uint256);
    /// @notice All four balances that matter for this option (collateral, consideration, option, receipt).
    function balancesOf(address account) external view returns (Balances memory);
    /// @notice Full option descriptor.
    function details() external view returns (OptionInfo memory);

    /// @notice Mint `amount` options to the caller.
    function mint(uint256 amount) external;
    /// @notice Mint `amount` options on behalf of `account`. Caller must be `account` or have been
    ///         granted `factory.approveOperator(account, msg.sender)`.
    function mint(address account, uint256 amount) external;
    /// @notice ERC20 transfer override — runs auto-mint / auto-burn hooks; reverts past `exerciseDeadline`.
    function transfer(address to, uint256 amount) external returns (bool);
    /// @notice ERC20 transferFrom override — runs auto-mint / auto-burn hooks; reverts past `exerciseDeadline`.
    function transferFrom(address from, address to, uint256 amount) external returns (bool);

    /// @notice Exercise the caller's full Option balance — safe self-exercise.
    function exercise() external;
    /// @notice Exercise `amount` of the caller's Options — safe self-exercise.
    function exercise(uint256 amount) external;
    /// @notice **Dangerous keeper path.** Burn `amount` of `holder`'s Options; caller pays the
    ///         consideration AND receives the collateral. Holder gets nothing on-chain. Caller must
    ///         be `holder` or have been authorised via `factory.allowExercise(holder, true)`.
    /// @return Amount actually exercised (`== amount` on success).
    function exerciseFor(address holder, uint256 amount) external returns (uint256);
    /// @notice Batch variant of {exerciseFor(address,uint256)}. Exercises `amounts[i]` of `holders[i]`
    ///         (arrays must be equal length). Entries that fail the per-holder allowance check or carry
    ///         a zero amount are skipped; an amount exceeding a holder's balance reverts the call.
    function exerciseFor(address[] calldata holders, uint256[] calldata amounts) external;

    /// @notice Pair-burn matched Option + Receipt to recover collateral. Allowed up to and including
    ///         `exerciseDeadline` (boundary inclusive). Caller must hold both sides in equal amount.
    function burn(uint256 amount) external;
}
