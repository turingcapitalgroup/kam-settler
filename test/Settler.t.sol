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
import { Settler } from "src/Settler.sol";

contract SettlerTest is BaseVaultTest {
    using SafeTransferLib for address;

    Settler public settler;
    ERC20ExecutionValidator public paramChecker;

    function setUp() public override {
        DeploymentBaseTest.setUp();

        // Get the paramChecker deployed during DeploymentBaseTest setup
        bytes4 approveSelector = bytes4(keccak256("approve(address,uint256)"));
        paramChecker = ERC20ExecutionValidator(
            IExecutionGuardian(address(registry))
                .getExecutionValidator(address(minterAdapterUSDC), tokens.usdc, approveSelector)
        );

        // Deploy Settler using the deployment script
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

        // Second execution: approve erc7540USDC to DNVaultAdapter
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

        // Third execution: requestDeposit and deposit
        uint256 balance = tokens.usdc.balanceOf(address(minterAdapterUSDC));

        // zeroize vault balance
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
        // With sync settlement, closeAndProposeMinterBatch handles everything in one call
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
        uint256 netted = depositAmount - requestAmount;
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
        _disableProfitDistribution(); // Disable profit distribution to insurance/treasury for this test
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
        // No profit from kminter should be transferred to DN strategy
        assertEq(assetRouter.getSettlementProposal(proposalId).yield, 0);

        assetRouter.executeSettleBatch(proposalId);

        uint256 aliceSharesBefore = vault.balanceOf(users.alice);

        vm.prank(users.alice);
        vault.claimStakedShares(requestId);

        uint256 gotShares = vault.balanceOf(users.alice) - aliceSharesBefore;

        // Alice shouldnt have any profit(she has on first settlement?)
        assertEq(vault.convertToAssets(gotShares), depositAmount);

        vm.prank(users.alice);
        kUSD.approve(address(vault), type(uint256).max);
        vm.prank(users.alice);
        requestId = vault.requestStake(users.alice, depositAmount);

        proposalId = _closeAndProposeDeltaNeutralBatch();
        assertApproxEqAbs(
            uint256(assetRouter.getSettlementProposal(proposalId).yield), metaVaultProfit, 2, "yield not accurate"
        );
        assetRouter.executeSettleBatch(proposalId);

        aliceSharesBefore = vault.balanceOf(users.alice);

        vm.prank(users.alice);
        vault.claimStakedShares(requestId);

        gotShares = vault.balanceOf(users.alice) - aliceSharesBefore;

        // Alice shouldnt profit again (allow 1 wei rounding difference)
        assertApproxEqAbs(vault.convertToAssets(gotShares), depositAmount, 1, "not accurate");

        tokens.usdc.call(abi.encodeWithSignature("mint(address,uint256)", address(erc7540USDC), metaVaultProfit));

        uint256 sharePriceBefore = vault.sharePrice();
        proposalId = _closeAndProposeDeltaNeutralBatch();
        assertApproxEqAbs(
            uint256(assetRouter.getSettlementProposal(proposalId).yield), metaVaultProfit, 2, "yield not accurate 2"
        );
        assetRouter.executeSettleBatch(proposalId);

        uint256 sharePriceAfter = vault.sharePrice();
        // Alice should see profit in the next batch
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
        // Get current shares and assets in kMinter adapter
        uint256 _kMinterShares = erc7540USDC.balanceOf(address(minterAdapterUSDC));
        uint256 _actualKMinterAssets = erc7540USDC.convertToAssets(_kMinterShares);

        // Get expected assets based on kToken total supply
        uint256 _expectedKMinterAssets = IVaultAdapter(address(minterAdapterUSDC)).totalAssets();

        // Calculate difference between expected and actual
        return int256(_expectedKMinterAssets) - int256(_actualKMinterAssets);
    }

    function _setFeesToZero() internal {
        vm.startPrank(users.admin);
        vault.setManagementFee(0);
        vault.setPerformanceFee(0);
        vault.setHardHurdleRate(false); // Soft hurdle by default
        vm.stopPrank();

        vm.prank(users.admin);
        registry.setHurdleRate(tokens.usdc, 0);
    }

    function _disableProfitDistribution() internal {
        vm.stopPrank(); // Stop any existing prank
        vm.startPrank(users.admin);
        // Set insurance and treasury BPS to 0 to disable profit distribution
        registry.setInsuranceBps(0);
        registry.setTreasuryBps(0);
        vm.stopPrank();
    }

    function _setupProfitDistribution(uint16 insuranceBps, uint16 treasuryBps) internal {
        vm.stopPrank(); // Stop any existing prank
        vm.startPrank(users.admin);
        registry.setInsuranceBps(insuranceBps);
        registry.setTreasuryBps(treasuryBps);
        // Allow transfers to insurance and treasury for profit distribution
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
        // Set insurance to 10% target of kMinter total assets, treasury to 0
        _setupProfitDistribution(1000, 0); // 10% insurance, 0% treasury

        uint256 metaVaultProfit = 200e6;
        uint256 depositAmount = 100e6;

        // First do a full cycle to get shares minted
        test_settler_kminter_netted_positive();

        vm.startPrank(users.alice);
        kUSD.approve(address(vault), type(uint256).max);
        bytes32 requestId = vault.requestStake(users.alice, depositAmount);
        vm.stopPrank();

        // Settle the first DN batch to mint shares to Alice
        bytes32 proposalId = _closeAndProposeDeltaNeutralBatch();
        assetRouter.executeSettleBatch(proposalId);

        // Claim shares
        vm.prank(users.alice);
        vault.claimStakedShares(requestId);

        // Now do another stake request
        vm.startPrank(users.alice);
        kUSD.approve(address(vault), type(uint256).max);
        vault.requestStake(users.alice, depositAmount);
        vm.stopPrank();

        // Add profit to metavault AFTER shares exist
        (bool success,) =
            tokens.usdc.call(abi.encodeWithSignature("mint(address,uint256)", address(erc7540USDC), metaVaultProfit));
        require(success, "mint failed");

        // Get insurance address and balance before
        (, address insurance,,) = registry.getSettlementConfig();
        uint256 insuranceBalanceBefore = erc7540USDC.balanceOf(insurance);

        // Close and propose DN batch - this should distribute profit
        proposalId = _closeAndProposeDeltaNeutralBatch();

        // Check insurance received shares
        uint256 insuranceBalanceAfter = erc7540USDC.balanceOf(insurance);
        assertGt(insuranceBalanceAfter, insuranceBalanceBefore, "Insurance should receive shares");

        assetRouter.executeSettleBatch(proposalId);
    }

    function test_settler_profit_distribution_to_treasury() public {
        _setFeesToZero();
        // Set insurance to 0, treasury to 20%
        _setupProfitDistribution(0, 2000); // 0% insurance, 20% treasury

        uint256 metaVaultProfit = 200e6;
        uint256 depositAmount = 100e6;

        // First do a full cycle to get shares minted
        test_settler_kminter_netted_positive();

        vm.startPrank(users.alice);
        kUSD.approve(address(vault), type(uint256).max);
        bytes32 requestId = vault.requestStake(users.alice, depositAmount);
        vm.stopPrank();

        // Settle the first DN batch to mint shares to Alice
        bytes32 proposalId = _closeAndProposeDeltaNeutralBatch();
        assetRouter.executeSettleBatch(proposalId);

        // Claim shares
        vm.prank(users.alice);
        vault.claimStakedShares(requestId);

        // Now do another stake request
        vm.startPrank(users.alice);
        kUSD.approve(address(vault), type(uint256).max);
        vault.requestStake(users.alice, depositAmount);
        vm.stopPrank();

        // Add profit to metavault AFTER shares exist
        (bool success,) =
            tokens.usdc.call(abi.encodeWithSignature("mint(address,uint256)", address(erc7540USDC), metaVaultProfit));
        require(success, "mint failed");

        // Get treasury address and balance before
        (address treasury,,,) = registry.getSettlementConfig();
        uint256 treasuryBalanceBefore = erc7540USDC.balanceOf(treasury);

        // Close and propose DN batch - this should distribute profit
        proposalId = _closeAndProposeDeltaNeutralBatch();

        // Check treasury received shares (20% of profit)
        uint256 treasuryBalanceAfter = erc7540USDC.balanceOf(treasury);
        assertGt(treasuryBalanceAfter, treasuryBalanceBefore, "Treasury should receive shares");

        assetRouter.executeSettleBatch(proposalId);
    }

    function test_settler_profit_distribution_insurance_and_treasury() public {
        _setFeesToZero();
        // Set very small insurance (0.01%) so target is small enough to exceed with profit
        // and treasury at 20% so it gets some of the remaining profit
        // kMinterAdapter has ~14M USDC, so 0.01% = 1400 USDC. We add 5000 USDC profit to exceed target.
        _setupProfitDistribution(1, 2000); // 0.01% insurance target, 20% treasury

        uint256 metaVaultProfit = 5000e6; // 5000 USDC - enough to fill insurance target and have remainder for treasury
        uint256 depositAmount = 100e6;

        // First do a full cycle to get shares minted
        test_settler_kminter_netted_positive();

        vm.startPrank(users.alice);
        kUSD.approve(address(vault), type(uint256).max);
        bytes32 requestId = vault.requestStake(users.alice, depositAmount);
        vm.stopPrank();

        // Settle the first DN batch to mint shares to Alice
        bytes32 proposalId = _closeAndProposeDeltaNeutralBatch();
        assetRouter.executeSettleBatch(proposalId);

        // Claim shares
        vm.prank(users.alice);
        vault.claimStakedShares(requestId);

        // Now do another stake request
        vm.startPrank(users.alice);
        kUSD.approve(address(vault), type(uint256).max);
        vault.requestStake(users.alice, depositAmount);
        vm.stopPrank();

        // Add profit to metavault AFTER shares exist
        (bool success,) =
            tokens.usdc.call(abi.encodeWithSignature("mint(address,uint256)", address(erc7540USDC), metaVaultProfit));
        require(success, "mint failed");

        // Get addresses and balances before
        (address treasury, address insurance,,) = registry.getSettlementConfig();
        uint256 insuranceBalanceBefore = erc7540USDC.balanceOf(insurance);
        uint256 treasuryBalanceBefore = erc7540USDC.balanceOf(treasury);

        // Close and propose DN batch - this should distribute profit
        proposalId = _closeAndProposeDeltaNeutralBatch();

        // Both should receive shares
        uint256 insuranceBalanceAfter = erc7540USDC.balanceOf(insurance);
        uint256 treasuryBalanceAfter = erc7540USDC.balanceOf(treasury);

        assertGt(insuranceBalanceAfter, insuranceBalanceBefore, "Insurance should receive shares");
        assertGt(treasuryBalanceAfter, treasuryBalanceBefore, "Treasury should receive shares");

        assetRouter.executeSettleBatch(proposalId);
    }

    function test_settler_dn_batch_with_profit_share_bps() public {
        _setFeesToZero();
        _disableProfitDistribution();

        uint256 metaVaultProfit = 200e6;
        uint256 depositAmount = 100e6;
        uint16 profitShareBps = 5000; // 50% profit share to DN vault adapter

        // First do a full cycle to get shares minted
        test_settler_kminter_netted_positive();

        vm.startPrank(users.alice);
        kUSD.approve(address(vault), type(uint256).max);
        bytes32 requestId = vault.requestStake(users.alice, depositAmount);
        vm.stopPrank();

        // Settle the first DN batch to mint shares to Alice
        bytes32 proposalId = _closeAndProposeDeltaNeutralBatch();
        assetRouter.executeSettleBatch(proposalId);

        // Claim shares
        vm.prank(users.alice);
        vault.claimStakedShares(requestId);

        // Now do another stake request
        vm.startPrank(users.alice);
        kUSD.approve(address(vault), type(uint256).max);
        vault.requestStake(users.alice, depositAmount);
        vm.stopPrank();

        // Add profit to metavault AFTER shares exist
        (bool success,) =
            tokens.usdc.call(abi.encodeWithSignature("mint(address,uint256)", address(erc7540USDC), metaVaultProfit));
        require(success, "mint failed");

        uint256 dnAdapterBalanceBefore = erc7540USDC.balanceOf(address(DNVaultAdapterUSDC));

        // Close with profit share parameter
        vm.startPrank(users.relayer);
        proposalId = settler.closeAndProposeDNVaultBatch(tokens.usdc, profitShareBps);
        vm.stopPrank();

        uint256 dnAdapterBalanceAfter = erc7540USDC.balanceOf(address(DNVaultAdapterUSDC));
        assertGt(dnAdapterBalanceAfter, dnAdapterBalanceBefore, "DN adapter should receive shares");

        assetRouter.executeSettleBatch(proposalId);
    }
}