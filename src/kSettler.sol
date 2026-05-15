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
    KSETTLER_ASSET_MISMATCH,
    KSETTLER_BATCH_ALREADY_CLOSED,
    KSETTLER_BATCH_ALREADY_SETTLED,
    KSETTLER_INSUFFICIENT_BALANCE,
    KSETTLER_INVALID_TARGET_TYPE,
    KSETTLER_INVALID_VAULT_TYPE,
    KSETTLER_MISSING_ALLOWANCE,
    KSETTLER_PROPOSAL_ALREADY_FINALISED,
    KSETTLER_PROPOSAL_NOT_EXECUTED
} from "./errors/Errors.sol";

import "forge-std/console2.sol";
import { IRegistry as IRegistryBase } from "kam/src/interfaces/IRegistry.sol";
import { IExecutionGuardian } from "kam/src/interfaces/modules/IExecutionGuardian.sol";
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
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    struct PendingSettlement {
        bool isActive;
        bool isMinter;
        address asset;
        address metawallet;
        address minterAdapter;
        address vaultAdapter;
        int256 minterNettedAmount;
        int256 netSharesToVaultAdapter;
        uint256 sharesToInsurance;
        uint256 sharesToTreasury;
        uint256 profitSharesToVaultAdapter;
    }

    mapping(bytes32 => PendingSettlement) public pendingSettlements;

    /*//////////////////////////////////////////////////////////////
                              ROLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Admin role for authorized operations
    uint256 internal constant ADMIN_ROLE = _ROLE_0;

    /// @notice Relayer role for settlement automation
    /// @dev Named SETTLER_RELAYER_ROLE to disambiguate from KAM's RELAYER_ROLE (_ROLE_3).
    uint256 internal constant SETTLER_RELAYER_ROLE = _ROLE_1;

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
        _grantRoles(_relayer, SETTLER_RELAYER_ROLE);
    }

    /*//////////////////////////////////////////////////////////////
                              ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IkSettler
    function grantAdminRole(address _admin) external {
        _checkOwner();
        require(_admin != address(0), KSETTLER_ADDRESS_ZERO);
        _grantRoles(_admin, ADMIN_ROLE);
    }

    /// @inheritdoc IkSettler
    function revokeAdminRole(address _admin) external {
        _checkOwner();
        _removeRoles(_admin, ADMIN_ROLE);
    }

    /// @inheritdoc IkSettler
    function grantRelayerRole(address _relayer) external payable {
        _checkRoles(ADMIN_ROLE);
        require(_relayer != address(0), KSETTLER_ADDRESS_ZERO);
        _grantRoles(_relayer, SETTLER_RELAYER_ROLE);
    }

    /// @inheritdoc IkSettler
    function revokeRelayerRole(address _relayer) external payable {
        _checkRoles(ADMIN_ROLE);
        _removeRoles(_relayer, SETTLER_RELAYER_ROLE);
    }

    /*//////////////////////////////////////////////////////////////
                            kMINTER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IkSettler
    function closeAndProposeMinterBatch(address _asset) external payable returns (bytes32 _proposalId) {
        _lockReentrant();
        _checkRoles(SETTLER_RELAYER_ROLE);

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
        address _target = _getTarget(address(_adapter), IExecutionGuardian.TargetType.METAWALLET);

        // Get batch balances and calculate netted assets
        (uint256 _deposited, uint256 _requested) = kAssetRouter.getBatchIdBalances(address(kMinter), _batchInfo.batchId);
        int256 _nettedAmount = int256(_deposited) - int256(_requested);

        uint256 _adapterAssets = IVaultAdapter(address(_adapter)).totalAssets();

        _proposalId = kAssetRouter.proposeSettleBatch(_asset, address(kMinter), _batchId, _adapterAssets);

        pendingSettlements[_proposalId] = PendingSettlement({
            isActive: true,
            isMinter: true,
            asset: _asset,
            metawallet: _target,
            minterAdapter: address(_adapter),
            vaultAdapter: address(0),
            minterNettedAmount: _nettedAmount,
            netSharesToVaultAdapter: 0,
            sharesToInsurance: 0,
            sharesToTreasury: 0,
            profitSharesToVaultAdapter: 0
        });

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
        _checkRoles(SETTLER_RELAYER_ROLE);

        // Get all required addresses for the asset
        IMinimalSmartAccount _kMinterAdapter = IMinimalSmartAccount(registry.getAdapter(address(kMinter), _asset));
        IkStakingVault _vault =
            IkStakingVault(registry.getVaultByAssetAndType(_asset, uint8(IRegistryBase.VaultType.DN)));
        IMinimalSmartAccount _vaultAdapter = IMinimalSmartAccount(registry.getAdapter(address(_vault), _asset));
        address _target = _getTarget(address(_vaultAdapter), IExecutionGuardian.TargetType.METAWALLET);
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

        // Apply profit/loss distribution and rebalancing based on depeg direction.
        // Extracted into a dedicated frame to keep this function within EVM stack limits.
        (int256 _depegSharesVault, uint256 _sharesToInsurance, uint256 _sharesToTreasury) =
            _handleDepeg(_depeg, _asset, _vault.totalSupply() != 0, _metawallet, _kMinterAdapter);

        // Calculate final asset data for settlement. Netting is computed but not transferred yet;
        // the physical MetaWallet share transfer runs in executeSettleBatch before router execution.
        (uint256 _newTotalAssets, int256 _nettedSharesVault) =
            _calculateAssetDataSimulated(_metawallet, _vault, _batchInfo, _depegSharesVault);

        // Propose the batch settlement to the asset router
        _proposalId = kAssetRouter.proposeSettleBatch(_asset, address(_vault), _batchInfo._batchId, _newTotalAssets);

        // Calculate pure profit shares to the vault adapter for the event (only when _depegSharesVault > 0 and there is
        // supply)
        uint256 _profitSharesToVaultAdapter = 0;
        if (_depegSharesVault > 0 && _vault.totalSupply() != 0) {
            _profitSharesToVaultAdapter = uint256(_depegSharesVault);
        }

        pendingSettlements[_proposalId] = PendingSettlement({
            isActive: true,
            isMinter: false,
            asset: _asset,
            metawallet: address(_metawallet),
            minterAdapter: address(_kMinterAdapter),
            vaultAdapter: address(_vaultAdapter),
            minterNettedAmount: 0,
            netSharesToVaultAdapter: _depegSharesVault + _nettedSharesVault,
            sharesToInsurance: _sharesToInsurance,
            sharesToTreasury: _sharesToTreasury,
            profitSharesToVaultAdapter: _profitSharesToVaultAdapter
        });
    }

    /*//////////////////////////////////////////////////////////////
                            EXECUTE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IkSettler
    function executeSettleBatch(bytes32 _proposalId) external payable {
        _lockReentrant();
        _checkRoles(SETTLER_RELAYER_ROLE);

        PendingSettlement memory _pending = pendingSettlements[_proposalId];
        if (_pending.isActive) {
            _executePendingSettlement(_pending);
            delete pendingSettlements[_proposalId];
        }

        kAssetRouter.executeSettleBatch(_proposalId);

        _unlockReentrant();
    }

    /// @notice Clears a cancelled pending settlement payload
    function clearCancelledSettlement(bytes32 _proposalId) external {
        _lockReentrant();
        _checkRoles(SETTLER_RELAYER_ROLE);
        require(!kAssetRouter.isProposalPending(_proposalId), KSETTLER_PROPOSAL_NOT_EXECUTED);
        delete pendingSettlements[_proposalId];
    }

    /// @notice Executes the deferred physical share transfers for a settlement proposal
    function _executePendingSettlement(PendingSettlement memory _pending) internal {
        if (_pending.isMinter) {
            if (_pending.minterNettedAmount < 0) {
                uint256 _abs = uint256(-_pending.minterNettedAmount);
                Execution[] memory _executions = ExecutionDataLibrary.getWithdrawExecutionData(
                    _pending.metawallet, _pending.minterAdapter, _pending.minterAdapter, _abs
                );
                _executeAdapterCall(IMinimalSmartAccount(_pending.minterAdapter), _executions);
            } else if (_pending.minterNettedAmount > 0) {
                Execution[] memory _executions = ExecutionDataLibrary.getDepositExecutionData(
                    _pending.metawallet, _pending.minterAdapter, uint256(_pending.minterNettedAmount)
                );
                _executeAdapterCall(IMinimalSmartAccount(_pending.minterAdapter), _executions);
            }
        } else {
            IERC4626 _metawallet = IERC4626(_pending.metawallet);
            IMinimalSmartAccount _kMinterAdapter = IMinimalSmartAccount(_pending.minterAdapter);
            IMinimalSmartAccount _vaultAdapter = IMinimalSmartAccount(_pending.vaultAdapter);

            if (_pending.sharesToInsurance > 0) {
                (, address _insurance,,) = registry.getSettlementConfig();
                Execution[] memory _exe = ExecutionDataLibrary.getTransferExecutionData(
                    address(_metawallet), _insurance, _pending.sharesToInsurance
                );
                _executeAdapterCall(_kMinterAdapter, _exe);
            }
            if (_pending.sharesToTreasury > 0) {
                (address _treasury,,,) = registry.getSettlementConfig();
                Execution[] memory _exe = ExecutionDataLibrary.getTransferExecutionData(
                    address(_metawallet), _treasury, _pending.sharesToTreasury
                );
                _executeAdapterCall(_kMinterAdapter, _exe);
            }
            if (_pending.netSharesToVaultAdapter != 0) {
                _executeNettedTransfer(
                    _pending.netSharesToVaultAdapter > 0,
                    address(_metawallet),
                    address(_kMinterAdapter),
                    address(_vaultAdapter),
                    _pending.netSharesToVaultAdapter > 0
                        ? uint256(_pending.netSharesToVaultAdapter)
                        : uint256(-_pending.netSharesToVaultAdapter)
                );
            }

            if (
                _pending.sharesToInsurance > 0 || _pending.sharesToTreasury > 0
                    || _pending.profitSharesToVaultAdapter > 0
            ) {
                emit ProfitDistributed(
                    _pending.sharesToInsurance, _pending.sharesToTreasury, _pending.profitSharesToVaultAdapter
                );
            }
        }
    }

    /// @inheritdoc IkSettler
    function liquidateInsurance(address _asset, address _metawallet) external payable {
        _lockReentrant();
        _checkRoles(SETTLER_RELAYER_ROLE);

        require(_metawallet != address(0), KSETTLER_ADDRESS_ZERO);
        require(IERC4626(_metawallet).asset() == _asset, KSETTLER_ASSET_MISMATCH);

        (, address _insurance,,) = registry.getSettlementConfig();
        require(_insurance != address(0), KSETTLER_ADDRESS_ZERO);

        IERC4626 _metawalletContract = IERC4626(_metawallet);
        uint256 _shares = _metawalletContract.balanceOf(_insurance);
        if (_shares == 0) {
            _unlockReentrant();
            return;
        }

        uint256 _assetsValue = _metawalletContract.convertToAssets(_shares);

        Execution[] memory _executions =
            ExecutionDataLibrary.getWithdrawExecutionData(_metawallet, _insurance, _insurance, _assetsValue);
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
        _checkRoles(SETTLER_RELAYER_ROLE);

        // Only custodial vaults can use the generic proposeSettleBatch.
        // kMinter and DN vaults must settle through their dedicated functions.
        uint8 _vaultType = registry.getVaultType(_vault);
        require(
            _vaultType != uint8(IRegistryBase.VaultType.MINTER) && _vaultType != uint8(IRegistryBase.VaultType.DN),
            KSETTLER_INVALID_VAULT_TYPE
        );

        _proposalId = kAssetRouter.proposeSettleBatch(_asset, _vault, _batchId, _totalAssets);
        _unlockReentrant();
    }

    /// @inheritdoc IkSettler
    function closeVaultBatch(address _vault, bytes32 _batchId, bool _create) external payable {
        _lockReentrant();
        _checkRoles(SETTLER_RELAYER_ROLE);

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
        _checkRoles(SETTLER_RELAYER_ROLE);

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

        // Apply netted-based redemption / deposit in an isolated stack frame.
        // Keeps this function within EVM stack limits (ABI decoder for `VaultSettlementProposal` is heavy).
        _finaliseCustodialNetted(
            _proposal.netted,
            _proposal.asset,
            _getTarget(address(_kMinterAdapter), IExecutionGuardian.TargetType.METAWALLET),
            _getTarget(address(_vaultAdapter), IExecutionGuardian.TargetType.CUSTODIAL),
            _kMinterAdapter
        );
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

        // Get deposited amount and pending shares in a single router call.
        // The previously-separate getRequestedShares read the same `requestedSharesInBatch`
        // value that getBatchIdBalances returns as its second tuple element.
        (_batchInfo._deposited, _batchInfo._pendingShares) =
            kAssetRouter.getBatchIdBalances(address(_vault), _batchInfo._batchId);
    }

    /// @notice Calculates asset data for settlement
    /// @dev Determines current adapter shares/assets, calculates deferred netted shares, and computes the simulated
    ///      totalAssets passed to the router. Physical MetaWallet share transfers run in executeSettleBatch before
    ///      router accounting is updated.
    /// @param _metawallet the address of the target metawallet
    /// @param _vault the vault address
    /// @param _batchInfo Struct containing batch information
    /// @param _depegSharesVault The depeg shares
    /// @return _newTotalAssets Struct containing calculated asset data
    /// @return _nettedSharesVault The netted shares
    function _calculateAssetDataSimulated(
        IERC4626 _metawallet,
        IkStakingVault _vault,
        BatchInfo memory _batchInfo,
        int256 _depegSharesVault
    )
        internal
        view
        returns (uint256 _newTotalAssets, int256 _nettedSharesVault)
    {
        uint256 _dnAdapterShares = _metawallet.balanceOf(registry.getAdapter(address(_vault), _metawallet.asset()));
        uint256 _dnAdapterAssets = _metawallet.convertToAssets(_dnAdapterShares);

        uint256 _requestedAssets =
            _vault.convertToAssetsWithTotals(_batchInfo._pendingShares, _dnAdapterAssets, _vault.totalSupply());

        int256 _nettedAssets_ = int256(_batchInfo._deposited) - int256(_requestedAssets);

        if (_nettedAssets_ != 0) {
            uint256 _absShares = _metawallet.convertToShares(_nettedAssets_.abs());
            _nettedSharesVault = _nettedAssets_ > 0 ? int256(_absShares) : -int256(_absShares);
        }

        int256 _projectedSharesWithoutNetting = int256(_dnAdapterShares) + _depegSharesVault;
        require(_projectedSharesWithoutNetting >= 0, "KSETTLER_NEGATIVE_SHARES");
        _newTotalAssets = _metawallet.convertToAssets(uint256(_projectedSharesWithoutNetting));
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

    /// @notice Applies the netted redemption / deposit flow for a custodial settlement
    /// @dev Isolated into its own stack frame to keep `finaliseCustodialSettlement` within EVM stack limits.
    ///      The auto-generated ABI decoder for `VaultSettlementProposal` is heavy; offloading this block
    ///      frees the slots needed by `dataEnd` in the parent's decoder.
    ///      - `_netted > 0`: redeem from MetaWallet via kMinter adapter, then transfer underlying to custodial target.
    ///      - `_netted < 0`: deposit underlying back into MetaWallet via kMinter adapter.
    ///      - `_netted == 0`: no-op.
    /// @param _netted The signed netted amount for the batch (deposited - requested)
    /// @param _asset The underlying asset address (e.g., USDC)
    /// @param _targetMetawallet The MetaWallet target behind the kMinter adapter
    /// @param _targetCustodial The custodial target (e.g., CEFFU) behind the vault adapter
    /// @param _kMinterAdapter The kMinter adapter executing the transfers
    function _finaliseCustodialNetted(
        int256 _netted,
        address _asset,
        address _targetMetawallet,
        address _targetCustodial,
        IMinimalSmartAccount _kMinterAdapter
    )
        internal
    {
        if (_netted == 0) return;

        address _kMinterAdapterAddr = address(_kMinterAdapter);

        if (_netted > 0) {
            uint256 _nettedAbs = uint256(_netted);

            // Redeem assets from MetaWallet using the kMinter adapter
            Execution[] memory _executions = ExecutionDataLibrary.getWithdrawExecutionData(
                _targetMetawallet, _kMinterAdapterAddr, _kMinterAdapterAddr, _nettedAbs
            );
            _executeAdapterCall(_kMinterAdapter, _executions);

            require(IkToken(_asset).balanceOf(_kMinterAdapterAddr) >= _nettedAbs, KSETTLER_INSUFFICIENT_BALANCE);

            // Transfer underlying to the custodial target (e.g., CEFFU)
            _executions = ExecutionDataLibrary.getTransferExecutionData(_asset, _targetCustodial, _nettedAbs);
            _executeAdapterCall(_kMinterAdapter, _executions);
        } else {
            Execution[] memory _executions =
                ExecutionDataLibrary.getDepositExecutionData(_targetMetawallet, _kMinterAdapterAddr, _netted.abs());
            _executeAdapterCall(_kMinterAdapter, _executions);
        }
    }

    /// @notice returns the target address of a given adapter matching the expected type
    /// @param _adapter the adapter address
    /// @param _expectedType the expected target type
    /// @return _target the target of a given adapter matching the expected type
    function _getTarget(
        address _adapter,
        IExecutionGuardian.TargetType _expectedType
    )
        internal
        view
        returns (address _target)
    {
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

    /// @notice Applies depeg-driven profit/loss handling between kMinter and DN vault adapters
    /// @dev Isolated into its own stack frame to keep `_closeAndProposeDNVaultBatch` within EVM stack limits.
    ///      - `_depeg > 0`  (profit): distribute via insurance -> treasury -> vault adapter (or treasury when no
    ///        stakers exist to avoid stranding value on the kMinter adapter).
    ///      - `_depeg < 0`  (loss): only transferred from vault adapter when stakers exist to bear the loss.
    ///      - `_depeg == 0`: no-op.
    /// @param _depeg The signed depeg delta (post-settle minus pre-settle kMinter MetaWallet value)
    /// @param _asset The underlying asset address (e.g., USDC)
    /// @param _hasSupply Whether the DN vault has any staker supply
    /// @param _metawallet The MetaWallet (ERC4626) shared between kMinter and DN adapters
    /// @param _kMinterAdapter The kMinter adapter holding shares to redistribute
    function _handleDepeg(
        int256 _depeg,
        address _asset,
        bool _hasSupply,
        IERC4626 _metawallet,
        IMinimalSmartAccount _kMinterAdapter
    )
        internal
        view
        returns (int256 _depegSharesVault, uint256 _sharesToInsurance, uint256 _sharesToTreasury)
    {
        if (_depeg > 0) {
            uint256 _sharesToVaultAdapter;
            (_sharesToVaultAdapter, _sharesToInsurance, _sharesToTreasury) =
                _distributeProfitShares(_metawallet, _kMinterAdapter, uint256(_depeg), true, _asset);

            if (_sharesToVaultAdapter > 0) {
                if (_hasSupply) {
                    _depegSharesVault = int256(_sharesToVaultAdapter);
                } else {
                    _sharesToTreasury += _sharesToVaultAdapter;
                }
            }
        } else if (_depeg < 0 && _hasSupply) {
            uint256 _lossAssets = uint256(-_depeg);
            uint256 _shareValue = _metawallet.convertToShares(_lossAssets);
            while (_metawallet.convertToAssets(_shareValue) < _lossAssets) {
                _shareValue += 1;
            }
            _depegSharesVault = -int256(_shareValue);
        }
    }

    /// @notice Calculates how many assets insurance still needs to reach target
    /// @dev Target is insuranceBps/10000 * kMinterAdapter.totalAssets()
    /// @param _metawallet The metawallet for share/asset conversion
    /// @param _kMinterAdapter The kMinter adapter (for totalAssets as base)
    /// @param _asset The underlying asset address (e.g., USDC)
    /// @return _deficitAssets Assets still needed by insurance (0 if target met)
    function _getInsuranceDeficit(
        IERC4626 _metawallet,
        IMinimalSmartAccount _kMinterAdapter,
        address _asset,
        address _insurance,
        uint16 _insuranceBps
    )
        internal
        view
        returns (uint256 _deficitAssets)
    {
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
        view
        returns (uint256 _sharesToVaultAdapter, uint256 _sharesToInsurance, uint256 _sharesToTreasury)
    {
        if (_profitAssets == 0) return (0, 0, 0);

        uint256 _profitShares = _metawallet.convertToShares(_profitAssets);
        while (_metawallet.convertToAssets(_profitShares) < _profitAssets) {
            _profitShares += 1;
        }

        uint256 _remainingShares = _profitShares;
        (address _treasury, address _insurance, uint16 _treasuryBps, uint16 _insuranceBps) =
            registry.getSettlementConfig();

        uint256 _insuranceDeficitAssets =
            _getInsuranceDeficit(_metawallet, _kMinterAdapter, _asset, _insurance, _insuranceBps);

        if (_insuranceDeficitAssets > 0 && _insurance != address(0)) {
            uint256 _insuranceDeficitShares = _metawallet.convertToShares(_insuranceDeficitAssets);
            while (_metawallet.convertToAssets(_insuranceDeficitShares) < _insuranceDeficitAssets) {
                _insuranceDeficitShares += 1;
            }
            _sharesToInsurance = _remainingShares < _insuranceDeficitShares ? _remainingShares : _insuranceDeficitShares;

            if (_sharesToInsurance > 0) {
                _remainingShares -= _sharesToInsurance;
            }
        }

        if (_remainingShares > 0 && _treasuryBps > 0 && _treasury != address(0)) {
            _sharesToTreasury = (_remainingShares * _treasuryBps) / 10_000;
            if (_sharesToTreasury > 0) {
                _remainingShares -= _sharesToTreasury;
            }
        }

        if (_isVaultSettlement && _remainingShares > 0) {
            _sharesToVaultAdapter = _remainingShares;
        }
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
