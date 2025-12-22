// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import { console2 as console } from "forge-std/console2.sol";
import { ERC20ExecutionValidator } from "kam/src/adapters/parameters/ERC20ExecutionValidator.sol";
import { IVaultAdapter } from "kam/src/interfaces/IVaultAdapter.sol";
import { IkRegistry } from "kam/src/interfaces/IkRegistry.sol";
import { IExecutionGuardian } from "kam/src/interfaces/modules/IExecutionGuardian.sol";
import { MockERC7540 } from "kam/test/mocks/MockERC7540.sol";
import { BaseVaultTest, DeploymentBaseTest, IkStakingVault, SafeTransferLib } from "kam/test/utils/BaseVaultTest.sol";
import { Execution, ExecutionLib } from "minimal-smart-account/libraries/ExecutionLib.sol";
import { ModeCode, ModeLib } from "minimal-smart-account/libraries/ModeLib.sol";
import { DeploySettlerScript } from "script/DeploySettler.s.sol";
import { OptimizedFixedPointMathLib } from "solady/utils/OptimizedFixedPointMathLib.sol";
import { Settler } from "src/Settler.sol";

contract SettlerTest is BaseVaultTest {
    using SafeTransferLib for address;
    using OptimizedFixedPointMathLib for int256;

    Settler public settler;
    ERC20ExecutionValidator public paramChecker;

    function setUp() public override {
        DeploymentBaseTest.setUp();

        bytes4 approveSelector = bytes4(keccak256("approve(address,uint256)"));
        paramChecker = ERC20ExecutionValidator(
            IExecutionGuardian(address(registry))
                .getExecutionValidator(address(minterAdapterUSDC), tokens.usdc, approveSelector)
        );

        DeploySettlerScript deployScript = new DeploySettlerScript();
        DeploySettlerScript.SettlerDeployment memory deployment = deployScript.runTest(
            users.owner, users.admin, users.relayer, address(minter), address(assetRouter), address(registry)
        );
        settler = Settler(deployment.settler);

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
        paramChecker.setAllowedSpender(address(erc7540USDC), address(DNVaultAdapterUSDC), true);
        vm.startPrank(users.relayer);

        uint256 _kMinterShares = erc7540USDC.balanceOf(address(minterAdapterUSDC));
        uint256 _actualKMinterAssets = erc7540USDC.convertToAssets(_kMinterShares);

        Execution[] memory executions1 = new Execution[](1);
        executions1[0] = Execution({
            target: tokens.usdc,
            value: 0,
            callData: abi.encodeWithSignature("approve(address,uint256)", address(erc7540USDC), type(uint256).max)
        });
        bytes memory executionCalldata1 = ExecutionLib.encodeBatch(executions1);
        ModeCode mode1 = ModeLib.encodeSimpleBatch();
        minterAdapterUSDC.execute(mode1, executionCalldata1);

        Execution[] memory executions2 = new Execution[](1);
        executions2[0] = Execution({
            target: address(erc7540USDC),
            value: 0,
            callData: abi.encodeWithSignature(
                "approve(address,uint256)", address(DNVaultAdapterUSDC), type(uint256).max
            )
        });
        bytes memory executionCalldata2 = ExecutionLib.encodeBatch(executions2);
        ModeCode mode2 = ModeLib.encodeSimpleBatch();
        minterAdapterUSDC.execute(mode2, executionCalldata2);

        uint256 balance = tokens.usdc.balanceOf(address(minterAdapterUSDC));

        deal(tokens.usdc, address(erc7540USDC), 0);
        Execution[] memory executions3 = new Execution[](2);
        executions3[0] = Execution({
            target: address(erc7540USDC),
            value: 0,
            callData: abi.encodeWithSignature(
                "requestDeposit(uint256,address,address)",
                balance,
                address(minterAdapterUSDC),
                address(minterAdapterUSDC)
            )
        });
        executions3[1] = Execution({
            target: address(erc7540USDC),
            value: 0,
            callData: abi.encodeWithSignature(
                "deposit(uint256,address,address)", balance, address(minterAdapterUSDC), address(minterAdapterUSDC)
            )
        });

        bytes memory executionCalldata3 = ExecutionLib.encodeBatch(executions3);
        ModeCode mode3 = ModeLib.encodeSimpleBatch();
        minterAdapterUSDC.execute(mode3, executionCalldata3);

        _kMinterShares = erc7540USDC.balanceOf(address(minterAdapterUSDC));
        _actualKMinterAssets = erc7540USDC.convertToAssets(_kMinterShares);

        vm.stopPrank();
    }

    function test_settler_kminter_empty_batch() public {
        bytes32 proposalId = _closeMinterBatch();
        assertEq(proposalId, bytes32(0));
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

        uint256 erc7540USDCBalanceBefore = tokens.usdc.balanceOf(address(erc7540USDC));
        bytes32 proposalId = _closeMinterBatch();
        assertNotEq(proposalId, bytes32(0));
        uint256 erc7540USDCBalanceAfter = tokens.usdc.balanceOf(address(erc7540USDC));

        assertEq(erc7540USDCBalanceAfter - erc7540USDCBalanceBefore, depositAmount - requestAmount);
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

        uint256 erc7540USDCBalanceBefore = tokens.usdc.balanceOf(address(erc7540USDC));
        bytes32 proposalId = _closeMinterBatch();
        assertNotEq(proposalId, bytes32(0));

        uint256 erc7540USDCBalanceAfter = tokens.usdc.balanceOf(address(erc7540USDC));

        assertEq(erc7540USDCBalanceBefore - erc7540USDCBalanceAfter, requestAmount - depositAmount);
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
        bytes32 requestId = vault.requestStake(users.alice, depositAmount);
        uint256 adapterBalanceBefore = erc7540USDC.balanceOf(address(DNVaultAdapterUSDC));
        bytes32 proposalId = _closeAndProposeDeltaNeutralBatch();
        uint256 adapterBalanceAfter = erc7540USDC.balanceOf(address(DNVaultAdapterUSDC));
        assertGt(adapterBalanceAfter, adapterBalanceBefore);
        assertEq(assetRouter.getSettlementProposal(proposalId).yield, 0);

        assetRouter.executeSettleBatch(proposalId);

        vm.prank(users.alice);
        vault.claimStakedShares(requestId);

        vm.prank(users.alice);
        kUSD.approve(address(vault), type(uint256).max);
        vm.prank(users.alice);
        vault.requestStake(users.alice, depositAmount);
        vm.prank(users.alice);
        requestId = vault.requestUnstake(users.alice, requestAmount);

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
        bytes32 requestId = vault.requestStake(users.alice, requestAmount);
        uint256 adapterBalanceBefore = erc7540USDC.balanceOf(address(DNVaultAdapterUSDC));
        bytes32 proposalId = _closeAndProposeDeltaNeutralBatch();
        uint256 adapterBalanceAfter = erc7540USDC.balanceOf(address(DNVaultAdapterUSDC));
        assertGt(adapterBalanceAfter, adapterBalanceBefore);
        assertEq(assetRouter.getSettlementProposal(proposalId).yield, 0);

        assetRouter.executeSettleBatch(proposalId);

        vm.prank(users.alice);
        vault.claimStakedShares(requestId);

        vm.prank(users.alice);
        kUSD.approve(address(vault), type(uint256).max);
        vm.prank(users.alice);
        vault.requestStake(users.alice, depositAmount);
        vm.prank(users.alice);
        requestId = vault.requestUnstake(users.alice, requestAmount);

        proposalId = _closeAndProposeDeltaNeutralBatch();

        assetRouter.executeSettleBatch(proposalId);

        vm.prank(users.alice);
        vault.claimUnstakedAssets(requestId);
    }

    function test_settler_delta_neutral_kminter_profit() public {
        _setFeesToZero();
        _disableProfitDistribution();
        uint256 metaVaultProfit = 200e6;
        uint256 depositAmount = 50e6;
        test_settler_kminter_netted_positive();
        vm.startPrank(users.alice);
        kUSD.approve(address(vault), type(uint256).max);
        bytes32 requestId = vault.requestStake(users.alice, depositAmount);
        uint256 adapterBalanceBefore = erc7540USDC.balanceOf(address(DNVaultAdapterUSDC));

        tokens.usdc.call(abi.encodeWithSignature("mint(address,uint256)", address(erc7540USDC), metaVaultProfit));

        bytes32 proposalId = _closeAndProposeDeltaNeutralBatch();
        uint256 adapterBalanceAfter = erc7540USDC.balanceOf(address(DNVaultAdapterUSDC));
        assertGt(adapterBalanceAfter, adapterBalanceBefore);

        assetRouter.executeSettleBatch(proposalId);

        uint256 aliceSharesBefore = vault.balanceOf(users.alice);

        vm.prank(users.alice);
        vault.claimStakedShares(requestId);

        uint256 gotShares = vault.balanceOf(users.alice) - aliceSharesBefore;

        assertEq(vault.convertToAssets(gotShares), depositAmount);

        vm.prank(users.alice);
        kUSD.approve(address(vault), type(uint256).max);
        vm.prank(users.alice);
        requestId = vault.requestStake(users.alice, depositAmount);

        tokens.usdc.call(abi.encodeWithSignature("mint(address,uint256)", address(erc7540USDC), metaVaultProfit));

        proposalId = _closeAndProposeDeltaNeutralBatch();
        assetRouter.executeSettleBatch(proposalId);

        aliceSharesBefore = vault.balanceOf(users.alice);

        vm.prank(users.alice);
        vault.claimStakedShares(requestId);

        gotShares = vault.balanceOf(users.alice) - aliceSharesBefore;

        assertApproxEqAbs(vault.convertToAssets(gotShares), depositAmount, 1);

        tokens.usdc.call(abi.encodeWithSignature("mint(address,uint256)", address(erc7540USDC), metaVaultProfit));

        uint256 sharePriceBefore = vault.sharePrice();
        proposalId = _closeAndProposeDeltaNeutralBatch();
        assetRouter.executeSettleBatch(proposalId);

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
        proposalId = settler.closeAndProposeDNVaultBatch(tokens.usdc);
        vm.stopPrank();
    }

    function _getDepeg() internal view returns (int256) {
        uint256 _kMinterShares = erc7540USDC.balanceOf(address(minterAdapterUSDC));
        uint256 _actualKMinterAssets = erc7540USDC.convertToAssets(_kMinterShares);
        uint256 _expectedKMinterAssets = IVaultAdapter(address(minterAdapterUSDC)).totalAssets();
        return int256(_expectedKMinterAssets) - int256(_actualKMinterAssets);
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

    function _setupProfitDistribution(uint16 insuranceBps, uint16 treasuryBps) internal {
        vm.stopPrank();
        vm.startPrank(users.admin);
        registry.setInsuranceBps(insuranceBps);
        registry.setTreasuryBps(treasuryBps);
        (address treasury, address insurance,,) = registry.getSettlementConfig();
        if (insurance != address(0)) {
            paramChecker.setAllowedReceiver(address(erc7540USDC), insurance, true);
        }
        if (treasury != address(0)) {
            paramChecker.setAllowedReceiver(address(erc7540USDC), treasury, true);
        }
        vm.stopPrank();
    }

    function test_settler_profit_distribution_to_insurance() public {
        _setFeesToZero();
        uint16 insuranceBps = 1000;
        _setupProfitDistribution(insuranceBps, 0);

        uint256 metaVaultProfit = 200e6;
        uint256 depositAmount = 100e6;

        test_settler_kminter_netted_positive();

        vm.startPrank(users.alice);
        kUSD.approve(address(vault), type(uint256).max);
        bytes32 requestId = vault.requestStake(users.alice, depositAmount);
        vm.stopPrank();

        bytes32 proposalId = _closeAndProposeDeltaNeutralBatch();
        assetRouter.executeSettleBatch(proposalId);

        vm.prank(users.alice);
        vault.claimStakedShares(requestId);

        vm.startPrank(users.alice);
        kUSD.approve(address(vault), type(uint256).max);
        vault.requestStake(users.alice, depositAmount);
        vm.stopPrank();

        (bool success,) =
            tokens.usdc.call(abi.encodeWithSignature("mint(address,uint256)", address(erc7540USDC), metaVaultProfit));
        require(success);

        (, address insurance,,) = registry.getSettlementConfig();
        uint256 insuranceBalanceBefore = erc7540USDC.balanceOf(insurance);

        uint256 kMinterShares = erc7540USDC.balanceOf(address(minterAdapterUSDC));
        uint256 actualKMinterAssets = erc7540USDC.convertToAssets(kMinterShares);
        uint256 expectedKMinterAssets = IVaultAdapter(address(minterAdapterUSDC)).totalAssets();
        int256 depeg = int256(expectedKMinterAssets) - int256(actualKMinterAssets);

        uint256 profitAssets = depeg < 0 ? uint256(-depeg) : 0;

        uint256 insuranceTarget = (expectedKMinterAssets * insuranceBps) / 10_000;
        uint256 insuranceCurrentAssets = erc7540USDC.convertToAssets(insuranceBalanceBefore);
        uint256 insuranceDeficitAssets =
            insuranceCurrentAssets >= insuranceTarget ? 0 : insuranceTarget - insuranceCurrentAssets;

        uint256 profitShares = erc7540USDC.convertToShares(profitAssets);
        while (erc7540USDC.convertToAssets(profitShares) < profitAssets) {
            profitShares += 1;
        }

        uint256 insuranceDeficitShares = erc7540USDC.convertToShares(insuranceDeficitAssets);
        uint256 expectedInsuranceShares = profitShares < insuranceDeficitShares ? profitShares : insuranceDeficitShares;

        proposalId = _closeAndProposeDeltaNeutralBatch();

        uint256 insuranceBalanceAfter = erc7540USDC.balanceOf(insurance);
        uint256 insuranceSharesReceived = insuranceBalanceAfter - insuranceBalanceBefore;

        assertEq(insuranceSharesReceived, expectedInsuranceShares);

        assetRouter.executeSettleBatch(proposalId);
    }

    function test_settler_profit_distribution_to_treasury() public {
        _setFeesToZero();
        uint16 treasuryBps = 2000;
        _setupProfitDistribution(0, treasuryBps);

        uint256 metaVaultProfit = 200e6;
        uint256 depositAmount = 100e6;

        test_settler_kminter_netted_positive();

        vm.startPrank(users.alice);
        kUSD.approve(address(vault), type(uint256).max);
        bytes32 requestId = vault.requestStake(users.alice, depositAmount);
        vm.stopPrank();

        bytes32 proposalId = _closeAndProposeDeltaNeutralBatch();
        assetRouter.executeSettleBatch(proposalId);

        vm.prank(users.alice);
        vault.claimStakedShares(requestId);

        vm.startPrank(users.alice);
        kUSD.approve(address(vault), type(uint256).max);
        vault.requestStake(users.alice, depositAmount);
        vm.stopPrank();

        (bool success,) =
            tokens.usdc.call(abi.encodeWithSignature("mint(address,uint256)", address(erc7540USDC), metaVaultProfit));
        require(success);

        (address treasury,,,) = registry.getSettlementConfig();
        uint256 treasuryBalanceBefore = erc7540USDC.balanceOf(treasury);

        uint256 kMinterShares = erc7540USDC.balanceOf(address(minterAdapterUSDC));
        uint256 actualKMinterAssets = erc7540USDC.convertToAssets(kMinterShares);
        uint256 expectedKMinterAssets = IVaultAdapter(address(minterAdapterUSDC)).totalAssets();
        int256 depeg = int256(expectedKMinterAssets) - int256(actualKMinterAssets);

        uint256 profitAssets = depeg < 0 ? uint256(-depeg) : 0;

        uint256 profitShares = erc7540USDC.convertToShares(profitAssets);
        while (erc7540USDC.convertToAssets(profitShares) < profitAssets) {
            profitShares += 1;
        }

        uint256 remainingShares = profitShares;
        uint256 expectedTreasuryShares = (remainingShares * treasuryBps) / 10_000;

        proposalId = _closeAndProposeDeltaNeutralBatch();

        uint256 treasuryBalanceAfter = erc7540USDC.balanceOf(treasury);
        uint256 treasurySharesReceived = treasuryBalanceAfter - treasuryBalanceBefore;

        assertEq(treasurySharesReceived, expectedTreasuryShares);

        assetRouter.executeSettleBatch(proposalId);
    }

    function test_settler_profit_distribution_insurance_and_treasury() public {
        _setFeesToZero();
        uint16 insuranceBps = 1;
        uint16 treasuryBps = 2000;
        _setupProfitDistribution(insuranceBps, treasuryBps);

        uint256 metaVaultProfit = 5000e6;
        uint256 depositAmount = 100e6;

        test_settler_kminter_netted_positive();

        vm.startPrank(users.alice);
        kUSD.approve(address(vault), type(uint256).max);
        bytes32 requestId = vault.requestStake(users.alice, depositAmount);
        vm.stopPrank();

        bytes32 proposalId = _closeAndProposeDeltaNeutralBatch();
        assetRouter.executeSettleBatch(proposalId);

        vm.prank(users.alice);
        vault.claimStakedShares(requestId);

        vm.startPrank(users.alice);
        kUSD.approve(address(vault), type(uint256).max);
        vault.requestStake(users.alice, depositAmount);
        vm.stopPrank();

        (bool success,) =
            tokens.usdc.call(abi.encodeWithSignature("mint(address,uint256)", address(erc7540USDC), metaVaultProfit));
        require(success);

        (address treasury, address insurance,,) = registry.getSettlementConfig();
        uint256 insuranceBalanceBefore = erc7540USDC.balanceOf(insurance);
        uint256 treasuryBalanceBefore = erc7540USDC.balanceOf(treasury);

        uint256 kMinterShares = erc7540USDC.balanceOf(address(minterAdapterUSDC));
        uint256 actualKMinterAssets = erc7540USDC.convertToAssets(kMinterShares);
        uint256 expectedKMinterAssets = IVaultAdapter(address(minterAdapterUSDC)).totalAssets();
        int256 depeg = int256(expectedKMinterAssets) - int256(actualKMinterAssets);

        uint256 profitAssets = depeg < 0 ? uint256(-depeg) : 0;

        uint256 insuranceTarget = (expectedKMinterAssets * insuranceBps) / 10_000;
        uint256 insuranceCurrentAssets = erc7540USDC.convertToAssets(insuranceBalanceBefore);
        uint256 insuranceDeficitAssets =
            insuranceCurrentAssets >= insuranceTarget ? 0 : insuranceTarget - insuranceCurrentAssets;

        uint256 profitShares = erc7540USDC.convertToShares(profitAssets);
        while (erc7540USDC.convertToAssets(profitShares) < profitAssets) {
            profitShares += 1;
        }

        uint256 insuranceDeficitShares = erc7540USDC.convertToShares(insuranceDeficitAssets);
        uint256 expectedInsuranceShares = profitShares < insuranceDeficitShares ? profitShares : insuranceDeficitShares;

        uint256 remainingSharesAfterInsurance = profitShares - expectedInsuranceShares;
        uint256 expectedTreasuryShares = (remainingSharesAfterInsurance * treasuryBps) / 10_000;

        proposalId = _closeAndProposeDeltaNeutralBatch();

        uint256 insuranceBalanceAfter = erc7540USDC.balanceOf(insurance);
        uint256 treasuryBalanceAfter = erc7540USDC.balanceOf(treasury);

        uint256 insuranceSharesReceived = insuranceBalanceAfter - insuranceBalanceBefore;
        uint256 treasurySharesReceived = treasuryBalanceAfter - treasuryBalanceBefore;

        assertEq(insuranceSharesReceived, expectedInsuranceShares);
        assertEq(treasurySharesReceived, expectedTreasuryShares);

        assetRouter.executeSettleBatch(proposalId);
    }

    function test_settler_dn_batch_with_profit_share_bps() public {
        _setFeesToZero();
        _disableProfitDistribution();

        uint256 metaVaultProfit = 200e6;
        uint256 depositAmount = 100e6;
        uint16 profitShareBps = 5000;

        test_settler_kminter_netted_positive();

        vm.startPrank(users.alice);
        kUSD.approve(address(vault), type(uint256).max);
        bytes32 requestId = vault.requestStake(users.alice, depositAmount);
        vm.stopPrank();

        bytes32 proposalId = _closeAndProposeDeltaNeutralBatch();
        assetRouter.executeSettleBatch(proposalId);

        vm.prank(users.alice);
        vault.claimStakedShares(requestId);

        vm.startPrank(users.alice);
        kUSD.approve(address(vault), type(uint256).max);
        vault.requestStake(users.alice, depositAmount);
        vm.stopPrank();

        (bool success,) =
            tokens.usdc.call(abi.encodeWithSignature("mint(address,uint256)", address(erc7540USDC), metaVaultProfit));
        require(success);

        uint256 dnAdapterBalanceBefore = erc7540USDC.balanceOf(address(DNVaultAdapterUSDC));

        uint256 kMinterShares = erc7540USDC.balanceOf(address(minterAdapterUSDC));
        uint256 actualKMinterAssets = erc7540USDC.convertToAssets(kMinterShares);
        uint256 expectedKMinterAssets = IVaultAdapter(address(minterAdapterUSDC)).totalAssets();
        int256 depeg = int256(expectedKMinterAssets) - int256(actualKMinterAssets);

        uint256 profitAssets = depeg < 0 ? uint256(-depeg) : 0;

        uint256 profitShares = erc7540USDC.convertToShares(profitAssets);
        while (erc7540USDC.convertToAssets(profitShares) < profitAssets) {
            profitShares += 1;
        }

        uint256 remainingShares = profitShares;
        uint256 expectedVaultAdapterProfitShares = (remainingShares * profitShareBps) / 10_000;

        vm.startPrank(users.relayer);
        proposalId = settler.closeAndProposeDNVaultBatch(tokens.usdc, profitShareBps);
        vm.stopPrank();

        uint256 dnAdapterBalanceAfter = erc7540USDC.balanceOf(address(DNVaultAdapterUSDC));
        uint256 vaultAdapterSharesReceived = dnAdapterBalanceAfter - dnAdapterBalanceBefore;

        uint256 nettingShares = erc7540USDC.convertToShares(depositAmount);

        assertGt(vaultAdapterSharesReceived, nettingShares);

        uint256 profitShareReceived = vaultAdapterSharesReceived - nettingShares;
        assertApproxEqAbs(profitShareReceived, expectedVaultAdapterProfitShares, 2);

        assetRouter.executeSettleBatch(proposalId);
    }
}
