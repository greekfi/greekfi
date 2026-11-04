// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import { IPriceFeed } from "../contracts/interfaces/IPriceFeed.sol";

/// @dev An 8-decimal Chainlink-style feed whose answer is always `age` seconds old, so tests can warp
///      freely without the price going stale.
contract MockPriceFeed is IPriceFeed {
    int256 public answer = 3_000e8;
    uint256 public age;

    function set(int256 answer_) external {
        answer = answer_;
    }

    function setAge(uint256 age_) external {
        age = age_;
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, block.timestamp - age, block.timestamp - age, 1);
    }
}
