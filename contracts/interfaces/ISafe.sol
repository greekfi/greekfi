// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

/// @notice The slice of a Safe 1.3.0 that the PositionRouter and its tests use.
interface ISafe {
    function domainSeparator() external view returns (bytes32);

    /// @param operation 0 = CALL, 1 = DELEGATECALL.
    function execTransactionFromModule(address to, uint256 value, bytes calldata data, uint8 operation) external returns (bool success);
}
