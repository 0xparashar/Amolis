// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "@forge-std/Test.sol";
import {Id, IMorpho, Market, MarketParams} from "@morpho-blue/src/interfaces/IMorpho.sol";
import {IOracle} from "@morpho-blue/src/interfaces/IOracle.sol";
import {MarketParamsLib} from "@morpho-blue/src/libraries/MarketParamsLib.sol";
import {Morpho} from "@morpho-blue/src/Morpho.sol";
import {ErrorsLib as VaultErrorsLib} from "@morpho-vault/src/libraries/ErrorsLib.sol";
import {IVaultV2} from "@morpho-vault/src/interfaces/IVaultV2.sol";
import {MAX_MAX_RATE, WAD} from "@morpho-vault/src/libraries/ConstantsLib.sol";
import {MorphoMarketV1AdapterV2Factory} from "@morpho-vault/src/adapters/MorphoMarketV1AdapterV2Factory.sol";
import {VaultV2Factory} from "@morpho-vault/src/VaultV2Factory.sol";
import {MorphoChainlinkOracleV2Factory} from "@morpho-oracles/src/morpho-chainlink/MorphoChainlinkOracleV2Factory.sol";
import {AdaptiveCurveIrm} from "@morpho-blue-irm/src/adaptive-curve-irm/AdaptiveCurveIrm.sol";

import {ERC20Mock} from "../lib/vault-v2/test/mocks/ERC20Mock.sol";
import {ChainlinkAggregatorMock} from "../lib/morpho-blue-oracles/test/mocks/ChainlinkAggregatorMock.sol";
import {AmolisFactory} from "../src/AmolisFactory.sol";
import {AmolisVaultController} from "../src/AmolisVaultController.sol";

contract AmolisFactoryTest is Test {
    using MarketParamsLib for MarketParams;

    struct DeploymentData {
        address oracle;
        bytes32 marketId;
        address vault;
        address adapter;
        address controller;
    }

    uint256 internal constant FIXED_LLTV = 94.5e16;
    uint256 internal constant INITIAL_CAP_6_DECIMALS = 1_000_000e6;
    uint256 internal constant INITIAL_CAP_18_DECIMALS = 1_000_000e18;
    uint256 internal constant PERFORMANCE_FEE = 0.1 ether;

    address internal morphoOwner;
    address internal deployer;
    address internal secondaryOwner;
    address internal alice;
    address internal bob;
    address internal feeRecipient;

    IMorpho internal morpho;
    AdaptiveCurveIrm internal irm;
    VaultV2Factory internal vaultV2Factory;
    MorphoMarketV1AdapterV2Factory internal adapterFactory;
    MorphoChainlinkOracleV2Factory internal oracleFactory;
    ERC20Mock internal usdc;
    ERC20Mock internal xusdSixA;
    ERC20Mock internal xusdSixB;
    ERC20Mock internal xusdEighteen;
    ChainlinkAggregatorMock internal usdcFeed;
    AmolisFactory internal factory;

    /// @notice Sets up Morpho, the shared factories, and three XUSD test tokens with different decimals.
    /// @dev It enables the adaptive curve IRM and the fixed 94.5% LLTV once so every deployment test can use the same
    /// protocol fixture without redeploying the shared dependencies.
    /// Use this setup implicitly through Foundry before each individual test case in this file.
    function setUp() public {
        morphoOwner = makeAddr("morphoOwner");
        deployer = makeAddr("deployer");
        secondaryOwner = makeAddr("secondaryOwner");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        feeRecipient = makeAddr("feeRecipient");

        morpho = IMorpho(address(new Morpho(morphoOwner)));
        irm = new AdaptiveCurveIrm(address(morpho));

        vm.startPrank(morphoOwner);
        morpho.enableIrm(address(irm));
        morpho.enableLltv(FIXED_LLTV);
        vm.stopPrank();

        vaultV2Factory = new VaultV2Factory();
        adapterFactory = new MorphoMarketV1AdapterV2Factory(address(morpho), address(irm));
        oracleFactory = new MorphoChainlinkOracleV2Factory();

        usdc = new ERC20Mock(6);
        xusdSixA = new ERC20Mock(6);
        xusdSixB = new ERC20Mock(6);
        xusdEighteen = new ERC20Mock(18);

        usdcFeed = new ChainlinkAggregatorMock();
        usdcFeed.setAnwser(1e8);

        factory = new AmolisFactory(
            address(morpho),
            address(vaultV2Factory),
            address(adapterFactory),
            address(oracleFactory),
            address(usdc),
            address(usdcFeed)
        );
    }

    /// @notice Verifies that the factory reuses one oracle for equal decimals pairs and deploys a new one for a new pair.
    /// @dev It creates two 6-decimal XUSD markets and one 18-decimal XUSD market, then compares the oracle addresses
    /// returned by each deployment and the stored `oracleForPair` entries.
    /// Use this test to confirm the decimals-keyed oracle reuse policy stays intact.
    function testOracleReuseByDecimalsPair() public {
        DeploymentData memory first =
            _createDeployment(deployer, address(xusdSixA), INITIAL_CAP_6_DECIMALS, bytes32("A"));
        DeploymentData memory second =
            _createDeployment(secondaryOwner, address(xusdSixB), INITIAL_CAP_6_DECIMALS, bytes32("B"));
        DeploymentData memory third =
            _createDeployment(alice, address(xusdEighteen), INITIAL_CAP_18_DECIMALS, bytes32("C"));

        assertEq(first.oracle, second.oracle);
        assertTrue(first.oracle != address(0));
        assertTrue(first.oracle != third.oracle);

        assertEq(factory.oracleForPair(_oraclePairKey(6, 6)), first.oracle);
        assertEq(factory.oracleForPair(_oraclePairKey(6, 18)), third.oracle);
    }

    /// @notice Verifies that one deployment returns the expected addresses, market parameters, and oracle price.
    /// @dev It creates one system, checks the returned deployment addresses and Morpho market params, and confirms the
    /// 6-decimal oracle resolves to the expected 1e36 collateral price when both assets are priced at one dollar.
    /// Use this test to confirm the core bootstrap wiring is creating the intended USDC/XUSD market without a registry.
    function testDeploymentFlowAndMarketCorrectness() public {
        DeploymentData memory deployed =
            _createDeployment(deployer, address(xusdSixA), INITIAL_CAP_6_DECIMALS, bytes32("A"));

        MarketParams memory marketParams = morpho.idToMarketParams(Id.wrap(deployed.marketId));
        assertEq(marketParams.loanToken, address(xusdSixA));
        assertEq(marketParams.collateralToken, address(usdc));
        assertEq(marketParams.oracle, deployed.oracle);
        assertEq(marketParams.irm, address(irm));
        assertEq(marketParams.lltv, FIXED_LLTV);

        Market memory market = morpho.market(Id.wrap(deployed.marketId));
        assertTrue(market.lastUpdate != 0);
        assertEq(IOracle(deployed.oracle).price(), 1e36);
        AmolisVaultController controllerContract = AmolisVaultController(deployed.controller);
        assertEq(controllerContract.owner(), deployer);
        assertEq(controllerContract.FACTORY(), address(factory));
        assertEq(address(controllerContract.vault()), deployed.vault);
        assertEq(controllerContract.adapter(), deployed.adapter);
    }

    /// @notice Verifies that the created vault is wired to one adapter, one liquidity path, fixed gates, and aligned caps.
    /// @dev It reads the deployed vault configuration, compares the stored liquidity data against the market params, and
    /// checks the three absolute and relative caps created during bootstrap.
    /// Use this test to confirm the vault came up in the intended single-market, least-risk configuration.
    function testVaultBootstrapCorrectness() public {
        DeploymentData memory deployed =
            _createDeployment(deployer, address(xusdSixA), INITIAL_CAP_6_DECIMALS, bytes32("A"));

        IVaultV2 vault = IVaultV2(deployed.vault);
        MarketParams memory marketParams = _marketParams(address(xusdSixA), deployed.oracle);
        bytes memory adapterIdData = _adapterIdData(deployed.adapter);
        bytes memory collateralIdData = _collateralIdData();
        bytes memory marketIdData = _marketIdData(deployed.adapter, marketParams);
        AmolisVaultController controller = AmolisVaultController(deployed.controller);

        assertEq(vault.owner(), deployed.controller);
        assertEq(vault.curator(), deployed.controller);
        assertEq(vault.adaptersLength(), 1);
        assertTrue(vault.isAdapter(deployed.adapter));
        assertEq(vault.liquidityAdapter(), deployed.adapter);
        assertEq(keccak256(vault.liquidityData()), keccak256(abi.encode(marketParams)));
        assertEq(vault.maxRate(), MAX_MAX_RATE);
        assertFalse(vault.isAllocator(address(factory)));
        assertFalse(vault.isAllocator(deployed.controller));
        assertEq(vault.receiveSharesGate(), deployed.controller);
        assertEq(vault.sendAssetsGate(), deployed.controller);
        assertEq(vault.sendSharesGate(), address(0));
        assertEq(vault.receiveAssetsGate(), address(0));
        assertTrue(controller.depositWhitelistEnabled());
        assertTrue(controller.isDepositor(deployer));

        assertEq(vault.relativeCap(keccak256(adapterIdData)), WAD);
        assertEq(vault.relativeCap(keccak256(collateralIdData)), WAD);
        assertEq(vault.relativeCap(keccak256(marketIdData)), WAD);

        assertEq(vault.absoluteCap(keccak256(adapterIdData)), INITIAL_CAP_6_DECIMALS);
        assertEq(vault.absoluteCap(keccak256(collateralIdData)), INITIAL_CAP_6_DECIMALS);
        assertEq(vault.absoluteCap(keccak256(marketIdData)), INITIAL_CAP_6_DECIMALS);
        assertEq(address(controller.vault()), deployed.vault);
        assertEq(controller.adapter(), deployed.adapter);
    }

    /// @notice Verifies that the controller can update only the intended safe settings and keeps the three caps aligned.
    /// @dev It updates the fee recipient, performance fee, total cap, and ERC20 metadata through the controller, then
    /// inspects the vault state to confirm every safe mutation was applied as expected.
    /// Use this test to confirm the user-facing admin surface is narrow but functional.
    function testControllerPermissions() public {
        DeploymentData memory deployed =
            _createDeployment(deployer, address(xusdEighteen), INITIAL_CAP_18_DECIMALS, bytes32("A"));

        AmolisVaultController controller = AmolisVaultController(deployed.controller);
        IVaultV2 vault = IVaultV2(deployed.vault);
        MarketParams memory marketParams = _marketParams(address(xusdEighteen), deployed.oracle);
        bytes memory adapterIdData = _adapterIdData(deployed.adapter);
        bytes memory collateralIdData = _collateralIdData();
        bytes memory marketIdData = _marketIdData(deployed.adapter, marketParams);

        vm.startPrank(deployer);
        controller.setDepositor(feeRecipient, true);
        controller.setDepositWhitelistEnabled(true);
        controller.setPerformanceFeeRecipient(feeRecipient);
        controller.setPerformanceFee(PERFORMANCE_FEE);
        controller.setTotalCap(2_000_000e18);
        controller.setTotalCap(500_000e18);
        controller.setVaultName("Amolis XUSD");
        controller.setVaultSymbol("amXUSD");
        vm.stopPrank();

        assertEq(vault.performanceFeeRecipient(), feeRecipient);
        assertEq(vault.performanceFee(), PERFORMANCE_FEE);
        assertEq(vault.absoluteCap(keccak256(adapterIdData)), 500_000e18);
        assertEq(vault.absoluteCap(keccak256(collateralIdData)), 500_000e18);
        assertEq(vault.absoluteCap(keccak256(marketIdData)), 500_000e18);
        assertEq(vault.name(), "Amolis XUSD");
        assertEq(vault.symbol(), "amXUSD");

        vm.prank(bob);
        vm.expectRevert(AmolisVaultController.Unauthorized.selector);
        controller.setVaultName("bad");
    }

    /// @notice Verifies that deposits start owner-only, can be widened or opened later, and withdrawals remain open.
    /// @dev It confirms a non-owner deposit reverts on a fresh deployment, lets the owner deposit, then allowlists and
    /// later removes another depositor before confirming that user can still withdraw successfully.
    /// Use this test to confirm the fixed gate policy matches the least-risk deposit requirements.
    function testGateBehavior() public {
        DeploymentData memory deployed =
            _createDeployment(deployer, address(xusdEighteen), INITIAL_CAP_18_DECIMALS, bytes32("A"));

        AmolisVaultController controller = AmolisVaultController(deployed.controller);
        IVaultV2 vault = IVaultV2(deployed.vault);

        deal(address(xusdEighteen), alice, 1_000e18);
        vm.startPrank(alice);
        xusdEighteen.approve(deployed.vault, type(uint256).max);
        vm.expectRevert(VaultErrorsLib.CannotReceiveShares.selector);
        vault.deposit(100e18, alice);
        vm.stopPrank();

        deal(address(xusdEighteen), deployer, 1_000e18);
        vm.startPrank(deployer);
        xusdEighteen.approve(deployed.vault, type(uint256).max);
        uint256 ownerShares = vault.deposit(100e18, deployer);
        controller.setDepositor(alice, true);
        vm.stopPrank();

        assertGt(ownerShares, 0);
        assertGt(vault.balanceOf(deployer), 0);

        vm.startPrank(alice);
        xusdEighteen.approve(deployed.vault, type(uint256).max);
        uint256 mintedShares = vault.deposit(100e18, alice);
        vm.stopPrank();

        assertGt(mintedShares, 0);
        assertGt(vault.balanceOf(alice), 0);

        deal(address(xusdEighteen), bob, 100e18);
        vm.startPrank(bob);
        xusdEighteen.approve(deployed.vault, type(uint256).max);
        vm.expectRevert(VaultErrorsLib.CannotReceiveShares.selector);
        vault.deposit(10e18, bob);
        vm.stopPrank();

        vm.prank(deployer);
        controller.setDepositor(alice, false);

        uint256 aliceAssetsBefore = xusdEighteen.balanceOf(alice);
        vm.prank(alice);
        vault.withdraw(50e18, alice, alice);
        assertEq(xusdEighteen.balanceOf(alice), aliceAssetsBefore + 50e18);

        vm.prank(deployer);
        controller.setDepositWhitelistEnabled(false);

        vm.startPrank(bob);
        vault.deposit(10e18, bob);
        vm.stopPrank();
    }

    /// @notice Verifies the vault owner surface is inaccessible to the deployment EOA: only the controller may curate.
    /// @dev The human owner controls the controller contract; they are not the vault's `owner` or `curator`, so direct
    /// curator or owner calls from that EOA must revert as `Unauthorized`.
    /// Use this test to confirm the bootstrap wires access control as intended without relying on selector abdication.
    function testLockdownBehavior() public {
        DeploymentData memory deployed =
            _createDeployment(deployer, address(xusdSixA), INITIAL_CAP_6_DECIMALS, bytes32("A"));

        IVaultV2 vault = IVaultV2(deployed.vault);

        vm.prank(deployer);
        vm.expectRevert(VaultErrorsLib.Unauthorized.selector);
        vault.setCurator(bob);

        vm.prank(deployer);
        vm.expectRevert(VaultErrorsLib.Unauthorized.selector);
        vault.submit(abi.encodeCall(IVaultV2.addAdapter, (address(0xBEEF))));

        vm.prank(deployer);
        vm.expectRevert(VaultErrorsLib.Unauthorized.selector);
        vault.setLiquidityAdapterAndData(address(0), hex"");
    }

    /// @notice Verifies that the factory can bootstrap multiple independent deployments for the same XUSD token.
    /// @dev It deploys twice with the same XUSD and different salts, then checks both deployments were created and that
    /// they reuse the same oracle and Morpho market while keeping vault, adapter, and controller addresses distinct.
    /// Use this test to confirm removing the on-chain deployment registry still preserves isolated vault deployments.
    function testDuplicateXusdDeploymentAllowed() public {
        DeploymentData memory first =
            _createDeployment(deployer, address(xusdSixA), INITIAL_CAP_6_DECIMALS, bytes32("A"));
        DeploymentData memory second =
            _createDeployment(deployer, address(xusdSixA), INITIAL_CAP_6_DECIMALS, bytes32("B"));

        assertEq(first.oracle, second.oracle);
        assertEq(first.marketId, second.marketId);
        assertTrue(first.vault != second.vault);
        assertTrue(first.adapter != second.adapter);
        assertTrue(first.controller != second.controller);
    }

    /// @dev Creates one deployment as the requested owner and returns the deployed addresses to the caller.
    /// Use this helper inside tests when you want a concise way to bootstrap a fresh Amolis system.
    /// @param owner Address pranked as `msg.sender` for `factory.createAmolis` (becomes controller owner).
    /// @param xusd Loan token address passed to the factory.
    /// @param initialTotalCap Initial absolute cap in `xusd` decimals, forwarded to controller bootstrap.
    /// @param salt Salt for vault address derivation.
    /// @return deployed Struct packing oracle, market id, vault, adapter, and controller from the factory call.
    function _createDeployment(address owner, address xusd, uint256 initialTotalCap, bytes32 salt)
        internal
        returns (DeploymentData memory deployed)
    {
        vm.prank(owner);
        (deployed.oracle, deployed.marketId, deployed.vault, deployed.adapter, deployed.controller) =
            factory.createAmolis(xusd, initialTotalCap, salt);
    }

    /// @dev Rebuilds the fixed market params used by the factory so tests can compare market ids and liquidity data.
    /// Use this helper whenever a test needs the canonical USDC/XUSD market definition for one deployment.
    /// @param xusd Loan token address for the market tuple.
    /// @param oracleAddress Oracle address matching the deployment under test.
    /// @return params Market params consistent with `FIXED_LLTV`, fixture `irm`, and fixture `usdc`.
    function _marketParams(address xusd, address oracleAddress) internal view returns (MarketParams memory) {
        return MarketParams({
            loanToken: xusd, collateralToken: address(usdc), oracle: oracleAddress, irm: address(irm), lltv: FIXED_LLTV
        });
    }

    /// @dev Rebuilds the oracle pair key the factory uses to store reusable oracle addresses.
    /// Use this helper when a test needs to inspect `oracleForPair` directly.
    /// @param usdcDecimals Collateral token decimals for the key.
    /// @param xusdDecimals Loan token decimals for the key.
    /// @return key Same value as `AmolisFactory.oraclePairKey(usdcDecimals, xusdDecimals)`.
    function _oraclePairKey(uint8 usdcDecimals, uint8 xusdDecimals) internal pure returns (bytes32) {
        return keccak256(abi.encode(usdcDecimals, xusdDecimals));
    }

    /// @dev Rebuilds the adapter-wide cap payload used by the controller and vault absolute-cap checks.
    /// Use this helper when a test needs to inspect the adapter-level cap entry.
    /// @param adapter Adapter contract address under test.
    /// @return idData Encoded adapter cap id payload `abi.encode("this", adapter)`.
    function _adapterIdData(address adapter) internal pure returns (bytes memory) {
        return abi.encode("this", adapter);
    }

    /// @dev Rebuilds the collateral-wide cap payload used by the controller and vault absolute-cap checks.
    /// Use this helper when a test needs to inspect the collateral-level cap entry.
    /// @return idData Encoded collateral cap id `abi.encode("collateralToken", address(usdc))`.
    function _collateralIdData() internal view returns (bytes memory) {
        return abi.encode("collateralToken", address(usdc));
    }

    /// @dev Rebuilds the exact market cap payload used by the controller and vault absolute-cap checks.
    /// Use this helper when a test needs to inspect the market-specific cap entry or liquidity data.
    /// @param adapter Adapter contract address tied to the market cap slot.
    /// @param marketParams Full Morpho market parameters for the exact-market cap id.
    /// @return idData Encoded market cap id payload `abi.encode("this/marketParams", adapter, marketParams)`.
    function _marketIdData(address adapter, MarketParams memory marketParams) internal pure returns (bytes memory) {
        return abi.encode("this/marketParams", adapter, marketParams);
    }
}
