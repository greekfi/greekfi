// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

/// @notice Parameters for {IFactory.createOption}.
/// @param collateral     Underlying collateral token (must differ from consideration).
/// @param consideration  Quote / consideration token.
/// @param expirationDate Unix expiration timestamp (must be in the future).
/// @param strike         Strike price, 18-decimal fixed point (consideration per collateral; for puts
///                       this should be the inverted `1e36 / humanStrike`).
/// @param isPut          `true` for puts.
/// @param isEuro         `true` for European-style options (exercise barred pre-expiry; only the
///                       post-expiry window is exercisable). `false` for American.
/// @param windowSeconds  Length in seconds of the post-expiry exercise window. Taken LITERALLY —
///                       no contract-side default substitution. American options may pass `0` for
///                       "no post-expiry extension" (window collapses to `expirationDate`).
///                       European options require `> 0` (else reverts with `InvalidValue`).
///                       After `expirationDate + windowSeconds`, exercise reverts and short-side
///                       redemption opens.
struct CreateParams {
    address collateral;
    address consideration;
    uint40 expirationDate;
    uint256 strike;
    bool isPut;
    bool isEuro;
    uint40 windowSeconds;
}

/// @title  IFactory — option pair deployer + allowance hub
/// @author Greek.fi
/// @notice Deploys Option + Receipt pairs via EIP-1167 clones, serves as the single ERC20 approval
///         point for every option pair it creates, and holds the per-(owner, operator)
///         permission registry ({Perm} bitmasks: TRANSFER / MINT / BURN / REDEEM / EXERCISE).
interface IFactory {
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
    /// @notice Emitted on {approve} (factory-level allowance set).
    event Approval(address indexed token, address indexed owner, uint256 amount);

    /// @notice Zero address supplied where a contract is required.
    error InvalidAddress();
    /// @notice Collateral and consideration were the same address.
    error InvalidTokens();
    /// @notice A value param (strike, expiration, window, decimals, permission mask) is invalid.
    error InvalidValue();
    /// @notice Token transferFrom delivered less than `amount` — fee-on-transfer / rebasing tokens are not supported.
    error FeeOnTransferNotSupported();

    /// @notice Receipt template clone.
    function RECEIPT_CLONE() external view returns (address);
    /// @notice Option template clone.
    function OPTION_CLONE() external view returns (address);
    /// @notice Informational suggested-default window length (frontend convenience). The contract
    ///         does NOT consult this — `CreateParams.windowSeconds` is always taken literally.
    function DEFAULT_EXERCISE_WINDOW() external view returns (uint40);
    /// @notice `true` if `rec` is a Receipt produced by this factory. Validate an Option `opt` by
    ///         checking `receipts(opt.receipt()) && IReceipt(opt.receipt()).option() == opt`.
    function receipts(address rec) external view returns (bool);
    /// @notice Canonical Option address for the params identified by `key` (see {optionKey}), or
    ///         `address(0)` if no such option exists. {createOption} is get-or-create against this
    ///         registry, so economically-identical markets are deduped and existence is queryable.
    function optionFor(bytes32 key) external view returns (address);
    /// @notice Deterministic registry key for a set of economic params. Folds in all seven
    ///         {CreateParams} fields; differing in any field yields a different key.
    function optionKey(CreateParams memory p) external pure returns (bytes32);
    /// @notice Factory-level allowance: how much of `token` the factory may pull from `owner`.
    function allowance(address token, address owner) external view returns (uint256);
    /// @notice `operator`'s permission bitmask over `owner`'s positions — see {Perm}: TRANSFER (1),
    ///         MINT (2), BURN (4), REDEEM (8), EXERCISE (16). The self entry
    ///         `permissions(account, account)` carries the account's automation opt-ins
    ///         (MINT = auto-mint on shortfall, BURN = auto-burn on receive).
    function permissions(address owner, address operator) external view returns (uint256);
    /// @notice `true` if `operator` holds every bit of `mask` in `owner`'s grant.
    function hasPermissions(address owner, address operator, uint256 mask) external view returns (bool);

    /// @notice Create a new Option + Receipt pair per the given parameters, or return the existing
    ///         canonical Option if one with economically-identical params already exists (get-or-create).
    function createOption(CreateParams memory params) external returns (address);
    /// @notice Batch form of {createOption}.
    function createOptions(CreateParams[] memory params) external returns (address[] memory);
    /// @notice Pull tokens via the factory-level allowance. Only callable by Collateral clones.
    function transferFrom(address from, address to, uint256 amount, address token) external returns (bool success);
    /// @notice Set the caller's factory-level allowance for `token`.
    function approve(address token, uint256 amount) external;
    /// @notice Set `operator`'s permission mask over the caller's positions, overwriting any
    ///         previous mask (`0` revokes everything). Reverts on bits outside `Perm.ALL`.
    ///         `operator == msg.sender` sets the caller's own automation opt-ins.
    function setPermissions(address operator, uint256 mask) external;
    /// @notice OR `mask` into `operator`'s existing permission mask (adds bits, never removes).
    function addPermissions(address operator, uint256 mask) external;
}
