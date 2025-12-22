// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

// External Libraries
import { OptimizedOwnableRoles } from "kam/src/vendor/solady/auth/OptimizedOwnableRoles.sol";

// Internal Libraries
import { ExecutionDataLibrary } from "./libraries/ExecutionDataLibrary.sol";
import { OptimizedFixedPointMathLib, VaultMathLibrary } from "./libraries/VaultMathLibrary.sol";
import { Execution, ExecutionLib } from "minimal-smart-account/libraries/ExecutionLib.sol";
import { ModeCode, ModeLib } from "minimal-smart-account/libraries/ModeLib.sol";

// Local Interfaces
import { IRegistry } from "./interfaces/IRegistry.sol";
import { ISettler, IVaultAdapter, IkAssetRouter, IkMinter, IkStakingVault, IkToken } from "./interfaces/ISettler.sol";
import { IERC7540 } from "kam/src/interfaces/IERC7540.sol";
import { IRegistry as IRegistryBase } from "kam/src/interfaces/IRegistry.sol";
import { IMinimalSmartAccount } from "minimal-smart-account/interfaces/IMinimalSmartAccount.sol";

/// @title Settler
/// @notice Contract responsible for settling batch operations in delta-neutral vaults
/// @dev This contract handles the complex settlement process for delta-neutral vault batches,
///      including rebalancing, fee calculations, and asset netting operations.
///      It manages the interaction between kMinter, vault adapters, and meta-vaults.
contract Settler is ISettler, OptimizedOwnableRoles {
    using VaultMathLibrary for IkStakingVault;
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

    /// @notice Initializes the Settler contract with required dependencies
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

    /// @inheritdoc ISettler
    /// @param _relayer The address to grant relayer role to
    /// @dev Grants relayer role to the specified address. Only callable by admin.
    function grantRelayerRole(address _relayer) external payable {
        hasAnyRole(msg.sender, ADMIN_ROLE);
        _grantRoles(_relayer, RELAYER_ROLE);
    }

    /*//////////////////////////////////////////////////////////////
                            kMINTER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ISettler
    /// @param _asset The asset address for which to close the batch
    /// @return _proposalId The proposal ID for the settlement, or bytes32(0) if no netting is needed
    /// @dev Closes a kMinter batch and handles asset rebalancing. If netted assets are negative,
    ///      requests redemption from the delta-neutral meta-vault. If positive, deposits excess
    ///      assets to the meta-vault and creates a settlement proposal.
    ///      Also distributes any profit to insurance and treasury before netting.
    function closeAndProposeMinterBatch(address _asset) external payable returns (bytes32 _proposalId) {
        if (!hasAnyRole(msg.sender, RELAYER_ROLE)) revert Unauthorized();

        // Retrieve current batch information
        bytes32 _batchId = kMinter.getBatchId(_asset);
        IkMinter.BatchInfo memory _batchInfo = kMinter.getBatchInfo(_batchId);

        // Validate batch state
        if (_batchInfo.isClosed) revert BatchAlreadyClosed();
        if (_batchInfo.isSettled) revert BatchAlreadySettled();

        // Close the batch in the kMinter
        kMinter.closeBatch(_batchInfo.batchId, true);

        // Get adapter and metavault
        IMinimalSmartAccount _adapter = IMinimalSmartAccount(registry.getAdapter(address(kMinter), _asset));
        address _target = _getTarget(address(_adapter));
        IERC7540 _metavault = IERC7540(_target);

        // NOTE: Profit distribution is NOT done here. It happens in DN vault batch settlement
        // via closeAndProposeDNVaultBatch. The kMinter batch only handles kToken minting/burning.

        // Get batch balances and calculate netted assets
        (uint256 _deposited, uint256 _requested) = kAssetRouter.getBatchIdBalances(address(kMinter), _batchInfo.batchId);
        int256 _nettedAmount = int256(_deposited) - int256(_requested);

        if (_nettedAmount == 0) return bytes32(0);

        uint256 _adapterAssets;

        if (_nettedAmount < 0) {
            // Convert absolute value of netted assets to shares
            uint256 _shares = _metavault.convertToShares(_nettedAmount.abs());
            // Adjust any dust
            while (_metavault.convertToAssets(_shares) < _nettedAmount.abs()) {
                _shares += 1;
            }

            // Money should always be iddle if not revert and divest 1st.
            Execution[] memory _executions = new Execution[](2);

            _executions[0] = ExecutionDataLibrary.getRequestRedeemExecutionData(
                _target, address(_adapter), address(_adapter), _shares
            )[0];
            _executions[1] =
                ExecutionDataLibrary.getRedeemExecutionData(_target, address(_adapter), address(_adapter), _shares)[0];

            _executeAdapterCall(_adapter, _executions);

            _adapterAssets = IVaultAdapter(address(_adapter)).totalAssets();
        } else {
            _adapterAssets = IVaultAdapter(address(_adapter)).totalAssets();

            Execution[] memory _execution = ExecutionDataLibrary.getDepositExecutionData(
                _target, address(_adapter), address(_adapter), uint256(_nettedAmount)
            );

            _executeAdapterCall(_adapter, _execution);
        }
        _proposalId = kAssetRouter.proposeSettleBatch(_asset, address(kMinter), _batchId, _adapterAssets, 0, 0);
    }

    /*//////////////////////////////////////////////////////////////
                            DN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ISettler
    /// @param _asset The asset address for which to close the batch
    /// @return _proposalId The proposal ID for the settlement
    /// @dev Closes a delta-neutral vault batch with default 0 profit share to vault adapter
    function closeAndProposeDNVaultBatch(address _asset) external payable returns (bytes32 _proposalId) {
        return _closeAndProposeDNVaultBatch(_asset, 0);
    }

    /// @inheritdoc ISettler
    /// @param _asset The asset address for which to close the batch
    /// @param _profitShareBps Basis points of remaining profit to send to vault adapter
    /// @return _proposalId The proposal ID for the settlement
    /// @dev Closes a delta-neutral vault batch and initiates settlement with profit distribution.
    function closeAndProposeDNVaultBatch(
        address _asset,
        uint16 _profitShareBps
    )
        external
        payable
        returns (bytes32 _proposalId)
    {
        return _closeAndProposeDNVaultBatch(_asset, _profitShareBps);
    }

    /// @notice Internal implementation for closing and proposing DN vault batch
    /// @param _asset The asset address for which to close the batch
    /// @param _profitShareBps Basis points of remaining profit to send to vault adapter
    /// @return _proposalId The proposal ID for the settlement
    function _closeAndProposeDNVaultBatch(
        address _asset,
        uint16 _profitShareBps
    )
        internal
        returns (bytes32 _proposalId)
    {
        // Ensure only authorized relayers can call this function
        if (!hasAnyRole(msg.sender, RELAYER_ROLE)) revert Unauthorized();

        // Validate profit share is reasonable (max 100%)
        if (_profitShareBps > 10_000) revert InvalidProfitShareBps();

        // Get all required addresses for the asset
        IMinimalSmartAccount _kMinterAdapter = IMinimalSmartAccount(registry.getAdapter(address(kMinter), _asset));
        IkStakingVault _vault =
            IkStakingVault(registry.getVaultByAssetAndType(_asset, uint8(IRegistryBase.VaultType.DN)));
        IMinimalSmartAccount _vaultAdapter = IMinimalSmartAccount(registry.getAdapter(address(_vault), _asset));
        address _target = _getTarget(address(_vaultAdapter));
        IERC7540 _metavault = IERC7540(_target);

        // Retrieve current batch information
        BatchInfo memory _batchInfo = _getBatchInfo(_vault);

        // Validate batch state
        if (_batchInfo._isClosed) revert BatchAlreadyClosed();
        if (_batchInfo._isSettled) revert BatchAlreadySettled();

        // Close the batch in the vault
        _vault.closeBatch(_batchInfo._batchId, true);

        // Handle profit distribution and rebalancing
        int256 _depeg = _getDepeg(_kMinterAdapter, _metavault);

        // Do not send profit when total supply is zero, to avoid shares inflation
        if (_vault.totalSupply() != 0) {
            if (_depeg < 0) {
                // PROFIT: negative depeg means kMinter has more assets than expected
                // Distribute profit: insurance -> treasury -> vault adapter
                uint256 _profitAssets = uint256(-_depeg);
                uint256 _sharesToVaultAdapter = _distributeProfitShares(
                    _metavault,
                    _kMinterAdapter,
                    _profitAssets,
                    _profitShareBps,
                    true // isVaultSettlement
                );

                // Transfer remaining shares to vault adapter if any
                if (_sharesToVaultAdapter > 0) {
                    _executeRebalanceTransfer(
                        false, // isPositive = false means transfer FROM kMinter TO vaultAdapter
                        _metavault,
                        _kMinterAdapter,
                        _vaultAdapter,
                        _sharesToVaultAdapter
                    );
                }
            } else if (_depeg > 0) {
                // LOSS: positive depeg means kMinter needs more assets
                // Transfer from DN adapter to kMinter adapter (existing behavior)
                uint256 _shareValue = _metavault.convertToShares(uint256(_depeg));
                while (_metavault.convertToAssets(_shareValue) < uint256(_depeg)) {
                    _shareValue += 1;
                }
                _executeRebalanceTransfer(true, _metavault, _kMinterAdapter, _vaultAdapter, _shareValue);
            }
        }

        // Calculate and process fees
        (uint64 _lastFeesChargedDateManagement, uint64 _lastFeesChargedDatePerformance) =
            _fees(_vault, _vaultAdapter, _metavault);

        // Calculate final asset data for settlement
        AssetData memory _assetData =
            _calculateAssetData(_metavault, _kMinterAdapter, _vaultAdapter, _vault, _batchInfo);

        // Propose the batch settlement to the asset router
        _proposalId = kAssetRouter.proposeSettleBatch(
            _asset,
            address(_vault),
            _batchInfo._batchId,
            _assetData._newTotalAssets,
            _lastFeesChargedDateManagement,
            _lastFeesChargedDatePerformance
        );
    }

    /*//////////////////////////////////////////////////////////////
                            EXECUTE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ISettler
    /// @param _proposalId The proposal ID to execute
    /// @dev Executes a settlement batch proposal through the kAssetRouter
    function executeSettleBatch(bytes32 _proposalId) external payable {
        if (!hasAnyRole(msg.sender, RELAYER_ROLE)) revert Unauthorized();

        kAssetRouter.executeSettleBatch(_proposalId);
    }

    /// @inheritdoc ISettler
    /// @param _asset The asset address for the settlement
    /// @param _vault The vault address for the settlement
    /// @param _batchId The batch ID for the settlement
    /// @param _totalAssets The total assets for the settlement
    /// @param _lastFeesChargedManagement The timestamp of last management fee charge
    /// @param _lastFeesChargedPerformance The timestamp of last performance fee charge
    /// @return _proposalId The proposal ID for the settlement
    /// @dev Proposes a settlement batch through the kAssetRouter with fee information
    function proposeSettleBatch(
        address _asset,
        address _vault,
        bytes32 _batchId,
        uint256 _totalAssets,
        uint64 _lastFeesChargedManagement,
        uint64 _lastFeesChargedPerformance
    )
        external
        payable
        returns (bytes32 _proposalId)
    {
        if (!hasAnyRole(msg.sender, RELAYER_ROLE)) revert Unauthorized();

        _proposalId = kAssetRouter.proposeSettleBatch(
            _asset, _vault, _batchId, _totalAssets, _lastFeesChargedManagement, _lastFeesChargedPerformance
        );
    }

    /// @inheritdoc ISettler
    /// @param _vault The vault address to close the batch for
    /// @param _batchId The batch ID to close
    /// @param _create Whether to create a new batch after closing
    /// @dev Closes a vault batch through the IkStakingVault interface
    function closeVaultBatch(address _vault, bytes32 _batchId, bool _create) external payable {
        if (!hasAnyRole(msg.sender, RELAYER_ROLE)) revert Unauthorized();

        IkStakingVault(_vault).closeBatch(_batchId, _create);
    }

    /*//////////////////////////////////////////////////////////////
                        ALPHA & BETA FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ISettler
    /// @param _proposalId The proposal ID to finalise
    /// @dev Finalises a custodial batch settlement by handling asset transfers between
    ///      kMinter and vault adapters based on the netted amount in the proposal.
    function finaliseCustodialSettlement(bytes32 _proposalId) external payable {
        if (!hasAnyRole(msg.sender, RELAYER_ROLE)) revert Unauthorized();

        IkAssetRouter.VaultSettlementProposal memory _proposal = kAssetRouter.getSettlementProposal(_proposalId);

        IMinimalSmartAccount _kMinterAdapter =
            IMinimalSmartAccount(registry.getAdapter(address(kMinter), _proposal.asset));
        IMinimalSmartAccount _vaultAdapter =
            IMinimalSmartAccount(registry.getAdapter(address(_proposal.vault), _proposal.asset));

        address _kMinterAdapterAddr = address(_kMinterAdapter);
        address _targetMetavault = _getTarget(_kMinterAdapterAddr);
        IERC7540 _metavault = IERC7540(_targetMetavault);
        address _targetCustodial = _getTarget(address(_vaultAdapter));
        int256 _netted = int256(_proposal.netted);

        if (_proposal.netted == 0) return;
        if (_proposal.netted > 0) {
            uint256 _nettedAbs = uint256(_netted);
            uint256 _shares = _metavault.convertToShares(_nettedAbs);
            // Adjust any dust
            while (_metavault.convertToAssets(_shares) < _nettedAbs) _shares += 1;

            // Execute redemption request through the kMinter adapter
            Execution[] memory _executions = new Execution[](2);
            _executions[0] = ExecutionDataLibrary.getRequestRedeemExecutionData(
                address(_metavault), _kMinterAdapterAddr, _kMinterAdapterAddr, _shares
            )[0];
            _executions[1] = ExecutionDataLibrary.getRedeemExecutionData(
                address(_metavault), _kMinterAdapterAddr, _kMinterAdapterAddr, _shares
            )[0];

            // requestRedeem + redeem shares from metavault using kMinter adapter
            _executeAdapterCall(_kMinterAdapter, _executions);

            if (IkToken(_proposal.asset).balanceOf(_kMinterAdapterAddr) < _nettedAbs) revert InsufficientBalance();

            // Transfer assets to custodial target (CEFFU)
            _executions = ExecutionDataLibrary.getTransferExecutionData(_proposal.asset, _targetCustodial, _nettedAbs);
            _executeAdapterCall(_kMinterAdapter, _executions);
        } else {
            Execution[] memory _executions = ExecutionDataLibrary.getDepositExecutionData(
                _targetMetavault, _kMinterAdapterAddr, _kMinterAdapterAddr, _netted.abs()
            );

            _executeAdapterCall(_kMinterAdapter, _executions);
        }
    }

    /*//////////////////////////////////////////////////////////////
                              VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ISettler
    /// @param _proposalId The proposal ID to check
    /// @return _isNettedNegative True if the proposal has negative netted assets, false otherwise
    /// @dev Checks if a settlement proposal has negative netted assets
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
    /// @param _metavault the address of the target metavault
    /// @param _kMinterAdapter the kMinter adapter address
    /// @param _vaultAdapter the vault adapter address
    /// @param _vault the vault address
    /// @param _batchInfo Struct containing batch information
    /// @return _assetData Struct containing calculated asset data
    function _calculateAssetData(
        IERC7540 _metavault,
        IMinimalSmartAccount _kMinterAdapter,
        IMinimalSmartAccount _vaultAdapter,
        IkStakingVault _vault,
        BatchInfo memory _batchInfo
    )
        internal
        returns (AssetData memory _assetData)
    {
        // Get current shares and assets in the DN adapter
        _assetData._dnAdapterShares = _metavault.balanceOf(address(_vaultAdapter));
        _assetData._dnAdapterAssets = _metavault.convertToAssets(_assetData._dnAdapterShares);
        // Calculate netted assets (difference between deposited and requested)
        _assetData._nettedAssets = _nettedAssets(
            _assetData._dnAdapterAssets,
            _batchInfo._deposited,
            _batchInfo._pendingShares,
            _metavault,
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
    /// @param _dnMetaVault Address of the delta-neutral meta-vault
    /// @param _kMinterAdapter Address of the kMinter adapter
    /// @param _dnVaultAdapter Address of the DN vault adapter
    /// @return The net amount of assets after netting (can be negative)
    function _nettedAssets(
        uint256 _dnAdapterAssets,
        uint256 _deposited,
        uint256 _pendingShares,
        IERC7540 _dnMetaVault,
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
        uint256 _nettedShares = _dnMetaVault.convertToShares(_nettedAssets_.abs());

        // Execute the netted transfer between adapters
        _executeNettedTransfer(
            _nettedAssets_ > 0, address(_dnMetaVault), address(_kMinterAdapter), address(_dnVaultAdapter), _nettedShares
        );

        return _nettedAssets_;
    }

    /// @notice Executes the netted transfer between adapters
    /// @dev Transfers shares between kMinter and DN vault adapters based on netting direction
    /// @param _isPositive Whether the netting is positive (deposited > requested)
    /// @param _metavault Address of the delta-neutral meta-vault
    /// @param _kMinterAdapter Address of the kMinter adapter
    /// @param _vaultAdapter Address of the DN vault adapter
    /// @param _nettedShares Amount of shares to transfer
    function _executeNettedTransfer(
        bool _isPositive,
        address _metavault,
        address _kMinterAdapter,
        address _vaultAdapter,
        uint256 _nettedShares
    )
        internal
    {
        Execution[] memory _executions;

        if (_isPositive) {
            // Transfer from kMinter adapter to DN vault adapter
            _executions = ExecutionDataLibrary.getTransferFromExecutionData(
                _metavault, _kMinterAdapter, _vaultAdapter, _nettedShares
            );
            _executeAdapterCall(IMinimalSmartAccount(_vaultAdapter), _executions);
        } else {
            // Transfer from DN vault adapter to kMinter adapter
            _executions = ExecutionDataLibrary.getTransferExecutionData(_metavault, _kMinterAdapter, _nettedShares);
            _executeAdapterCall(IMinimalSmartAccount(_vaultAdapter), _executions);
        }
    }

    /// @notice Rebalances assets between kMinter and DN vault adapters
    /// @dev Ensures kMinter adapter has the correct amount of assets based on kToken total supply
    /// @param _kMinterAdapter Address of the kMinter adapter
    /// @param _dnMetaVault Address of the delta-neutral meta-vault
    function _getDepeg(IMinimalSmartAccount _kMinterAdapter, IERC7540 _dnMetaVault) internal view returns (int256) {
        // Get current shares and assets in kMinter adapter
        uint256 _kMinterShares = _dnMetaVault.balanceOf(address(_kMinterAdapter));
        uint256 _actualKMinterAssets = _dnMetaVault.convertToAssets(_kMinterShares);

        // Get expected assets based on kToken total supply
        uint256 _expectedKMinterAssets = IVaultAdapter(address(_kMinterAdapter)).totalAssets();

        // Calculate difference between expected and actual
        return int256(_expectedKMinterAssets) - int256(_actualKMinterAssets);
    }

    function _rebalance(
        IMinimalSmartAccount _kMinterAdapter,
        IMinimalSmartAccount _dnVaultAdapter,
        IERC7540 _dnMetaVault,
        int256 _difference
    )
        internal
    {
        if (_difference != 0) {
            uint256 _shareValue = _dnMetaVault.convertToShares(_difference.abs());
            // Adjust any dust
            while (_dnMetaVault.convertToAssets(_shareValue) < _difference.abs()) _shareValue += 1;
            _executeRebalanceTransfer(_difference > 0, _dnMetaVault, _kMinterAdapter, _dnVaultAdapter, _shareValue);
        }
    }

    /// @notice Executes the rebalancing transfer between adapters
    /// @dev Transfers shares between adapters to achieve proper balance
    /// @param _isPositive Whether to transfer to kMinter adapter (true) or from it (false)
    /// @param _metavault Address of the delta-neutral meta-vault
    /// @param _kMinterAdapter Address of the kMinter adapter
    /// @param _vaultAdapter Address of the DN vault adapter
    /// @param _shareValue Amount of shares to transfer
    function _executeRebalanceTransfer(
        bool _isPositive,
        IERC7540 _metavault,
        IMinimalSmartAccount _kMinterAdapter,
        IMinimalSmartAccount _vaultAdapter,
        uint256 _shareValue
    )
        internal
    {
        Execution[] memory _executions;

        if (_isPositive) {
            // Transfer to kMinter adapter (from DN vault adapter)
            _executions = ExecutionDataLibrary.getTransferExecutionData(
                address(_metavault), address(_kMinterAdapter), _shareValue
            );
            _executeAdapterCall(_vaultAdapter, _executions);
        } else {
            // Transfer from kMinter adapter (to DN vault adapter)
            _executions = ExecutionDataLibrary.getTransferFromExecutionData(
                address(_metavault), address(_kMinterAdapter), address(_vaultAdapter), _shareValue
            );
            _executeAdapterCall(_vaultAdapter, _executions);
        }
    }

    /// @notice Calculates and processes fees for the vault
    /// @dev Computes management and performance fees and transfers them to treasury
    /// @param _vault Address of the vault to calculate fees for
    /// @param _dnVaultAdapter Address of the DN vault adapter
    /// @param _dnMetaVault Address of the delta-neutral meta-vault
    /// @return _lastFeesChargedDateManagement Timestamp of last management fee charge
    /// @return _lastFeesChargedDatePerformance Timestamp of last performance fee charge
    function _fees(
        IkStakingVault _vault,
        IMinimalSmartAccount _dnVaultAdapter,
        IERC7540 _dnMetaVault
    )
        internal
        returns (uint64 _lastFeesChargedDateManagement, uint64 _lastFeesChargedDatePerformance)
    {
        // Calculate fees and get timestamps
        uint256 _feeShares;
        (_feeShares, _lastFeesChargedDateManagement, _lastFeesChargedDatePerformance) = _calculateFees(_vault);

        // If there are fees to charge, execute the transfer
        if (_feeShares > 0) {
            _executeFeeTransfer(_dnMetaVault, _dnVaultAdapter, _feeShares);
        }
    }

    /// @notice Calculates management and performance fees for the vault
    /// @dev Determines if fees are due and calculates the total fee shares
    /// @param _vault Address of the vault to calculate fees for
    /// @return _feeShares Total number of fee shares to charge
    /// @return _lastFeesChargedDateManagement Timestamp of last management fee charge
    /// @return _lastFeesChargedDatePerformance Timestamp of last performance fee charge
    function _calculateFees(IkStakingVault _vault)
        internal
        view
        returns (uint256 _feeShares, uint64 _lastFeesChargedDateManagement, uint64 _lastFeesChargedDatePerformance)
    {
        // Get next fee timestamps from vault reader
        uint256 _managementFeeTimestamp = _vault.nextManagementFeeTimestamp();
        uint256 _performanceFeeTimestamp = _vault.nextPerformanceFeeTimestamp();

        // Get calculated fees from vault reader
        uint256 _totalAssets = _vault.totalAssets();

        (uint256 _managementFee, uint256 _performanceFee,) =
            _vault.computeLastBatchFeesWithAssetsAndSupply(_totalAssets, _vault.totalSupply());

        // Check if management fee is due
        if (zeroFloorSub(block.timestamp, _managementFeeTimestamp) > 0) {
            _feeShares += _managementFee;
            _lastFeesChargedDateManagement = uint64(block.timestamp);
        }

        // Check if performance fee is due
        if (zeroFloorSub(block.timestamp, _performanceFeeTimestamp) > 0) {
            _feeShares += _performanceFee;
            _lastFeesChargedDatePerformance = uint64(block.timestamp);
        }
    }

    /// @notice Executes the transfer of fee shares to the treasury
    /// @dev Transfers calculated fee shares from the meta-vault to the treasury
    /// @param _dnMetaVault Address of the delta-neutral meta-vault
    /// @param _dnVaultAdapter Address of the DN vault adapter
    /// @param _feeShares Number of fee shares to transfer
    function _executeFeeTransfer(
        IERC7540 _dnMetaVault,
        IMinimalSmartAccount _dnVaultAdapter,
        uint256 _feeShares
    )
        internal
    {
        // Get treasury address from registry
        address _treasury = registry.getTreasury();

        // Generate execution data for fee transfer
        Execution[] memory _executions =
            ExecutionDataLibrary.getTransferExecutionData(address(_dnMetaVault), _treasury, _feeShares);

        // Execute the transfer through the DN vault adapter
        _executeAdapterCall(_dnVaultAdapter, _executions);
    }

    /// @dev Returns `max(0, x - y)`. Alias for `saturatingSub`.
    function zeroFloorSub(uint256 _x, uint256 _y) internal pure returns (uint256 _z) {
        /// @solidity memory-safe-assembly
        assembly {
            _z := mul(gt(_x, _y), sub(_x, _y))
        }
    }

    /// @notice returns the vault type of the vault in the proposal
    /// @param _proposalId the proposal id to get the vault type from
    /// @return _vaultType the type of the vault in the proposal
    function _getVaultType(bytes32 _proposalId) internal view returns (uint8 _vaultType) {
        IkAssetRouter.VaultSettlementProposal memory _proposal = kAssetRouter.getSettlementProposal(_proposalId);
        _vaultType = registry.getVaultType(_proposal.vault);
    }

    /// @notice returns the target address of a given adapter
    /// @param _adapter the adapter address
    /// @return _target the target of a given adapter (metavault)
    function _getTarget(address _adapter) internal view returns (address _target) {
        address[] memory _targets = registry.getExecutorTargets(_adapter);
        _target = _targets[0];
    }

    /*//////////////////////////////////////////////////////////////
                        PROFIT DISTRIBUTION FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Calculates how many assets insurance still needs to reach target
    /// @dev Target is insuranceBps/10000 * kMinterAdapter.totalAssets()
    /// @param _metavault The metavault for share/asset conversion
    /// @param _kMinterAdapter The kMinter adapter (for totalAssets as base)
    /// @return _deficitAssets Assets still needed by insurance (0 if target met)
    function _getInsuranceDeficit(
        IERC7540 _metavault,
        IMinimalSmartAccount _kMinterAdapter
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

        // Current insurance balance in assets
        uint256 _insuranceShares = _metavault.balanceOf(_insurance);
        uint256 _insuranceAssets = _metavault.convertToAssets(_insuranceShares);

        if (_insuranceAssets >= _insuranceTarget) return 0;

        _deficitAssets = _insuranceTarget - _insuranceAssets;
    }

    /// @notice Distributes profit shares according to priority: insurance -> treasury -> vault adapter
    /// @dev All distributions are in metavault shares. Remaining profit stays with kMinter.
    /// @param _metavault The metavault contract
    /// @param _kMinterAdapter The kMinter adapter holding the profit shares
    /// @param _profitAssets Total profit in assets (absolute value of negative depeg)
    /// @param _profitShareBps Basis points of remaining profit to send to vault adapter
    /// @param _isVaultSettlement True if this is a DN/custodial vault settlement
    /// @return _sharesToVaultAdapter Shares that should be transferred to vault adapter
    function _distributeProfitShares(
        IERC7540 _metavault,
        IMinimalSmartAccount _kMinterAdapter,
        uint256 _profitAssets,
        uint16 _profitShareBps,
        bool _isVaultSettlement
    )
        internal
        returns (uint256 _sharesToVaultAdapter)
    {
        if (_profitAssets == 0) return 0;

        // Convert profit to shares
        uint256 _profitShares = _metavault.convertToShares(_profitAssets);
        // Adjust for dust
        while (_metavault.convertToAssets(_profitShares) < _profitAssets) {
            _profitShares += 1;
        }

        uint256 _remainingShares = _profitShares;

        // Get settlement config
        (address _treasury, address _insurance, uint16 _treasuryBps,) = registry.getSettlementConfig();

        // 1. Insurance priority distribution
        uint256 _insuranceDeficitAssets = _getInsuranceDeficit(_metavault, _kMinterAdapter);
        uint256 _insuranceShares = 0;

        if (_insuranceDeficitAssets > 0 && _insurance != address(0)) {
            uint256 _insuranceDeficitShares = _metavault.convertToShares(_insuranceDeficitAssets);
            _insuranceShares = _remainingShares < _insuranceDeficitShares ? _remainingShares : _insuranceDeficitShares;

            if (_insuranceShares > 0) {
                _executeShareTransfer(_metavault, _kMinterAdapter, _insurance, _insuranceShares);
                _remainingShares -= _insuranceShares;
            }
        }

        // 2. Treasury distribution (from remaining profit)
        uint256 _treasuryShares = 0;
        if (_remainingShares > 0 && _treasuryBps > 0 && _treasury != address(0)) {
            _treasuryShares = (_remainingShares * _treasuryBps) / 10_000;
            if (_treasuryShares > 0) {
                _executeShareTransfer(_metavault, _kMinterAdapter, _treasury, _treasuryShares);
                _remainingShares -= _treasuryShares;
            }
        }

        // 3. Remaining profit goes to vault adapter to maintain kMinter peg
        // kMinter should never hold excess profit - it must stay pegged to kToken supply
        // For vault settlements: ALL remaining shares go to the vault adapter being settled
        // The profitShareBps parameter controls how much of this the settled vault keeps vs DN vault
        // (handled by caller for non-DN settlements)
        if (_isVaultSettlement && _remainingShares > 0) {
            _sharesToVaultAdapter = _remainingShares * _profitShareBps / 10_000;
        }

        emit ProfitDistributed(_insuranceShares, _treasuryShares, _sharesToVaultAdapter);
    }

    /// @notice Transfers shares from kMinter adapter to a recipient
    /// @dev Uses ExecutionDataLibrary pattern for ERC20 transfer
    /// @param _metavault The metavault (ERC20 token to transfer)
    /// @param _kMinterAdapter The adapter executing the transfer
    /// @param _recipient The recipient address (insurance or treasury)
    /// @param _shares Number of shares to transfer
    function _executeShareTransfer(
        IERC7540 _metavault,
        IMinimalSmartAccount _kMinterAdapter,
        address _recipient,
        uint256 _shares
    )
        internal
    {
        Execution[] memory _executions =
            ExecutionDataLibrary.getTransferExecutionData(address(_metavault), _recipient, _shares);
        _executeAdapterCall(_kMinterAdapter, _executions);
    }
}
