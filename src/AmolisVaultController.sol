// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.21;

import {Id, IMorpho, MarketParams} from "@morpho-blue/src/interfaces/IMorpho.sol";
import {
    IMorphoMarketV1AdapterV2Factory
} from "@morpho-vault/src/adapters/interfaces/IMorphoMarketV1AdapterV2Factory.sol";
import {IReceiveSharesGate, ISendAssetsGate} from "@morpho-vault/src/interfaces/IGate.sol";
import {IVaultV2} from "@morpho-vault/src/interfaces/IVaultV2.sol";
import {IVaultV2Factory} from "@morpho-vault/src/interfaces/IVaultV2Factory.sol";
import {MAX_MAX_RATE, WAD} from "@morpho-vault/src/libraries/ConstantsLib.sol";

/**
 * @title AmolisVaultController
 * @notice Permanent owner and curator of one Amolis VaultV2: narrow owner-gated configuration and deposit whitelist gates.
 */
contract AmolisVaultController is IReceiveSharesGate, ISendAssetsGate {
    //// Immutable State Variables ////
    address public immutable FACTORY;
    IVaultV2Factory public immutable VAULT_V2_FACTORY;
    IMorphoMarketV1AdapterV2Factory public immutable MORPHO_MARKET_V1_ADAPTER_V2_FACTORY;
    IMorpho public immutable MORPHO;
    bytes32 public immutable MARKET_ID;

    //// State Variables ////
    IVaultV2 public vault;
    address public adapter;
    address public owner;
    bool public depositWhitelistEnabled;
    mapping(address account => bool) public isDepositor;

    //// Errors ////
    error AlreadyInitialized();
    error CapMismatch();
    error FeeRecipientNotAllowed(address recipient);
    error NotFactory();
    error NotInitialized();
    error Unauthorized();
    error ZeroAddress();

    //// Events ////
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event Initialized(address indexed vault, address indexed adapter, uint256 initialTotalCap, bytes32 indexed salt);
    event PerformanceFeeUpdated(uint256 newPerformanceFee);
    event PerformanceFeeRecipientUpdated(address indexed newRecipient);
    event TotalCapUpdated(uint256 newTotalCap);
    event DepositWhitelistEnabledUpdated(bool enabled);
    event DepositorUpdated(address indexed account, bool isAllowed);
    event VaultNameUpdated(string newName);
    event VaultSymbolUpdated(string newSymbol);

    /// @notice Stores the immutable bootstrap dependencies and Morpho market identity this controller will govern.
    /// @dev It records the factory that may call `initialize`, the factories needed to deploy the vault stack, and the
    /// Morpho market id whose params are loaded from `IMorpho.idToMarketParams` for cap ids and liquidity wiring.
    /// Deploy this only from `AmolisFactory` after the market exists on Morpho, then have that factory call
    /// `initialize` once to finish bootstrap.
    /// @param _initialOwner Account that becomes `owner`, is allowlisted as depositor, and receives `OwnershipTransferred`.
    /// @param _vaultV2FactoryAddress VaultV2 factory the controller calls during `initialize` to deploy the vault.
    /// @param _morphoMarketV1AdapterV2FactoryAddress Adapter factory used once in `initialize` to deploy the market adapter.
    /// @param _morphoAddress Morpho Blue instance; must expose a fully populated market for `_marketId`.
    /// @param _marketId Morpho market id (`bytes32`); loan/collateral/oracle/irm must be non-zero on `_morphoAddress`.
    constructor(
        address _initialOwner,
        address _vaultV2FactoryAddress,
        address _morphoMarketV1AdapterV2FactoryAddress,
        address _morphoAddress,
        bytes32 _marketId
    ) {
        if (
            _initialOwner == address(0) || _vaultV2FactoryAddress == address(0)
                || _morphoMarketV1AdapterV2FactoryAddress == address(0) || _morphoAddress == address(0)
        ) {
            revert ZeroAddress();
        }
        if (_marketId == bytes32(0)) revert ZeroAddress();

        IMorpho morpho = IMorpho(_morphoAddress);
        MarketParams memory marketParams = morpho.idToMarketParams(Id.wrap(_marketId));
        if (
            marketParams.loanToken == address(0) || marketParams.collateralToken == address(0)
                || marketParams.oracle == address(0) || marketParams.irm == address(0)
        ) revert ZeroAddress();

        owner = _initialOwner;
        FACTORY = msg.sender;
        VAULT_V2_FACTORY = IVaultV2Factory(_vaultV2FactoryAddress);
        MORPHO_MARKET_V1_ADAPTER_V2_FACTORY = IMorphoMarketV1AdapterV2Factory(_morphoMarketV1AdapterV2FactoryAddress);
        MORPHO = morpho;
        MARKET_ID = _marketId;
        depositWhitelistEnabled = true;
        isDepositor[_initialOwner] = true;

        emit OwnershipTransferred(address(0), _initialOwner);
        emit DepositWhitelistEnabledUpdated(true);
        emit DepositorUpdated(_initialOwner, true);
    }

    /// @notice Finishes the Amolis bootstrap by deploying the vault and locking it into one adapter and one market.
    /// @dev Only the deploying factory may call this once; it creates the vault and adapter and configures the fixed
    /// caps, gates, and liquidity path before returning.
    /// Call this only from `AmolisFactory.createAmolis` immediately after deploying the controller.
    /// @param _initialTotalCap Initial absolute cap in loan-token units mirrored across adapter, collateral, and market caps.
    /// @param _salt Salt forwarded to VaultV2Factory for deterministic vault addressing.
    /// @return vaultAddress Deployed VaultV2 owned by this controller.
    /// @return adapterAddress Deployed Morpho market adapter registered on the vault.
    function initialize(uint256 _initialTotalCap, bytes32 _salt)
        external
        returns (address vaultAddress, address adapterAddress)
    {
        if (msg.sender != FACTORY) revert NotFactory();
        if (address(vault) != address(0)) revert AlreadyInitialized();

        MarketParams memory marketParams = _marketParams();

        vaultAddress = VAULT_V2_FACTORY.createVaultV2(address(this), marketParams.loanToken, _salt);
        vault = IVaultV2(vaultAddress);
        vault.setCurator(address(this));

        adapterAddress = MORPHO_MARKET_V1_ADAPTER_V2_FACTORY.createMorphoMarketV1AdapterV2(vaultAddress);
        adapter = adapterAddress;

        bytes memory adapterIdData = _adapterIdData();
        bytes memory collateralIdData = _collateralIdData();
        bytes memory marketIdData = _marketIdData();
        bytes memory liquidityData = abi.encode(marketParams);

        _submitAndExecuteVault(abi.encodeCall(IVaultV2.addAdapter, (adapterAddress)));
        _submitAndExecuteVault(abi.encodeCall(IVaultV2.setIsAllocator, (address(this), true)));
        _submitAndExecuteVault(abi.encodeCall(IVaultV2.setReceiveSharesGate, (address(this))));
        _submitAndExecuteVault(abi.encodeCall(IVaultV2.setSendAssetsGate, (address(this))));

        _submitAndExecuteVault(abi.encodeCall(IVaultV2.increaseRelativeCap, (adapterIdData, WAD)));
        _submitAndExecuteVault(abi.encodeCall(IVaultV2.increaseRelativeCap, (collateralIdData, WAD)));
        _submitAndExecuteVault(abi.encodeCall(IVaultV2.increaseRelativeCap, (marketIdData, WAD)));

        _submitAndExecuteVault(abi.encodeCall(IVaultV2.increaseAbsoluteCap, (adapterIdData, _initialTotalCap)));
        _submitAndExecuteVault(abi.encodeCall(IVaultV2.increaseAbsoluteCap, (collateralIdData, _initialTotalCap)));
        _submitAndExecuteVault(abi.encodeCall(IVaultV2.increaseAbsoluteCap, (marketIdData, _initialTotalCap)));

        vault.setLiquidityAdapterAndData(adapterAddress, liquidityData);
        vault.setMaxRate(MAX_MAX_RATE);

        _submitAndExecuteVault(abi.encodeCall(IVaultV2.setIsAllocator, (address(this), false)));

        emit Initialized(vaultAddress, adapterAddress, _initialTotalCap, _salt);
    }

    /// @notice Transfers controller ownership to a new user without changing the vault owner contract.
    /// @dev The vault remains owned by this controller contract while only the controller's privileged caller changes,
    /// and the new owner is allowlisted so they can deposit immediately if whitelist mode stays enabled.
    /// Call this when you want another account to manage the safe Amolis settings exposed by this contract.
    /// @param _newOwner Next `owner`; auto-allowlisted for deposits if whitelist mode remains enabled.
    function transferOwnership(address _newOwner) external {
        if (msg.sender != owner) revert Unauthorized();
        if (_newOwner == address(0)) revert ZeroAddress();

        address previousOwner = owner;
        owner = _newOwner;
        if (!isDepositor[_newOwner]) {
            isDepositor[_newOwner] = true;
            emit DepositorUpdated(_newOwner, true);
        }

        emit OwnershipTransferred(previousOwner, _newOwner);
    }

    /// @notice Sets the vault performance fee through the controller's narrow curator surface.
    /// @dev It submits and executes the timelocked vault action in one transaction because the Amolis vault leaves
    /// this selector on a zero timelock, while also ensuring fee shares can still be received when whitelist mode is on.
    /// Call this after setting a valid fee recipient if you want the vault to charge an interest-based fee.
    /// @param _newPerformanceFee Performance fee in vault-native units forwarded to `IVaultV2.setPerformanceFee`.
    function setPerformanceFee(uint256 _newPerformanceFee) external {
        if (msg.sender != owner) revert Unauthorized();
        _requireInitialized();
        if (depositWhitelistEnabled && _newPerformanceFee != 0) {
            _requireAllowedFeeRecipient(vault.performanceFeeRecipient());
        }

        _submitAndExecuteVault(abi.encodeCall(IVaultV2.setPerformanceFee, (_newPerformanceFee)));
        emit PerformanceFeeUpdated(_newPerformanceFee);
    }

    /// @notice Sets the vault performance fee recipient through the controller's narrow curator surface.
    /// @dev It submits and executes the timelocked vault action and rejects a recipient that cannot receive shares while
    /// whitelist mode is active and fees are enabled.
    /// Call this before or after setting the fee when you want interest-fee shares minted to a different recipient.
    /// @param _newPerformanceFeeRecipient Address receiving performance-fee shares; must be allowlisted if whitelist and fees apply.
    function setPerformanceFeeRecipient(address _newPerformanceFeeRecipient) external {
        if (msg.sender != owner) revert Unauthorized();
        _requireInitialized();
        if (depositWhitelistEnabled && vault.performanceFee() != 0) {
            _requireAllowedFeeRecipient(_newPerformanceFeeRecipient);
        }

        _submitAndExecuteVault(abi.encodeCall(IVaultV2.setPerformanceFeeRecipient, (_newPerformanceFeeRecipient)));
        emit PerformanceFeeRecipientUpdated(_newPerformanceFeeRecipient);
    }

    /// @notice Updates the single user-facing total cap and mirrors it across the vault's three enforced adapter ids.
    /// @dev It validates that all three caps are aligned, then uses the increase or decrease path required by VaultV2
    /// so the adapter id, collateral id, and exact market id always stay synchronized.
    /// Call this whenever you want to raise or lower the maximum XUSD allocation allowed in the Amolis vault.
    /// @param _newTotalCap Target absolute cap applied in lockstep to adapter, collateral, and market cap slots.
    function setTotalCap(uint256 _newTotalCap) external {
        if (msg.sender != owner) revert Unauthorized();
        _requireInitialized();

        uint256 currentTotalCap = _currentTotalCap();
        bytes memory adapterIdData = _adapterIdData();
        bytes memory collateralIdData = _collateralIdData();
        bytes memory marketIdData = _marketIdData();

        if (_newTotalCap > currentTotalCap) {
            _submitAndExecuteVault(abi.encodeCall(IVaultV2.increaseAbsoluteCap, (adapterIdData, _newTotalCap)));
            _submitAndExecuteVault(abi.encodeCall(IVaultV2.increaseAbsoluteCap, (collateralIdData, _newTotalCap)));
            _submitAndExecuteVault(abi.encodeCall(IVaultV2.increaseAbsoluteCap, (marketIdData, _newTotalCap)));
        } else if (_newTotalCap < currentTotalCap) {
            vault.decreaseAbsoluteCap(adapterIdData, _newTotalCap);
            vault.decreaseAbsoluteCap(collateralIdData, _newTotalCap);
            vault.decreaseAbsoluteCap(marketIdData, _newTotalCap);
        }

        emit TotalCapUpdated(_newTotalCap);
    }

    /// @notice Enables or disables depositor whitelist enforcement for deposits and share receipts.
    /// @dev It flips a controller-local boolean that the fixed vault gates read, and it blocks activation when enabled
    /// fees would mint shares to a recipient that is not currently allowed.
    /// Call this to switch the Amolis vault between its default owner-only deposit mode and a wider deposit policy.
    /// @param _enabled When true, enforces `isDepositor` for share receipt and asset deposit; when false, gates are open.
    function setDepositWhitelistEnabled(bool _enabled) external {
        if (msg.sender != owner) revert Unauthorized();
        _requireInitialized();
        if (_enabled && vault.performanceFee() != 0) _requireAllowedFeeRecipient(vault.performanceFeeRecipient());

        depositWhitelistEnabled = _enabled;
        emit DepositWhitelistEnabledUpdated(_enabled);
    }

    /// @notice Marks an account as allowed or disallowed for deposits and share receipts when whitelist mode is enabled.
    /// @dev It updates the controller-local allowlist and prevents removing an active fee recipient while fee minting
    /// still depends on that recipient being able to receive shares.
    /// Call this before enabling whitelist mode or whenever you need to adjust the permitted depositor set.
    /// @param _account Address whose deposit/share eligibility is updated.
    /// @param _allowed When true, account may deposit and receive shares under whitelist mode; when false, blocked (subject to fee-recipient rules).
    function setDepositor(address _account, bool _allowed) external {
        if (msg.sender != owner) revert Unauthorized();
        if (_account == address(0)) revert ZeroAddress();
        if (
            !_allowed && depositWhitelistEnabled && address(vault) != address(0) && vault.performanceFee() != 0
                && vault.performanceFeeRecipient() == _account
        ) {
            revert FeeRecipientNotAllowed(_account);
        }

        isDepositor[_account] = _allowed;
        emit DepositorUpdated(_account, _allowed);
    }

    /// @notice Sets the VaultV2 name through the controller's owner surface.
    /// @dev It forwards directly to the vault owner function because the controller permanently owns the vault.
    /// Call this when you want to customize the ERC20 share name shown for the Amolis vault.
    /// @param _newName ERC-20 name string forwarded to `IVaultV2.setName`.
    function setVaultName(string calldata _newName) external {
        if (msg.sender != owner) revert Unauthorized();
        _requireInitialized();

        vault.setName(_newName);
        emit VaultNameUpdated(_newName);
    }

    /// @notice Sets the VaultV2 symbol through the controller's owner surface.
    /// @dev It forwards directly to the vault owner function because the controller permanently owns the vault.
    /// Call this when you want to customize the ERC20 share symbol shown for the Amolis vault.
    /// @param _newSymbol ERC-20 symbol string forwarded to `IVaultV2.setSymbol`.
    function setVaultSymbol(string calldata _newSymbol) external {
        if (msg.sender != owner) revert Unauthorized();
        _requireInitialized();

        vault.setSymbol(_newSymbol);
        emit VaultSymbolUpdated(_newSymbol);
    }

    /// @notice Returns whether an account can receive vault shares under the fixed Amolis deposit policy.
    /// @dev The vault reads this gate on deposits and share transfers, allowing everyone when whitelist mode is off and
    /// only explicitly allowed accounts when whitelist mode is on.
    /// The vault calls this automatically, and integrators can also query it off-chain before depositing or transferring.
    /// @param _account Address checked for share receipt eligibility.
    /// @return allowed True if whitelist is off or `_account` is in `isDepositor`.
    function canReceiveShares(address _account) external view returns (bool) {
        return !depositWhitelistEnabled || isDepositor[_account];
    }

    /// @notice Returns whether an account can send vault assets into the vault under the fixed Amolis deposit policy.
    /// @dev The vault reads this gate on deposits, allowing everyone when whitelist mode is off and only explicitly
    /// allowed accounts when whitelist mode is on.
    /// The vault calls this automatically, and integrators can also query it off-chain before depositing.
    /// @param _account Address checked for asset deposit eligibility.
    /// @return allowed True if whitelist is off or `_account` is in `isDepositor`.
    function canSendAssets(address _account) external view returns (bool) {
        return !depositWhitelistEnabled || isDepositor[_account];
    }

    /// @dev Rebuilds the exact market parameters used by the Amolis vault so cap ids stay deterministic.
    /// Use this helper internally whenever controller logic needs the canonical market id payload.
    /// @return params Morpho `MarketParams` for `MARKET_ID` as read from `MORPHO.idToMarketParams`.
    function _marketParams() internal view returns (MarketParams memory) {
        return MORPHO.idToMarketParams(Id.wrap(MARKET_ID));
    }

    /// @dev Returns the adapter id payload consumed by VaultV2 absolute-cap functions for this single adapter setup.
    /// Use this helper internally when the controller needs to read or write the adapter-wide cap.
    /// @return idData ABI-encoded cap identifier `abi.encode("this", adapter)`.
    function _adapterIdData() internal view returns (bytes memory) {
        return abi.encode("this", adapter);
    }

    /// @dev Returns the collateral id payload consumed by VaultV2 absolute-cap functions for this fixed USDC market.
    /// Use this helper internally when the controller needs to read or write the collateral-wide cap.
    /// @return idData ABI-encoded cap identifier `abi.encode("collateralToken", collateralToken)`.
    function _collateralIdData() internal view returns (bytes memory) {
        return abi.encode("collateralToken", _marketParams().collateralToken);
    }

    /// @dev Returns the exact market id payload consumed by VaultV2 absolute-cap functions for this fixed market.
    /// Use this helper internally when the controller needs to read or write the market-specific cap.
    /// @return idData ABI-encoded cap identifier `abi.encode("this/marketParams", adapter, marketParams)`.
    function _marketIdData() internal view returns (bytes memory) {
        return abi.encode("this/marketParams", adapter, _marketParams());
    }

    /// @dev Reads the three enforced absolute caps and returns the shared cap only when they are perfectly aligned.
    /// Use this helper internally before cap updates so the controller never writes over an unexpected mismatch.
    /// @return cap Shared absolute cap when adapter, collateral, and market caps match; reverts with `CapMismatch` otherwise.
    function _currentTotalCap() internal view returns (uint256) {
        uint256 adapterCap = vault.absoluteCap(keccak256(_adapterIdData()));
        uint256 collateralCap = vault.absoluteCap(keccak256(_collateralIdData()));
        uint256 marketCap = vault.absoluteCap(keccak256(_marketIdData()));

        if (adapterCap != collateralCap || adapterCap != marketCap) revert CapMismatch();
        return adapterCap;
    }

    /// @dev Submits and immediately executes one vault curator action through the controller-owned vault.
    /// Use this helper during bootstrap and for the few vault selectors intentionally left accessible afterward.
    /// @param _data ABI-encoded call data for one `vault` function (same payload used for `submit` and low-level `call`).
    function _submitAndExecuteVault(bytes memory _data) internal {
        vault.submit(_data);
        (bool success, bytes memory returnData) = address(vault).call(_data);
        if (!success) _revertWith(returnData);
    }

    /// @dev Reverts unless the controller has already deployed and stored its managed vault and adapter.
    /// Use this helper before post-bootstrap admin mutations so they can never become silent no-ops.
    function _requireInitialized() internal view {
        if (address(vault) == address(0) || adapter == address(0)) revert NotInitialized();
    }

    /// @dev Validates that a fee recipient can receive shares under the current deposit whitelist policy.
    /// Use this helper before enabling fees or whitelist mode so fee accrual cannot silently mint into a blocked account.
    /// @param _recipient Address that must be non-zero and present in `isDepositor` when checks apply.
    function _requireAllowedFeeRecipient(address _recipient) internal view {
        if (_recipient == address(0) || !isDepositor[_recipient]) revert FeeRecipientNotAllowed(_recipient);
    }

    /// @dev Re-throws the exact revert payload returned by a failed vault or adapter call.
    /// Use this helper after low-level calls so callers receive the original revert reason from the underlying contract.
    /// @param _returnData Returndata blob from a failed `call`, passed through verbatim to `revert`.
    function _revertWith(bytes memory _returnData) internal pure {
        assembly ("memory-safe") {
            revert(add(_returnData, 0x20), mload(_returnData))
        }
    }
}
