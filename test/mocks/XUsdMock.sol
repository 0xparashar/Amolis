// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title XUsdMock
/// @notice Minimal mintable ERC-20 standing in for an XUSD-style loan asset on mainnet forks and unit tests.
contract XUsdMock is ERC20 {
    uint8 private immutable _decimals;

    /// @notice Deploys a fixed-decimal mock XUSD with public minting for test actors.
    /// @dev It pins `name`/`symbol` to stable identifiers and stores the requested decimal scale used by Morpho markets.
    /// Use this from Foundry tests when you need a fresh loan token that behaves like a standard ERC-20 without admin logic.
    /// @param decimals_ Decimal precision the mock should report through `decimals()`.
    constructor(uint8 decimals_) ERC20("XUSD Mock", "XUSD") {
        _decimals = decimals_;
    }

    /// @notice Returns the immutable decimal scale configured at deployment.
    /// @dev It overrides OpenZeppelin's default of 18 so Morpho oracles and vault previews match a 6-decimal XUSD profile.
    /// Call this through `IERC20.decimals()` when wiring factory tests or fork setups that assume USDC-like precision.
    /// @return d Immutable decimals value set in the constructor.
    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    /// @notice Mints fresh XUSD to any address without access control for test scenarios.
    /// @dev It uses OpenZeppelin `_mint` so balances and `Transfer` events stay ERC-20 compliant on every call.
    /// Use this in `setUp` or individual tests when actors need loan liquidity for supply, borrow, or repay flows.
    /// @param to Address that should receive the freshly minted mock XUSD.
    /// @param amount Amount of mock XUSD to mint in base units.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
