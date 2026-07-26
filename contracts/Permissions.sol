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
///           factory allowance to cover the missing balance). This **removes the ERC-20 safety
///           net**: a transfer larger than your balance no longer reverts with
///           `ERC20InsufficientBalance`, it silently opens a new short against your collateral
///           allowance. A fat-fingered amount becomes a position, not an error.
///         - `BURN` on self  → auto-burn when you move your own options and also hold the matching
///           Receipt (pair-burns them back into collateral). For *inbound* transfers the auto-burn
///           leg reads `permissions[you][sender]`, so the self bit alone does not let strangers net
///           against your short — you grant `BURN` to each sender whose transfers you want netted.
///
///         Neither self bit is a mere convenience flag, and note the self entry is read with the
///         same lookup as an operator grant, so setting `permissions[self][self]` is what enables
///         these; `setPermissions(self, Perm.ALL)` is **not** the harmless self-initialisation it
///         looks like (three of the five bits are genuine no-ops on self, but MINT and BURN are not).
///
///         ### ⚠ EVERY BIT IS DANGEROUS — GRANT ONLY TO AUDITED, TRUSTED CONTRACTS
///
///         There is no "safe" bit in this table. Each one hands a third party real power over your
///         position, and several of them compose into more than the sum of their parts. Treat any
///         grant the way you would treat an unlimited ERC-20 approval: only to contracts you have
///         audited, and revoke with {Factory.setPermissions}`(operator, 0)` when you are done.
///
///         Granted to a third-party operator:
///         - `TRANSFER` → move the owner's Option tokens without a per-option ERC20 allowance
///           ({Option.transferFrom} skips `_spendAllowance`). **This is full custody of the owner's
///           long positions.** The operator can move the longs to itself and then exercise them as
///           their own holder, capturing the entire in-the-money value — it does not need
///           `EXERCISE` to do so. Combined with `MINT` it also reaches the auto-mint branch, which
///           manufactures balance the owner never held out of their collateral allowance.
///         - `MINT`     → mint new positions against the owner's factory collateral allowance
///           ({Option.mint(address,uint256)} and the auto-mint branch of transfers). Equivalent
///           to a permit on the owner's collateral. On its own an operator can only force the owner
///           into a position (recoverable 1:1 by pair-burn); paired with `TRANSFER`, `EXERCISE` or
///           `REDEEM` it becomes an unbounded drain of everything the owner has approved to the
///           factory, across every market that exists or will ever exist.
///         - `BURN`     → pair-burn the owner's matched Option+Receipt back into collateral
///           ({Option.burn(address,uint256)}) and clean up expired longs ({Option.expire}).
///           Collateral always returns to the owner, but the operator chooses *when* — it can
///           unwind a hedge at a moment of its choosing.
///         - `REDEEM`   → trigger redemption via {Receipt.redeemFor}, at any time, under {Receipt.redeem}
///           semantics (consideration-first FCFS; the collateral leg only opens after
///           `exerciseDeadline`). There is **no post-window restriction** on this bit. The payout
///           always goes to the owner, but the operator chooses the timing and therefore which leg
///           the owner is settled into — and settling the short leg of a matched position pre-expiry
///           leaves the owner holding a naked long they can no longer pair-burn out of. This is a
///           trusted-keeper mechanism: grant it to a keeper you have instructed to collect your
///           consideration on your behalf, not to an arbitrary address.
///         - `EXERCISE` → burn the owner's options via {Option.exerciseFor}: the operator pays
///           consideration and RECEIVES THE COLLATERAL. This is a withdrawal right over the
///           owner's ITM value — the most dangerous single bit.
library Perm {
    uint256 internal constant TRANSFER = 1 << 0; // 1
    uint256 internal constant MINT = 1 << 1; // 2
    uint256 internal constant BURN = 1 << 2; // 4
    uint256 internal constant REDEEM = 1 << 3; // 8
    uint256 internal constant EXERCISE = 1 << 4; // 16

    /// @notice Every valid bit; masks with bits outside this range are rejected by the Factory.
    uint256 internal constant ALL = TRANSFER | MINT | BURN | REDEEM | EXERCISE; // 31
}
