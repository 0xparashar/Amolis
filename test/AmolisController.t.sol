// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "@forge-std/Test.sol";
import {Vm} from "@forge-std/Vm.sol";
import {Id, IMorpho, MarketParams} from "@morpho-blue/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "@morpho-blue/src/libraries/MarketParamsLib.sol";
import {Morpho} from "@morpho-blue/src/Morpho.sol";
import {ErrorsLib as VaultErrorsLib} from "@morpho-vault/src/libraries/ErrorsLib.sol";
import {IVaultV2} from "@morpho-vault/src/interfaces/IVaultV2.sol";
import {MAX_PERFORMANCE_FEE} from "@morpho-vault/src/libraries/ConstantsLib.sol";
import {MorphoMarketV1AdapterV2Factory} from "@morpho-vault/src/adapters/MorphoMarketV1AdapterV2Factory.sol";
import {VaultV2Factory} from "@morpho-vault/src/VaultV2Factory.sol";
import {MorphoChainlinkOracleV2Factory} from "@morpho-oracles/src/morpho-chainlink/MorphoChainlinkOracleV2Factory.sol";
import {AdaptiveCurveIrm} from "@morpho-blue-irm/src/adaptive-curve-irm/AdaptiveCurveIrm.sol";

import {ERC20Mock} from "../lib/vault-v2/test/mocks/ERC20Mock.sol";
import {ChainlinkAggregatorMock} from "../lib/morpho-blue-oracles/test/mocks/ChainlinkAggregatorMock.sol";
import {AmolisFactory} from "../src/AmolisFactory.sol";
import {AmolisVaultController} from "../src/AmolisVaultController.sol";

contract AmolisControllerTest is Test {
    using MarketParamsLib for MarketParams;

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

    struct DeploymentData {
        address oracle;
        bytes32 marketId;
        address vault;
        address adapter;
        address controller;
    }

    uint256 internal constant FIXED_LLTV = 94.5e16;
    uint256 internal constant INITIAL_CAP = 1_000_000e18;
    uint256 internal constant PERFORMANCE_FEE = 0.1 ether;

    address internal morphoOwner;
    address internal owner;
    address internal alice;
    address internal bob;
    address internal feeRecipient;

    IMorpho internal morpho;
    AdaptiveCurveIrm internal irm;
    VaultV2Factory internal vaultV2Factory;
    MorphoMarketV1AdapterV2Factory internal adapterFactory;
    MorphoChainlinkOracleV2Factory internal oracleFactory;
    ERC20Mock internal usdc;
    ERC20Mock internal xusd;
    ChainlinkAggregatorMock internal usdcFeed;
    AmolisFactory internal factory;

    /// @notice Sets up the shared local Morpho deployment, factories, tokens, and Amolis factory used by the
    /// deterministic controller branch tests.
    /// @dev It mirrors the production bootstrap path with mock dependencies so each test can cheaply create a fresh
    /// Amolis deployment or a raw controller instance without relying on a fork.
    /// Use this setup implicitly through Foundry before running any test in this file.
    function setUp() public {
        morphoOwner = makeAddr("morphoOwner");
        owner = makeAddr("owner");
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

    /// @notice Verifies that the factory constructor rejects zero-valued protocol dependencies.
    /// @dev It deploys the factory repeatedly while zeroing one required constructor argument so each validation branch
    /// is exercised directly by the unit test.
    /// Use this test to confirm deployments cannot be misconfigured with missing live protocol addresses.
    function testFactoryConstructorZeroAddressReverts() public {
        vm.expectRevert(AmolisFactory.ZeroAddress.selector);
        new AmolisFactory(
            address(0),
            address(vaultV2Factory),
            address(adapterFactory),
            address(oracleFactory),
            address(usdc),
            address(usdcFeed)
        );

        vm.expectRevert(AmolisFactory.ZeroAddress.selector);
        new AmolisFactory(
            address(morpho),
            address(0),
            address(adapterFactory),
            address(oracleFactory),
            address(usdc),
            address(usdcFeed)
        );

        vm.expectRevert(AmolisFactory.ZeroAddress.selector);
        new AmolisFactory(
            address(morpho),
            address(vaultV2Factory),
            address(0),
            address(oracleFactory),
            address(usdc),
            address(usdcFeed)
        );

        vm.expectRevert(AmolisFactory.ZeroAddress.selector);
        new AmolisFactory(
            address(morpho),
            address(vaultV2Factory),
            address(adapterFactory),
            address(0),
            address(usdc),
            address(usdcFeed)
        );

        vm.expectRevert(AmolisFactory.ZeroAddress.selector);
        new AmolisFactory(
            address(morpho),
            address(vaultV2Factory),
            address(adapterFactory),
            address(oracleFactory),
            address(0),
            address(usdcFeed)
        );

        vm.expectRevert(AmolisFactory.ZeroAddress.selector);
        new AmolisFactory(
            address(morpho),
            address(vaultV2Factory),
            address(adapterFactory),
            address(oracleFactory),
            address(usdc),
            address(0)
        );
    }

    /// @notice Verifies that the controller constructor rejects zero-valued bootstrap inputs and unknown markets.
    /// @dev It registers one Morpho market, then creates raw controller deployments with missing owner, missing
    /// factories, zero Morpho address, zero market id, or a market id that does not exist on Morpho.
    /// Use this test to confirm a controller cannot be deployed in an unusable partially configured state.
    function testControllerConstructorZeroAddressReverts() public {
        MarketParams memory params = _marketParams(address(xusd), address(0xBEEF));
        morpho.createMarket(params);
        bytes32 validMarketId = Id.unwrap(params.id());

        vm.expectRevert(AmolisVaultController.ZeroAddress.selector);
        new AmolisVaultController(
            address(0), address(vaultV2Factory), address(adapterFactory), address(morpho), validMarketId
        );

        vm.expectRevert(AmolisVaultController.ZeroAddress.selector);
        new AmolisVaultController(owner, address(0), address(adapterFactory), address(morpho), validMarketId);

        vm.expectRevert(AmolisVaultController.ZeroAddress.selector);
        new AmolisVaultController(owner, address(vaultV2Factory), address(0), address(morpho), validMarketId);

        vm.expectRevert(AmolisVaultController.ZeroAddress.selector);
        new AmolisVaultController(owner, address(vaultV2Factory), address(adapterFactory), address(0), validMarketId);

        vm.expectRevert(AmolisVaultController.ZeroAddress.selector);
        new AmolisVaultController(owner, address(vaultV2Factory), address(adapterFactory), address(morpho), bytes32(0));

        vm.expectRevert(AmolisVaultController.ZeroAddress.selector);
        new AmolisVaultController(
            owner, address(vaultV2Factory), address(adapterFactory), address(morpho), keccak256("no such market")
        );
    }

    /// @notice Verifies that the factory emits the oracle-registration and deployment events on first bootstrap.
    /// @dev It precomputes the oracle key and market id, then checks the indexed event topics emitted during the first
    /// deployment of a new decimals pair.
    /// Use this test to confirm off-chain indexers can observe the canonical bootstrap events.
    function testFactoryEmitsDeploymentEvents() public {
        bytes32 oracleKey = factory.oraclePairKey(usdc.decimals(), xusd.decimals());

        vm.expectEmit(true, false, false, false, address(factory));
        emit OracleRegistered(oracleKey, address(0), 0, 0);

        vm.expectEmit(true, true, false, false, address(factory));
        emit AmolisCreated(address(xusd), owner, bytes32(0), address(0), address(0), address(0), address(0));

        vm.prank(owner);
        factory.createAmolis(address(xusd), INITIAL_CAP, bytes32("EVENTS"));
    }

    /// @notice Verifies that the decimals-pair key helper is deterministic for the same pair and distinct for a new
    /// pair.
    /// @dev It computes the key multiple times across different decimals tuples and compares the resulting hashes.
    /// Use this test to confirm oracle reuse depends only on token decimals.
    function testOraclePairKeyIsDeterministic() public view {
        bytes32 first = factory.oraclePairKey(6, 18);
        bytes32 second = factory.oraclePairKey(6, 18);
        bytes32 third = factory.oraclePairKey(6, 6);

        assertEq(first, second);
        assertTrue(first != third);
    }

    /// @notice Verifies that creating a deployment with the zero XUSD address is rejected.
    /// @dev It calls the public factory entrypoint directly with a zero loan token and expects the dedicated custom
    /// error before any protocol side effects occur.
    /// Use this test to confirm bootstrap always targets a real loan token contract.
    function testCreateAmolisZeroXusdReverts() public {
        vm.prank(owner);
        vm.expectRevert(AmolisFactory.ZeroAddress.selector);
        factory.createAmolis(address(0), INITIAL_CAP, bytes32("ZERO"));
    }

    /// @notice Verifies that ownership transfer rejects unauthorized callers and zero-address recipients.
    /// @dev It boots one deployment, then exercises both guarded branches on the controller's ownership transfer path.
    /// Use this test to confirm only the current owner can hand control to another address.
    function testTransferOwnershipGuards() public {
        AmolisVaultController controller = AmolisVaultController(_createDeployment().controller);

        vm.prank(alice);
        vm.expectRevert(AmolisVaultController.Unauthorized.selector);
        controller.transferOwnership(alice);

        vm.prank(owner);
        vm.expectRevert(AmolisVaultController.ZeroAddress.selector);
        controller.transferOwnership(address(0));
    }

    /// @notice Verifies that ownership transfer allowlists the new owner so deposits still work after the handoff.
    /// @dev It transfers ownership once and checks both the stored owner and the controller-local depositor mapping.
    /// Use this test to confirm the safe deposit policy remains intact across ownership rotation.
    function testTransferOwnershipAllowlistsNewOwner() public {
        AmolisVaultController controller = AmolisVaultController(_createDeployment().controller);

        vm.prank(owner);
        controller.transferOwnership(alice);

        assertEq(controller.owner(), alice);
        assertTrue(controller.isDepositor(alice));
    }

    /// @notice Verifies that post-bootstrap owner functions reject callers before initialization is complete.
    /// @dev It deploys a raw controller without calling `initialize`, then exercises the guarded not-initialized branch
    /// on the representative owner entrypoints.
    /// Use this test to confirm raw controllers cannot silently accept owner mutations before bootstrap finishes.
    function testOwnerFunctionsRevertWhenNotInitialized() public {
        AmolisVaultController controller = _deployUninitializedController();

        vm.prank(owner);
        vm.expectRevert(AmolisVaultController.NotInitialized.selector);
        controller.setPerformanceFee(PERFORMANCE_FEE);

        vm.prank(owner);
        vm.expectRevert(AmolisVaultController.NotInitialized.selector);
        controller.setPerformanceFeeRecipient(feeRecipient);

        vm.prank(owner);
        vm.expectRevert(AmolisVaultController.NotInitialized.selector);
        controller.setTotalCap(INITIAL_CAP);

        vm.prank(owner);
        vm.expectRevert(AmolisVaultController.NotInitialized.selector);
        controller.setDepositWhitelistEnabled(false);

        vm.prank(owner);
        vm.expectRevert(AmolisVaultController.NotInitialized.selector);
        controller.setVaultName("name");

        vm.prank(owner);
        vm.expectRevert(AmolisVaultController.NotInitialized.selector);
        controller.setVaultSymbol("sym");
    }

    /// @notice Verifies that the controller rejects unauthorized callers across the restricted owner surface.
    /// @dev It boots one deployment, then has a foreign caller attempt each state-changing owner function.
    /// Use this test to confirm the controller never exposes privileged vault settings to non-owners.
    function testUnauthorizedOwnerFunctionsRevert() public {
        AmolisVaultController controller = AmolisVaultController(_createDeployment().controller);

        vm.startPrank(alice);
        vm.expectRevert(AmolisVaultController.Unauthorized.selector);
        controller.setPerformanceFee(PERFORMANCE_FEE);

        vm.expectRevert(AmolisVaultController.Unauthorized.selector);
        controller.setPerformanceFeeRecipient(feeRecipient);

        vm.expectRevert(AmolisVaultController.Unauthorized.selector);
        controller.setTotalCap(INITIAL_CAP / 2);

        vm.expectRevert(AmolisVaultController.Unauthorized.selector);
        controller.setDepositWhitelistEnabled(false);

        vm.expectRevert(AmolisVaultController.Unauthorized.selector);
        controller.setDepositor(alice, true);

        vm.expectRevert(AmolisVaultController.Unauthorized.selector);
        controller.setVaultName("bad");

        vm.expectRevert(AmolisVaultController.Unauthorized.selector);
        controller.setVaultSymbol("bad");
        vm.stopPrank();
    }

    /// @notice Verifies that enabling fees while whitelist mode is active requires an allowlisted fee recipient.
    /// @dev It first attempts to enable fees with the default zero recipient, then configures an allowlisted recipient
    /// and confirms the happy path succeeds.
    /// Use this test to confirm fee minting cannot be directed toward a blocked share recipient.
    function testSetPerformanceFeeEnforcesRecipientCompatibility() public {
        DeploymentData memory deployed = _createDeployment();
        AmolisVaultController controller = AmolisVaultController(deployed.controller);
        IVaultV2 vault = IVaultV2(deployed.vault);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(AmolisVaultController.FeeRecipientNotAllowed.selector, address(0)));
        controller.setPerformanceFee(PERFORMANCE_FEE);

        vm.startPrank(owner);
        controller.setDepositor(feeRecipient, true);
        controller.setPerformanceFeeRecipient(feeRecipient);
        controller.setPerformanceFee(PERFORMANCE_FEE);
        vm.stopPrank();

        assertEq(vault.performanceFeeRecipient(), feeRecipient);
        assertEq(vault.performanceFee(), PERFORMANCE_FEE);
    }

    /// @notice Verifies that changing the fee recipient while fees are active requires the new recipient to be
    /// allowlisted.
    /// @dev It turns fees on with a valid recipient, then attempts to switch to an unapproved recipient and expects the
    /// dedicated custom error.
    /// Use this test to confirm fee-recipient changes preserve the whitelist invariant once fees are live.
    function testSetPerformanceFeeRecipientRejectsBlockedRecipientWhenFeeIsActive() public {
        AmolisVaultController controller = AmolisVaultController(_createDeployment().controller);

        vm.startPrank(owner);
        controller.setDepositor(feeRecipient, true);
        controller.setPerformanceFeeRecipient(feeRecipient);
        controller.setPerformanceFee(PERFORMANCE_FEE);
        vm.expectRevert(abi.encodeWithSelector(AmolisVaultController.FeeRecipientNotAllowed.selector, bob));
        controller.setPerformanceFeeRecipient(bob);
        vm.stopPrank();
    }

    /// @notice Verifies that re-enabling whitelist mode rejects a currently configured active fee recipient that is no
    /// longer allowlisted.
    /// @dev It disables whitelist mode to configure an incompatible active fee recipient, then tries to switch the
    /// whitelist back on and expects the compatibility guard to fire.
    /// Use this test to confirm whitelist activation cannot strand fee shares at a blocked address.
    function testSetDepositWhitelistEnabledRejectsIncompatibleActiveFeeRecipient() public {
        AmolisVaultController controller = AmolisVaultController(_createDeployment().controller);

        vm.startPrank(owner);
        controller.setDepositWhitelistEnabled(false);
        controller.setPerformanceFeeRecipient(bob);
        controller.setPerformanceFee(PERFORMANCE_FEE);
        vm.expectRevert(abi.encodeWithSelector(AmolisVaultController.FeeRecipientNotAllowed.selector, bob));
        controller.setDepositWhitelistEnabled(true);
        vm.stopPrank();
    }

    /// @notice Verifies that removing an active fee recipient from the depositor set is blocked while whitelist mode
    /// and fees are both active.
    /// @dev It turns on fees for an allowlisted recipient and then attempts to remove that recipient from the whitelist.
    /// Use this test to confirm the controller preserves fee minting compatibility across depositor updates.
    function testSetDepositorRejectsRemovingActiveFeeRecipient() public {
        AmolisVaultController controller = AmolisVaultController(_createDeployment().controller);

        vm.startPrank(owner);
        controller.setDepositor(feeRecipient, true);
        controller.setPerformanceFeeRecipient(feeRecipient);
        controller.setPerformanceFee(PERFORMANCE_FEE);
        vm.expectRevert(abi.encodeWithSelector(AmolisVaultController.FeeRecipientNotAllowed.selector, feeRecipient));
        controller.setDepositor(feeRecipient, false);
        vm.stopPrank();
    }

    /// @notice Verifies that depositor updates reject the zero address and that the share and asset gating helpers
    /// expose both their open and restricted branches.
    /// @dev It checks the zero-address guard, then flips whitelist mode on and off while querying the gate view
    /// functions for allowlisted and non-allowlisted accounts.
    /// Use this test to confirm the controller's fixed gates match the intended deposit policy.
    function testDepositorZeroAddressAndGateViews() public {
        AmolisVaultController controller = AmolisVaultController(_createDeployment().controller);

        vm.prank(owner);
        vm.expectRevert(AmolisVaultController.ZeroAddress.selector);
        controller.setDepositor(address(0), true);

        assertTrue(controller.canReceiveShares(owner));
        assertTrue(controller.canSendAssets(owner));
        assertFalse(controller.canReceiveShares(alice));
        assertFalse(controller.canSendAssets(alice));

        vm.prank(owner);
        controller.setDepositWhitelistEnabled(false);

        assertTrue(controller.canReceiveShares(alice));
        assertTrue(controller.canSendAssets(alice));
    }

    /// @notice Verifies the equal-value no-op, increase, decrease, and cap-mismatch branches of `setTotalCap`.
    /// @dev It first exercises the no-op and normal update paths, then corrupts one absolute-cap entry directly in test
    /// storage so the controller detects a desynchronized cap triplet and reverts with `CapMismatch`.
    /// Use this test to confirm the single user-facing cap stays mirrored across all three enforced ids.
    function testSetTotalCapBranchesAndCapMismatch() public {
        DeploymentData memory deployed = _createDeployment();
        AmolisVaultController controller = AmolisVaultController(deployed.controller);
        IVaultV2 vault = IVaultV2(deployed.vault);
        bytes32 adapterId = keccak256(_adapterIdData(deployed.adapter));
        bytes32 collateralId = keccak256(_collateralIdData());
        bytes32 marketId = keccak256(_marketIdData(deployed.adapter, _marketParams(address(xusd), deployed.oracle)));

        vm.startPrank(owner);
        controller.setTotalCap(INITIAL_CAP);
        controller.setTotalCap(2 * INITIAL_CAP);
        controller.setTotalCap(INITIAL_CAP / 2);
        vm.stopPrank();

        assertEq(vault.absoluteCap(adapterId), INITIAL_CAP / 2);
        assertEq(vault.absoluteCap(collateralId), INITIAL_CAP / 2);
        assertEq(vault.absoluteCap(marketId), INITIAL_CAP / 2);

        // Raise only the collateral cap via the real vault path. `stdstore` on `absoluteCap(bytes32)` is unsafe here
        // because Caps packs absoluteCap with relativeCap in one word; a blind write corrupts storage and can panic.
        bytes memory increaseCollateral =
            abi.encodeCall(IVaultV2.increaseAbsoluteCap, (_collateralIdData(), INITIAL_CAP));
        vm.startPrank(address(controller));
        vault.submit(increaseCollateral);
        (bool collateralOk,) = address(vault).call(increaseCollateral);
        vm.stopPrank();
        assertTrue(collateralOk);
        assertEq(vault.absoluteCap(collateralId), INITIAL_CAP);
        assertEq(vault.absoluteCap(adapterId), INITIAL_CAP / 2);

        vm.prank(owner);
        vm.expectRevert(AmolisVaultController.CapMismatch.selector);
        controller.setTotalCap(INITIAL_CAP / 4);
    }

    /// @notice Verifies that the metadata setters succeed for the owner and leave the configured values on the vault.
    /// @dev It updates the ERC20 share name and symbol through the controller after bootstrap and reads them back from
    /// the managed vault.
    /// Use this test to confirm the narrow metadata customization surface still works post-lockdown.
    function testVaultMetadataHappyPath() public {
        DeploymentData memory deployed = _createDeployment();
        AmolisVaultController controller = AmolisVaultController(deployed.controller);
        IVaultV2 vault = IVaultV2(deployed.vault);

        vm.startPrank(owner);
        controller.setVaultName("Amolis Vault");
        controller.setVaultSymbol("AMV");
        vm.stopPrank();

        assertEq(vault.name(), "Amolis Vault");
        assertEq(vault.symbol(), "AMV");
    }

    /// @notice Verifies that `initialize` rejects any caller other than the immutable factory address captured at deploy.
    /// @dev It deploys a raw controller from the test harness, pranks a third party, and expects `NotFactory` before any vault exists.
    /// Use this test to lock the single-shot bootstrap entrypoint to the Amolis factory address.
    function testInitializeOnlyFactoryMayCallInitialize() public {
        AmolisVaultController controller = _deployUninitializedController();

        vm.prank(alice);
        vm.expectRevert(AmolisVaultController.NotFactory.selector);
        controller.initialize(INITIAL_CAP, bytes32("INIT"));
    }

    /// @notice Verifies that vault configuration errors bubble through the controller's submit-and-execute helper.
    /// @dev It configures a valid performance fee recipient, then attempts to set a fee above `MAX_PERFORMANCE_FEE` so VaultV2 reverts and `_revertWith` rethrows the payload.
    /// Use this test to ensure curator shortcuts surface the same errors as direct vault calls.
    function testSetPerformanceFeeBubblesVaultFeeTooHigh() public {
        AmolisVaultController controller = AmolisVaultController(_createDeployment().controller);

        vm.startPrank(owner);
        controller.setDepositor(feeRecipient, true);
        controller.setPerformanceFeeRecipient(feeRecipient);
        vm.expectRevert(VaultErrorsLib.FeeTooHigh.selector);
        controller.setPerformanceFee(MAX_PERFORMANCE_FEE + 1);
        vm.stopPrank();
    }

    /// @notice Verifies that transferring ownership to an already-allowlisted account does not emit a redundant depositor event.
    /// @dev It allowlists `alice`, records logs during `transferOwnership`, and asserts no `DepositorUpdated` topic appears because `isDepositor` was already true.
    /// Use this test to cover the guarded branch inside `transferOwnership` that skips duplicate allowlisting work.
    function testTransferOwnershipSkipsDepositorUpdatedWhenNewOwnerAlreadyAllowlisted() public {
        AmolisVaultController controller = AmolisVaultController(_createDeployment().controller);

        vm.startPrank(owner);
        controller.setDepositor(alice, true);
        vm.recordLogs();
        controller.transferOwnership(alice);
        vm.stopPrank();

        bytes32 depositorTopic = keccak256("DepositorUpdated(address,bool)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool sawDepositorUpdated;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == depositorTopic) {
                sawDepositorUpdated = true;
                break;
            }
        }
        assertFalse(sawDepositorUpdated);
        assertEq(controller.owner(), alice);
    }

    /// @notice Verifies that turning on performance fees while whitelist mode stays enabled requires the configured recipient to be allowlisted first.
    /// @dev It sets the fee recipient without adding them to the depositor map, then expects `FeeRecipientNotAllowed` when fees become non-zero.
    /// Use this test to cover the whitelist gate inside `setPerformanceFee` independently of the recipient setter path.
    function testSetPerformanceFeeRejectsDisallowedRecipientUnderWhitelist() public {
        AmolisVaultController controller = AmolisVaultController(_createDeployment().controller);

        vm.startPrank(owner);
        controller.setPerformanceFeeRecipient(bob);
        vm.expectRevert(abi.encodeWithSelector(AmolisVaultController.FeeRecipientNotAllowed.selector, bob));
        controller.setPerformanceFee(PERFORMANCE_FEE);
        vm.stopPrank();
    }

    /// @notice Creates one Amolis deployment and returns the deployed addresses for subsequent branch tests.
    /// @dev It calls the public factory entrypoint as the configured owner so the deployment mirrors production
    /// bootstrap exactly and all controller guards can be exercised afterward.
    /// Use this helper whenever a test needs a fully initialized controller, vault, and market.
    function _createDeployment() internal returns (DeploymentData memory deployed) {
        vm.prank(owner);
        (deployed.oracle, deployed.marketId, deployed.vault, deployed.adapter, deployed.controller) =
            factory.createAmolis(address(xusd), INITIAL_CAP, bytes32("CTRL"));
    }

    /// @notice Deploys a raw controller without running its one-time `initialize` step.
    /// @dev It constructs the controller directly from the test contract so owner-method not-initialized guards can be
    /// exercised without creating a vault or adapter.
    /// Use this helper whenever a test specifically targets the pre-bootstrap controller state.
    function _deployUninitializedController() internal returns (AmolisVaultController controller) {
        MarketParams memory params = _marketParams(address(xusd), address(0xBEEF));
        morpho.createMarket(params);
        controller = new AmolisVaultController(
            owner, address(vaultV2Factory), address(adapterFactory), address(morpho), Id.unwrap(params.id())
        );
    }

    /// @notice Rebuilds the market params the Amolis factory uses for the given XUSD and oracle.
    /// @dev It keeps the unit tests aligned with the production market tuple so market ids and cap ids stay
    /// deterministic across helper calls.
    /// Use this helper whenever a test needs the canonical Amolis market definition.
    /// @param xusdAddress Loan token address for the market tuple.
    /// @param oracleAddress Oracle address for the market tuple (may be a placeholder when only the id is needed).
    /// @return params Canonical `MarketParams` using fixture `usdc`, `irm`, and `FIXED_LLTV`.
    function _marketParams(address xusdAddress, address oracleAddress) internal view returns (MarketParams memory) {
        return MarketParams({
            loanToken: xusdAddress,
            collateralToken: address(usdc),
            oracle: oracleAddress,
            irm: address(irm),
            lltv: FIXED_LLTV
        });
    }

    /// @notice Rebuilds the adapter id payload that the controller and vault use for adapter-wide cap tracking.
    /// @dev It encodes the same discriminator and adapter address as the production controller helper so storage reads
    /// and writes target the exact same cap entry.
    /// Use this helper whenever a test needs to inspect or mutate the adapter cap directly.
    /// @param adapter Adapter address deployed for the deployment under test.
    /// @return idData Encoded adapter cap id `abi.encode("this", adapter)`.
    function _adapterIdData(address adapter) internal pure returns (bytes memory) {
        return abi.encode("this", adapter);
    }

    /// @notice Rebuilds the collateral id payload that the controller and vault use for collateral-wide cap tracking.
    /// @dev It encodes the fixed USDC collateral token exactly as the production controller helper does.
    /// Use this helper whenever a test needs to inspect or mutate the collateral cap directly.
    /// @return idData Encoded collateral cap id `abi.encode("collateralToken", address(usdc))`.
    function _collateralIdData() internal view returns (bytes memory) {
        return abi.encode("collateralToken", address(usdc));
    }

    /// @notice Rebuilds the market id payload that the controller and vault use for exact-market cap tracking.
    /// @dev It encodes the adapter and the canonical market params so the derived storage key matches production.
    /// Use this helper whenever a test needs to inspect or mutate the market-specific cap directly.
    /// @param adapter Adapter address for the encoded market cap id.
    /// @param marketParams Full Morpho market parameters paired with `adapter` in the encoding.
    /// @return idData Encoded exact-market cap id `abi.encode("this/marketParams", adapter, marketParams)`.
    function _marketIdData(address adapter, MarketParams memory marketParams) internal pure returns (bytes memory) {
        return abi.encode("this/marketParams", adapter, marketParams);
    }
}
