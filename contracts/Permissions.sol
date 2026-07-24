// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

/// @title  Perm — permission bit flags for the Factory's operator registry
/// @author Greek.fi
/// @notice Each (owner, operator) pair in {Factory.permissions} carries a bitmask of these flags.
///         Grant with {Factory.setPermissions} (overwrite) or {Factory.addPermissions} (OR-in).
///
///         The **self entry** `permissions[account][account]` configures the account's own
///         transfer-time automation in {Option}:
///         - `MINT` on self  → auto-mint on transfer shortfall (pulls collateral via the
///           factory allowance to cover the missing balance).
///         - `BURN` on self  → auto-burn on receive when the account also holds the matching
///           Receipt (pair-burns incoming options back into collateral).
///
///         Granted to a third-party operator:
///         - `TRANSFER` → move the owner's Option tokens without a per-option ERC20 allowance
///           ({Option.transferFrom} skips `_spendAllowance`).
///         - `MINT`     → mint new positions against the owner's factory collateral allowance
///           ({Option.mint(address,uint256)} and the auto-mint branch of transfers). Equivalent
///           to a permit on the owner's collateral — grant only to audited protocol contracts.
///         - `BURN`     → pair-burn the owner's matched Option+Receipt back into collateral
///           ({Option.burn(address,uint256)}) and clean up expired longs ({Option.expire}).
///           Collateral always returns to the owner; the operator is a trigger.
///         - `REDEEM`   → trigger post-window pro-rata redemption via {Receipt.redeemFor}.
///           Payout always goes to the owner; the operator is a trigger.
///         - `EXERCISE` → burn the owner's options via {Option.exerciseFor}: the operator pays
///           consideration and RECEIVES THE COLLATERAL. This is a withdrawal right over the
///           owner's ITM value — the most dangerous bit; grant only to audited keeper contracts.
library Perm {
    uint256 internal constant TRANSFER = 1 << 0; // 1
    uint256 internal constant MINT = 1 << 1; // 2
    uint256 internal constant BURN = 1 << 2; // 4
    uint256 internal constant REDEEM = 1 << 3; // 8
    uint256 internal constant EXERCISE = 1 << 4; // 16

    /// @notice Every valid bit; masks with bits outside this range are rejected by the Factory.
    uint256 internal constant ALL = TRANSFER | MINT | BURN | REDEEM | EXERCISE; // 31
}
