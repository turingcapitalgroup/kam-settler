// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import { console2 as console } from "forge-std/console2.sol";
import { ERC20ExecutionValidator } from "kam/src/adapters/parameters/ERC20ExecutionValidator.sol";
import { IRegistry } from "kam/src/interfaces/IRegistry.sol";
import { IVaultAdapter } from "kam/src/interfaces/IVaultAdapter.sol";
import { IkRegistry } from "kam/src/interfaces/IkRegistry.sol";
import { IExecutionGuardian } from "kam/src/interfaces/modules/IExecutionGuardian.sol";
import { MockERC7540 } from "kam/test/mocks/MockERC7540.sol";
import { BaseVaultTest, DeploymentBaseTest, IkStakingVault, SafeTransferLib } from "kam/test/utils/BaseVaultTest.sol";
import { Execution, ExecutionLib } from "minimal-smart-account/libraries/ExecutionLib.sol";
import { ModeCode, ModeLib } from "minimal-smart-account/libraries/ModeLib.sol";
import { DeploykSettlerScript } from "script/DeploykSettler.s.sol";
import { IkAssetRouter, IkSettler } from "src/interfaces/IkSettler.sol";
import { kSettler } from "src/kSettler.sol";
import { DeployMetaWallet } from "test/utils/DeployMetaWallet.sol";

/// @title CustodialVaultTest
/// @notice Tests for alpha and beta vault (custodial) settlement flows
/// @dev Tests the full settlement flow: closeBatch -> proposeSettleBatch -> executeSettlement -> mockWallet transfer ->
/// finaliseCustodialSettlement
contract CustodialVaultTest is BaseVaultTest, DeployMetaWallet {
    using SafeTransferLib for address;

    kSettler public settler;
    ERC20ExecutionValidator public paramChecker;

    function setUp() public override(BaseVaultTest, DeploymentBaseTest) {
        // Point to kam-v1's deployments folder which has the complete config
        vm.setEnv("DEPLOYMENT_BASE_PATH", "dependencies/kam-v1/deployments");
        DeploymentBaseTest.setUp();

        // Get the paramChecker deployed during DeploymentBaseTest setup
        bytes4 approveSelector = bytes4(keccak256("approve(address,uint256)"));
        paramChecker = ERC20ExecutionValidator(
            IExecutionGuardian(address(registry))
                .getExecutionValidator(address(minterAdapterUSDC), tokens.usdc, approveSelector)
        );

        // Deploy kSettler using the deployment script
        DeploykSettlerScript deployScript = new DeploykSettlerScript();
        DeploykSettlerScript.kSettlerDeployment memory deployment = deployScript.runTest(
            users.owner, users.admin, users.relayer, address(minter), address(assetRouter), address(registry)
        );
        settler = kSettler(deployment.settler);

        _deployAndSwapMetaWallet(address(settler));

        vm.startPrank(users.admin);
        vault = IkStakingVault(address(alphaVault));
        vm.stopPrank();

        BaseVaultTest.setUp();

        // Grant roles to settler for all adapters
        vm.startPrank(users.owner);
        minterAdapterUSDC.grantRoles(address(settler), 2);
        DNVaultAdapterUSDC.grantRoles(address(settler), 2);
        ALPHAVaultAdapterUSDC.grantRoles(address(settler), 2);
        BETHAVaultAdapterUSDC.grantRoles(address(settler), 2);

        // Grant roles to relayer for adapters
        minterAdapterUSDC.grantRoles(address(users.relayer), 2);
        DNVaultAdapterUSDC.grantRoles(address(users.relayer), 2);
        ALPHAVaultAdapterUSDC.grantRoles(address(users.relayer), 2);
        BETHAVaultAdapterUSDC.grantRoles(address(users.relayer), 2);
        vm.stopPrank();

        _disableFees();

        // Setup param checker for alpha/beta adapters
        vm.startPrank(users.admin);
        paramChecker.setAllowedSpender(address(erc7540USDC), address(ALPHAVaultAdapterUSDC), true);
        paramChecker.setAllowedSpender(address(erc7540USDC), address(BETHAVaultAdapterUSDC), true);
        // Allow transfers to wallet (custodial target)
        paramChecker.setAllowedReceiver(tokens.usdc, address(wallet), true);
        paramChecker.setAllowedReceiver(address(erc7540USDC), address(wallet), true);
        vm.stopPrank();

        // Setup initial deposits to metawallet for kMinter adapter
        _setupMinterAdapterDeposits();
    }

    /// @notice Setup initial deposits to metawallet for kMinter adapter
    function _setupMinterAdapterDeposits() internal {
        vm.startPrank(users.relayer);

        // First execution: approve USDC to erc7540USDC
        Execution[] memory executions1 = new Execution[](1);
        executions1[0] = Execution({
            target: tokens.usdc,
            value: 0,
            callData: abi.encodeWithSignature("approve(address,uint256)", address(erc7540USDC), type(uint256).max)
        });
        bytes memory executionCalldata1 = ExecutionLib.encodeBatch(executions1);
        ModeCode mode1 = ModeLib.encodeSimpleBatch();
        minterAdapterUSDC.execute(mode1, executionCalldata1);

        // Second execution: approve erc7540USDC to adapters
        Execution[] memory executions2 = new Execution[](1);
        executions2[0] = Execution({
            target: address(erc7540USDC),
            value: 0,
            callData: abi.encodeWithSignature(
                "approve(address,uint256)", address(ALPHAVaultAdapterUSDC), type(uint256).max
            )
        });
        bytes memory executionCalldata2 = ExecutionLib.encodeBatch(executions2);
        minterAdapterUSDC.execute(ModeLib.encodeSimpleBatch(), executionCalldata2);

        // Third execution: deposit
        uint256 balance = tokens.usdc.balanceOf(address(minterAdapterUSDC));

        // zeroize vault balance
        deal(tokens.usdc, address(erc7540USDC), 0);
        Execution[] memory executions3 = new Execution[](1);
        executions3[0] = Execution({
            target: address(erc7540USDC),
            value: 0,
            callData: abi.encodeWithSignature("deposit(uint256,address)", balance, address(minterAdapterUSDC))
        });

        bytes memory executionCalldata3 = ExecutionLib.encodeBatch(executions3);
        minterAdapterUSDC.execute(ModeLib.encodeSimpleBatch(), executionCalldata3);

        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                            ALPHA VAULT TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Test alpha vault full settlement flow with positive netting
    /// @dev Flow: closeBatch -> proposeSettleBatch -> executeSettlement -> mockWallet transfer ->
    /// finaliseCustodialSettlement
    function test_custodial_alpha_vault_settlement_positive_netted() public {
        uint256 depositAmount = 100e6;
        uint256 requestAmount = 50e6;

        // First, setup kMinter with deposits so we have assets
        _setupKMinterDeposits(depositAmount, requestAmount);

        // Switch to alpha vault for staking
        vault = alphaVault;

        // User stakes kUSD in alpha vault
        vm.startPrank(users.alice);
        kUSD.approve(address(alphaVault), type(uint256).max);
        bytes32 stakeRequestId = alphaVault.requestStake(users.alice, users.alice, depositAmount);
        vm.stopPrank();

        // Get batch info before closing
        (bytes32 batchId,, bool isClosed, bool isSettled) = alphaVault.getCurrentBatchInfo();
        assertFalse(isClosed, "Batch should not be closed yet");
        assertFalse(isSettled, "Batch should not be settled yet");

        // Step 1: Close the vault batch
        vm.prank(users.relayer);
        settler.closeVaultBatch(address(alphaVault), batchId, true);

        // Verify batch is closed
        (,, isClosed, isSettled) = alphaVault.getCurrentBatchInfo();

        // Step 2: Get total assets (actual, not netted) and propose settlement
        uint256 totalAssets = IVaultAdapter(address(ALPHAVaultAdapterUSDC)).totalAssets();

        vm.prank(users.relayer);
        bytes32 proposalId = settler.proposeSettleBatch(
            tokens.usdc,
            address(alphaVault),
            batchId,
            totalAssets, // Pass actual total assets
            0, // lastFeesChargedManagement
            0 // lastFeesChargedPerformance
        );

        IkAssetRouter.VaultSettlementProposal memory proposal = assetRouter.getSettlementProposal(proposalId);
        assertEq(proposal.vault, address(alphaVault), "Proposal vault mismatch");
        assertEq(proposal.batchId, batchId, "Proposal batchId mismatch");

        vm.prank(users.relayer);
        settler.executeSettleBatch(proposalId);

        vm.prank(users.relayer);
        settler.finaliseCustodialSettlement(proposalId);

        vm.prank(users.alice);
        alphaVault.claimStakedShares(stakeRequestId);

        uint256 aliceShares = alphaVault.balanceOf(users.alice);
        assertGt(aliceShares, 0, "Alice should have received shares");
        assertEq(ALPHAVaultAdapterUSDC.totalAssets(), alphaVault.totalAssets());
        assertEq(proposal.yield, 0, "Yield should be zero");
    }

    /// @notice Test alpha vault settlement with negative netting (redemptions > deposits)
    function test_custodial_alpha_vault_settlement_negative_netted() public {
        uint256 depositAmount = 50e6;
        uint256 stakeAmount = 100e6;

        test_custodial_alpha_vault_settlement_positive_netted();

        // First, setup kMinter with deposits
        _setupKMinterDeposits(depositAmount, 0);

        // Switch to alpha vault
        vault = alphaVault;

        // User stakes kUSD in alpha vault
        vm.startPrank(users.alice);
        kUSD.approve(address(alphaVault), type(uint256).max);
        bytes32 stakeRequestId = alphaVault.requestStake(users.alice, users.alice, stakeAmount);
        vm.stopPrank();

        // Close and settle first batch to get shares
        (bytes32 batchId1,,,) = alphaVault.getCurrentBatchInfo();

        vm.prank(users.relayer);
        settler.closeVaultBatch(address(alphaVault), batchId1, true);

        uint256 totalAssets1 = IVaultAdapter(address(ALPHAVaultAdapterUSDC)).totalAssets();

        vm.prank(users.relayer);
        bytes32 proposalId1 = settler.proposeSettleBatch(tokens.usdc, address(alphaVault), batchId1, totalAssets1, 0, 0);

        vm.prank(users.relayer);
        settler.executeSettleBatch(proposalId1);

        vm.prank(users.relayer);
        settler.finaliseCustodialSettlement(proposalId1);

        // Claim shares
        vm.prank(users.alice);
        alphaVault.claimStakedShares(stakeRequestId);

        // Now request unstake (creates negative netting scenario)
        uint256 aliceShares = alphaVault.balanceOf(users.alice);
        vm.prank(users.alice);
        bytes32 unstakeRequestId = alphaVault.requestUnstake(users.alice, users.alice, aliceShares);

        // Close and settle second batch with redemption
        (bytes32 batchId2,,,) = alphaVault.getCurrentBatchInfo();

        vm.prank(users.relayer);
        settler.closeVaultBatch(address(alphaVault), batchId2, true);

        uint256 totalAssets2 = IVaultAdapter(address(ALPHAVaultAdapterUSDC)).totalAssets();

        vm.prank(users.relayer);
        bytes32 proposalId2 = settler.proposeSettleBatch(tokens.usdc, address(alphaVault), batchId2, totalAssets2, 0, 0);

        vm.prank(users.relayer);
        settler.executeSettleBatch(proposalId2);

        uint256 _amount = alphaVault.convertToAssets(aliceShares);

        // Step 4: For negative netting, CEFFU needs to transfer to kMinterAdapter
        vm.prank(users.admin);
        wallet.transfer(tokens.usdc, address(minterAdapterUSDC), _amount);

        // Verify proposal has negative netting
        IkAssetRouter.VaultSettlementProposal memory proposal2 = assetRouter.getSettlementProposal(proposalId2);

        vm.prank(users.relayer);
        settler.finaliseCustodialSettlement(proposalId2);

        // Claim unstaked assets
        vm.prank(users.alice);
        alphaVault.claimUnstakedAssets(unstakeRequestId);

        assertEq(ALPHAVaultAdapterUSDC.totalAssets(), alphaVault.totalAssets());
        assertEq(proposal2.yield, 0, "Yield should be zero");
    }

    /*//////////////////////////////////////////////////////////////
                            BETA VAULT TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Test beta vault full settlement flow with positive netting
    function test_custodial_beta_vault_settlement_positive_netted() public {
        uint256 depositAmount = 100e6;
        uint256 requestAmount = 50e6;

        // First, setup kMinter with deposits
        _setupKMinterDeposits(depositAmount, requestAmount);

        // Switch to beta vault
        vault = betaVault;

        // User stakes kUSD in beta vault
        vm.startPrank(users.alice);
        kUSD.approve(address(betaVault), type(uint256).max);
        bytes32 stakeRequestId = betaVault.requestStake(users.alice, users.alice, depositAmount);
        vm.stopPrank();

        (bytes32 batchId,, bool isClosed,) = betaVault.getCurrentBatchInfo();
        assertFalse(isClosed, "Batch should not be closed yet");

        vm.prank(users.relayer);
        settler.closeVaultBatch(address(betaVault), batchId, true);

        uint256 totalAssets = IVaultAdapter(address(BETHAVaultAdapterUSDC)).totalAssets();

        vm.prank(users.relayer);
        bytes32 proposalId = settler.proposeSettleBatch(tokens.usdc, address(betaVault), batchId, totalAssets, 0, 0);

        vm.prank(users.relayer);
        settler.executeSettleBatch(proposalId);

        vm.prank(users.relayer);
        settler.finaliseCustodialSettlement(proposalId);

        // Verify settlement completed
        vm.prank(users.alice);
        betaVault.claimStakedShares(stakeRequestId);

        assertEq(BETHAVaultAdapterUSDC.totalAssets(), betaVault.totalAssets());
        IkAssetRouter.VaultSettlementProposal memory proposal = assetRouter.getSettlementProposal(proposalId);
        assertEq(proposal.yield, 0, "Yield should be zero");

        uint256 aliceShares = betaVault.balanceOf(users.alice);
        assertGt(aliceShares, 0, "Alice should have received shares");
    }

    /// @notice Test beta vault settlement with empty batch (no netting)
    function test_custodial_beta_vault_empty_batch() public {
        // Switch to beta vault
        vault = betaVault;

        (bytes32 batchId,,,) = betaVault.getCurrentBatchInfo();

        vm.prank(users.relayer);
        settler.closeVaultBatch(address(betaVault), batchId, true);

        vm.prank(users.relayer);
        bytes32 proposalId = settler.proposeSettleBatch(tokens.usdc, address(betaVault), batchId, 0, 0, 0);

        vm.prank(users.relayer);
        settler.executeSettleBatch(proposalId);

        IkAssetRouter.VaultSettlementProposal memory proposal = assetRouter.getSettlementProposal(proposalId);
        assertEq(proposal.yield, 0, "Yield should be zero");
        assertEq(proposal.netted, 0, "Empty batch should have zero netted");

        vm.prank(users.relayer);
        settler.finaliseCustodialSettlement(proposalId);
    }

    /// @notice Test that closeVaultBatch reverts when called on a DN vault
    function test_custodial_closeVaultBatch_reverts_on_dn_vault() public {
        (bytes32 batchId,,,) = dnVault.getCurrentBatchInfo();

        vm.prank(users.relayer);
        vm.expectRevert(bytes("KS7"));
        settler.closeVaultBatch(address(dnVault), batchId, true);
    }

    /// @notice Test that closeVaultBatch reverts when called on the kMinter
    function test_custodial_closeVaultBatch_reverts_on_minter() public {
        bytes32 batchId = minter.getBatchId(tokens.usdc);

        vm.prank(users.relayer);
        vm.expectRevert(bytes("KS7"));
        settler.closeVaultBatch(address(minter), batchId, true);
    }

    /// @notice Test that finaliseCustodialSettlement reverts on a cancelled (non-executed) proposal
    function test_custodial_finaliseCustodialSettlement_reverts_cancelled_proposal() public {
        uint256 depositAmount = 100e6;
        uint256 requestAmount = 50e6;

        // Setup kMinter deposits
        _setupKMinterDeposits(depositAmount, requestAmount);

        // Switch to alpha vault
        vault = alphaVault;

        // User stakes kUSD in alpha vault
        vm.startPrank(users.alice);
        kUSD.approve(address(alphaVault), type(uint256).max);
        alphaVault.requestStake(users.alice, users.alice, depositAmount);
        vm.stopPrank();

        // Close the vault batch
        (bytes32 batchId,,,) = alphaVault.getCurrentBatchInfo();
        vm.prank(users.relayer);
        settler.closeVaultBatch(address(alphaVault), batchId, true);

        // Propose settlement
        uint256 totalAssets = IVaultAdapter(address(ALPHAVaultAdapterUSDC)).totalAssets();
        vm.prank(users.relayer);
        bytes32 proposalId = settler.proposeSettleBatch(tokens.usdc, address(alphaVault), batchId, totalAssets, 0, 0);

        // Guardian cancels the proposal (removes from pending, does NOT add to executed)
        vm.prank(users.guardian);
        assetRouter.cancelProposal(proposalId);

        // Relayer tries to finalise the cancelled proposal — should revert with KS8
        vm.prank(users.relayer);
        vm.expectRevert(bytes("KS8"));
        settler.finaliseCustodialSettlement(proposalId);
    }

    /*//////////////////////////////////////////////////////////////
                            HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Setup kMinter with deposits and optional burn requests
    function _setupKMinterDeposits(uint256 _depositAmount, uint256 _requestAmount) internal {
        vm.startPrank(users.institution);
        tokens.usdc.safeApprove(address(minter), type(uint256).max);
        minter.mint(tokens.usdc, users.institution, _depositAmount);

        if (_requestAmount > 0) {
            kUSD.approve(address(minter), type(uint256).max);
            minter.requestBurn(tokens.usdc, users.institution, _requestAmount);
        }
        vm.stopPrank();

        // Close minter batch
        vm.prank(users.relayer);
        bytes32 minterProposalId = settler.closeAndProposeMinterBatch(tokens.usdc);

        if (minterProposalId != bytes32(0)) {
            vm.prank(users.relayer);
            assetRouter.executeSettleBatch(minterProposalId);
        }
    }

    /// @notice Disable fees for cleaner testing
    function _disableFees() internal {
        vm.startPrank(users.admin);
        alphaVault.setManagementFee(0);
        alphaVault.setPerformanceFee(0);
        betaVault.setManagementFee(0);
        betaVault.setPerformanceFee(0);
        vm.stopPrank();

        vm.prank(users.admin);
        registry.setHurdleRate(tokens.usdc, 0);
    }
}
