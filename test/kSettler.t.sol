// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import { console2 as console } from "forge-std/console2.sol";
import { ERC20ExecutionValidator } from "kam/src/adapters/parameters/ERC20ExecutionValidator.sol";
import { IVaultAdapter } from "kam/src/interfaces/IVaultAdapter.sol";
import { IkAssetRouter } from "kam/src/interfaces/IkAssetRouter.sol";
import { IkRegistry } from "kam/src/interfaces/IkRegistry.sol";
import { IExecutionGuardian } from "kam/src/interfaces/modules/IExecutionGuardian.sol";
import { Ownable } from "kam/src/vendor/solady/auth/Ownable.sol";
import { MockERC4626 } from "kam/test/mocks/MockERC4626.sol";
import { BaseVaultTest, DeploymentBaseTest, IkStakingVault, SafeTransferLib } from "kam/test/utils/BaseVaultTest.sol";
import { IERC4626 } from "metawallet/src/interfaces/IERC4626.sol";
import { IVaultModule } from "metawallet/src/interfaces/IVaultModule.sol";
import { MinimalSmartAccount } from "minimal-smart-account/MinimalSmartAccount.sol";
import { Execution, ExecutionLib } from "minimal-smart-account/libraries/ExecutionLib.sol";
import { ModeCode, ModeLib } from "minimal-smart-account/libraries/ModeLib.sol";
import { DeploykSettlerScript } from "script/DeploykSettler.s.sol";
import { OptimizedFixedPointMathLib } from "solady/utils/OptimizedFixedPointMathLib.sol";
import { KSETTLER_ADDRESS_ZERO, KSETTLER_ASSET_MISMATCH } from "src/errors/Errors.sol";
import { kSettler } from "src/kSettler.sol";
import { DeployMetaWallet } from "test/utils/DeployMetaWallet.sol";

contract kSettlerTest is BaseVaultTest, DeployMetaWallet {
    using SafeTransferLib for address;
    using OptimizedFixedPointMathLib for int256;

    kSettler public settler;
    ERC20ExecutionValidator public paramChecker;

    uint256 internal constant _ACCOUNTING_DUST = 5;

    function setUp() public override(BaseVaultTest, DeploymentBaseTest) {
        // Point to kam-v1's deployments folder which has the complete config
        vm.setEnv("DEPLOYMENT_BASE_PATH", "dependencies/kam-v1/deployments");
        DeploymentBaseTest.setUp();

        bytes4 approveSelector = bytes4(keccak256("approve(address,uint256)"));
        paramChecker = ERC20ExecutionValidator(
            IExecutionGuardian(address(registry))
                .getExecutionValidator(address(minterAdapterUSDC), tokens.usdc, approveSelector)
        );

        DeploykSettlerScript deployScript = new DeploykSettlerScript();
        DeploykSettlerScript.kSettlerDeployment memory deployment = deployScript.runTest(
            users.owner, users.admin, users.relayer, address(minter), address(assetRouter), address(registry)
        );
        settler = kSettler(deployment.settler);

        _deployAndSwapMetaWallet(address(settler));

        vm.startPrank(users.admin);
        vault = IkStakingVault(address(dnVault));

        vm.stopPrank();
        BaseVaultTest.setUp();

        vm.prank(users.owner);
        minterAdapterUSDC.grantRoles(address(settler), 2);

        vm.prank(users.owner);
        DNVaultAdapterUSDC.grantRoles(address(settler), 2);

        vm.prank(users.owner);
        minterAdapterUSDC.grantRoles(address(users.relayer), 2);

        vm.prank(users.owner);
        DNVaultAdapterUSDC.grantRoles(address(users.relayer), 2);

        vm.stopPrank();
        vm.prank(users.admin);
        paramChecker.setAllowedSpender(address(metawalletUSDC), address(DNVaultAdapterUSDC), true);
        vm.startPrank(users.relayer);

        uint256 _kMinterShares = metawalletUSDC.balanceOf(address(minterAdapterUSDC));
        uint256 _actualKMinterAssets = metawalletUSDC.convertToAssets(_kMinterShares);

        Execution[] memory executions1 = new Execution[](1);
        executions1[0] = Execution({
            target: tokens.usdc,
            value: 0,
            callData: abi.encodeWithSignature("approve(address,uint256)", address(metawalletUSDC), type(uint256).max)
        });
        bytes memory executionCalldata1 = ExecutionLib.encodeBatch(executions1);
        ModeCode mode1 = ModeLib.encodeSimpleBatch();
        minterAdapterUSDC.execute(mode1, executionCalldata1);

        Execution[] memory executions2 = new Execution[](1);
        executions2[0] = Execution({
            target: address(metawalletUSDC),
            value: 0,
            callData: abi.encodeWithSignature(
                "approve(address,uint256)", address(DNVaultAdapterUSDC), type(uint256).max
            )
        });
        bytes memory executionCalldata2 = ExecutionLib.encodeBatch(executions2);
        ModeCode mode2 = ModeLib.encodeSimpleBatch();
        minterAdapterUSDC.execute(mode2, executionCalldata2);

        uint256 balance = tokens.usdc.balanceOf(address(minterAdapterUSDC));

        deal(tokens.usdc, address(metawalletUSDC), 0);
        Execution[] memory executions3 = new Execution[](1);
        executions3[0] = Execution({
            target: address(metawalletUSDC),
            value: 0,
            callData: abi.encodeWithSignature("deposit(uint256,address)", balance, address(minterAdapterUSDC))
        });

        bytes memory executionCalldata3 = ExecutionLib.encodeBatch(executions3);
        ModeCode mode3 = ModeLib.encodeSimpleBatch();
        minterAdapterUSDC.execute(mode3, executionCalldata3);

        _kMinterShares = metawalletUSDC.balanceOf(address(minterAdapterUSDC));
        _actualKMinterAssets = metawalletUSDC.convertToAssets(_kMinterShares);

        vm.stopPrank();
    }

    function test_settler_kminter_empty_batch() public {
        bytes32 proposalId = _closeMinterBatch();
        assertNotEq(proposalId, bytes32(0));
    }

    function test_settler_kminter_netted_positive() public {
        uint256 depositAmount = 100e6;
        uint256 requestAmount = 50e6;

        vm.startPrank(users.institution);
        tokens.usdc.safeApprove(address(minter), type(uint256).max);
        uint256 adapterBalanceBefore = tokens.usdc.balanceOf(address(minterAdapterUSDC));
        minter.mint(tokens.usdc, users.institution, depositAmount);
        uint256 adapterBalanceAfter = tokens.usdc.balanceOf(address(minterAdapterUSDC));
        assertEq(adapterBalanceAfter - adapterBalanceBefore, depositAmount);

        kUSD.approve(address(minter), type(uint256).max);
        adapterBalanceAfter = tokens.usdc.balanceOf(address(minterAdapterUSDC));
        bytes32 requestId = minter.requestBurn(tokens.usdc, users.institution, requestAmount);
        assertEq(adapterBalanceAfter - adapterBalanceBefore, depositAmount);

        uint256 metawalletUsdcBalanceBefore = tokens.usdc.balanceOf(address(metawalletUSDC));
        bytes32 proposalId = _closeMinterBatch();
        assertNotEq(proposalId, bytes32(0));

        // Before execution, balances should be unchanged
        uint256 metawalletUsdcBalanceAfterProposal = tokens.usdc.balanceOf(address(metawalletUSDC));
        assertEq(metawalletUsdcBalanceAfterProposal, metawalletUsdcBalanceBefore);

        _executeSettlement(proposalId);

        uint256 metawalletUsdcBalanceAfter = tokens.usdc.balanceOf(address(metawalletUSDC));
        assertEq(metawalletUsdcBalanceAfter - metawalletUsdcBalanceBefore, depositAmount - requestAmount);

        uint256 finalAdapterBalance = tokens.usdc.balanceOf(address(minterAdapterUSDC));
        assertEq(finalAdapterBalance, adapterBalanceBefore);

        vm.prank(users.institution);
        minter.burn(requestId);

        assertEq(assetRouter.getSettlementProposal(proposalId).yield, 0);
    }

    function test_settler_kminter_netted_negative() public {
        uint256 depositAmount = 50e6;
        uint256 requestAmount = 100e6;

        vm.startPrank(users.institution);
        tokens.usdc.safeApprove(address(minter), type(uint256).max);
        uint256 adapterBalanceBefore = tokens.usdc.balanceOf(address(minterAdapterUSDC));
        minter.mint(tokens.usdc, users.institution, depositAmount);
        uint256 adapterBalanceAfter = tokens.usdc.balanceOf(address(minterAdapterUSDC));
        assertEq(adapterBalanceAfter - adapterBalanceBefore, depositAmount);

        kUSD.approve(address(minter), type(uint256).max);
        adapterBalanceAfter = tokens.usdc.balanceOf(address(minterAdapterUSDC));
        bytes32 requestId = minter.requestBurn(tokens.usdc, users.institution, requestAmount);
        assertEq(adapterBalanceAfter - adapterBalanceBefore, depositAmount);

        uint256 metawalletUsdcBalanceBefore = tokens.usdc.balanceOf(address(metawalletUSDC));
        bytes32 proposalId = _closeMinterBatch();
        assertNotEq(proposalId, bytes32(0));

        // Before execution, balances should be unchanged
        uint256 metawalletUsdcBalanceAfterProposal = tokens.usdc.balanceOf(address(metawalletUSDC));
        assertEq(metawalletUsdcBalanceAfterProposal, metawalletUsdcBalanceBefore);

        _executeSettlement(proposalId);

        uint256 metawalletUsdcBalanceAfter = tokens.usdc.balanceOf(address(metawalletUSDC));
        assertEq(metawalletUsdcBalanceBefore - metawalletUsdcBalanceAfter, requestAmount - depositAmount);

        uint256 finalAdapterBalance = tokens.usdc.balanceOf(address(minterAdapterUSDC));
        assertEq(finalAdapterBalance, adapterBalanceBefore);

        vm.prank(users.institution);
        minter.burn(requestId);

        assertEq(assetRouter.getSettlementProposal(proposalId).yield, 0);
    }

    function test_settler_delta_neutral_netted_positive() public {
        uint256 depositAmount = 100e6;
        uint256 requestAmount = 50e6;
        test_settler_kminter_netted_positive();
        vm.startPrank(users.alice);
        kUSD.approve(address(vault), type(uint256).max);
        bytes32 requestId = vault.requestStake(users.alice, users.alice, depositAmount);
        uint256 adapterBalanceBefore = metawalletUSDC.balanceOf(address(DNVaultAdapterUSDC));
        bytes32 proposalId = _closeAndProposeDeltaNeutralBatch();
        uint256 adapterBalanceAfterProposal = metawalletUSDC.balanceOf(address(DNVaultAdapterUSDC));
        assertEq(adapterBalanceAfterProposal, adapterBalanceBefore);
        assertEq(assetRouter.getSettlementProposal(proposalId).yield, 0);

        _executeSettlement(proposalId);
        uint256 adapterBalanceAfter = metawalletUSDC.balanceOf(address(DNVaultAdapterUSDC));
        assertGt(adapterBalanceAfter, adapterBalanceBefore);

        vm.prank(users.alice);
        vault.claimStakedShares(requestId);

        vm.prank(users.alice);
        kUSD.approve(address(vault), type(uint256).max);
        vm.prank(users.alice);
        vault.requestStake(users.alice, users.alice, depositAmount);
        vm.prank(users.alice);
        requestId = vault.requestUnstake(users.alice, users.alice, requestAmount);

        proposalId = _closeAndProposeDeltaNeutralBatch();
        _executeSettlement(proposalId);

        vm.prank(users.alice);
        vault.claimUnstakedAssets(requestId);
    }

    function test_settler_delta_neutral_netted_negative() public {
        uint256 depositAmount = 50e6;
        uint256 requestAmount = 100e6;
        test_settler_kminter_netted_negative();
        vm.startPrank(users.alice);
        kUSD.approve(address(vault), type(uint256).max);
        bytes32 requestId = vault.requestStake(users.alice, users.alice, requestAmount);
        uint256 adapterBalanceBefore = metawalletUSDC.balanceOf(address(DNVaultAdapterUSDC));
        bytes32 proposalId = _closeAndProposeDeltaNeutralBatch();
        uint256 adapterBalanceAfterProposal = metawalletUSDC.balanceOf(address(DNVaultAdapterUSDC));
        assertEq(adapterBalanceAfterProposal, adapterBalanceBefore);
        assertEq(assetRouter.getSettlementProposal(proposalId).yield, 0);

        _acceptAndExecute(proposalId);
        uint256 adapterBalanceAfter = metawalletUSDC.balanceOf(address(DNVaultAdapterUSDC));
        assertGt(adapterBalanceAfter, adapterBalanceBefore);

        vm.prank(users.alice);
        vault.claimStakedShares(requestId);

        vm.prank(users.alice);
        kUSD.approve(address(vault), type(uint256).max);
        vm.prank(users.alice);
        vault.requestStake(users.alice, users.alice, depositAmount);
        vm.prank(users.alice);
        requestId = vault.requestUnstake(users.alice, users.alice, requestAmount);

        proposalId = _closeAndProposeDeltaNeutralBatch();

        _acceptAndExecute(proposalId);

        vm.prank(users.alice);
        vault.claimUnstakedAssets(requestId);
    }

    function test_settler_delta_neutral_kminter_profit() public {
        _disableProfitDistribution();
        uint256 metaWalletProfit = 200e6;
        uint256 depositAmount = 50e6;
        test_settler_kminter_netted_positive();
        vm.startPrank(users.alice);
        kUSD.approve(address(vault), type(uint256).max);
        bytes32 requestId = vault.requestStake(users.alice, users.alice, depositAmount);
        uint256 adapterBalanceBefore = metawalletUSDC.balanceOf(address(DNVaultAdapterUSDC));

        tokens.usdc.call(abi.encodeWithSignature("mint(address,uint256)", address(metawalletUSDC), metaWalletProfit));

        bytes32 proposalId = _closeAndProposeDeltaNeutralBatch();
        uint256 adapterBalanceAfterProposal = metawalletUSDC.balanceOf(address(DNVaultAdapterUSDC));
        assertEq(adapterBalanceAfterProposal, adapterBalanceBefore);

        _acceptAndExecute(proposalId);
        uint256 adapterBalanceAfter = metawalletUSDC.balanceOf(address(DNVaultAdapterUSDC));
        assertGt(adapterBalanceAfter, adapterBalanceBefore);

        uint256 aliceSharesBefore = vault.balanceOf(users.alice);

        vm.prank(users.alice);
        vault.claimStakedShares(requestId);

        uint256 gotShares = vault.balanceOf(users.alice) - aliceSharesBefore;

        assertEq(vault.convertToAssets(gotShares), depositAmount);

        vm.prank(users.alice);
        kUSD.approve(address(vault), type(uint256).max);
        vm.prank(users.alice);
        requestId = vault.requestStake(users.alice, users.alice, depositAmount);

        tokens.usdc.call(abi.encodeWithSignature("mint(address,uint256)", address(metawalletUSDC), metaWalletProfit));

        proposalId = _closeAndProposeDeltaNeutralBatch();
        _acceptAndExecute(proposalId);

        aliceSharesBefore = vault.balanceOf(users.alice);

        vm.prank(users.alice);
        vault.claimStakedShares(requestId);

        gotShares = vault.balanceOf(users.alice) - aliceSharesBefore;

        assertApproxEqAbs(vault.convertToAssets(gotShares), depositAmount, 5);

        tokens.usdc.call(abi.encodeWithSignature("mint(address,uint256)", address(metawalletUSDC), metaWalletProfit));

        uint256 sharePriceBefore = vault.sharePrice();
        proposalId = _closeAndProposeDeltaNeutralBatch();
        _acceptAndExecute(proposalId);

        uint256 sharePriceAfter = vault.sharePrice();
        assertGt(sharePriceAfter, sharePriceBefore);
    }

    function test_settler_dn_settlement_no_drift_with_fees() public {
        test_settler_kminter_netted_positive();

        uint256 stakeAmount = 200e6;
        vm.startPrank(users.alice);
        kUSD.approve(address(vault), type(uint256).max);
        bytes32 stakeReq = vault.requestStake(users.alice, users.alice, stakeAmount);
        vm.stopPrank();

        bytes32 proposalId = _closeAndProposeDeltaNeutralBatch();
        _executeSettlement(proposalId);

        vm.prank(users.alice);
        vault.claimStakedShares(stakeReq);

        _setupTestFees();

        vm.warp(block.timestamp + 30 days);

        uint256 unstakeShares = vault.balanceOf(users.alice) / 2;
        vm.prank(users.alice);
        vault.requestUnstake(users.alice, users.alice, unstakeShares);

        uint256 yieldAmount = 50_000e6;
        (bool ok,) =
            tokens.usdc.call(abi.encodeWithSignature("mint(address,uint256)", address(metawalletUSDC), yieldAmount));
        require(ok);

        proposalId = _closeAndProposeDeltaNeutralBatch();
        _executeSettlement(proposalId);

        IkAssetRouter.VaultSettlementProposal memory proposal = assetRouter.getSettlementProposal(proposalId);
        assertGt(proposal.managementFees + proposal.performanceFees, 0, "expected non-zero settlement fees");
    }

    function _closeMinterBatch() internal returns (bytes32 proposalId) {
        vm.startPrank(users.relayer);
        proposalId = settler.closeAndProposeMinterBatch(tokens.usdc);
        vm.stopPrank();
    }

    function _closeAndProposeDeltaNeutralBatch() internal returns (bytes32 proposalId) {
        vm.startPrank(users.relayer);
        uint256 _totalAssets = tokens.usdc.balanceOf(address(metawalletUSDC));
        bytes32 _rootHash = keccak256(abi.encodePacked(address(metawalletUSDC), _totalAssets));
        proposalId = settler.closeAndProposeDNVaultBatch(tokens.usdc, _totalAssets, _rootHash);
        vm.stopPrank();
    }

    function _acceptAndExecute(bytes32 proposalId) internal {
        IkAssetRouter.VaultSettlementProposal memory proposal = assetRouter.getSettlementProposal(proposalId);
        if (proposal.requiresApproval) {
            vm.prank(users.guardian);
            assetRouter.acceptProposal(proposalId);
        }
        _executeSettlement(proposalId);
    }

    function _getDepeg() internal view returns (int256) {
        uint256 _kMinterShares = metawalletUSDC.balanceOf(address(minterAdapterUSDC));
        uint256 _actualKMinterAssets = metawalletUSDC.convertToAssets(_kMinterShares);
        uint256 _expectedKMinterAssets = IVaultAdapter(address(minterAdapterUSDC)).totalAssets();
        // Positive = surplus/profit, Negative = deficit/loss
        return int256(_actualKMinterAssets) - int256(_expectedKMinterAssets);
    }

    function _disableProfitDistribution() internal {
        vm.stopPrank();
        vm.startPrank(users.admin);
        registry.setInsuranceBps(0);
        registry.setTreasuryBps(0);
        vm.stopPrank();
    }

    function _syncMetaWalletTotalAssets() internal {
        uint256 newTotalAssets = tokens.usdc.balanceOf(address(metawalletUSDC));
        bytes32 rootHash = keccak256(abi.encodePacked(address(metawalletUSDC), newTotalAssets));
        vm.prank(address(settler));
        IVaultModule(address(metawalletUSDC)).settleTotalAssets(newTotalAssets, rootHash);
    }

    function _setupProfitDistribution(uint16 insuranceBps, uint16 treasuryBps) internal {
        vm.stopPrank();
        vm.startPrank(users.admin);
        registry.setInsuranceBps(insuranceBps);
        registry.setTreasuryBps(treasuryBps);
        (address treasury, address insurance,,) = registry.getSettlementConfig();
        if (insurance != address(0)) {
            paramChecker.setAllowedReceiver(address(metawalletUSDC), insurance, true);
        }
        if (treasury != address(0)) {
            paramChecker.setAllowedReceiver(address(metawalletUSDC), treasury, true);
        }
        vm.stopPrank();
    }

    /// @notice Computes the expected insurance/treasury share distribution for a DN profit settlement
    /// @dev Mirrors the on-chain logic in `_distributeProfitShares` so tests can assert exact amounts.
    ///      Isolated into its own internal helper to keep callers within EVM stack limits.
    /// @param insuranceBps Insurance basis points configured in the registry
    /// @param treasuryBps Treasury basis points configured in the registry
    /// @param insuranceBalanceBefore Pre-settlement metawallet shares held by the insurance address
    function _computeExpectedDistribution(
        uint16 insuranceBps,
        uint16 treasuryBps,
        uint256 insuranceBalanceBefore
    )
        internal
        view
        returns (uint256 expectedInsuranceShares, uint256 expectedTreasuryShares)
    {
        uint256 kMinterShares = metawalletUSDC.balanceOf(address(minterAdapterUSDC));
        uint256 valueBefore = metawalletUSDC.convertToAssets(kMinterShares);
        uint256 newTotal = tokens.usdc.balanceOf(address(metawalletUSDC));
        uint256 mwSupply = metawalletUSDC.totalSupply();
        uint256 valueAfter = (kMinterShares * (newTotal + 1)) / (mwSupply + 1);
        uint256 profitAssets = valueAfter > valueBefore ? valueAfter - valueBefore : 0;

        uint256 insuranceDeficitAssets;
        {
            uint256 expectedKMinterAssets = IVaultAdapter(address(minterAdapterUSDC)).totalAssets();
            uint256 insuranceTarget = (expectedKMinterAssets * insuranceBps) / 10_000;
            uint256 insuranceCurrentAssets = metawalletUSDC.convertToAssets(insuranceBalanceBefore);
            insuranceDeficitAssets =
                insuranceCurrentAssets >= insuranceTarget ? 0 : insuranceTarget - insuranceCurrentAssets;
        }

        uint256 profitShares = (profitAssets * (mwSupply + 1)) / (newTotal + 1);
        while ((profitShares * (newTotal + 1)) / (mwSupply + 1) < profitAssets) {
            profitShares += 1;
        }

        uint256 insuranceDeficitShares = (insuranceDeficitAssets * (mwSupply + 1)) / (newTotal + 1);
        while ((insuranceDeficitShares * (newTotal + 1)) / (mwSupply + 1) < insuranceDeficitAssets) {
            insuranceDeficitShares += 1;
        }
        expectedInsuranceShares = profitShares < insuranceDeficitShares ? profitShares : insuranceDeficitShares;

        uint256 remainingSharesAfterInsurance = profitShares - expectedInsuranceShares;
        expectedTreasuryShares = (remainingSharesAfterInsurance * treasuryBps) / 10_000;
    }

    /// @notice Snapshots metawallet state and computes the resulting profit shares
    /// @dev Isolated into its own internal helper so callers stay within EVM stack limits.
    ///      Mirrors the dust-rounding loop used on-chain when converting profit assets to shares.
    /// @return profitShares Number of metawallet shares matching the current depeg-derived profit
    /// @return mwSupply Pre-settlement metawallet total supply (needed by callers for netting math)
    /// @return newTotal Pre-settlement underlying balance held by the metawallet
    function _computeProfitSharesAndMwState()
        internal
        view
        returns (uint256 profitShares, uint256 mwSupply, uint256 newTotal)
    {
        uint256 kMinterShares = metawalletUSDC.balanceOf(address(minterAdapterUSDC));
        uint256 valueBefore = metawalletUSDC.convertToAssets(kMinterShares);
        newTotal = tokens.usdc.balanceOf(address(metawalletUSDC));
        mwSupply = metawalletUSDC.totalSupply();
        uint256 valueAfter = (kMinterShares * (newTotal + 1)) / (mwSupply + 1);
        uint256 profitAssets = valueAfter > valueBefore ? valueAfter - valueBefore : 0;

        profitShares = (profitAssets * (mwSupply + 1)) / (newTotal + 1);
        while ((profitShares * (newTotal + 1)) / (mwSupply + 1) < profitAssets) {
            profitShares += 1;
        }
    }

    function test_settler_profit_distribution_to_insurance() public {
        uint16 insuranceBps = 1000;
        _setupProfitDistribution(insuranceBps, 0);

        uint256 metaWalletProfit = 200e6;
        uint256 depositAmount = 100e6;

        test_settler_kminter_netted_positive();

        vm.startPrank(users.alice);
        kUSD.approve(address(vault), type(uint256).max);
        bytes32 requestId = vault.requestStake(users.alice, users.alice, depositAmount);
        vm.stopPrank();

        bytes32 proposalId = _closeAndProposeDeltaNeutralBatch();
        _executeSettlement(proposalId);

        vm.prank(users.alice);
        vault.claimStakedShares(requestId);

        vm.startPrank(users.alice);
        kUSD.approve(address(vault), type(uint256).max);
        vault.requestStake(users.alice, users.alice, depositAmount);
        vm.stopPrank();

        (bool success,) = tokens.usdc
        .call(abi.encodeWithSignature("mint(address,uint256)", address(metawalletUSDC), metaWalletProfit));
        require(success);

        (, address insurance,,) = registry.getSettlementConfig();
        uint256 insuranceBalanceBefore = metawalletUSDC.balanceOf(insurance);

        // Compute expected distribution in a dedicated stack frame to keep this test within EVM stack limits.
        (uint256 expectedInsuranceShares,) = _computeExpectedDistribution(insuranceBps, 0, insuranceBalanceBefore);

        proposalId = _closeAndProposeDeltaNeutralBatch();

        // Before execution, insurance balance should be unchanged
        uint256 insuranceBalanceAfterProposal = metawalletUSDC.balanceOf(insurance);
        assertEq(insuranceBalanceAfterProposal, insuranceBalanceBefore);

        _acceptAndExecute(proposalId);

        uint256 insuranceBalanceAfter = metawalletUSDC.balanceOf(insurance);
        uint256 insuranceSharesReceived = insuranceBalanceAfter - insuranceBalanceBefore;

        assertApproxEqAbs(insuranceSharesReceived, expectedInsuranceShares, 5);
    }

    function test_settler_profit_distribution_to_treasury() public {
        uint16 treasuryBps = 2000;
        _setupProfitDistribution(0, treasuryBps);

        uint256 metaWalletProfit = 200e6;
        uint256 depositAmount = 100e6;

        test_settler_kminter_netted_positive();

        vm.startPrank(users.alice);
        kUSD.approve(address(vault), type(uint256).max);
        bytes32 requestId = vault.requestStake(users.alice, users.alice, depositAmount);
        vm.stopPrank();

        bytes32 proposalId = _closeAndProposeDeltaNeutralBatch();
        _executeSettlement(proposalId);

        vm.prank(users.alice);
        vault.claimStakedShares(requestId);

        vm.startPrank(users.alice);
        kUSD.approve(address(vault), type(uint256).max);
        vault.requestStake(users.alice, users.alice, depositAmount);
        vm.stopPrank();

        (bool success,) = tokens.usdc
        .call(abi.encodeWithSignature("mint(address,uint256)", address(metawalletUSDC), metaWalletProfit));
        require(success);

        (address treasury,,,) = registry.getSettlementConfig();
        uint256 treasuryBalanceBefore = metawalletUSDC.balanceOf(treasury);

        // Compute expected distribution in a dedicated stack frame to keep this test within EVM stack limits.
        (, uint256 expectedTreasuryShares) = _computeExpectedDistribution(0, treasuryBps, 0);

        proposalId = _closeAndProposeDeltaNeutralBatch();

        // Before execution, treasury balance should be unchanged
        uint256 treasuryBalanceAfterProposal = metawalletUSDC.balanceOf(treasury);
        assertEq(treasuryBalanceAfterProposal, treasuryBalanceBefore);

        _acceptAndExecute(proposalId);

        uint256 treasurySharesReceived = metawalletUSDC.balanceOf(treasury) - treasuryBalanceBefore;

        assertApproxEqAbs(treasurySharesReceived, expectedTreasuryShares, 5);
    }

    function test_settler_profit_distribution_insurance_and_treasury() public {
        uint16 insuranceBps = 1;
        uint16 treasuryBps = 2000;
        _setupProfitDistribution(insuranceBps, treasuryBps);

        uint256 metaWalletProfit = 5000e6;
        uint256 depositAmount = 100e6;

        test_settler_kminter_netted_positive();

        vm.startPrank(users.alice);
        kUSD.approve(address(vault), type(uint256).max);
        bytes32 requestId = vault.requestStake(users.alice, users.alice, depositAmount);
        vm.stopPrank();

        bytes32 proposalId = _closeAndProposeDeltaNeutralBatch();
        _executeSettlement(proposalId);

        vm.prank(users.alice);
        vault.claimStakedShares(requestId);

        vm.startPrank(users.alice);
        kUSD.approve(address(vault), type(uint256).max);
        vault.requestStake(users.alice, users.alice, depositAmount);
        vm.stopPrank();

        (bool success,) = tokens.usdc
        .call(abi.encodeWithSignature("mint(address,uint256)", address(metawalletUSDC), metaWalletProfit));
        require(success);

        (address treasury, address insurance,,) = registry.getSettlementConfig();
        uint256 insuranceBalanceBefore = metawalletUSDC.balanceOf(insurance);
        uint256 treasuryBalanceBefore = metawalletUSDC.balanceOf(treasury);

        // Compute expected distribution in a dedicated stack frame to keep this test within EVM stack limits.
        (uint256 expectedInsuranceShares, uint256 expectedTreasuryShares) =
            _computeExpectedDistribution(insuranceBps, treasuryBps, insuranceBalanceBefore);

        proposalId = _closeAndProposeDeltaNeutralBatch();

        // Before execution, balances should be unchanged
        uint256 insuranceBalanceAfterProposal = metawalletUSDC.balanceOf(insurance);
        assertEq(insuranceBalanceAfterProposal, insuranceBalanceBefore);

        _acceptAndExecute(proposalId);

        uint256 insuranceBalanceAfter = metawalletUSDC.balanceOf(insurance);
        uint256 treasuryBalanceAfter = metawalletUSDC.balanceOf(treasury);

        uint256 insuranceSharesReceived = insuranceBalanceAfter - insuranceBalanceBefore;
        uint256 treasurySharesReceived = treasuryBalanceAfter - treasuryBalanceBefore;

        assertApproxEqAbs(insuranceSharesReceived, expectedInsuranceShares, 5);
        assertApproxEqAbs(treasurySharesReceived, expectedTreasuryShares, 5);
    }

    function test_settler_dn_batch_all_profit_distributed() public {
        _disableProfitDistribution();

        uint256 metaWalletProfit = 200e6;
        uint256 depositAmount = 100e6;

        test_settler_kminter_netted_positive();

        vm.startPrank(users.alice);
        kUSD.approve(address(vault), type(uint256).max);
        bytes32 requestId = vault.requestStake(users.alice, users.alice, depositAmount);
        vm.stopPrank();

        bytes32 proposalId = _closeAndProposeDeltaNeutralBatch();
        _executeSettlement(proposalId);

        vm.prank(users.alice);
        vault.claimStakedShares(requestId);

        vm.startPrank(users.alice);
        kUSD.approve(address(vault), type(uint256).max);
        vault.requestStake(users.alice, users.alice, depositAmount);
        vm.stopPrank();

        (bool success,) = tokens.usdc
        .call(abi.encodeWithSignature("mint(address,uint256)", address(metawalletUSDC), metaWalletProfit));
        require(success);

        uint256 dnAdapterBalanceBefore = metawalletUSDC.balanceOf(address(DNVaultAdapterUSDC));

        // All profit shares should go to vault adapter (no partial distribution).
        // Snapshot metawallet state in a dedicated frame to keep this test within EVM stack limits.
        (uint256 expectedVaultAdapterProfitShares, uint256 mwSupply, uint256 newTotal) =
            _computeProfitSharesAndMwState();

        proposalId = _closeAndProposeDeltaNeutralBatch();

        uint256 dnAdapterBalanceAfterProposal = metawalletUSDC.balanceOf(address(DNVaultAdapterUSDC));
        assertEq(dnAdapterBalanceAfterProposal, dnAdapterBalanceBefore);

        _acceptAndExecute(proposalId);

        uint256 vaultAdapterSharesReceived =
            metawalletUSDC.balanceOf(address(DNVaultAdapterUSDC)) - dnAdapterBalanceBefore;

        uint256 nettingShares = (depositAmount * (mwSupply + 1)) / (newTotal + 1);

        assertGt(vaultAdapterSharesReceived, nettingShares);

        uint256 profitShareReceived = vaultAdapterSharesReceived - nettingShares;
        assertApproxEqAbs(profitShareReceived, expectedVaultAdapterProfitShares, _ACCOUNTING_DUST);
    }

    function test_settler_liquidate_insurance() public {
        uint16 insuranceBps = 1000;
        _setupProfitDistribution(insuranceBps, 0);

        uint256 metaWalletProfit = 200e6;
        uint256 depositAmount = 100e6;

        // Setup: first do a kMinter batch
        test_settler_kminter_netted_positive();

        // Stake in DN vault
        vm.startPrank(users.alice);
        kUSD.approve(address(vault), type(uint256).max);
        bytes32 requestId = vault.requestStake(users.alice, users.alice, depositAmount);
        vm.stopPrank();

        bytes32 proposalId = _closeAndProposeDeltaNeutralBatch();
        _executeSettlement(proposalId);

        vm.prank(users.alice);
        vault.claimStakedShares(requestId);

        // Second stake to create more activity
        vm.startPrank(users.alice);
        kUSD.approve(address(vault), type(uint256).max);
        vault.requestStake(users.alice, users.alice, depositAmount);
        vm.stopPrank();

        // Mint profit to metawallet
        (bool success,) = tokens.usdc
        .call(abi.encodeWithSignature("mint(address,uint256)", address(metawalletUSDC), metaWalletProfit));
        require(success);

        // Close batch - this should distribute profit to insurance
        proposalId = _closeAndProposeDeltaNeutralBatch();
        _executeSettlement(proposalId);

        // Get insurance address and verify it has shares
        (, address insurance,,) = registry.getSettlementConfig();
        uint256 insuranceSharesBefore = metawalletUSDC.balanceOf(insurance);
        uint256 insuranceAssetsBefore = tokens.usdc.balanceOf(insurance);

        // Insurance should have received some shares
        assertGt(insuranceSharesBefore, 0);

        // Setup insurance account permissions for redeem
        _setupInsurancePermissions(insurance);

        // Liquidate insurance - convert shares to underlying assets
        vm.startPrank(users.relayer);
        settler.liquidateInsurance(tokens.usdc, address(metawalletUSDC));
        vm.stopPrank();

        // Verify insurance now has assets instead of shares
        uint256 insuranceSharesAfter = metawalletUSDC.balanceOf(insurance);
        uint256 insuranceAssetsAfter = tokens.usdc.balanceOf(insurance);

        // Shares should be gone (or significantly reduced)
        assertEq(insuranceSharesAfter, 0);

        // Assets should have increased by approximately the value of shares redeemed
        uint256 expectedAssets = metawalletUSDC.convertToAssets(insuranceSharesBefore);
        assertApproxEqAbs(insuranceAssetsAfter - insuranceAssetsBefore, expectedAssets, 1);
    }

    function test_settler_liquidate_insurance_no_shares() public {
        // Disable profit distribution so insurance gets no shares
        _disableProfitDistribution();

        // Get insurance address
        (, address insurance,,) = registry.getSettlementConfig();

        // Setup permissions even though we have no shares
        _setupInsurancePermissions(insurance);

        // Verify insurance has no shares
        uint256 insuranceSharesBefore = metawalletUSDC.balanceOf(insurance);
        assertEq(insuranceSharesBefore, 0);

        // Liquidate should return early without reverting
        vm.startPrank(users.relayer);
        settler.liquidateInsurance(tokens.usdc, address(metawalletUSDC));
        vm.stopPrank();

        // Verify nothing changed
        uint256 insuranceSharesAfter = metawalletUSDC.balanceOf(insurance);
        assertEq(insuranceSharesAfter, 0);
    }

    function test_settler_zero_supply_profit_distributed_to_insurance_and_treasury() public {
        uint16 insuranceBps = 0; // No insurance to ensure profit reaches treasury
        uint16 treasuryBps = 2000;
        _setupProfitDistribution(insuranceBps, treasuryBps);

        uint256 metaWalletProfit = 200e6;

        // Setup: run kMinter batch (no DN stakers yet — vault has zero supply)
        test_settler_kminter_netted_positive();

        // At this point, the DN vault has totalSupply == 0
        assertEq(vault.totalSupply(), 0);

        // Mint profit into the metawallet (simulates strategy yield)
        (bool success,) = tokens.usdc
        .call(abi.encodeWithSignature("mint(address,uint256)", address(metawalletUSDC), metaWalletProfit));
        require(success);

        // Capture pre-state
        (address treasury,,,) = registry.getSettlementConfig();
        uint256 treasuryBalanceBefore = metawalletUSDC.balanceOf(treasury);
        uint256 dnAdapterBalanceBefore = metawalletUSDC.balanceOf(address(DNVaultAdapterUSDC));

        // Close DN batch — with zero supply, profit should still go to insurance + treasury
        vm.startPrank(users.relayer);
        uint256 _totalAssets = tokens.usdc.balanceOf(address(metawalletUSDC));
        bytes32 _rootHash = keccak256(abi.encodePacked(address(metawalletUSDC), _totalAssets));
        bytes32 proposalId = settler.closeAndProposeDNVaultBatch(tokens.usdc, _totalAssets, _rootHash);
        vm.stopPrank();

        uint256 treasuryBalanceAfterProposal = metawalletUSDC.balanceOf(treasury);
        assertEq(treasuryBalanceAfterProposal, treasuryBalanceBefore);

        _acceptAndExecute(proposalId);

        uint256 treasuryBalanceAfter = metawalletUSDC.balanceOf(treasury);
        uint256 dnAdapterBalanceAfter = metawalletUSDC.balanceOf(address(DNVaultAdapterUSDC));

        // Treasury should have received shares (its BPS cut + residual from zero supply)
        assertGt(treasuryBalanceAfter, treasuryBalanceBefore);

        // DN vault adapter should NOT have received any profit shares (zero supply guard)
        // The residual that would have gone to vault adapter is routed to treasury instead
        assertEq(dnAdapterBalanceAfter, dnAdapterBalanceBefore);
    }

    function test_settler_zero_supply_profit_all_to_treasury_when_no_insurance() public {
        uint16 treasuryBps = 2000;
        _setupProfitDistribution(0, treasuryBps);

        uint256 metaWalletProfit = 200e6;

        // Setup: run kMinter batch (no DN stakers yet — vault has zero supply)
        test_settler_kminter_netted_positive();

        assertEq(vault.totalSupply(), 0);

        (bool success,) = tokens.usdc
        .call(abi.encodeWithSignature("mint(address,uint256)", address(metawalletUSDC), metaWalletProfit));
        require(success);

        (address treasury,,,) = registry.getSettlementConfig();
        uint256 treasuryBalanceBefore = metawalletUSDC.balanceOf(treasury);

        bytes32 proposalId = _closeAndProposeDeltaNeutralBatch();

        uint256 treasuryBalanceAfterProposal = metawalletUSDC.balanceOf(treasury);
        assertEq(treasuryBalanceAfterProposal, treasuryBalanceBefore);

        _acceptAndExecute(proposalId);

        uint256 treasuryBalanceAfter = metawalletUSDC.balanceOf(treasury);

        // Treasury should have received both its BPS cut and the residual
        assertGt(treasuryBalanceAfter, treasuryBalanceBefore);
    }

    function _setupInsurancePermissions(address insurance) internal {
        vm.stopPrank();

        // The insurance smart account is a base MinimalSmartAccount (not SmartAdapterAccount)
        // so it checks EXECUTOR_ROLE (_ROLE_1 = 2) on the caller, not isManager()
        // We need to grant this role from the owner of the insurance account
        vm.startPrank(users.owner);
        // Grant EXECUTOR_ROLE (value = 2) to settler on the insurance smart account
        MinimalSmartAccount(payable(insurance)).grantRoles(address(settler), 2);
        vm.stopPrank();

        vm.startPrank(users.admin);

        // Set up insurance executor permissions for metawallet operations
        bytes4 redeemSelector = IERC4626.withdraw.selector;

        // Cast registry to IExecutionGuardian to access setAllowedSelector
        IExecutionGuardian guardianModule = IExecutionGuardian(address(registry));

        // Allow insurance to call redeem on the metawallet (targetType = 0 for METAWALLET)
        guardianModule.setAllowedSelector(
            insurance, address(metawalletUSDC), IExecutionGuardian.TargetType.METAWALLET, redeemSelector, true
        );

        vm.stopPrank();
    }

    function _executeSettlement(bytes32 _proposalId) internal {
        vm.prank(users.relayer);
        settler.executeSettleBatch(_proposalId);
        _assertPostSettlementAccounting(_proposalId);
    }

    function _assertPostSettlementAccounting(bytes32 _proposalId) internal view {
        IkAssetRouter.VaultSettlementProposal memory proposal = assetRouter.getSettlementProposal(_proposalId);

        if (proposal.vault == address(minter)) {
            uint256 minterAdapterAssets = IVaultAdapter(address(minterAdapterUSDC)).totalAssets();
            uint256 minterMetaWalletAssets =
                metawalletUSDC.convertToAssets(metawalletUSDC.balanceOf(address(minterAdapterUSDC)));

            assertEq(minterAdapterAssets, proposal.totalAssets, "MINTER_ADAPTER_PROPOSAL_TOTAL_ASSETS");
            assertApproxEqAbs(
                minterMetaWalletAssets, minterAdapterAssets, _ACCOUNTING_DUST, "MINTER_ADAPTER_METAWALLET_POSITION"
            );
        } else if (proposal.vault == address(vault)) {
            uint256 dnVaultAssets = vault.totalAssets();
            uint256 dnAdapterAssets = IVaultAdapter(address(DNVaultAdapterUSDC)).totalAssets();
            uint256 dnMetaWalletAssets =
                metawalletUSDC.convertToAssets(metawalletUSDC.balanceOf(address(DNVaultAdapterUSDC)));

            assertEq(dnAdapterAssets, proposal.totalAssets, "DN_ADAPTER_PROPOSAL_TOTAL_ASSETS");
            assertEq(dnAdapterAssets, dnVaultAssets, "DN_ADAPTER_VAULT_TOTAL_ASSETS");
            assertApproxEqAbs(dnMetaWalletAssets, dnAdapterAssets, _ACCOUNTING_DUST, "DN_ADAPTER_METAWALLET_POSITION");
        }
    }

    uint256 internal constant _TEST_ADMIN_ROLE = 1;
    uint256 internal constant _TEST_SETTLER_RELAYER_ROLE = 2;

    function test_grantRelayerRole_byAdmin_succeeds() public {
        address newRelayer = makeAddr("newRelayer");
        vm.prank(users.admin);
        settler.grantRelayerRole(newRelayer);
        assertTrue(settler.hasAnyRole(newRelayer, _TEST_SETTLER_RELAYER_ROLE));
    }

    function test_grantRelayerRole_byNonAdmin_reverts() public {
        address newRelayer = makeAddr("newRelayer");
        vm.prank(users.relayer);
        vm.expectRevert(Ownable.Unauthorized.selector);
        settler.grantRelayerRole(newRelayer);
    }

    function test_grantRelayerRole_zeroAddress_reverts() public {
        vm.prank(users.admin);
        vm.expectRevert(bytes(KSETTLER_ADDRESS_ZERO));
        settler.grantRelayerRole(address(0));
    }

    function test_revokeRelayerRole_byAdmin_succeeds() public {
        address newRelayer = makeAddr("newRelayer");
        vm.prank(users.admin);
        settler.grantRelayerRole(newRelayer);
        assertTrue(settler.hasAnyRole(newRelayer, _TEST_SETTLER_RELAYER_ROLE));

        vm.prank(users.admin);
        settler.revokeRelayerRole(newRelayer);
        assertFalse(settler.hasAnyRole(newRelayer, _TEST_SETTLER_RELAYER_ROLE));
    }

    function test_revokeRelayerRole_byNonAdmin_reverts() public {
        address newRelayer = makeAddr("newRelayer");
        vm.prank(users.admin);
        settler.grantRelayerRole(newRelayer);

        vm.prank(users.relayer);
        vm.expectRevert(Ownable.Unauthorized.selector);
        settler.revokeRelayerRole(newRelayer);
    }

    function test_grantAdminRole_byOwner_succeeds() public {
        address newAdmin = makeAddr("newAdmin");
        vm.prank(users.owner);
        settler.grantAdminRole(newAdmin);
        assertTrue(settler.hasAnyRole(newAdmin, _TEST_ADMIN_ROLE));
    }

    function test_grantAdminRole_byAdmin_reverts() public {
        // localhost fixture sets users.owner == users.admin, so prank a freshly-granted admin.
        address freshAdmin = makeAddr("freshAdmin");
        vm.prank(users.owner);
        settler.grantAdminRole(freshAdmin);

        address newAdmin = makeAddr("newAdmin");
        vm.prank(freshAdmin);
        vm.expectRevert(Ownable.Unauthorized.selector);
        settler.grantAdminRole(newAdmin);
    }

    function test_grantAdminRole_zeroAddress_reverts() public {
        vm.prank(users.owner);
        vm.expectRevert(bytes(KSETTLER_ADDRESS_ZERO));
        settler.grantAdminRole(address(0));
    }

    function test_revokeAdminRole_byOwner_succeeds() public {
        address newAdmin = makeAddr("newAdmin");
        vm.prank(users.owner);
        settler.grantAdminRole(newAdmin);
        assertTrue(settler.hasAnyRole(newAdmin, _TEST_ADMIN_ROLE));

        vm.prank(users.owner);
        settler.revokeAdminRole(newAdmin);
        assertFalse(settler.hasAnyRole(newAdmin, _TEST_ADMIN_ROLE));
    }

    function test_revokeAdminRole_byAdmin_reverts() public {
        // localhost fixture sets users.owner == users.admin, so prank a freshly-granted admin.
        address freshAdmin = makeAddr("freshAdmin");
        vm.prank(users.owner);
        settler.grantAdminRole(freshAdmin);

        vm.prank(freshAdmin);
        vm.expectRevert(Ownable.Unauthorized.selector);
        settler.revokeAdminRole(freshAdmin);
    }

    function test_liquidateInsurance_zeroMetawallet_reverts() public {
        vm.prank(users.relayer);
        vm.expectRevert(bytes(KSETTLER_ADDRESS_ZERO));
        settler.liquidateInsurance(tokens.usdc, address(0));
    }

    function test_liquidateInsurance_assetMismatch_reverts() public {
        // metawalletUSDC.asset() is USDC; passing a different asset must revert.
        address wrongAsset = makeAddr("wrongAsset");
        vm.prank(users.relayer);
        vm.expectRevert(bytes(KSETTLER_ASSET_MISMATCH));
        settler.liquidateInsurance(wrongAsset, address(metawalletUSDC));
    }

    function test_settler_cancel_proposal() public {
        uint256 depositAmount = 100e6;

        vm.startPrank(users.alice);
        kUSD.approve(address(vault), type(uint256).max);
        vault.requestStake(users.alice, users.alice, depositAmount);
        vm.stopPrank();

        uint256 adapterBalanceBefore = metawalletUSDC.balanceOf(address(DNVaultAdapterUSDC));

        bytes32 proposalId = _closeAndProposeDeltaNeutralBatch();

        // Assert that balances did not change yet (due to deferred execution)
        uint256 adapterBalanceAfterProposal = metawalletUSDC.balanceOf(address(DNVaultAdapterUSDC));
        assertEq(adapterBalanceAfterProposal, adapterBalanceBefore);

        // Now cancel the proposal in the router
        vm.prank(users.guardian);
        assetRouter.cancelProposal(proposalId);

        // Ensure that clearing the cancelled proposal from the settler works
        vm.prank(users.relayer);
        settler.clearCancelledSettlement(proposalId);

        // Balances should still be unchanged
        uint256 adapterBalanceAfterCancel = metawalletUSDC.balanceOf(address(DNVaultAdapterUSDC));
        assertEq(adapterBalanceAfterCancel, adapterBalanceBefore);

        // Expect revert if we try to execute the cancelled proposal
        vm.prank(users.relayer);
        vm.expectRevert();
        settler.executeSettleBatch(proposalId);
    }
}
