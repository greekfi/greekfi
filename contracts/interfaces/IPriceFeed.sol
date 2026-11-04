// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

/// @notice The slice of a Chainlink `AggregatorV3Interface` the PositionRouter reads. On mainnet the
///         router uses the ETH / USD feed (`0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419`).
interface IPriceFeed {
    function decimals() external view returns (uint8);

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
