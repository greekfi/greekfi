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

/// @title  IFactory — option pair deployer + transfer hub
/// @author Greek.fi
/// @notice Deploys Option + Receipt pairs via EIP-1167 clones, serves as the single ERC20-allowance
///         pull point for every option pair it creates, and holds an operator + auto-mint-redeem registry.
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
    /// @notice Emitted on {approveOperator}.
    event OperatorApproval(address indexed owner, address indexed operator, bool approved);
    /// @notice Emitted on {enableAutoMintBurn}.
    event AutoMintBurnUpdated(address indexed account, bool enabled);

    /// @notice Zero address supplied where a contract is required.
    error InvalidAddress();
    /// @notice Collateral and consideration were the same address.
    error InvalidTokens();
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
    /// @notice `true` if `account` has opted into Option's auto-mint / auto-redeem transfer hooks.
    function autoMintBurn(address account) external view returns (bool);
    /// @notice `true` if `operator` has blanket authority over `owner`'s Option tokens.
    function approvedOperator(address owner, address operator) external view returns (bool);
    /// @notice `true` if `exercisor` may burn `holder`'s options via `exerciseFor`.
    function exerciseAllowed(address holder, address exercisor) external view returns (bool);
    /// @notice `true` if `redeemer` may trigger `Receipt.redeemFor` on behalf of `holder`.
    function redeemAllowed(address holder, address redeemer) external view returns (bool);

    /// @notice Create a new Option + Receipt pair per the given parameters, or return the existing
    ///         canonical Option if one with economically-identical params already exists (get-or-create).
    function createOption(CreateParams memory params) external returns (address);
    /// @notice Batch form of {createOption}.
    function createOptions(CreateParams[] memory params) external returns (address[] memory);
    /// @notice Pull tokens via the token's ERC-20 allowance to the factory. Only callable by Receipt clones.
    function transferFrom(address from, address to, uint256 amount, address token) external returns (bool success);
    /// @notice Opt-in / opt-out of Option's auto-mint-on-transfer / auto-redeem-on-receive behaviour.
    function enableAutoMintBurn(bool enabled) external;
    /// @notice Grant / revoke blanket operator authority over the caller's options.
    function approveOperator(address operator, bool approved) external;
    /// @notice Authorise / revoke `exercisor` for `Option.exerciseFor` on the caller's options.
    function allowExercise(address exercisor, bool allowed) external;
    /// @notice Authorise / revoke `redeemer` for `Receipt.redeemFor` on the caller's receipts.
    function allowRedeem(address redeemer, bool allowed) external;
}
