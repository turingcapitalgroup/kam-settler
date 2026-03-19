// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import { console2 as console } from "forge-std/console2.sol";
import { ERC20ExecutionValidator } from "kam/src/adapters/parameters/ERC20ExecutionValidator.sol";
import { IVaultAdapter } from "kam/src/interfaces/IVaultAdapter.sol";
import { IkAssetRouter } from "kam/src/interfaces/IkAssetRouter.sol";
import { IkRegistry } from "kam/src/interfaces/IkRegistry.sol";
import { IExecutionGuardian } from "kam/src/interfaces/modules/IExecutionGuardian.sol";
import { MockERC4626 } from "kam/test/mocks/MockERC4626.sol";
import { BaseVaultTest, DeploymentBaseTest, IkStakingVault, SafeTransferLib } from "kam/test/utils/BaseVaultTest.sol";
import { IERC4626 } from "metawallet/src/interfaces/IERC4626.sol";
import { IVaultModule } from "metawallet/src/interfaces/IVaultModule.sol";
import { MinimalSmartAccount } from "minimal-smart-account/MinimalSmartAccount.sol";
import { Execution, ExecutionLib } from "minimal-smart-account/libraries/ExecutionLib.sol";
import { ModeCode, ModeLib } from "minimal-smart-account/libraries/ModeLib.sol";
import { DeploykSettlerScript } from "script/DeploykSettler.s.sol";
import { OptimizedFixedPointMathLib } from "solady/utils/OptimizedFixedPointMathLib.sol";
import { kSettler } from "src/kSettler.sol";
import { DeployMetaWallet } from "test/utils/DeployMetaWallet.sol";

contract kSettlerTest is BaseVaultTest, DeployMetaWallet {
    using SafeTransferLib for address;
    using OptimizedFixedPointMathLib for int256;

    kSettler public settler;
    ERC20ExecutionValidator public paramChecker;

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

        _setupTestFees();

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
        uint256 metawalletUsdcBalanceAfter = tokens.usdc.balanceOf(address(metawalletUSDC));

        assertEq(metawalletUsdcBalanceAfter - metawalletUsdcBalanceBefore, depositAmount - requestAmount);
        adapterBalanceAfter = tokens.usdc.balanceOf(address(minterAdapterUSDC));
        assertEq(adapterBalanceAfter - adapterBalanceBefore, requestAmount);

        assetRouter.executeSettleBatch(proposalId);
        uint256 finalAdapterBalance = tokens.usdc.balanceOf(address(minterAdapterUSDC));
        assertEq(adapterBalanceAfter - finalAdapterBalance, requestAmount);

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

        uint256 metawalletUsdcBalanceAfter = tokens.usdc.balanceOf(address(metawalletUSDC));

        assertEq(metawalletUsdcBalanceBefore - metawalletUsdcBalanceAfter, requestAmount - depositAmount);
        adapterBalanceAfter = tokens.usdc.balanceOf(address(minterAdapterUSDC));

        assertEq(adapterBalanceAfter - adapterBalanceBefore, requestAmount);

        assetRouter.executeSettleBatch(proposalId);
        uint256 finalAdapterBalance = tokens.usdc.balanceOf(address(minterAdapterUSDC));
        assertEq(adapterBalanceAfter - finalAdapterBalance, requestAmount);

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
        uint256 adapterBalanceAfter = metawalletUSDC.balanceOf(address(DNVaultAdapterUSDC));
        assertGt(adapterBalanceAfter, adapterBalanceBefore);
        assertEq(assetRouter.getSettlementProposal(proposalId).yield, 0);

        assetRouter.executeSettleBatch(proposalId);

        vm.prank(users.alice);
        vault.claimStakedShares(requestId);

        vm.prank(users.alice);
        kUSD.approve(address(vault), type(uint256).max);
        vm.prank(users.alice);
        vault.requestStake(users.alice, users.alice, depositAmount);
        vm.prank(users.alice);
        requestId = vault.requestUnstake(users.alice, users.alice, requestAmount);

        proposalId = _closeAndProposeDeltaNeutralBatch();
        assetRouter.executeSettleBatch(proposalId);

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
        uint256 adapterBalanceAfter = metawalletUSDC.balanceOf(address(DNVaultAdapterUSDC));
        assertGt(adapterBalanceAfter, adapterBalanceBefore);
        assertEq(assetRouter.getSettlementProposal(proposalId).yield, 0);

        _acceptAndExecute(proposalId);

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
        _setFeesToZero();
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
        uint256 adapterBalanceAfter = metawalletUSDC.balanceOf(address(DNVaultAdapterUSDC));
        assertGt(adapterBalanceAfter, adapterBalanceBefore);

        _acceptAndExecute(proposalId);

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

        assertApproxEqAbs(vault.convertToAssets(gotShares), depositAmount, 10);

        tokens.usdc.call(abi.encodeWithSignature("mint(address,uint256)", address(metawalletUSDC), metaWalletProfit));

        uint256 sharePriceBefore = vault.sharePrice();
        proposalId = _closeAndProposeDeltaNeutralBatch();
        _acceptAndExecute(proposalId);

        uint256 sharePriceAfter = vault.sharePrice();
        assertGt(sharePriceAfter, sharePriceBefore);
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
        assetRouter.executeSettleBatch(proposalId);
    }

    function _getDepeg() internal view returns (int256) {
        uint256 _kMinterShares = metawalletUSDC.balanceOf(address(minterAdapterUSDC));
        uint256 _actualKMinterAssets = metawalletUSDC.convertToAssets(_kMinterShares);
        uint256 _expectedKMinterAssets = IVaultAdapter(address(minterAdapterUSDC)).totalAssets();
        // Positive = surplus/profit, Negative = deficit/loss
        return int256(_actualKMinterAssets) - int256(_expectedKMinterAssets);
    }

    function _setFeesToZero() internal {
        vm.startPrank(users.admin);
        vault.setManagementFee(0);
        vault.setPerformanceFee(0);
        vault.setHardHurdleRate(false);
        vm.stopPrank();

        vm.prank(users.admin);
        registry.setHurdleRate(tokens.usdc, 0);
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

    function test_settler_profit_distribution_to_insurance() public {
        _setFeesToZero();
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
        assetRouter.executeSettleBatch(proposalId);

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

        uint256 kMinterShares = metawalletUSDC.balanceOf(address(minterAdapterUSDC));
        uint256 valueBefore = metawalletUSDC.convertToAssets(kMinterShares);
        uint256 newTotal = tokens.usdc.balanceOf(address(metawalletUSDC));
        uint256 mwSupply = metawalletUSDC.totalSupply();
        uint256 valueAfter = (kMinterShares * (newTotal + 1)) / (mwSupply + 1);
        uint256 profitAssets = valueAfter > valueBefore ? valueAfter - valueBefore : 0;

        uint256 expectedKMinterAssets = IVaultAdapter(address(minterAdapterUSDC)).totalAssets();
        uint256 insuranceTarget = (expectedKMinterAssets * insuranceBps) / 10_000;
        uint256 insuranceCurrentAssets = metawalletUSDC.convertToAssets(insuranceBalanceBefore);
        uint256 insuranceDeficitAssets =
            insuranceCurrentAssets >= insuranceTarget ? 0 : insuranceTarget - insuranceCurrentAssets;

        uint256 profitShares = (profitAssets * (mwSupply + 1)) / (newTotal + 1);
        while ((profitShares * (newTotal + 1)) / (mwSupply + 1) < profitAssets) {
            profitShares += 1;
        }

        uint256 insuranceDeficitShares = (insuranceDeficitAssets * (mwSupply + 1)) / (newTotal + 1);
        while ((insuranceDeficitShares * (newTotal + 1)) / (mwSupply + 1) < insuranceDeficitAssets) {
            insuranceDeficitShares += 1;
        }
        uint256 expectedInsuranceShares = profitShares < insuranceDeficitShares ? profitShares : insuranceDeficitShares;

        proposalId = _closeAndProposeDeltaNeutralBatch();

        uint256 insuranceBalanceAfter = metawalletUSDC.balanceOf(insurance);
        uint256 insuranceSharesReceived = insuranceBalanceAfter - insuranceBalanceBefore;

        assertApproxEqAbs(insuranceSharesReceived, expectedInsuranceShares, 10);

        _acceptAndExecute(proposalId);
    }

    function test_settler_profit_distribution_to_treasury() public {
        _setFeesToZero();
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
        assetRouter.executeSettleBatch(proposalId);

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

        uint256 kMinterShares = metawalletUSDC.balanceOf(address(minterAdapterUSDC));
        uint256 valueBefore = metawalletUSDC.convertToAssets(kMinterShares);
        uint256 newTotal = tokens.usdc.balanceOf(address(metawalletUSDC));
        uint256 mwSupply = metawalletUSDC.totalSupply();
        uint256 valueAfter = (kMinterShares * (newTotal + 1)) / (mwSupply + 1);
        uint256 profitAssets = valueAfter > valueBefore ? valueAfter - valueBefore : 0;

        uint256 profitShares = (profitAssets * (mwSupply + 1)) / (newTotal + 1);
        while ((profitShares * (newTotal + 1)) / (mwSupply + 1) < profitAssets) {
            profitShares += 1;
        }

        uint256 remainingShares = profitShares;
        uint256 expectedTreasuryShares = (remainingShares * treasuryBps) / 10_000;

        proposalId = _closeAndProposeDeltaNeutralBatch();

        uint256 treasuryBalanceAfter = metawalletUSDC.balanceOf(treasury);
        uint256 treasurySharesReceived = treasuryBalanceAfter - treasuryBalanceBefore;

        assertApproxEqAbs(treasurySharesReceived, expectedTreasuryShares, 10);

        _acceptAndExecute(proposalId);
    }

    function test_settler_profit_distribution_insurance_and_treasury() public {
        _setFeesToZero();
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
        assetRouter.executeSettleBatch(proposalId);

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

        uint256 kMinterShares = metawalletUSDC.balanceOf(address(minterAdapterUSDC));
        uint256 valueBefore = metawalletUSDC.convertToAssets(kMinterShares);
        uint256 newTotal = tokens.usdc.balanceOf(address(metawalletUSDC));
        uint256 mwSupply = metawalletUSDC.totalSupply();
        uint256 valueAfter = (kMinterShares * (newTotal + 1)) / (mwSupply + 1);
        uint256 profitAssets = valueAfter > valueBefore ? valueAfter - valueBefore : 0;

        uint256 expectedKMinterAssets = IVaultAdapter(address(minterAdapterUSDC)).totalAssets();
        uint256 insuranceTarget = (expectedKMinterAssets * insuranceBps) / 10_000;
        uint256 insuranceCurrentAssets = metawalletUSDC.convertToAssets(insuranceBalanceBefore);
        uint256 insuranceDeficitAssets =
            insuranceCurrentAssets >= insuranceTarget ? 0 : insuranceTarget - insuranceCurrentAssets;

        uint256 profitShares = (profitAssets * (mwSupply + 1)) / (newTotal + 1);
        while ((profitShares * (newTotal + 1)) / (mwSupply + 1) < profitAssets) {
            profitShares += 1;
        }

        uint256 insuranceDeficitShares = (insuranceDeficitAssets * (mwSupply + 1)) / (newTotal + 1);
        while ((insuranceDeficitShares * (newTotal + 1)) / (mwSupply + 1) < insuranceDeficitAssets) {
            insuranceDeficitShares += 1;
        }
        uint256 expectedInsuranceShares = profitShares < insuranceDeficitShares ? profitShares : insuranceDeficitShares;

        uint256 remainingSharesAfterInsurance = profitShares - expectedInsuranceShares;
        uint256 expectedTreasuryShares = (remainingSharesAfterInsurance * treasuryBps) / 10_000;

        proposalId = _closeAndProposeDeltaNeutralBatch();

        uint256 insuranceBalanceAfter = metawalletUSDC.balanceOf(insurance);
        uint256 treasuryBalanceAfter = metawalletUSDC.balanceOf(treasury);

        uint256 insuranceSharesReceived = insuranceBalanceAfter - insuranceBalanceBefore;
        uint256 treasurySharesReceived = treasuryBalanceAfter - treasuryBalanceBefore;

        assertApproxEqAbs(insuranceSharesReceived, expectedInsuranceShares, 10);
        assertApproxEqAbs(treasurySharesReceived, expectedTreasuryShares, 10);

        _acceptAndExecute(proposalId);
    }

    function test_settler_dn_batch_all_profit_distributed() public {
        _setFeesToZero();
        _disableProfitDistribution();

        uint256 metaWalletProfit = 200e6;
        uint256 depositAmount = 100e6;

        test_settler_kminter_netted_positive();

        vm.startPrank(users.alice);
        kUSD.approve(address(vault), type(uint256).max);
        bytes32 requestId = vault.requestStake(users.alice, users.alice, depositAmount);
        vm.stopPrank();

        bytes32 proposalId = _closeAndProposeDeltaNeutralBatch();
        assetRouter.executeSettleBatch(proposalId);

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

        uint256 kMinterShares = metawalletUSDC.balanceOf(address(minterAdapterUSDC));
        uint256 valueBefore = metawalletUSDC.convertToAssets(kMinterShares);
        uint256 newTotal = tokens.usdc.balanceOf(address(metawalletUSDC));
        uint256 mwSupply = metawalletUSDC.totalSupply();
        uint256 valueAfter = (kMinterShares * (newTotal + 1)) / (mwSupply + 1);
        uint256 profitAssets = valueAfter > valueBefore ? valueAfter - valueBefore : 0;

        uint256 profitShares = (profitAssets * (mwSupply + 1)) / (newTotal + 1);
        while ((profitShares * (newTotal + 1)) / (mwSupply + 1) < profitAssets) {
            profitShares += 1;
        }

        // All profit shares should go to vault adapter (no partial distribution)
        uint256 expectedVaultAdapterProfitShares = profitShares;

        proposalId = _closeAndProposeDeltaNeutralBatch();

        uint256 dnAdapterBalanceAfter = metawalletUSDC.balanceOf(address(DNVaultAdapterUSDC));
        uint256 vaultAdapterSharesReceived = dnAdapterBalanceAfter - dnAdapterBalanceBefore;

        uint256 nettingShares = (depositAmount * (mwSupply + 1)) / (newTotal + 1);

        assertGt(vaultAdapterSharesReceived, nettingShares);

        uint256 profitShareReceived = vaultAdapterSharesReceived - nettingShares;
        assertApproxEqAbs(profitShareReceived, expectedVaultAdapterProfitShares, 10);

        _acceptAndExecute(proposalId);
    }

    function test_settler_liquidate_insurance() public {
        _setFeesToZero();
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
        assetRouter.executeSettleBatch(proposalId);

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
        assetRouter.executeSettleBatch(proposalId);

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
        settler.liquidateInsurance(tokens.usdc);
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
        settler.liquidateInsurance(tokens.usdc);
        vm.stopPrank();

        // Verify nothing changed
        uint256 insuranceSharesAfter = metawalletUSDC.balanceOf(insurance);
        assertEq(insuranceSharesAfter, 0);
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
        guardianModule.setAllowedSelector(insurance, address(metawalletUSDC), 0, redeemSelector, true);

        vm.stopPrank();
    }
}
