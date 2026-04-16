// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

// External Libraries
import { OptimizedOwnableRoles } from "kam/src/vendor/solady/auth/OptimizedOwnableRoles.sol";
import { OptimizedReentrancyGuardTransient } from "kam/src/vendor/solady/utils/OptimizedReentrancyGuardTransient.sol";

// Internal Libraries
import { ExecutionDataLibrary } from "./libraries/ExecutionDataLibrary.sol";
import { OptimizedFixedPointMathLib } from "kam/src/vendor/solady/utils/OptimizedFixedPointMathLib.sol";
import { Execution, ExecutionLib } from "minimal-smart-account/libraries/ExecutionLib.sol";
import { ModeCode, ModeLib } from "minimal-smart-account/libraries/ModeLib.sol";

// Local Interfaces
import { IRegistry } from "./interfaces/IRegistry.sol";
import { IVaultAdapter, IkAssetRouter, IkMinter, IkSettler, IkStakingVault, IkToken } from "./interfaces/IkSettler.sol";

// Errors
import {
    KSETTLER_ADDRESS_ZERO,
    KSETTLER_BATCH_ALREADY_CLOSED,
    KSETTLER_BATCH_ALREADY_SETTLED,
    KSETTLER_INSUFFICIENT_BALANCE,
    KSETTLER_INVALID_TARGET_TYPE,
    KSETTLER_INVALID_VAULT_TYPE,
    KSETTLER_MISSING_ALLOWANCE,
    KSETTLER_PROPOSAL_ALREADY_FINALISED,
    KSETTLER_PROPOSAL_NOT_EXECUTED
} from "./errors/Errors.sol";
import { IRegistry as IRegistryBase } from "kam/src/interfaces/IRegistry.sol";
import { IERC4626 } from "metawallet/src/interfaces/IERC4626.sol";
import { IVaultModule } from "metawallet/src/interfaces/IVaultModule.sol";
import { IMinimalSmartAccount } from "minimal-smart-account/interfaces/IMinimalSmartAccount.sol";

/// @title kSettler
/// @notice Contract responsible for settling batch operations in delta-neutral vaults
/// @dev This contract handles the complex settlement process for delta-neutral vault batches,
///      including rebalancing and asset netting operations.
///      It manages the interaction between kMinter, vault adapters, and meta-wallets.
contract kSettler is IkSettler, OptimizedOwnableRoles, OptimizedReentrancyGuardTransient {
    using OptimizedFixedPointMathLib for int256;
    using ExecutionLib for bytes;

    /*//////////////////////////////////////////////////////////////
                              STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice The kMinter contract for batch operations
    IkMinter public kMinter;

    /// @notice The kAssetRouter contract for asset routing
    IkAssetRouter public kAssetRouter;

    /// @notice The registry contract for address resolution
    IRegistry public registry;

    /// @notice Tracks whether a proposal has already been finalised via finaliseCustodialSettlement
    mapping(bytes32 => bool) public finalisedProposals;

    /*//////////////////////////////////////////////////////////////
                              ROLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Admin role for authorized operations
    uint256 internal constant ADMIN_ROLE = _ROLE_0;

    /// @notice Emergency admin role for emergency operations
    uint256 internal constant RELAYER_ROLE = _ROLE_1;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Initializes the kSettler contract with required dependencies
    /// @param _owner the address of the owner
    /// @param _admin the address of the admin
    /// @param _relayer the address of the relayer
    /// @param _kMinter The kMinter contract address
    /// @param _kAssetRouter The kAssetRouter contract address
    /// @param _registry The registry contract address
    constructor(
        address _owner,
        address _admin,
        address _relayer,
        address _kMinter,
        address _kAssetRouter,
        address _registry
    ) {
        require(_owner != address(0), KSETTLER_ADDRESS_ZERO);
        require(_admin != address(0), KSETTLER_ADDRESS_ZERO);
        require(_relayer != address(0), KSETTLER_ADDRESS_ZERO);
        require(_kMinter != address(0), KSETTLER_ADDRESS_ZERO);
        require(_kAssetRouter != address(0), KSETTLER_ADDRESS_ZERO);
        require(_registry != address(0), KSETTLER_ADDRESS_ZERO);

        kMinter = IkMinter(_kMinter);
        kAssetRouter = IkAssetRouter(_kAssetRouter);
        registry = IRegistry(_registry);

        _initializeOwner(_owner);
        _grantRoles(_admin, ADMIN_ROLE);
        _grantRoles(_relayer, RELAYER_ROLE);
    }

    /*//////////////////////////////////////////////////////////////
                              ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IkSettler
    function grantRelayerRole(address _relayer) external payable {
        _checkRoles(ADMIN_ROLE);
        _grantRoles(_relayer, RELAYER_ROLE);
    }

    /*//////////////////////////////////////////////////////////////
                            kMINTER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IkSettler
    function closeAndProposeMinterBatch(address _asset) external payable returns (bytes32 _proposalId) {
        _lockReentrant();
        _checkRoles(RELAYER_ROLE);

        // Retrieve current batch information
        bytes32 _batchId = kMinter.getBatchId(_asset);
        IkMinter.BatchInfo memory _batchInfo = kMinter.getBatchInfo(_batchId);

        // Validate batch state
        require(!_batchInfo.isClosed, KSETTLER_BATCH_ALREADY_CLOSED);
        require(!_batchInfo.isSettled, KSETTLER_BATCH_ALREADY_SETTLED);

        // Close the batch in the kMinter
        kMinter.closeBatch(_batchInfo.batchId, true);

        // Get adapter and metawallet target
        IMinimalSmartAccount _adapter = IMinimalSmartAccount(registry.getAdapter(address(kMinter), _asset));
        address _target = _getTarget(address(_adapter), 0);

        // Get batch balances and calculate netted assets
        (uint256 _deposited, uint256 _requested) = kAssetRouter.getBatchIdBalances(address(kMinter), _batchInfo.batchId);
        int256 _nettedAmount = int256(_deposited) - int256(_requested);

        uint256 _adapterAssets = IVaultAdapter(address(_adapter)).totalAssets();

        if (_nettedAmount < 0) {
            uint256 _abs = _nettedAmount.abs();

            // Money should always be idle if not revert and divest 1st.
            Execution[] memory _executions =
                ExecutionDataLibrary.getWithdrawExecutionData(_target, address(_adapter), address(_adapter), _abs);

            _executeAdapterCall(_adapter, _executions);
        } else if (_nettedAmount > 0) {
            Execution[] memory _execution =
                ExecutionDataLibrary.getDepositExecutionData(_target, address(_adapter), uint256(_nettedAmount));

            _executeAdapterCall(_adapter, _execution);
        }
        _proposalId = kAssetRouter.proposeSettleBatch(_asset, address(kMinter), _batchId, _adapterAssets, 0, 0);
        _unlockReentrant();
    }

    /*//////////////////////////////////////////////////////////////
                            DN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IkSettler
    function closeAndProposeDNVaultBatch(
        address _asset,
        uint256 _newMetaWalletTotalAssets,
        bytes32 _rootHash
    )
        external
        payable
        returns (bytes32 _proposalId)
    {
        _lockReentrant();
        _proposalId = _closeAndProposeDNVaultBatch(_asset, _newMetaWalletTotalAssets, _rootHash);
        _unlockReentrant();
    }

    /// @notice Internal implementation for closing and proposing DN vault batch
    /// @param _asset The asset address for which to close the batch
    /// @param _newMetaWalletTotalAssets The new total assets for the MetaWallet (idle + strategies)
    /// @param _rootHash The merkle root committing to the strategy breakdown
    /// @return _proposalId The proposal ID for the settlement
    function _closeAndProposeDNVaultBatch(
        address _asset,
        uint256 _newMetaWalletTotalAssets,
        bytes32 _rootHash
    )
        internal
        returns (bytes32 _proposalId)
    {
        // Ensure only authorized relayers can call this function
        _checkRoles(RELAYER_ROLE);

        // Get all required addresses for the asset
        IMinimalSmartAccount _kMinterAdapter = IMinimalSmartAccount(registry.getAdapter(address(kMinter), _asset));
        IkStakingVault _vault =
            IkStakingVault(registry.getVaultByAssetAndType(_asset, uint8(IRegistryBase.VaultType.DN)));
        IMinimalSmartAccount _vaultAdapter = IMinimalSmartAccount(registry.getAdapter(address(_vault), _asset));
        address _target = _getTarget(address(_vaultAdapter), 0);
        IERC4626 _metawallet = IERC4626(_target);

        // Verify kMinterAdapter has approved vaultAdapter to transferFrom MetaWallet shares.
        // This approval is an external deployment invariant that must be set by a MANAGER.
        // NOTE: The actual allowance sufficiency is checked before each transferFrom call below.

        // Compute depeg as the rate delta from settleTotalAssets on the kMinter's MetaWallet position.
        // Capture value BEFORE settlement, then compare AFTER. The delta isolates pure yield/loss
        // from any prior minter deposits/withdrawals, ensuring correct depeg regardless of ordering.
        // Proof: remaining_value = shares × old_rate = totalAssets + pending_deposit, always.
        uint256 _valueBefore = _metawallet.convertToAssets(_metawallet.balanceOf(address(_kMinterAdapter)));
        IVaultModule(_target).settleTotalAssets(_newMetaWalletTotalAssets, _rootHash);
        int256 _depeg =
            int256(_metawallet.convertToAssets(_metawallet.balanceOf(address(_kMinterAdapter)))) - int256(_valueBefore);

        // Retrieve current batch information
        BatchInfo memory _batchInfo = _getBatchInfo(_vault);

        // Validate batch state
        require(!_batchInfo._isClosed, KSETTLER_BATCH_ALREADY_CLOSED);
        require(!_batchInfo._isSettled, KSETTLER_BATCH_ALREADY_SETTLED);

        // Close the batch in the vault
        _vault.closeBatch(_batchInfo._batchId, true);

        // Do not send profit when total supply is zero, to avoid shares inflation
        if (_vault.totalSupply() != 0) {
            if (_depeg > 0) {
                // PROFIT: positive depeg means kMinter has more assets than expected (surplus)
                // Distribute profit: insurance -> treasury -> vault adapter
                uint256 _profitAssets = uint256(_depeg);
                uint256 _sharesToVaultAdapter = _distributeProfitShares(
                    _metawallet,
                    _kMinterAdapter,
                    _profitAssets,
                    true, // isVaultSettlement
                    _asset
                );

                // Transfer remaining shares to vault adapter if any
                if (_sharesToVaultAdapter > 0) {
                    require(
                        _metawallet.allowance(address(_kMinterAdapter), address(_vaultAdapter))
                            >= _sharesToVaultAdapter,
                        KSETTLER_MISSING_ALLOWANCE
                    );
                    _executeRebalanceTransfer(
                        false, // toKMinterAdapter = false means transfer FROM kMinter TO vaultAdapter
                        _metawallet,
                        _kMinterAdapter,
                        _vaultAdapter,
                        _sharesToVaultAdapter
                    );
                }
            } else if (_depeg < 0) {
                // LOSS: negative depeg means kMinter needs more assets (deficit)
                // Transfer from DN adapter to kMinter adapter (existing behavior)
                uint256 _shareValue = _metawallet.convertToShares(uint256(-_depeg));
                while (_metawallet.convertToAssets(_shareValue) < uint256(-_depeg)) {
                    _shareValue += 1;
                }
                _executeRebalanceTransfer(true, _metawallet, _kMinterAdapter, _vaultAdapter, _shareValue);
            }
        }

        // Calculate final asset data for settlement
        AssetData memory _assetData =
            _calculateAssetData(_metawallet, _kMinterAdapter, _vaultAdapter, _vault, _batchInfo);

        // Propose the batch settlement to the asset router
        _proposalId = kAssetRouter.proposeSettleBatch(
            _asset, address(_vault), _batchInfo._batchId, _assetData._newTotalAssets, 0, 0
        );
    }

    /*//////////////////////////////////////////////////////////////
                            EXECUTE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IkSettler
    function executeSettleBatch(bytes32 _proposalId) external payable {
        _lockReentrant();
        _checkRoles(RELAYER_ROLE);

        kAssetRouter.executeSettleBatch(_proposalId);
        _unlockReentrant();
    }

    /// @inheritdoc IkSettler
    function liquidateInsurance(address _asset) external payable {
        _lockReentrant();
        _checkRoles(RELAYER_ROLE);

        // Get insurance address from registry
        (, address _insurance,,) = registry.getSettlementConfig();
        require(_insurance != address(0), KSETTLER_ADDRESS_ZERO);

        // Get the metawallet target for the insurance account
        address[] memory _targets = registry.getExecutorTargets(_insurance);
        require(_targets.length != 0, KSETTLER_ADDRESS_ZERO);

        // Find the metawallet target (type METAWALLET = 0)
        address _metawalletAddr;
        for (uint256 i = 0; i < _targets.length; i++) {
            if (registry.getTargetType(_targets[i]) == 0) {
                _metawalletAddr = _targets[i];
                break;
            }
        }
        require(_metawalletAddr != address(0), KSETTLER_ADDRESS_ZERO);

        IERC4626 _metawallet = IERC4626(_metawalletAddr);

        // Get insurance's share balance
        uint256 _shares = _metawallet.balanceOf(_insurance);
        if (_shares == 0) {
            _unlockReentrant();
            return;
        }

        uint256 _assetsValue = _metawallet.convertToAssets(_shares);

        // Build execution for redeem
        Execution[] memory _executions =
            ExecutionDataLibrary.getWithdrawExecutionData(_metawalletAddr, _insurance, _insurance, _assetsValue);

        // Execute through insurance smart account
        _executeAdapterCall(IMinimalSmartAccount(_insurance), _executions);

        emit InsuranceLiquidated(_asset, _shares, _assetsValue);
        _unlockReentrant();
    }

    /// @inheritdoc IkSettler
    function proposeSettleBatch(
        address _asset,
        address _vault,
        bytes32 _batchId,
        uint256 _totalAssets
    )
        external
        payable
        returns (bytes32 _proposalId)
    {
        _lockReentrant();
        _checkRoles(RELAYER_ROLE);

        // Only custodial vaults can use the generic proposeSettleBatch.
        // kMinter and DN vaults must settle through their dedicated functions.
        uint8 _vaultType = registry.getVaultType(_vault);
        require(
            _vaultType != uint8(IRegistryBase.VaultType.MINTER) && _vaultType != uint8(IRegistryBase.VaultType.DN),
            KSETTLER_INVALID_VAULT_TYPE
        );

        _proposalId = kAssetRouter.proposeSettleBatch(_asset, _vault, _batchId, _totalAssets, 0, 0);
        _unlockReentrant();
    }

    /// @inheritdoc IkSettler
    function closeVaultBatch(address _vault, bytes32 _batchId, bool _create) external payable {
        _lockReentrant();
        _checkRoles(RELAYER_ROLE);

        uint8 _vaultType = registry.getVaultType(_vault);
        require(
            _vaultType != uint8(IRegistryBase.VaultType.MINTER) && _vaultType != uint8(IRegistryBase.VaultType.DN),
            KSETTLER_INVALID_VAULT_TYPE
        );

        IkStakingVault(_vault).closeBatch(_batchId, _create);
        _unlockReentrant();
    }

    /*//////////////////////////////////////////////////////////////
                        ALPHA & BETA FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IkSettler
    function finaliseCustodialSettlement(bytes32 _proposalId) external payable {
        _lockReentrant();
        _checkRoles(RELAYER_ROLE);

        require(!finalisedProposals[_proposalId], KSETTLER_PROPOSAL_ALREADY_FINALISED);
        finalisedProposals[_proposalId] = true;

        IkAssetRouter.VaultSettlementProposal memory _proposal = kAssetRouter.getSettlementProposal(_proposalId);

        require(kAssetRouter.isProposalExecuted(_proposalId), KSETTLER_PROPOSAL_NOT_EXECUTED);

        // Only custodial vaults (Alpha, Beta, etc.) can use finaliseCustodialSettlement
        uint8 _vaultType = registry.getVaultType(_proposal.vault);
        require(
            _vaultType != uint8(IRegistryBase.VaultType.MINTER) && _vaultType != uint8(IRegistryBase.VaultType.DN),
            KSETTLER_INVALID_VAULT_TYPE
        );

        IMinimalSmartAccount _kMinterAdapter =
            IMinimalSmartAccount(registry.getAdapter(address(kMinter), _proposal.asset));
        IMinimalSmartAccount _vaultAdapter =
            IMinimalSmartAccount(registry.getAdapter(address(_proposal.vault), _proposal.asset));

        address _kMinterAdapterAddr = address(_kMinterAdapter);
        address _targetMetawallet = _getTarget(_kMinterAdapterAddr, 0);
        IERC4626 _metawallet = IERC4626(_targetMetawallet);
        address _targetCustodial = _getTarget(address(_vaultAdapter), 1);
        int256 _netted = int256(_proposal.netted);

        if (_proposal.netted == 0) {
            _unlockReentrant();
            return;
        }
        if (_proposal.netted > 0) {
            uint256 _nettedAbs = uint256(_netted);

            // Execute redemption through the kMinter adapter
            Execution[] memory _executions = ExecutionDataLibrary.getWithdrawExecutionData(
                address(_metawallet), _kMinterAdapterAddr, _kMinterAdapterAddr, _nettedAbs
            );

            // redeem assets from metawallet using kMinter adapter
            _executeAdapterCall(_kMinterAdapter, _executions);

            require(
                IkToken(_proposal.asset).balanceOf(_kMinterAdapterAddr) >= _nettedAbs, KSETTLER_INSUFFICIENT_BALANCE
            );

            // Transfer assets to custodial target (CEFFU)
            _executions = ExecutionDataLibrary.getTransferExecutionData(_proposal.asset, _targetCustodial, _nettedAbs);
            _executeAdapterCall(_kMinterAdapter, _executions);
        } else {
            Execution[] memory _executions =
                ExecutionDataLibrary.getDepositExecutionData(_targetMetawallet, _kMinterAdapterAddr, _netted.abs());

            _executeAdapterCall(_kMinterAdapter, _executions);
        }
        _unlockReentrant();
    }

    /*//////////////////////////////////////////////////////////////
                              VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IkSettler
    function isNettedNegative(bytes32 _proposalId) external view returns (bool _isNettedNegative) {
        IkAssetRouter.VaultSettlementProposal memory _proposal = kAssetRouter.getSettlementProposal(_proposalId);
        if (_proposal.netted < 0) return true;
    }

    /*//////////////////////////////////////////////////////////////
                              INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Executes a batch of operations through the adapter using MinimalSmartAccount interface
    /// @dev Encodes the execution array and calls the adapter's execute function
    /// @param _adapter The adapter to execute through
    /// @param _executions Array of Execution structs to execute
    function _executeAdapterCall(IMinimalSmartAccount _adapter, Execution[] memory _executions) internal {
        bytes memory _executionCalldata = ExecutionLib.encodeBatch(_executions);
        ModeCode _mode = ModeLib.encodeSimpleBatch();
        _adapter.execute(_mode, _executionCalldata);
    }

    /// @notice Retrieves current batch information for a vault
    /// @dev Gets batch state and balances from vault reader and asset router
    /// @param _vault The vault address to get batch info for
    /// @return _batchInfo Struct containing batch information
    function _getBatchInfo(IkStakingVault _vault) internal view returns (BatchInfo memory _batchInfo) {
        // Get basic batch information from vault reader
        (_batchInfo._batchId,, _batchInfo._isClosed, _batchInfo._isSettled) = _vault.getCurrentBatchInfo();

        // Get deposited amount for this batch
        (_batchInfo._deposited,) = kAssetRouter.getBatchIdBalances(address(_vault), _batchInfo._batchId);

        // Get pending shares for this batch
        _batchInfo._pendingShares = kAssetRouter.getRequestedShares(address(_vault), _batchInfo._batchId);
    }

    /// @notice Calculates asset data for settlement
    /// @dev Determines current adapter assets, calculates netted assets, and computes new total
    /// @param _metawallet the address of the target metawallet
    /// @param _kMinterAdapter the kMinter adapter address
    /// @param _vaultAdapter the vault adapter address
    /// @param _vault the vault address
    /// @param _batchInfo Struct containing batch information
    /// @return _assetData Struct containing calculated asset data
    function _calculateAssetData(
        IERC4626 _metawallet,
        IMinimalSmartAccount _kMinterAdapter,
        IMinimalSmartAccount _vaultAdapter,
        IkStakingVault _vault,
        BatchInfo memory _batchInfo
    )
        internal
        returns (AssetData memory _assetData)
    {
        // Get current shares and assets in the DN adapter
        _assetData._dnAdapterShares = _metawallet.balanceOf(address(_vaultAdapter));
        _assetData._dnAdapterAssets = _metawallet.convertToAssets(_assetData._dnAdapterShares);
        // Calculate netted assets (difference between deposited and requested)
        _assetData._nettedAssets = _nettedAssets(
            _assetData._dnAdapterAssets,
            _batchInfo._deposited,
            _batchInfo._pendingShares,
            _metawallet,
            _kMinterAdapter,
            _vaultAdapter,
            _vault
        );

        _assetData._newTotalAssets = _assetData._dnAdapterAssets;
    }

    /// @dev Handles the netting process by transferring assets between adapters based on the difference
    /// @param _dnAdapterAssets Current assets in the DN adapter
    /// @param _deposited Total amount deposited in the batch
    /// @param _pendingShares Number of shares pending redemption
    /// @param _dnMetaWallet Address of the delta-neutral meta-wallet
    /// @param _kMinterAdapter Address of the kMinter adapter
    /// @param _dnVaultAdapter Address of the DN vault adapter
    /// @return The net amount of assets after netting (can be negative)
    function _nettedAssets(
        uint256 _dnAdapterAssets,
        uint256 _deposited,
        uint256 _pendingShares,
        IERC4626 _dnMetaWallet,
        IMinimalSmartAccount _kMinterAdapter,
        IMinimalSmartAccount _dnVaultAdapter,
        IkStakingVault _vault
    )
        internal
        returns (int256)
    {
        // Convert pending shares to assets using current adapter totals
        uint256 _requestedAssets =
            _vault.convertToAssetsWithTotals(_pendingShares, _dnAdapterAssets, _vault.totalSupply());

        // Calculate net difference between deposited and requested
        int256 _nettedAssets_ = int256(_deposited) - int256(_requestedAssets);

        // If no netting needed, return early
        if (_nettedAssets_ == 0) return 0;

        // Convert netted assets to shares for transfer
        uint256 _nettedShares = _dnMetaWallet.convertToShares(_nettedAssets_.abs());

        // Execute the netted transfer between adapters
        _executeNettedTransfer(
            _nettedAssets_ > 0,
            address(_dnMetaWallet),
            address(_kMinterAdapter),
            address(_dnVaultAdapter),
            _nettedShares
        );

        return _nettedAssets_;
    }

    /// @notice Executes the netted transfer between adapters
    /// @dev Transfers shares between kMinter and DN vault adapters based on netting direction
    /// @param _toVaultAdapter Whether to transfer shares to the DN vault adapter (true) or to kMinter adapter (false)
    /// @param _metawallet Address of the delta-neutral meta-wallet
    /// @param _kMinterAdapter Address of the kMinter adapter
    /// @param _vaultAdapter Address of the DN vault adapter
    /// @param _nettedShares Amount of shares to transfer
    function _executeNettedTransfer(
        bool _toVaultAdapter,
        address _metawallet,
        address _kMinterAdapter,
        address _vaultAdapter,
        uint256 _nettedShares
    )
        internal
    {
        Execution[] memory _executions;

        if (_toVaultAdapter) {
            // Transfer from kMinter adapter to DN vault adapter
            _executions = ExecutionDataLibrary.getTransferFromExecutionData(
                _metawallet, _kMinterAdapter, _vaultAdapter, _nettedShares
            );
            _executeAdapterCall(IMinimalSmartAccount(_vaultAdapter), _executions);
        } else {
            // Transfer from DN vault adapter to kMinter adapter
            _executions = ExecutionDataLibrary.getTransferExecutionData(_metawallet, _kMinterAdapter, _nettedShares);
            _executeAdapterCall(IMinimalSmartAccount(_vaultAdapter), _executions);
        }
    }

    /// @notice Executes the rebalancing transfer between adapters
    /// @dev Transfers shares between adapters to achieve proper balance
    /// @param _toKMinterAdapter Whether to transfer to kMinter adapter (true) or to DN vault adapter (false)
    /// @param _metawallet Address of the delta-neutral meta-wallet
    /// @param _kMinterAdapter Address of the kMinter adapter
    /// @param _vaultAdapter Address of the DN vault adapter
    /// @param _shareValue Amount of shares to transfer
    function _executeRebalanceTransfer(
        bool _toKMinterAdapter,
        IERC4626 _metawallet,
        IMinimalSmartAccount _kMinterAdapter,
        IMinimalSmartAccount _vaultAdapter,
        uint256 _shareValue
    )
        internal
    {
        Execution[] memory _executions;

        if (_toKMinterAdapter) {
            // Transfer to kMinter adapter (from DN vault adapter)
            _executions = ExecutionDataLibrary.getTransferExecutionData(
                address(_metawallet), address(_kMinterAdapter), _shareValue
            );
            _executeAdapterCall(_vaultAdapter, _executions);
        } else {
            // Transfer from kMinter adapter (to DN vault adapter)
            _executions = ExecutionDataLibrary.getTransferFromExecutionData(
                address(_metawallet), address(_kMinterAdapter), address(_vaultAdapter), _shareValue
            );
            _executeAdapterCall(_vaultAdapter, _executions);
        }
    }

    /// @notice returns the target address of a given adapter matching the expected type
    /// @param _adapter the adapter address
    /// @param _expectedType the expected target type (0 = METAWALLET, 1 = CUSTODIAL)
    /// @return _target the target of a given adapter matching the expected type
    function _getTarget(address _adapter, uint8 _expectedType) internal view returns (address _target) {
        address[] memory _targets = registry.getExecutorTargets(_adapter);
        for (uint256 i = 0; i < _targets.length; i++) {
            if (registry.getTargetType(_targets[i]) == _expectedType) {
                return _targets[i];
            }
        }
        revert(KSETTLER_INVALID_TARGET_TYPE);
    }

    /*//////////////////////////////////////////////////////////////
                        PROFIT DISTRIBUTION FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Calculates how many assets insurance still needs to reach target
    /// @dev Target is insuranceBps/10000 * kMinterAdapter.totalAssets()
    /// @param _metawallet The metawallet for share/asset conversion
    /// @param _kMinterAdapter The kMinter adapter (for totalAssets as base)
    /// @param _asset The underlying asset address (e.g., USDC)
    /// @return _deficitAssets Assets still needed by insurance (0 if target met)
    function _getInsuranceDeficit(
        IERC4626 _metawallet,
        IMinimalSmartAccount _kMinterAdapter,
        address _asset
    )
        internal
        view
        returns (uint256 _deficitAssets)
    {
        (, address _insurance,, uint16 _insuranceBps) = registry.getSettlementConfig();

        if (_insurance == address(0) || _insuranceBps == 0) return 0;

        // Target based on kMinter's total assets
        uint256 _kMinterTotalAssets = IVaultAdapter(address(_kMinterAdapter)).totalAssets();
        uint256 _insuranceTarget = (_kMinterTotalAssets * _insuranceBps) / 10_000;

        // Current insurance balance: metawallet shares + underlying tokens (post-liquidation)
        uint256 _insuranceShares = _metawallet.balanceOf(_insurance);
        uint256 _insuranceAssets = _metawallet.convertToAssets(_insuranceShares) + IkToken(_asset).balanceOf(_insurance);

        if (_insuranceAssets >= _insuranceTarget) return 0;

        _deficitAssets = _insuranceTarget - _insuranceAssets;
    }

    /// @notice Distributes profit shares according to priority: insurance -> treasury -> vault adapter
    /// @dev All distributions are in metawallet shares. All remaining profit after insurance and
    ///      treasury is sent to the vault adapter to maintain kMinter peg.
    /// @param _metawallet The metawallet contract
    /// @param _kMinterAdapter The kMinter adapter holding the profit shares
    /// @param _profitAssets Total profit in assets (positive depeg value)
    /// @param _isVaultSettlement True if this is a DN/custodial vault settlement
    /// @param _asset The underlying asset address (e.g., USDC)
    /// @return _sharesToVaultAdapter Shares that should be transferred to vault adapter
    function _distributeProfitShares(
        IERC4626 _metawallet,
        IMinimalSmartAccount _kMinterAdapter,
        uint256 _profitAssets,
        bool _isVaultSettlement,
        address _asset
    )
        internal
        returns (uint256 _sharesToVaultAdapter)
    {
        if (_profitAssets == 0) return 0;

        // Convert profit to shares
        uint256 _profitShares = _metawallet.convertToShares(_profitAssets);
        // Adjust for dust
        while (_metawallet.convertToAssets(_profitShares) < _profitAssets) {
            _profitShares += 1;
        }

        uint256 _remainingShares = _profitShares;

        // Get settlement config
        (address _treasury, address _insurance, uint16 _treasuryBps,) = registry.getSettlementConfig();

        // 1. Insurance priority distribution
        uint256 _insuranceDeficitAssets = _getInsuranceDeficit(_metawallet, _kMinterAdapter, _asset);
        uint256 _insuranceShares = 0;

        if (_insuranceDeficitAssets > 0 && _insurance != address(0)) {
            uint256 _insuranceDeficitShares = _metawallet.convertToShares(_insuranceDeficitAssets);
            // Adjust for dust (consistent with all other asset-to-share conversions)
            while (_metawallet.convertToAssets(_insuranceDeficitShares) < _insuranceDeficitAssets) {
                _insuranceDeficitShares += 1;
            }
            _insuranceShares = _remainingShares < _insuranceDeficitShares ? _remainingShares : _insuranceDeficitShares;

            if (_insuranceShares > 0) {
                _executeShareTransfer(_metawallet, _kMinterAdapter, _insurance, _insuranceShares);
                _remainingShares -= _insuranceShares;
            }
        }

        // 2. Treasury distribution (from remaining profit)
        uint256 _treasuryShares = 0;
        if (_remainingShares > 0 && _treasuryBps > 0 && _treasury != address(0)) {
            _treasuryShares = (_remainingShares * _treasuryBps) / 10_000;
            if (_treasuryShares > 0) {
                _executeShareTransfer(_metawallet, _kMinterAdapter, _treasury, _treasuryShares);
                _remainingShares -= _treasuryShares;
            }
        }

        // 3. Remaining profit goes to vault adapter to maintain kMinter peg
        // kMinter should never hold excess profit - it must stay pegged to kToken supply
        if (_isVaultSettlement && _remainingShares > 0) {
            _sharesToVaultAdapter = _remainingShares;
        }

        emit ProfitDistributed(_insuranceShares, _treasuryShares, _sharesToVaultAdapter);
    }

    /// @notice Transfers shares from kMinter adapter to a recipient
    /// @dev Uses ExecutionDataLibrary pattern for ERC20 transfer
    /// @param _metawallet The metawallet (ERC20 token to transfer)
    /// @param _kMinterAdapter The adapter executing the transfer
    /// @param _recipient The recipient address (insurance or treasury)
    /// @param _shares Number of shares to transfer
    function _executeShareTransfer(
        IERC4626 _metawallet,
        IMinimalSmartAccount _kMinterAdapter,
        address _recipient,
        uint256 _shares
    )
        internal
    {
        Execution[] memory _executions =
            ExecutionDataLibrary.getTransferExecutionData(address(_metawallet), _recipient, _shares);
        _executeAdapterCall(_kMinterAdapter, _executions);
    }
}
