// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "@forge-std/Test.sol";
import {Id, IMorpho, MarketParams} from "@morpho-blue/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "@morpho-blue/src/libraries/MarketParamsLib.sol";
import {Morpho} from "@morpho-blue/src/Morpho.sol";
import {AdaptiveCurveIrm} from "@morpho-blue-irm/src/adaptive-curve-irm/AdaptiveCurveIrm.sol";
import {MorphoChainlinkOracleV2Factory} from "@morpho-oracles/src/morpho-chainlink/MorphoChainlinkOracleV2Factory.sol";
import {MorphoMarketV1AdapterV2Factory} from "@morpho-vault/src/adapters/MorphoMarketV1AdapterV2Factory.sol";
import {VaultV2Factory} from "@morpho-vault/src/VaultV2Factory.sol";
import {IVaultV2} from "@morpho-vault/src/interfaces/IVaultV2.sol";

import {ChainlinkAggregatorMock} from "../lib/morpho-blue-oracles/test/mocks/ChainlinkAggregatorMock.sol";
import {ERC20Mock} from "../lib/vault-v2/test/mocks/ERC20Mock.sol";
import {AmolisFactory} from "../src/AmolisFactory.sol";
import {AmolisVaultController} from "../src/AmolisVaultController.sol";

contract AmolisBootstrapTest is Test {
    using MarketParamsLib for MarketParams;

    address internal morphoOwner;
    address internal deploymentOwner;

    IMorpho internal morpho;
    AdaptiveCurveIrm internal irm;
    VaultV2Factory internal vaultV2Factory;
    MorphoMarketV1AdapterV2Factory internal adapterFactory;
    MorphoChainlinkOracleV2Factory internal oracleFactory;
    ERC20Mock internal usdc;
    ERC20Mock internal xusd;
    ChainlinkAggregatorMock internal usdcFeed;
    AmolisFactory internal factory;

    uint256 internal constant FIXED_LLTV = 94.5e16;
    uint256 internal constant INITIAL_CAP = 1_000_000e18;

    /// @notice Deploys the shared Morpho, vault, and oracle dependencies used by the controller bootstrap smoke tests.
    /// @dev It enables the adaptive curve IRM and the fixed LLTV once, then creates one USDC token, one XUSD token,
    /// and the Amolis factory under test.
    /// Use this setup implicitly through Foundry before each test in this file.
    function setUp() public {
        morphoOwner = makeAddr("morphoOwner");
        deploymentOwner = makeAddr("deploymentOwner");

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
        xusd = new ERC20Mock(18);

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

    /// @notice Verifies that the factory now deploys the controller first and the controller owns vault initialization.
    /// @dev It creates one Amolis deployment, then checks the controller-recorded factory, vault, and adapter along
    /// with the VaultV2Factory record keyed by the controller address and bootstrap salt.
    /// Use this test to confirm the refactor moved vault deployment into the controller without changing final outputs.
    function testControllerOwnsVaultInitializationFlow() public {
        vm.prank(deploymentOwner);
        (address oracle, bytes32 marketId, address vault, address adapter, address controllerAddress) =
            factory.createAmolis(address(xusd), INITIAL_CAP, bytes32("BOOTSTRAP"));

        AmolisVaultController controller = AmolisVaultController(controllerAddress);

        assertTrue(oracle != address(0));
        assertTrue(marketId != bytes32(0));
        assertEq(controller.FACTORY(), address(factory));
        assertEq(address(controller.vault()), vault);
        assertEq(controller.adapter(), adapter);
        assertTrue(controller.depositWhitelistEnabled());
        assertTrue(controller.isDepositor(deploymentOwner));
        assertEq(vaultV2Factory.vaultV2(controllerAddress, address(xusd), bytes32("BOOTSTRAP")), vault);
        assertEq(IVaultV2(vault).owner(), controllerAddress);
        assertEq(IVaultV2(vault).curator(), controllerAddress);
    }

    /// @notice Verifies that `initialize` can only be called by the deploying factory and only once.
    /// @dev It deploys a controller directly from the test contract so the test contract becomes the allowed factory,
    /// then confirms a foreign caller is rejected and a second initialize call reverts after the first succeeds.
    /// Use this test to confirm the controller bootstrap entrypoint cannot be replayed or hijacked.
    function testControllerInitializeIsFactoryOnlyAndSingleUse() public {
        MarketParams memory marketParams = MarketParams({
            loanToken: address(xusd),
            collateralToken: address(usdc),
            oracle: address(0xBEEF),
            irm: address(irm),
            lltv: FIXED_LLTV
        });

        morpho.createMarket(marketParams);
        bytes32 marketId = Id.unwrap(marketParams.id());

        AmolisVaultController controller = new AmolisVaultController(
            deploymentOwner, address(vaultV2Factory), address(adapterFactory), address(morpho), marketId
        );

        vm.prank(makeAddr("outsider"));
        vm.expectRevert(AmolisVaultController.NotFactory.selector);
        controller.initialize(INITIAL_CAP, bytes32("BOOTSTRAP"));

        (address vault, address adapter) = controller.initialize(INITIAL_CAP, bytes32("BOOTSTRAP"));
        assertTrue(vault != address(0));
        assertTrue(adapter != address(0));

        vm.expectRevert(AmolisVaultController.AlreadyInitialized.selector);
        controller.initialize(INITIAL_CAP, bytes32("BOOTSTRAP-2"));
    }
}
