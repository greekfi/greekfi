// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title  IReceipt — short-side token interface (collateral receipt)
/// @author Greek.fi
/// @notice ERC20 extension for the short-side position: holds underlying collateral, receives
///         consideration on exercise, and handles post-window redemption math (cons-first, then
///         collateral 1:1 for any remainder).
interface IReceipt {
    /// @notice Emitted whenever collateral or consideration is returned to a holder.
    event Redeemed(address option, address token, address holder, uint256 amount);

    /// @notice Caller is not the paired Option (or, for `sweep`, not the factory owner).
    error UnauthorizedCaller();
    /// @notice Never thrown by Receipt itself — the pre-expiry mint gate lives in the paired
    ///         Option. Declared for ABI/tooling parity.
    error ContractExpired();
    /// @notice Zero-amount (or derived-zero) mutation rejected.
    error ZeroValue();
    /// @notice Never thrown by Receipt itself — the exercise-deadline gate lives in the paired
    ///         Option. Declared for ABI/tooling parity.
    error ExerciseWindowClosed();
    /// @notice Post-window-only path called while the exercise window is still open.
    error ExerciseWindowOpen();
    /// @notice Short-side redemption attempted on a European option before its exercise window opens.
    error BeforeExerciseWindow();
    /// @notice `sweep` called while receipts are still outstanding.
    error OutstandingReceipts();
    /// @notice The consideration or collateral pool cannot fully fund its leg of the requested
    ///         redemption — split into smaller amounts.
    error InsufficientPool();

    /// @notice Strike price (18-decimal fixed point, consideration per collateral; inverted for puts).
    function strike() external view returns (uint256);
    /// @notice Underlying collateral token.
    function collateral() external view returns (IERC20);
    /// @notice Consideration / quote token.
    function consideration() external view returns (IERC20);
    /// @notice Unix expiration timestamp (uint40).
    function expirationDate() external view returns (uint40);
    /// @notice Unix timestamp at which the post-expiry exercise window closes (uint64: the
    ///         expiration + window sum can exceed uint40).
    function exerciseDeadline() external view returns (uint64);
    /// @notice `true` if this is a put.
    function isPut() external view returns (bool);
    /// @notice `true` if European-style (exercise only allowed in the post-expiry window).
    function isEuro() external view returns (bool);
    /// @notice Cached `collateral.decimals()`.
    function decimals() external view returns (uint8);
    /// @notice Cached `consideration.decimals()`.
    function consDecimals() external view returns (uint8);
    /// @notice Decimal basis of the strike (always 18).
    function STRIKEDEC() external view returns (uint8);

    /// @notice ERC20 name (rendered `RCT[E]-coll-cons-strike-YYYY-MM-DD`).
    function name() external view returns (string memory);
    /// @notice ERC20 symbol (matches `name`).
    function symbol() external view returns (string memory);
    /// @notice Paired Option contract — the only address authorised to call `mint`/`burn`/`exercise`.
    function option() external view returns (address);
    /// @notice Factory that created this pair.
    function factory() external view returns (address);
    /// @notice Strike-rate conversion. `round=true` rounds up (used when collecting consideration on exercise);
    ///         `round=false` rounds down (used for payouts).
    function toConsideration(uint256 amount, bool round) external pure returns (uint256);
    /// @notice Inverse of {toConsideration} — how much collateral a given consideration amount is worth
    ///         (floor by design). Not used internally — exposed for off-chain indexers and
    ///         invariant tests.
    function toCollateral(uint256 consAmount) external pure returns (uint256);

    /// @notice Mint (Option-only). Pulls collateral from `account` via the factory.
    function mint(address account, uint256 amount) external;
    /// @notice Pair-burn helper (Option-only). Valid up to and including `exerciseDeadline`.
    function burn(address account, uint256 amount) external;
    /// @notice Exercise path invoked by the paired Option. `account` is both the consideration payer
    ///         and the collateral recipient (the Option contract forwards `msg.sender` here).
    function exercise(address account, uint256 amount) external;

    /// @notice Redeem the caller's full receipt balance. Cons-first, then collateral 1:1 for any
    ///         remainder. Cons leg is FCFS whenever the pool can cover it (European: not before
    ///         `expirationDate`); collateral leg requires
    ///         `block.timestamp > exerciseDeadline`.
    function redeem() external;
    /// @notice Redeem `amount` of the caller's receipts. Same cons-first semantics as `redeem()`.
    function redeem(uint256 amount) external;
    /// @notice Keeper-gated batch redeem. Per-holder authorisation via `factory.allowRedeem`; payouts
    ///         always go to the holder, never to the caller.
    function redeemFor(address[] calldata holders) external;
    /// @notice Factory-owner dust drain. Reverts if any receipt is outstanding.
    function sweep(address token, address to) external;

    /// @notice ERC20 balance.
    function balanceOf(address account) external view returns (uint256);
}
