// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "@forge-std/Test.sol";
import {Id, IMorpho, Market, MarketParams, Position} from "@morpho-blue/src/interfaces/IMorpho.sol";
import {IIrm} from "@morpho-blue/src/interfaces/IIrm.sol";
import {IOracle} from "@morpho-blue/src/interfaces/IOracle.sol";
import {MarketParamsLib} from "@morpho-blue/src/libraries/MarketParamsLib.sol";
import {MathLib} from "@morpho-blue/src/libraries/MathLib.sol";
import {MorphoBalancesLib} from "@morpho-blue/src/libraries/periphery/MorphoBalancesLib.sol";
import {ORACLE_PRICE_SCALE} from "@morpho-blue/src/libraries/ConstantsLib.sol";
import {IVaultV2} from "@morpho-vault/src/interfaces/IVaultV2.sol";
import {IERC20} from "@morpho-vault/src/interfaces/IERC20.sol";
import {MAX_MAX_RATE, WAD} from "@morpho-vault/src/libraries/ConstantsLib.sol";
import {ErrorsLib as VaultErrorsLib} from "@morpho-vault/src/libraries/ErrorsLib.sol";
import {IMorphoMarketV1AdapterV2} from "@morpho-vault/src/adapters/interfaces/IMorphoMarketV1AdapterV2.sol";

import {AmolisFactory} from "../../src/AmolisFactory.sol";
import {AmolisVaultController} from "../../src/AmolisVaultController.sol";
import {XUsdMock} from "../mocks/XUsdMock.sol";

/// @notice Minimal view into the Era2 deployer deployer used only to resolve the live adapter factory on mainnet forks.
interface IEra2Deployer5Deployer {
    /// @notice Returns the Era2 deployer contract one hop away from the known deployer-deployer address.
    /// @return era2 Address of the Era2 deployer holding Morpho peripheral factories.
    function era2Deployer5() external view returns (address era2);
}

/// @notice Minimal view into the Era2 deployer for discovering `MorphoMarketV1AdapterV2Factory` on a fork.
interface IEra2Deployer5 {
    /// @notice Returns the canonical Morpho Market V1 Adapter V2 factory used with live Morpho on mainnet.
    /// @return adapterFactoryAddr Adapter factory address passed into `AmolisFactory` on the fork.
    function morphoMarketV1AdapterV2Factory() external view returns (address adapterFactoryAddr);
}

/// @notice End-to-end Amolis flows against live Morpho, USDC, and Chainlink on an Ethereum mainnet fork.
/// @dev Configure `MAINNET_RPC_URL` in the process environment; optionally set `MAINNET_FORK_BLOCK` for a pinned block.
contract AmolisMainnetForkTest is Test {
    using MathLib for uint256;
    using MarketParamsLib for MarketParams;
    using MorphoBalancesLib for IMorpho;

    struct DeploymentData {
        address oracle;
        bytes32 marketId;
        address vault;
        address adapter;
        address controller;
    }

    uint256 internal constant FIXED_LLTV = 94.5e16;
    uint256 internal constant INITIAL_CAP = 1_000_000e18;
    uint256 internal constant LENDER_SUPPLY = 500_000e18;
    uint256 internal constant OWNER_DEPOSIT = 250_000e18;
    uint256 internal constant COLLATERAL_SUPPLY = 200_000e6;
    uint256 internal constant PERFORMANCE_FEE = 0.05 ether;
    uint256 internal constant BORROW_HEADROOM = 1e12;

    address internal constant MORPHO = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address internal constant VAULT_V2_FACTORY = 0xA1D94F746dEfa1928926b84fB2596c06926C0405;
    address internal constant CHAINLINK_ORACLE_V2_FACTORY = 0x3A7bB36Ee3f3eE32A60e9f2b33c1e5f2E83ad766;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant USDC_USD_FEED = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;
    address internal constant ERA2_DEPLOYER5_DEPLOYER = 0xeFb7e91bEaafc016955cf7FAa011318666485B45;

    address internal owner;
    address internal lender;
    address internal borrower;
    address internal alice;
    address internal feeRecipient;

    IMorpho internal morpho;
    IERC20 internal usdc;
    XUsdMock internal xusd;
    AmolisFactory internal factory;
    address internal adapterFactory;

    /// @notice Creates the Ethereum mainnet fork, deploys a fresh `XUsdMock` token, and wires Amolis to live infra.
    /// @dev It reads `MAINNET_RPC_URL` via cheatcodes, optionally pins the fork when `MAINNET_FORK_BLOCK` exists, and
    /// discovers the live Morpho Market V1 Adapter V2 Factory through the Era2 deployer before constructing the factory,
    /// and enables the adaptive curve IRM on Morpho when needed (94.5% LLTV is expected to already be enabled on mainnet).
    /// Run these tests with `forge test --profile mainnet-fork` after exporting the RPC URL.
    function setUp() public {
        owner = makeAddr("owner");
        lender = makeAddr("lender");
        borrower = makeAddr("borrower");
        alice = makeAddr("alice");
        feeRecipient = makeAddr("feeRecipient");

        _createFork();

        morpho = IMorpho(MORPHO);
        usdc = IERC20(USDC);
        adapterFactory = IEra2Deployer5(IEra2Deployer5Deployer(ERA2_DEPLOYER5_DEPLOYER).era2Deployer5())
            .morphoMarketV1AdapterV2Factory();

        address irm = _adaptiveCurveIrm();
        if (!morpho.isIrmEnabled(irm)) {
            vm.prank(morpho.owner());
            morpho.enableIrm(irm);
        }

        xusd = new XUsdMock(18);
        factory = new AmolisFactory(
            MORPHO, VAULT_V2_FACTORY, adapterFactory, CHAINLINK_ORACLE_V2_FACTORY, USDC, USDC_USD_FEED
        );
    }

    /// @notice Verifies Amolis deployment wiring, vault configuration, admin flow, and whitelist gates on a fork.
    /// @dev It deploys once, asserts oracle/market/vault/adapter topology and caps, checks non-whitelisted deposits revert,
    /// then walks owner-only admin actions (fee recipient, performance fee, cap changes, metadata, ownership transfer) and
    /// confirms the prior owner loses controller access after the handoff.
    /// Run with `forge test --match-contract AmolisMainnetForkTest --profile mainnet-fork` after setting `MAINNET_RPC_URL`.
    function testMainnetForkBootstrapAndAdminFlow() public {
        DeploymentData memory deployed = _createDeployment();
        AmolisVaultController controller = AmolisVaultController(deployed.controller);
        IVaultV2 vault = IVaultV2(deployed.vault);
        MarketParams memory marketParams = _marketParams(deployed.oracle);

        assertEq(factory.oracleForPair(factory.oraclePairKey(6, 18)), deployed.oracle);
        assertEq(morpho.idToMarketParams(Id.wrap(deployed.marketId)).loanToken, address(xusd));
        assertEq(morpho.idToMarketParams(Id.wrap(deployed.marketId)).collateralToken, USDC);
        assertEq(morpho.idToMarketParams(Id.wrap(deployed.marketId)).oracle, deployed.oracle);
        assertEq(morpho.idToMarketParams(Id.wrap(deployed.marketId)).irm, _adaptiveCurveIrm());
        assertEq(morpho.idToMarketParams(Id.wrap(deployed.marketId)).lltv, FIXED_LLTV);
        assertGt(IOracle(deployed.oracle).price(), 0);

        assertEq(vault.owner(), deployed.controller);
        assertEq(vault.curator(), deployed.controller);
        assertEq(vault.adaptersLength(), 1);
        assertTrue(vault.isAdapter(deployed.adapter));
        assertEq(vault.liquidityAdapter(), deployed.adapter);
        assertEq(keccak256(vault.liquidityData()), keccak256(abi.encode(marketParams)));
        assertEq(vault.maxRate(), MAX_MAX_RATE);
        assertEq(vault.receiveSharesGate(), deployed.controller);
        assertEq(vault.sendAssetsGate(), deployed.controller);
        assertTrue(controller.depositWhitelistEnabled());
        assertTrue(controller.isDepositor(owner));

        assertEq(vault.relativeCap(keccak256(_adapterIdData(deployed.adapter))), WAD);
        assertEq(vault.relativeCap(keccak256(_collateralIdData())), WAD);
        assertEq(vault.relativeCap(keccak256(_marketIdData(deployed.adapter, marketParams))), WAD);
        assertEq(vault.absoluteCap(keccak256(_adapterIdData(deployed.adapter))), INITIAL_CAP);
        assertEq(vault.absoluteCap(keccak256(_collateralIdData())), INITIAL_CAP);
        assertEq(vault.absoluteCap(keccak256(_marketIdData(deployed.adapter, marketParams))), INITIAL_CAP);

        deal(address(xusd), alice, 1_000e18);
        vm.startPrank(alice);
        xusd.approve(deployed.vault, type(uint256).max);
        vm.expectRevert(VaultErrorsLib.CannotReceiveShares.selector);
        vault.deposit(100e18, alice);
        vm.stopPrank();

        vm.startPrank(owner);
        controller.setDepositor(alice, true);
        controller.setDepositor(feeRecipient, true);
        controller.setPerformanceFeeRecipient(feeRecipient);
        controller.setPerformanceFee(PERFORMANCE_FEE);
        controller.setTotalCap(INITIAL_CAP / 2);
        controller.setTotalCap(INITIAL_CAP);
        controller.setVaultName("Amolis Mainnet");
        controller.setVaultSymbol("AMS");
        controller.transferOwnership(alice);
        vm.stopPrank();

        assertEq(vault.performanceFeeRecipient(), feeRecipient);
        assertEq(vault.performanceFee(), PERFORMANCE_FEE);
        assertEq(vault.name(), "Amolis Mainnet");
        assertEq(vault.symbol(), "AMS");
        assertEq(controller.owner(), alice);
        assertTrue(controller.isDepositor(alice));

        vm.prank(owner);
        vm.expectRevert(AmolisVaultController.Unauthorized.selector);
        controller.setVaultName("stale");
    }

    /// @notice Exercises the full Amolis lender-to-borrower loop from vault deposit through Morpho borrow and unwind.
    /// @dev Market liquidity comes only from `IVaultV2.deposit` through the vault liquidity adapter, then the borrower
    /// supplies USDC collateral, borrows up to just below the live 94.5% LLTV ceiling, accrues interest, repays, and
    /// finally proves vault deallocation still works on withdraw after a second depositor joins.
    /// Use this test to verify the fork flow end to end without bypassing the vault via direct `morpho.supply`.
    function testMainnetForkMarketLifecycleAndVaultFlow() public {
        DeploymentData memory deployed = _createDeployment();
        AmolisVaultController controller = AmolisVaultController(deployed.controller);
        IVaultV2 vault = IVaultV2(deployed.vault);
        IMorphoMarketV1AdapterV2 adapter = IMorphoMarketV1AdapterV2(deployed.adapter);
        MarketParams memory marketParams = _marketParams(deployed.oracle);

        vm.prank(owner);
        controller.setDepositor(lender, true);
        _depositVaultAndAllocate(deployed, vault, lender, LENDER_SUPPLY);

        assertGe(adapter.expectedSupplyAssets(deployed.marketId), LENDER_SUPPLY - 1e18);
        assertGt(morpho.position(Id.wrap(deployed.marketId), deployed.adapter).supplyShares, 0);
        assertGt(vault.balanceOf(lender), 0);

        _supplyBorrowerCollateral(marketParams);

        uint256 maxBorrowCapacity = _maxBorrowCapacity(marketParams, borrower);
        uint256 borrowAssets = maxBorrowCapacity - BORROW_HEADROOM;
        assertGt(maxBorrowCapacity, borrowAssets);
        assertGt(LENDER_SUPPLY, maxBorrowCapacity);

        uint256 borrowRateBefore =
            IIrm(marketParams.irm).borrowRateView(marketParams, morpho.market(Id.wrap(deployed.marketId)));
        uint256 expectedSupplyBeforeAccrual = adapter.expectedSupplyAssets(deployed.marketId);

        vm.prank(borrower);
        morpho.borrow(marketParams, borrowAssets, 0, borrower, borrower);

        uint256 debtAfterBorrow = morpho.expectedBorrowAssets(marketParams, borrower);
        assertLe(debtAfterBorrow, maxBorrowCapacity);
        assertEq(debtAfterBorrow, borrowAssets);

        uint256 headroomToLltv = maxBorrowCapacity - debtAfterBorrow;
        vm.prank(borrower);
        vm.expectRevert("insufficient collateral");
        morpho.borrow(marketParams, headroomToLltv + 1, 0, borrower, borrower);

        uint256 borrowRateAfter =
            IIrm(marketParams.irm).borrowRateView(marketParams, morpho.market(Id.wrap(deployed.marketId)));
        Position memory borrowedPosition = morpho.position(Id.wrap(deployed.marketId), borrower);
        Market memory marketAfterBorrow = morpho.market(Id.wrap(deployed.marketId));
        uint256 expectedBorrowBeforeAccrual = morpho.expectedBorrowAssets(marketParams, borrower);

        assertEq(xusd.balanceOf(borrower), borrowAssets);
        assertGt(borrowedPosition.borrowShares, 0);
        assertEq(borrowedPosition.collateral, COLLATERAL_SUPPLY);
        assertGt(marketAfterBorrow.totalBorrowAssets, 0);
        assertEq(marketAfterBorrow.totalSupplyAssets, LENDER_SUPPLY);
        assertGe(borrowRateAfter, borrowRateBefore);
        assertEq(marketParams.lltv, FIXED_LLTV);

        skip(7 days);
        morpho.accrueInterest(marketParams);

        uint256 expectedBorrowAfterAccrual = morpho.expectedBorrowAssets(marketParams, borrower);
        uint256 expectedSupplyAfterAccrual = adapter.expectedSupplyAssets(deployed.marketId);

        assertGt(expectedBorrowAfterAccrual, expectedBorrowBeforeAccrual);
        assertGt(expectedSupplyAfterAccrual, expectedSupplyBeforeAccrual);

        vm.prank(borrower);
        xusd.approve(MORPHO, type(uint256).max);
        vm.prank(borrower);
        morpho.repay(marketParams, expectedBorrowBeforeAccrual / 2, 0, borrower, hex"");

        uint256 debtAfterPartialRepay = morpho.expectedBorrowAssets(marketParams, borrower);
        assertLt(debtAfterPartialRepay, expectedBorrowAfterAccrual);

        vm.prank(borrower);
        vm.expectRevert("insufficient collateral");
        morpho.withdrawCollateral(marketParams, COLLATERAL_SUPPLY, borrower, borrower);

        uint128 borrowShares = morpho.position(Id.wrap(deployed.marketId), borrower).borrowShares;
        // Repay-by-shares pulls slightly more loan assets than `expectedBorrowAssets` after prior accruals; top up so
        // the closing `transferFrom` cannot revert on dust interest vs. the partial-repay balance.
        uint256 owedToClose = morpho.expectedBorrowAssets(marketParams, borrower);
        uint256 borrowerBal = xusd.balanceOf(borrower);
        if (borrowerBal < owedToClose) {
            xusd.mint(borrower, owedToClose - borrowerBal + 1e12);
        }

        vm.prank(borrower);
        morpho.repay(marketParams, 0, borrowShares, borrower, hex"");

        assertEq(morpho.expectedBorrowAssets(marketParams, borrower), 0);

        vm.prank(borrower);
        morpho.withdrawCollateral(marketParams, COLLATERAL_SUPPLY, borrower, borrower);
        assertEq(usdc.balanceOf(borrower), COLLATERAL_SUPPLY);

        deal(address(xusd), owner, OWNER_DEPOSIT);
        vm.startPrank(owner);
        xusd.approve(deployed.vault, type(uint256).max);
        uint256 ownerShares = vault.deposit(OWNER_DEPOSIT, owner);
        vm.stopPrank();
        assertGt(ownerShares, 0);

        vm.prank(owner);
        controller.setDepositWhitelistEnabled(false);

        deal(address(xusd), alice, 1_000e18);
        vm.startPrank(alice);
        xusd.approve(deployed.vault, type(uint256).max);
        vault.deposit(500e18, alice);
        vm.stopPrank();

        uint256 adapterAssetsBeforeWithdraw = adapter.expectedSupplyAssets(deployed.marketId);
        uint256 ownerAssetsBeforeWithdraw = xusd.balanceOf(owner);

        vm.prank(owner);
        vault.withdraw(OWNER_DEPOSIT / 2, owner, owner);

        assertGt(xusd.balanceOf(owner), ownerAssetsBeforeWithdraw);
        assertLt(adapter.expectedSupplyAssets(deployed.marketId), adapterAssetsBeforeWithdraw);
    }

    /// @notice Selects a mainnet fork URL from the environment and optionally pins it to `MAINNET_FORK_BLOCK`.
    /// @dev It requires `MAINNET_RPC_URL`; when `MAINNET_FORK_BLOCK` is unset, the fork follows the RPC latest block.
    /// Call from `setUp` only; missing env vars surface as Foundry cheatcode failures.
    function _createFork() internal {
        string memory rpcUrl = vm.envString("MAINNET_RPC_URL");
        if (vm.envExists("MAINNET_FORK_BLOCK")) {
            vm.createSelectFork(rpcUrl, vm.envUint("MAINNET_FORK_BLOCK"));
        } else {
            vm.createSelectFork(rpcUrl);
        }
    }

    /// @notice Bootstraps one Amolis deployment on the fork and returns all created addresses.
    /// @dev Pranks `owner` and calls `factory.createAmolis` with `xusd`, `INITIAL_CAP`, and a fixed salt label.
    /// @return deployed Oracle, Morpho market id, vault, adapter, and controller from the factory.
    function _createDeployment() internal returns (DeploymentData memory deployed) {
        vm.prank(owner);
        (deployed.oracle, deployed.marketId, deployed.vault, deployed.adapter, deployed.controller) =
            factory.createAmolis(address(xusd), INITIAL_CAP, bytes32("MAINNET"));
    }

    /// @notice Rebuilds canonical market params for the deployed oracle and mock XUSD token.
    /// @param oracle Morpho oracle address from the deployment under test.
    /// @return params Market tuple using fork `USDC`, live adaptive curve IRM, and `FIXED_LLTV`.
    function _marketParams(address oracle) internal view returns (MarketParams memory) {
        return MarketParams({
            loanToken: address(xusd), collateralToken: USDC, oracle: oracle, irm: _adaptiveCurveIrm(), lltv: FIXED_LLTV
        });
    }

    /// @notice Reads the adaptive curve IRM address from the live adapter factory discovered in `setUp`.
    /// @dev Uses `staticcall` to `adapterFactory` because only the return data is needed for assertions and market structs.
    /// @return irm IRM address returned by `adaptiveCurveIrm()` on the mainnet adapter factory.
    function _adaptiveCurveIrm() internal view returns (address irm) {
        (bool success, bytes memory data) = adapterFactory.staticcall(abi.encodeWithSignature("adaptiveCurveIrm()"));
        require(success, "adapter factory irm lookup failed");
        irm = abi.decode(data, (address));
    }

    /// @notice Mints mock XUSD to a whitelisted depositor and routes it into Morpho by depositing through the vault.
    /// @dev It funds the depositor, approves the vault, and calls `deposit`, which makes `VaultV2` invoke its configured
    /// liquidity adapter so the adapter supplies into the Amolis market on behalf of the vault system.
    /// Use this helper whenever the fork test needs to seed market liquidity through the real Amolis deposit path.
    /// @param deployed Deployment struct containing at least `vault` for approvals and deposits.
    /// @param vault Vault instance receiving the deposit and routing liquidity through its adapter.
    /// @param depositor Account that receives mock XUSD via `deal`, approves, and calls `deposit`.
    /// @param assets Loan-token amount to deposit in `xusd` decimals.
    function _depositVaultAndAllocate(DeploymentData memory deployed, IVaultV2 vault, address depositor, uint256 assets)
        internal
    {
        deal(address(xusd), depositor, assets);
        vm.startPrank(depositor);
        xusd.approve(deployed.vault, type(uint256).max);
        vault.deposit(assets, depositor);
        vm.stopPrank();
    }

    /// @notice Funds the borrower with USDC and posts it as collateral in the live Morpho market.
    /// @dev It deals the fixed collateral amount, approves Morpho, and calls `supplyCollateral` so later borrow checks
    /// use the exact same on-chain collateral state that Morpho health checks read.
    /// Use this helper before computing borrow capacity or attempting any borrow in the fork flow.
    /// @param marketParams Morpho market identifying USDC collateral and the loan asset for `supplyCollateral`.
    function _supplyBorrowerCollateral(MarketParams memory marketParams) internal {
        deal(USDC, borrower, COLLATERAL_SUPPLY);
        vm.startPrank(borrower);
        usdc.approve(MORPHO, type(uint256).max);
        morpho.supplyCollateral(marketParams, COLLATERAL_SUPPLY, borrower, hex"");
        vm.stopPrank();
    }

    /// @notice Returns the maximum loan assets Morpho allows for `borrowerAddr` from its live collateral and oracle price.
    /// @dev It mirrors Morpho Blue's `_isHealthy` capacity formula by converting posted collateral into loan-token value
    /// with the market oracle and then applying `lltv`, so the test can assert success below the boundary and failure above it.
    /// Use this helper after collateral is supplied when the test needs the exact LLTV-derived borrow ceiling.
    /// @param marketParams Market whose oracle price and `lltv` define the borrow bound.
    /// @param borrowerAddr Account whose Morpho position collateral is read for the capacity calculation.
    /// @return capacity Maximum borrowable loan assets implied by collateral, oracle price, and LLTV (floor division).
    function _maxBorrowCapacity(MarketParams memory marketParams, address borrowerAddr)
        internal
        view
        returns (uint256)
    {
        uint256 collateralPrice = IOracle(marketParams.oracle).price();
        uint256 collateral = morpho.position(marketParams.id(), borrowerAddr).collateral;
        return collateral.mulDivDown(collateralPrice, ORACLE_PRICE_SCALE).wMulDown(marketParams.lltv);
    }

    /// @notice Rebuilds adapter-level cap id data for assertions.
    /// @param adapter Adapter address from the deployment under test.
    /// @return idData Encoded adapter cap id `abi.encode("this", adapter)`.
    function _adapterIdData(address adapter) internal pure returns (bytes memory) {
        return abi.encode("this", adapter);
    }

    /// @notice Rebuilds collateral-level cap id data for assertions.
    /// @return idData Encoded collateral cap id `abi.encode("collateralToken", USDC)`.
    function _collateralIdData() internal pure returns (bytes memory) {
        return abi.encode("collateralToken", USDC);
    }

    /// @notice Rebuilds exact-market cap id data for assertions.
    /// @param adapter Adapter address bound into the market cap id.
    /// @param marketParams Market parameters bound into the market cap id.
    /// @return idData Encoded exact-market cap id `abi.encode("this/marketParams", adapter, marketParams)`.
    function _marketIdData(address adapter, MarketParams memory marketParams) internal pure returns (bytes memory) {
        return abi.encode("this/marketParams", adapter, marketParams);
    }
}
