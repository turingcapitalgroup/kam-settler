// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

// External Libraries
import { OptimizedOwnableRoles } from "kam/src/vendor/solady/auth/OptimizedOwnableRoles.sol";
import { OptimizedFixedPointMathLib } from "kam/src/vendor/solady/utils/OptimizedFixedPointMathLib.sol";
import { OptimizedReentrancyGuardTransient } from "kam/src/vendor/solady/utils/OptimizedReentrancyGuardTransient.sol";
import { Execution, ExecutionLib } from "minimal-smart-account/libraries/ExecutionLib.sol";
import { ModeCode, ModeLib } from "minimal-smart-account/libraries/ModeLib.sol";

// Internal Libraries
import { ExecutionDataLibrary } from "./libraries/ExecutionDataLibrary.sol";

// Local Interfaces
import { IRegistry } from "./interfaces/IRegistry.sol";
import { IVaultAdapter, IkAssetRouter, IkMinter, IkSettler, IkStakingVault, IkToken } from "./interfaces/IkSettler.sol";
import { IRegistry as IRegistryBase } from "kam/src/interfaces/IRegistry.sol";
import { IExecutionGuardian } from "kam/src/interfaces/modules/IExecutionGuardian.sol";
import { IERC4626 } from "metawallet/src/interfaces/IERC4626.sol";
import { IVaultModule } from "metawallet/src/interfaces/IVaultModule.sol";
import { IMinimalSmartAccount } from "minimal-smart-account/interfaces/IMinimalSmartAccount.sol";

// Errors
import {
    KSETTLER_ADDRESS_ZERO,
    KSETTLER_ASSET_MISMATCH,
    KSETTLER_BATCH_ALREADY_CLOSED,
    KSETTLER_BATCH_ALREADY_SETTLED,
    KSETTLER_DEPEG_LOSS_EXCEEDS_DN_POSITION,
    KSETTLER_INSUFFICIENT_BALANCE,
    KSETTLER_INVALID_TARGET_TYPE,
    KSETTLER_INVALID_VAULT_TYPE,
    KSETTLER_MISSING_ALLOWANCE,
    KSETTLER_PROPOSAL_ALREADY_FINALISED,
    KSETTLER_PROPOSAL_NOT_EXECUTED,
    KSETTLER_PROPOSAL_STILL_PENDING
} from "./errors/Errors.sol";

/// @title kSettler
/// @notice Settlement entrypoint for kMinter, DN, and custodial vault batches.
/// @dev Closes batches on the kMinter / staking vault, proposes settlement to the kAssetRouter,
///      and at execute time performs the deferred MetaWallet share movements (depeg distribution
///      and netting) immediately before the router updates adapter accounting.
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
                            PENDING SETTLEMENTS
    //////////////////////////////////////////////////////////////*/

    mapping(bytes32 => DNPendingSettlement) public pendingDNSettlements;

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
    /// @dev kSettler holds no per-proposal state for minter settlements: the deferred MetaWallet
    ///      movement at execute time is fully derivable from the router proposal + registry.
    function closeAndProposeMinterBatch(address _asset) external payable returns (bytes32 _proposalId) {
        _lockReentrant();
        _checkRoles(SETTLER_RELAYER_ROLE);

        bytes32 _batchId = kMinter.getBatchId(_asset);
        IkMinter.BatchInfo memory _batchInfo = kMinter.getBatchInfo(_batchId);
        require(!_batchInfo.isClosed, KSETTLER_BATCH_ALREADY_CLOSED);
        require(!_batchInfo.isSettled, KSETTLER_BATCH_ALREADY_SETTLED);

        kMinter.closeBatch(_batchId, true);

        address _adapter = registry.getAdapter(address(kMinter), _asset);
        _proposalId =
            kAssetRouter.proposeSettleBatch(_asset, address(kMinter), _batchId, IVaultAdapter(_adapter).totalAssets());

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

    /// @notice Internal implementation for closing and proposing a DN vault batch
    /// @param _asset The asset address for which to close the batch
    /// @param _newMetaWalletTotalAssets The new total assets for the MetaWallet (idle + strategies)
    /// @param _rootHash The merkle root committing to the strategy breakdown
    function _closeAndProposeDNVaultBatch(
        address _asset,
        uint256 _newMetaWalletTotalAssets,
        bytes32 _rootHash
    )
        internal
        returns (bytes32 _proposalId)
    {
        _checkRoles(SETTLER_RELAYER_ROLE);

        IMinimalSmartAccount _kMinterAdapter = IMinimalSmartAccount(registry.getAdapter(address(kMinter), _asset));
        IkStakingVault _vault =
            IkStakingVault(registry.getVaultByAssetAndType(_asset, uint8(IRegistryBase.VaultType.DN)));
        IMinimalSmartAccount _vaultAdapter = IMinimalSmartAccount(registry.getAdapter(address(_vault), _asset));
        IERC4626 _metawallet = IERC4626(_getTarget(address(_vaultAdapter), IExecutionGuardian.TargetType.METAWALLET));

        // Compute depeg as the rate delta on the kMinter MetaWallet position around settleTotalAssets.
        // Snapshotting before/after isolates pure yield/loss from any prior minter activity.
        uint256 _valueBefore = _metawallet.convertToAssets(_metawallet.balanceOf(address(_kMinterAdapter)));
        IVaultModule(address(_metawallet)).settleTotalAssets(_newMetaWalletTotalAssets, _rootHash);
        int256 _depeg =
            int256(_metawallet.convertToAssets(_metawallet.balanceOf(address(_kMinterAdapter)))) - int256(_valueBefore);

        BatchInfo memory _batchInfo = _getBatchInfo(_vault);
        require(!_batchInfo.isClosed, KSETTLER_BATCH_ALREADY_CLOSED);
        require(!_batchInfo.isSettled, KSETTLER_BATCH_ALREADY_SETTLED);
        _vault.closeBatch(_batchInfo.batchId, true);

        bool _hasSupply = _vault.totalSupply() != 0;

        (int256 _depegSharesVault, uint256 _sharesToInsurance, uint256 _sharesToTreasury) =
            _handleDepeg(_depeg, _asset, _hasSupply, _metawallet, _kMinterAdapter);

        // DN adapter totalAssets to propose: current MetaWallet position adjusted for depeg, pre-netting.
        uint256 _newTotalAssets;
        {
            int256 _projected = int256(_metawallet.balanceOf(address(_vaultAdapter))) + _depegSharesVault;
            require(_projected >= 0, KSETTLER_DEPEG_LOSS_EXCEEDS_DN_POSITION);
            _newTotalAssets = _metawallet.convertToAssets(uint256(_projected));
        }

        _proposalId = kAssetRouter.proposeSettleBatch(_asset, address(_vault), _batchInfo.batchId, _newTotalAssets);

        // Only kSettler-derived state needs to survive into execute. Asset / adapters / netted are
        // all on the router proposal and re-derived there.
        pendingDNSettlements[_proposalId] = DNPendingSettlement({
            depegSharesVault: _depegSharesVault,
            sharesToInsurance: _sharesToInsurance,
            sharesToTreasury: _sharesToTreasury
        });
    }

    /*//////////////////////////////////////////////////////////////
                            EXECUTE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IkSettler
    function executeSettleBatch(bytes32 _proposalId) external payable {
        _lockReentrant();
        _checkRoles(SETTLER_RELAYER_ROLE);

        IkAssetRouter.VaultSettlementProposal memory _proposal = kAssetRouter.getSettlementProposal(_proposalId);
        uint8 _vaultType = registry.getVaultType(_proposal.vault);

        if (_vaultType == uint8(IRegistryBase.VaultType.MINTER)) {
            _executeMinterSettlement(_proposal);
        } else if (_vaultType == uint8(IRegistryBase.VaultType.DN)) {
            _executeDNSettlement(_proposal, pendingDNSettlements[_proposalId]);
            delete pendingDNSettlements[_proposalId];
        }
        // custodial vaults: nothing to do here, router handles them.

        kAssetRouter.executeSettleBatch(_proposalId);

        _unlockReentrant();
    }

    /// @notice Discards a DN pending settlement whose proposal was cancelled on the router.
    function clearCancelledSettlement(bytes32 _proposalId) external {
        _lockReentrant();
        _checkRoles(SETTLER_RELAYER_ROLE);
        require(!kAssetRouter.isProposalPending(_proposalId), KSETTLER_PROPOSAL_STILL_PENDING);
        delete pendingDNSettlements[_proposalId];
    }

    /// @notice Runs the MetaWallet deposit/withdraw for a kMinter settlement.
    /// @dev `proposal.netted` is in asset units (kToken == asset). Positive = deposit into MetaWallet,
    ///      negative = withdraw out of MetaWallet, both via the kMinter adapter.
    function _executeMinterSettlement(IkAssetRouter.VaultSettlementProposal memory _proposal) internal {
        int256 _netted = _proposal.netted;
        if (_netted == 0) return;

        address _adapter = registry.getAdapter(address(kMinter), _proposal.asset);
        address _metawallet = _getTarget(_adapter, IExecutionGuardian.TargetType.METAWALLET);

        Execution[] memory _executions = _netted < 0
            ? ExecutionDataLibrary.getWithdrawExecutionData(_metawallet, _adapter, _adapter, uint256(-_netted))
            : ExecutionDataLibrary.getDepositExecutionData(_metawallet, _adapter, uint256(_netted));
        _executeAdapterCall(IMinimalSmartAccount(_adapter), _executions);
    }

    /// @notice Runs the MetaWallet movements for a DN settlement: insurance / treasury payouts from
    ///         the kMinter adapter, plus the combined depeg + netted share transfer between adapters.
    function _executeDNSettlement(
        IkAssetRouter.VaultSettlementProposal memory _proposal,
        DNPendingSettlement memory _pending
    )
        internal
    {
        address _kMinterAdapter = registry.getAdapter(address(kMinter), _proposal.asset);
        address _vaultAdapter = _proposal.adapter;
        IERC4626 _metawallet = IERC4626(_getTarget(_vaultAdapter, IExecutionGuardian.TargetType.METAWALLET));

        if (_pending.sharesToInsurance != 0 || _pending.sharesToTreasury != 0) {
            (address _treasury, address _insurance,,) = registry.getSettlementConfig();
            if (_pending.sharesToInsurance != 0) {
                _executeAdapterCall(
                    IMinimalSmartAccount(_kMinterAdapter),
                    ExecutionDataLibrary.getTransferExecutionData(
                        address(_metawallet), _insurance, _pending.sharesToInsurance
                    )
                );
            }
            if (_pending.sharesToTreasury != 0) {
                _executeAdapterCall(
                    IMinimalSmartAccount(_kMinterAdapter),
                    ExecutionDataLibrary.getTransferExecutionData(
                        address(_metawallet), _treasury, _pending.sharesToTreasury
                    )
                );
            }
        }

        // Combine depeg movement (kSettler-computed at propose) with netted movement (router-stored,
        // converted to MetaWallet shares at execute time).
        int256 _net = _pending.depegSharesVault;
        if (_proposal.netted != 0) {
            uint256 _abs = _metawallet.convertToShares(
                _proposal.netted < 0 ? uint256(-_proposal.netted) : uint256(_proposal.netted)
            );
            _net += _proposal.netted > 0 ? int256(_abs) : -int256(_abs);
        }
        if (_net != 0) {
            _executeNettedTransfer(
                _net > 0,
                address(_metawallet),
                _kMinterAdapter,
                _vaultAdapter,
                _net > 0 ? uint256(_net) : uint256(-_net)
            );
        }

        if (_pending.sharesToInsurance != 0 || _pending.sharesToTreasury != 0 || _pending.depegSharesVault > 0) {
            emit ProfitDistributed(
                _pending.sharesToInsurance,
                _pending.sharesToTreasury,
                _pending.depegSharesVault > 0 ? uint256(_pending.depegSharesVault) : 0
            );
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
    function isNettedNegative(bytes32 _proposalId) external view returns (bool) {
        return kAssetRouter.getSettlementProposal(_proposalId).netted < 0;
    }

    /*//////////////////////////////////////////////////////////////
                              INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Encodes and dispatches a batch of executions through a MinimalSmartAccount
    function _executeAdapterCall(IMinimalSmartAccount _adapter, Execution[] memory _executions) internal {
        bytes memory _executionCalldata = ExecutionLib.encodeBatch(_executions);
        ModeCode _mode = ModeLib.encodeSimpleBatch();
        _adapter.execute(_mode, _executionCalldata);
    }

    /// @notice Reads the current batch's id and closed/settled flags for a vault
    /// @dev Deposits and requested shares are no longer read here: the router computes the netting
    ///      itself in `_computeNetting` and the kSettler reads `proposal.netted` back after propose.
    function _getBatchInfo(IkStakingVault _vault) internal view returns (BatchInfo memory _batchInfo) {
        (_batchInfo.batchId,, _batchInfo.isClosed, _batchInfo.isSettled) = _vault.getCurrentBatchInfo();
    }

    /// @notice Moves netted MetaWallet shares between the kMinter and DN vault adapters
    /// @dev Always dispatched through the DN vault adapter:
    ///      - `_toVaultAdapter == true`:  transferFrom kMinter adapter to vault adapter (positive netting).
    ///      - `_toVaultAdapter == false`: transfer from vault adapter to kMinter adapter (negative netting).
    function _executeNettedTransfer(
        bool _toVaultAdapter,
        address _metawallet,
        address _kMinterAdapter,
        address _vaultAdapter,
        uint256 _nettedShares
    )
        internal
    {
        Execution[] memory _executions = _toVaultAdapter
            ? ExecutionDataLibrary.getTransferFromExecutionData(
                _metawallet, _kMinterAdapter, _vaultAdapter, _nettedShares
            )
            : ExecutionDataLibrary.getTransferExecutionData(_metawallet, _kMinterAdapter, _nettedShares);
        _executeAdapterCall(IMinimalSmartAccount(_vaultAdapter), _executions);
    }

    /// @notice Custodial netted-redeem / deposit flow, isolated to keep the parent under stack limits.
    /// @dev Behaviour by sign of `_netted`:
    ///      - `> 0`: redeem from MetaWallet via the kMinter adapter, then transfer the underlying to the
    ///        custodial target (e.g. CEFFU).
    ///      - `< 0`: deposit the underlying back into MetaWallet via the kMinter adapter.
    ///      - `== 0`: no-op.
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

    /// @notice First registered target of an adapter matching the requested type
    /// @dev Reverts with KSETTLER_INVALID_TARGET_TYPE if no target of `_expectedType` is registered.
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

    /// @notice Splits the depeg delta between insurance / treasury / vault adapter
    /// @dev Behaviour by sign of `_depeg`:
    ///      - `> 0` (profit): insurance -> treasury -> vault adapter, falling back to treasury when no
    ///        stakers exist so value isn't stranded on the kMinter adapter.
    ///      - `< 0` (loss): only debited from the vault adapter when stakers exist to bear it.
    ///      - `== 0`: no-op.
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

    /// @notice Assets insurance still needs to reach `insuranceBps` of `kMinterAdapter.totalAssets()`
    /// @return _deficitAssets Assets still needed by insurance (0 if target met or insurance unset)
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

    /// @notice Splits profit shares by priority: insurance deficit first, then treasury BPS, then
    ///         vault adapter (DN/custodial only) with the remainder so the kMinter peg holds.
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
}
