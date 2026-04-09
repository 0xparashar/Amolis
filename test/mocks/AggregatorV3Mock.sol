// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {AggregatorV3Interface} from "@morpho-oracles/src/morpho-chainlink/interfaces/AggregatorV3Interface.sol";

/// @title AggregatorV3Mock
/// @notice Minimal mutable Chainlink-style oracle used by tests to control answer and decimals deterministically.
contract AggregatorV3Mock is AggregatorV3Interface {
    /// @notice Latest signed answer returned by `getRoundData` and `latestRoundData`; set via `setAnswer`.
    int256 public answer;

    /// @notice Feed decimals metadata for scaling answers; defaults to 8 and can be changed with `setDecimals`.
    uint8 public override decimals = 8;

    /// @notice Stores a new oracle answer that later round-data reads will return.
    /// @dev It updates the single in-memory value that both `getRoundData` and `latestRoundData` expose.
    /// Use this in tests before pricing logic runs so dependent contracts observe the intended mock price.
    /// @param newAnswer Signed fixed-point answer returned on subsequent Chainlink-style reads.
    function setAnswer(int256 newAnswer) external {
        answer = newAnswer;
    }

    /// @notice Overrides the decimals metadata reported by the mock oracle.
    /// @dev It updates the public `decimals` storage variable that consumers read to scale answers.
    /// Use this in tests when you need to simulate a feed with a non-default decimal precision.
    /// @param d Decimals value exposed via `decimals()` after the update.
    function setDecimals(uint8 d) external {
        decimals = d;
    }

    /// @notice Returns a short human-readable label for the mock feed.
    /// @dev It always returns the constant string `mock` because tests only need interface compliance.
    /// Call this only when an integration under test inspects the optional Chainlink description field.
    /// @return desc Fixed label `mock` for interface compatibility.
    function description() external pure override returns (string memory) {
        return "mock";
    }

    /// @notice Returns the mock feed version.
    /// @dev It stays pinned to `1` because versioning is irrelevant for this test-only implementation.
    /// Call this only when an integration under test inspects the optional Chainlink version field.
    /// @return v Fixed version `1` for interface compatibility.
    function version() external pure override returns (uint256) {
        return 1;
    }

    /// @notice Returns one synthetic historical round using the current stored answer.
    /// @dev It ignores the requested round id and reuses the mock's single answer while zeroing all timestamps.
    /// Use this when a test target reads Chainlink-style historical data but only cares about the quoted answer.
    /// @param _roundId Requested Chainlink round id, ignored because this mock stores only one mutable answer.
    /// @return roundId Synthetic round id, always zero in this mock.
    /// @return ans Current `answer` stored via `setAnswer`.
    /// @return startedAt Synthetic started timestamp, always zero.
    /// @return updatedAt Synthetic updated timestamp, always zero.
    /// @return answeredInRound Synthetic answered-in-round field, always zero.
    function getRoundData(uint80 _roundId)
        external
        view
        override
        returns (uint80 roundId, int256 ans, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (0, answer, 0, 0, 0);
    }

    /// @notice Returns the latest synthetic round using the current stored answer.
    /// @dev It mirrors `getRoundData` and emits zero timestamps because the mock tracks only one mutable price point.
    /// Use this in tests for integrations that read the latest Chainlink answer rather than a historical round.
    /// @return roundId Synthetic round id, always zero in this mock.
    /// @return ans Current `answer` stored via `setAnswer`.
    /// @return startedAt Synthetic started timestamp, always zero.
    /// @return updatedAt Synthetic updated timestamp, always zero.
    /// @return answeredInRound Synthetic answered-in-round field, always zero.
    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 ans, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (0, answer, 0, 0, 0);
    }
}
