// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { TokenData, Balances, OptionInfo } from "./interfaces/IOption.sol";
import { IReceipt } from "./interfaces/IReceipt.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title  OptionUtils
 * @author Greek.fi
 * @notice Pure-function library used by {Option} and {Collateral} to render human-readable
 *         token names ("OPT-WETH-USDC-3000-2025-12-26") without blowing up the clone deployment cost.
 * @dev    Contains no state. All functions are `internal pure`. Two concerns:
 *
 *         - `strike2str`    — 18-decimal fixed point → human string, with sensible rounding and
 *                             scientific notation for very small values (e.g. inverted put strikes).
 *         - `epoch2str`     — unix timestamp → `YYYY-MM-DD` (UTC).
 *
 *         Integer → decimal ASCII delegates to OpenZeppelin's `Strings.toString`.
 *
 *         The helpers live here (not inline in Option / Receipt) so every option-pair clone
 *         shares a single deployed copy of the rendering logic.
 */
library OptionUtils {
    /// @notice Render an 18-decimal fixed-point strike as a compact, human-readable string.
    /// @dev    Rules applied, in order:
    ///         1. No fractional part → print the integer.
    ///         2. Whole > 0 with ≥4 leading fractional zeros → drop the noise (e.g. floating-point
    ///            artifacts from `1e36 / strike` on puts) and print only the integer.
    ///         3. Whole == 0 and >8 leading zeros → scientific notation (`"1e-9"`).
    ///         4. Otherwise → decimal, rounded half-up to 4 significant fractional digits, with
    ///            trailing zeros trimmed. Rounding overflow into the whole part (e.g. `0.99995 → 1`)
    ///            is handled.
    /// @param _i Strike price in 18-decimal fixed-point.
    /// @return Human-readable strike (e.g. `"3000"`, `"0.0005"`, `"1e-9"`).
    function strike2str(uint256 _i) internal pure returns (string memory) {
        uint256 whole = _i / 1e18;
        uint256 fractional = _i % 1e18;
        if (fractional == 0) return Strings.toString(whole);

        // leadingZeros = # of zero positions between the decimal point and the first non-zero
        // digit. For fractional ∈ [10^(17-k), 10^(18-k)), the result is k.
        uint256 leadingZeros;
        for (uint256 d = 1e17; fractional / d == 0; d /= 10) {
            leadingZeros++;
        }

        // (2) Inverted-put artifact (e.g. `3000.000000000003` → `"3000"`).
        if (whole > 0 && leadingZeros >= 4) return Strings.toString(whole);

        // (3) Scientific notation for sub-1e-8 values. First sig digit is `fractional / 10^(17-k)`.
        if (whole == 0 && leadingZeros > 8) {
            return string(
                abi.encodePacked(
                    Strings.toString(fractional / 10 ** (17 - leadingZeros)), "e-", Strings.toString(leadingZeros + 1)
                )
            );
        }

        // (4) Round half-up to 4 significant fractional digits. Expressed as floor + remainder
        // bump (instead of `(x + unit/2) / unit * unit`) to keep `divide-before-multiply` happy.
        if (leadingZeros < 14) {
            uint256 unit = 10 ** (14 - leadingZeros);
            uint256 quotient = fractional / unit;
            if (fractional % unit >= unit / 2) quotient++;
            fractional = quotient * unit;
            if (fractional >= 1e18) return Strings.toString(whole + 1);
        }

        // Strip trailing zeros, then emit `<leadingZeros zeros><digits>`.
        uint256 trailing;
        while (fractional % 10 == 0) {
            fractional /= 10;
            trailing++;
        }
        bytes memory digits = bytes(Strings.toString(fractional));
        bytes memory pad = new bytes(18 - trailing - digits.length);
        for (uint256 i; i < pad.length; ++i) {
            pad[i] = "0";
        }
        return string(abi.encodePacked(Strings.toString(whole), ".", pad, digits));
    }

    function zeroPad(uint256 _i) internal pure returns (string memory) {
        return _i < 10 ? string(abi.encodePacked("0", Strings.toString(_i))) : Strings.toString(_i);
    }

    /// @notice Convert a unix timestamp to a `YYYY-MM-DD` (UTC) string.
    /// @dev    Uses Howard Hinnant's branchless date algorithm
    ///         (https://howardhinnant.github.io/date_algorithms.html#civil_from_days), which
    ///         encodes the full Gregorian leap-year rules (÷4 except centuries, ÷400) without
    ///         per-year loops. block.timestamp is UTC, so no timezone handling is needed.
    /// @param _i Unix timestamp (seconds since 1970-01-01).
    /// @return Date string (e.g. `1704067200 → "2024-01-01"`).
    function epoch2str(uint256 _i) internal pure returns (string memory) {
        uint256 z = _i / 86400 + 719468;
        uint256 era = z / 146097;
        uint256 doe = z - era * 146097;
        uint256 yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
        uint256 doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        uint256 mp = (5 * doy + 2) / 153;
        uint256 day = doy - (153 * mp + 2) / 5 + 1;
        uint256 month = mp < 10 ? mp + 3 : mp - 9;
        uint256 year = yoe + era * 400 + (month <= 2 ? 1 : 0);

        return string(abi.encodePacked(Strings.toString(year), "-", zeroPad(month), "-", zeroPad(day)));
    }

    function name(
        string memory type_,
        string memory collSymbol,
        string memory consSymbol,
        uint256 _strike,
        uint256 _expirationDate
    ) internal pure returns (string memory) {
        return string(
            abi.encodePacked(
                type_,
                "-",
                collSymbol,
                "-",
                consSymbol,
                "-",
                OptionUtils.strike2str(_strike),
                "-",
                OptionUtils.epoch2str(_expirationDate)
            )
        );
    }

    // ============ QUERY ============

    /// @notice All four balances that matter for this option in one call.
    /// @param account Address to query.
    /// @return A {Balances} struct: collateral token, consideration token, long option, short receipt.
    function balancesOf(address receipt_, address account) public view returns (Balances memory) {
        IReceipt receipt = IReceipt(receipt_);
        return Balances({
            collateral: IERC20(receipt.collateral()).balanceOf(account),
            consideration: IERC20(receipt.consideration()).balanceOf(account),
            option: IERC20(receipt.option()).balanceOf(account),
            receipt: IERC20(address(receipt)).balanceOf(account)
        });
    }

    /// @notice Full option descriptor — addresses, token metadata, strike, expiry, deadline.
    ///         Convenient one-shot read for frontends.
    function details(address receipt_) public view returns (OptionInfo memory) {
        IReceipt receipt = IReceipt(receipt_);
        address colTok = address(receipt.collateral());
        address consTok = address(receipt.consideration());
        IERC20Metadata cm = IERC20Metadata(colTok);
        IERC20Metadata cnm = IERC20Metadata(consTok);
        return OptionInfo({
            option: address(receipt.option()),
            receipt: address(receipt),
            collateral: TokenData({ address_: colTok, name: cm.name(), symbol: cm.symbol(), decimals: cm.decimals() }),
            consideration: TokenData({ address_: consTok, name: cnm.name(), symbol: cnm.symbol(), decimals: cnm.decimals() }),
            expiration: receipt.expirationDate(),
            strike: receipt.strike(),
            isPut: receipt.isPut(),
            isEuro: receipt.isEuro(),
            exerciseDeadline: receipt.exerciseDeadline()
        });
    }
}
