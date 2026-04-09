// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.21;

import {Id, IMorpho, MarketParams} from "@morpho-blue/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "@morpho-blue/src/libraries/MarketParamsLib.sol";
import {
    IMorphoChainlinkOracleV2Factory
} from "@morpho-oracles/src/morpho-chainlink/interfaces/IMorphoChainlinkOracleV2Factory.sol";
import {AggregatorV3Interface} from "@morpho-oracles/src/morpho-chainlink/interfaces/AggregatorV3Interface.sol";
import {IERC4626 as OracleVault} from "@morpho-oracles/src/morpho-chainlink/libraries/VaultLib.sol";
import {
    IMorphoMarketV1AdapterV2Factory
} from "@morpho-vault/src/adapters/interfaces/IMorphoMarketV1AdapterV2Factory.sol";
import {IVaultV2Factory} from "@morpho-vault/src/interfaces/IVaultV2Factory.sol";
import {IERC20} from "@morpho-vault/src/interfaces/IERC20.sol";

import {AmolisVaultController} from "./AmolisVaultController.sol";

/**
 * @title AmolisFactory
 * @author Ankit Parashar
 * @notice This contract bootstraps a reusable oracle, one Morpho market, one VaultV2, and one constrained controller
 * for a user-provided XUSD token.
 *
 * It does not keep an on-chain mapping from XUSD to a single deployment; the same XUSD can be used for many independent
 * vault stacks (each with its own controller, vault, and adapter), typically sharing one Morpho market and oracle when
 * params match.
 *
 * Purpose of this factory is to create:
 * - A Morpho oracle for USDC collateral priced against XUSD debt.
 * - A Morpho Blue USDC/XUSD market.
 * - A VaultV2 that can only allocate to that exact market through one adapter.
 * - A narrow controller contract that owns the vault and only exposes safe configuration methods.
 */
contract AmolisFactory {
    using MarketParamsLib for MarketParams;

    uint256 public constant FIXED_LLTV = 94.5e16;

    IMorpho public immutable MORPHO;
    IVaultV2Factory public immutable VAULT_V2_FACTORY;
    IMorphoMarketV1AdapterV2Factory public immutable MORPHO_MARKET_V1_ADAPTER_V2_FACTORY;
    IMorphoChainlinkOracleV2Factory public immutable MORPHO_CHAINLINK_ORACLE_V2_FACTORY;
    IERC20 public immutable USDC;
    AggregatorV3Interface public immutable USDC_CHAINLINK_FEED;

    mapping(bytes32 oracleKey => address oracle) public oracleForPair;

    error ZeroAddress();

    event OracleRegistered(bytes32 indexed oracleKey, address indexed oracle, uint8 usdcDecimals, uint8 xusdDecimals);
    event AmolisCreated(
        address indexed xusd,
        address indexed owner,
        bytes32 indexed marketId,
        address oracle,
        address vault,
        address adapter,
        address controller
    );

    /// @notice Configures the shared protocol dependencies used by every Amolis deployment.
    /// @dev It stores immutable references for the Morpho core contracts and the reusable USDC feed while the LLTV
    /// stays fixed in contract code at `94.5e16` (94.5%).
    /// Deploy this once with the live protocol addresses for the target chain.
    /// @param _morpho Morpho Blue core contract used to create markets and read market state.
    /// @param _vaultV2Factory VaultV2 factory that deploys vaults owned by each new `AmolisVaultController`.
    /// @param _morphoMarketV1AdapterV2Factory Factory that deploys Morpho market adapters (provides the adaptive curve IRM address).
    /// @param _morphoChainlinkOracleV2Factory Factory that deploys Morpho Chainlink oracles reused per USDC/XUSD decimals pair.
    /// @param _usdc USDC (or chain-equivalent) ERC-20 used as Morpho collateral in every Amolis market this factory creates.
    /// @param _usdcChainlinkFeed Chainlink aggregator feeding the USDC leg of new Morpho oracles.
    constructor(
        address _morpho,
        address _vaultV2Factory,
        address _morphoMarketV1AdapterV2Factory,
        address _morphoChainlinkOracleV2Factory,
        address _usdc,
        address _usdcChainlinkFeed
    ) {
        if (
            _morpho == address(0) || _vaultV2Factory == address(0) || _morphoMarketV1AdapterV2Factory == address(0)
                || _morphoChainlinkOracleV2Factory == address(0) || _usdc == address(0)
                || _usdcChainlinkFeed == address(0)
        ) revert ZeroAddress();

        MORPHO = IMorpho(_morpho);
        VAULT_V2_FACTORY = IVaultV2Factory(_vaultV2Factory);
        MORPHO_MARKET_V1_ADAPTER_V2_FACTORY = IMorphoMarketV1AdapterV2Factory(_morphoMarketV1AdapterV2Factory);
        MORPHO_CHAINLINK_ORACLE_V2_FACTORY = IMorphoChainlinkOracleV2Factory(_morphoChainlinkOracleV2Factory);
        USDC = IERC20(_usdc);
        USDC_CHAINLINK_FEED = AggregatorV3Interface(_usdcChainlinkFeed);
    }

    /// @notice Returns the deterministic key used to reuse oracles for one USDC/XUSD decimals pair.
    /// @dev It hashes the USDC decimals together with the XUSD decimals so one decimals combination maps to one oracle.
    /// Call this off-chain or in tests when you want to inspect the `oracleForPair` mapping for a given token pair.
    /// @param _usdcDecimals On-chain `decimals()` of the collateral token (USDC) for the pair.
    /// @param _xusdDecimals On-chain `decimals()` of the loan token (XUSD) for the pair.
    /// @return key `keccak256(abi.encode(_usdcDecimals, _xusdDecimals))`; indexes `oracleForPair`.
    function oraclePairKey(uint8 _usdcDecimals, uint8 _xusdDecimals) public pure returns (bytes32) {
        return keccak256(abi.encode(_usdcDecimals, _xusdDecimals));
    }

    /// @notice Deploys the full Amolis system for one XUSD token and returns every created address.
    /// @dev It reuses or deploys the oracle keyed by decimals, calls `createMarket` only when Morpho has not yet
    /// initialized that market id (same loan/collateral/oracle/irm/lltv yields the same id), deploys a new controller,
    /// and lets that controller initialize a new vault and adapter. Nothing is written to a per-XUSD factory registry,
    /// so repeated calls for the same token are allowed and return distinct controller, vault, and adapter addresses.
    /// Call this whenever you want a fresh Amolis stack for an XUSD token with the desired initial cap and salt.
    /// @param _xusd Loan token (XUSD) address; must be a deployed ERC-20 with valid `decimals()`.
    /// @param _initialTotalCap Initial absolute supply cap in `_xusd` units, applied to adapter, collateral, and market caps during bootstrap.
    /// @param _salt Entropy for VaultV2Factory so repeated `createAmolis` for the same `_xusd` yields distinct vault addresses.
    /// @return oracle Morpho Chainlink oracle for this factory's USDC/`_xusd` decimals pair (reused or newly deployed).
    /// @return marketId Morpho Blue market id (`Id` as `bytes32`) for USDC collateral and `_xusd` debt at `FIXED_LLTV`.
    /// @return vault New VaultV2 managing `_xusd` and owned by the new controller.
    /// @return adapter New Morpho market adapter the vault uses for liquidity routing.
    /// @return controller New `AmolisVaultController` that owns the vault and exposes admin-only configuration.
    function createAmolis(address _xusd, uint256 _initialTotalCap, bytes32 _salt)
        external
        returns (address oracle, bytes32 marketId, address vault, address adapter, address controller)
    {
        if (_xusd == address(0)) revert ZeroAddress();

        uint8 usdcDecimals = USDC.decimals();
        uint8 xusdDecimals = IERC20(_xusd).decimals();

        oracle = _getOrCreateOracle(usdcDecimals, xusdDecimals);
        address adaptiveCurveIrm = MORPHO_MARKET_V1_ADAPTER_V2_FACTORY.adaptiveCurveIrm();

        MarketParams memory marketParams = MarketParams({
            loanToken: _xusd, collateralToken: address(USDC), oracle: oracle, irm: adaptiveCurveIrm, lltv: FIXED_LLTV
        });
        Id marketIdValue = marketParams.id();
        marketId = Id.unwrap(marketIdValue);

        if (MORPHO.market(marketIdValue).lastUpdate == 0) MORPHO.createMarket(marketParams);

        controller = address(
            new AmolisVaultController{salt: keccak256(abi.encode(msg.sender, _salt))}(
                msg.sender,
                address(VAULT_V2_FACTORY),
                address(MORPHO_MARKET_V1_ADAPTER_V2_FACTORY),
                address(MORPHO),
                marketId
            )
        );
        (vault, adapter) = AmolisVaultController(controller).initialize(_initialTotalCap, _salt);

        emit AmolisCreated(_xusd, msg.sender, marketId, oracle, vault, adapter, controller);
    }

    /// @dev Returns cached `oracleForPair[key]` when set; otherwise deploys via `MORPHO_CHAINLINK_ORACLE_V2_FACTORY`,
    /// records it, and emits `OracleRegistered`. Invoked only from `createAmolis` so oracle reuse stays factory-controlled.
    /// @param _usdcDecimals USDC decimals forwarded to the oracle factory (must match `USDC.decimals()`).
    /// @param _xusdDecimals XUSD decimals forwarded to the oracle factory (must match the loan token).
    /// @return oracle Existing or newly deployed oracle address registered under the decimals-pair key.
    function _getOrCreateOracle(uint8 _usdcDecimals, uint8 _xusdDecimals) internal returns (address oracle) {
        bytes32 key = oraclePairKey(_usdcDecimals, _xusdDecimals);
        oracle = oracleForPair[key];
        if (oracle != address(0)) return oracle;

        oracle = address(
            MORPHO_CHAINLINK_ORACLE_V2_FACTORY.createMorphoChainlinkOracleV2(
                OracleVault(address(0)),
                1,
                USDC_CHAINLINK_FEED,
                AggregatorV3Interface(address(0)),
                _usdcDecimals,
                OracleVault(address(0)),
                1,
                AggregatorV3Interface(address(0)),
                AggregatorV3Interface(address(0)),
                _xusdDecimals,
                keccak256(abi.encode(address(this), key))
            )
        );

        oracleForPair[key] = oracle;
        emit OracleRegistered(key, oracle, _usdcDecimals, _xusdDecimals);
    }
}
