// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import { IVaultAdapter } from "kam/src/interfaces/IVaultAdapter.sol";
import { IkAssetRouter } from "kam/src/interfaces/IkAssetRouter.sol";
import { IkMinter } from "kam/src/interfaces/IkMinter.sol";
import { IkStakingVault } from "kam/src/interfaces/IkStakingVault.sol";
import { IkToken } from "kam/src/interfaces/IkToken.sol";

interface ISettler {
    /*//////////////////////////////////////////////////////////////
                              ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when attempting to close a batch that is already closed
    error BatchAlreadyClosed();

    /// @notice Thrown when attempting to settle a batch that is already settled
    error BatchAlreadySettled();

    /// @notice Thrown when a required address is zero
    error AddressZero();

    /// @notice Thrown when netted assets are positive
    error NettedAssetsPositive();

    /// @notice Thrown when the balance of the kAssetRouter is insufficient
    error InsufficientBalance();

    /// @notice Thrown when the profit share basis points exceeds 10000
    error InvalidProfitShareBps();

    /*//////////////////////////////////////////////////////////////
                              EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when profit is distributed during settlement
    /// @param insuranceShares Shares sent to insurance
    /// @param treasuryShares Shares sent to treasury
    /// @param vaultAdapterShares Shares sent to vault adapter (DN/custodial only)
    event ProfitDistributed(uint256 insuranceShares, uint256 treasuryShares, uint256 vaultAdapterShares);

    /*//////////////////////////////////////////////////////////////
                              STRUCTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Contains information about a batch operation
    /// @param _batchId Unique identifier for the batch
    /// @param _deposited Total amount of assets deposited in the batch
    /// @param _pendingShares Number of shares pending in the batch
    /// @param _isClosed Whether the batch has been closed
    /// @param _isSettled Whether the batch has been settled
    struct BatchInfo {
        bytes32 _batchId;
        uint256 _deposited;
        uint256 _pendingShares;
        bool _isClosed;
        bool _isSettled;
    }

    /// @notice Contains all relevant addresses for vault operations
    /// @param _vault The delta-neutral vault address
    /// @param _kMinter The kMinter contract address
    /// @param _kMinterAdapter The adapter for kMinter operations
    /// @param _kAssetRouter The asset router contract
    /// @param _dnVaultAdapter The adapter for delta-neutral vault operations
    /// @param _kToken The kToken contract address
    struct VaultAddresses {
        IkStakingVault _vault;
        IkMinter _kMinter;
        IVaultAdapter _kMinterAdapter;
        IkAssetRouter _kAssetRouter;
        IVaultAdapter _dnVaultAdapter;
        IkToken _kToken;
    }

    /// @notice Contains calculated asset data for settlement
    /// @param _dnAdapterAssets Current assets in the delta-neutral adapter
    /// @param _dnAdapterShares Current shares in the delta-neutral adapter
    /// @param _nettedAssets Net assets after settlement calculations
    /// @param _newTotalAssets Total assets after settlement
    struct AssetData {
        uint256 _dnAdapterAssets;
        uint256 _dnAdapterShares;
        int256 _nettedAssets;
        uint256 _newTotalAssets;
    }

    /*//////////////////////////////////////////////////////////////
                              FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice grants the _relayer address the relayer role
    /// @param _relayer address to be granted the relayer role
    function grantRelayerRole(address _relayer) external payable;

    /// @notice Closes a delta-neutral vault batch and initiates settlement with default profit share
    /// @dev This function handles the complete settlement process for DN vault batches,
    ///      including rebalancing, fee calculation, and asset netting. Uses 0 profit share.
    /// @param _asset The asset address for which to close the batch
    /// @return _proposalId The proposal ID for the settlement
    function closeAndProposeDNVaultBatch(address _asset) external payable returns (bytes32 _proposalId);

    /// @notice Closes a delta-neutral vault batch and initiates settlement with profit sharing
    /// @dev This function handles the complete settlement process for DN vault batches,
    ///      including rebalancing, fee calculation, asset netting, and profit distribution.
    ///      Profit is distributed: insurance (up to target) -> treasury -> vault adapter -> kMinter keeps rest
    /// @param _asset The asset address for which to close the batch
    /// @param _profitShareBps Basis points of remaining profit (after insurance + treasury) to send to vault adapter
    /// @return _proposalId The proposal ID for the settlement
    function closeAndProposeDNVaultBatch(
        address _asset,
        uint16 _profitShareBps
    )
        external
        payable
        returns (bytes32 _proposalId);

    /// @notice Closes a kMinter batch and handles asset rebalancing
    /// @dev This function closes the kMinter batch and processes any negative netted assets
    ///      by requesting redemption from the delta-neutral meta-vault
    /// @param _asset The asset address for which to close the batch
    /// @return _proposalId The proposal ID for the settlement, or bytes32(0) if no netting is needed
    function closeAndProposeMinterBatch(address _asset) external payable returns (bytes32 _proposalId);

    /// @notice Transfer to/from ceffu to/from metawallet
    /// @dev Finalises a custodial batch settlement by handling asset transfers between
    ///      kMinter and vault adapters based on the netted amount in the proposal.
    /// @param _proposalId The proposal ID to finalise
    function finaliseCustodialSettlement(bytes32 _proposalId) external payable;

    /// @notice Executes a settlement batch proposal
    /// @dev Executes a settlement batch proposal through the kAssetRouter
    /// @param _proposalId The proposal ID to execute
    function executeSettleBatch(bytes32 _proposalId) external payable;

    /// @notice Proposes a settlement batch through the kAssetRouter
    /// @dev Proposes a settlement batch through the kAssetRouter with fee information
    /// @param _asset The asset address for the settlement
    /// @param _vault The vault address for the settlement
    /// @param _batchId The batch ID for the settlement
    /// @param _totalAssets The total assets for the settlement
    /// @param _lastFeesChargedManagement The timestamp of last management fee charge
    /// @param _lastFeesChargedPerformance The timestamp of last performance fee charge
    function proposeSettleBatch(
        address _asset,
        address _vault,
        bytes32 _batchId,
        uint256 _totalAssets,
        uint64 _lastFeesChargedManagement,
        uint64 _lastFeesChargedPerformance
    )
        external
        payable;

    /// @notice Closes the vault batches
    /// @param _vault the vault to close the batch
    /// @param _batchId the batch to be closed
    /// @param _create if we create a new batch or not
    function closeVaultBatch(address _vault, bytes32 _batchId, bool _create) external payable;

    /*//////////////////////////////////////////////////////////////
                              VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns if the proposal is netted negative or not
    /// @param _proposalId the proposal to verify the netted value
    /// @return _isNettedNegative if the netted is positive or negative
    function isNettedNegative(bytes32 _proposalId) external view returns (bool _isNettedNegative);
}
