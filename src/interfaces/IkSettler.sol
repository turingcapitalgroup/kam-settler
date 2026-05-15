// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import { IkToken } from "kToken0/interfaces/IkToken.sol";
import { IVaultAdapter } from "kam/src/interfaces/IVaultAdapter.sol";
import { IkAssetRouter } from "kam/src/interfaces/IkAssetRouter.sol";
import { IkMinter } from "kam/src/interfaces/IkMinter.sol";
import { IkStakingVault } from "kam/src/interfaces/IkStakingVault.sol";

interface IkSettler {
    /*//////////////////////////////////////////////////////////////
                              EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when profit is distributed during settlement
    /// @param insuranceShares Shares sent to insurance
    /// @param treasuryShares Shares sent to treasury
    /// @param vaultAdapterShares Shares sent to vault adapter (DN/custodial only)
    event ProfitDistributed(uint256 insuranceShares, uint256 treasuryShares, uint256 vaultAdapterShares);

    /// @notice Emitted when insurance shares are liquidated to underlying assets
    /// @param asset The asset for which insurance was liquidated
    /// @param shares The number of shares redeemed
    /// @param assets The amount of underlying assets received
    event InsuranceLiquidated(address indexed asset, uint256 shares, uint256 assets);

    /*//////////////////////////////////////////////////////////////
                              STRUCTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Closed/settled status snapshot for a vault batch
    /// @param batchId The batch identifier
    /// @param isClosed Whether the batch has been closed
    /// @param isSettled Whether the batch has been settled
    struct BatchInfo {
        bytes32 batchId;
        bool isClosed;
        bool isSettled;
    }

    /// @notice kSettler-only state that survives between propose and execute for a DN settlement
    /// @dev Asset / vault / adapters / netted are read off the router proposal at execute time and
    ///      therefore not duplicated here. Minter settlements need no kSettler state at all.
    /// @param depegSharesVault Signed MetaWallet shares to deliver to the DN vault adapter as
    ///        depeg-driven movement (positive = profit, negative = loss). Combined with the netted
    ///        share movement (derived from `proposal.netted` at execute) for a single transfer.
    /// @param sharesToInsurance MetaWallet shares to transfer from the kMinter adapter to insurance
    /// @param sharesToTreasury  MetaWallet shares to transfer from the kMinter adapter to treasury
    struct DNPendingSettlement {
        int256 depegSharesVault;
        uint256 sharesToInsurance;
        uint256 sharesToTreasury;
    }

    /*//////////////////////////////////////////////////////////////
                              FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /*//////////////////////////////////////////////////////////////
                          ROLES MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice Grants ADMIN_ROLE to an address
    /// @dev Only callable by contract owner. Reverts on zero address.
    /// @param _admin Admin role recipient
    function grantAdminRole(address _admin) external;

    /// @notice Revokes ADMIN_ROLE from an address
    /// @dev Only callable by contract owner
    /// @param _admin Address to strip of admin privileges
    function revokeAdminRole(address _admin) external;

    /// @notice Grants SETTLER_RELAYER_ROLE to an address
    /// @dev Only callable by addresses holding ADMIN_ROLE. Reverts on zero address.
    /// @param _relayer Relayer role recipient
    function grantRelayerRole(address _relayer) external payable;

    /// @notice Revokes SETTLER_RELAYER_ROLE from an address
    /// @dev Only callable by addresses holding ADMIN_ROLE
    /// @param _relayer Address to strip of relayer privileges
    function revokeRelayerRole(address _relayer) external payable;

    /// @notice Closes a delta-neutral vault batch and initiates settlement
    /// @dev This function handles the complete settlement process for DN vault batches,
    ///      including rebalancing, asset netting, and profit distribution.
    ///      All profit is distributed: insurance (up to target) -> treasury -> vault adapter.
    ///      Atomically settles the MetaWallet's virtualTotalAssets before computing depeg,
    ///      so that profit distribution reflects real strategy yield.
    /// @param _asset The asset address for which to close the batch
    /// @param _newMetaWalletTotalAssets The new total assets for the MetaWallet (idle + strategies)
    /// @param _rootHash The merkle root committing to the strategy breakdown
    /// @return _proposalId The proposal ID for the settlement
    function closeAndProposeDNVaultBatch(
        address _asset,
        uint256 _newMetaWalletTotalAssets,
        bytes32 _rootHash
    )
        external
        payable
        returns (bytes32 _proposalId);

    /// @notice Closes a kMinter batch and handles asset rebalancing
    /// @dev This function closes the kMinter batch and processes any negative netted assets
    ///      by requesting redemption from the delta-neutral meta-wallet
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
    /// @dev Proposes a settlement batch through the kAssetRouter
    /// @param _asset The asset address for the settlement
    /// @param _vault The vault address for the settlement
    /// @param _batchId The batch ID for the settlement
    /// @param _totalAssets The total assets for the settlement
    /// @return _proposalId The proposal ID for the settlement
    function proposeSettleBatch(
        address _asset,
        address _vault,
        bytes32 _batchId,
        uint256 _totalAssets
    )
        external
        payable
        returns (bytes32 _proposalId);

    /// @notice Closes the vault batches
    /// @param _vault the vault to close the batch
    /// @param _batchId the batch to be closed
    /// @param _create if we create a new batch or not
    function closeVaultBatch(address _vault, bytes32 _batchId, bool _create) external payable;

    /// @notice Liquidates insurance's metawallet shares to underlying assets
    /// @dev Calls redeem through the insurance smart account. The caller must specify
    ///      the metawallet directly so resolution is constant-time and cannot misroute
    ///      between assets when insurance backs more than one (TOB-KAM-38).
    /// @param _asset The underlying asset for which to liquidate insurance shares
    /// @param _metawallet The ERC4626 metawallet to redeem from. Must match _asset.
    function liquidateInsurance(address _asset, address _metawallet) external payable;

    /*//////////////////////////////////////////////////////////////
                              VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns if the proposal is netted negative or not
    /// @param _proposalId the proposal to verify the netted value
    /// @return _isNettedNegative if the netted is positive or negative
    function isNettedNegative(bytes32 _proposalId) external view returns (bool _isNettedNegative);
}
