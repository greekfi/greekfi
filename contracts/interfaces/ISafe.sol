// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

/// @notice The slice of a Safe 1.3.0 that the PositionRouter fork tests use.
interface ISafe {
    /// @param operation 0 = CALL, 1 = DELEGATECALL.
    function execTransactionFromModule(address to, uint256 value, bytes calldata data, uint8 operation) external returns (bool success);
}
