import { console2 as console } from "forge-std/console2.sol";
import { IkRegistry } from "kam/src/interfaces/IkRegistry.sol";
import { MockERC7540 } from "kam/test/mocks/MockERC7540.sol";
import { BaseVaultTest, DeploymentBaseTest, IkStakingVault, SafeTransferLib } from "kam/test/utils/BaseVaultTest.sol";
import { Settler } from "src/Settler.sol";
import { ExecutionLib, Execution } from "minimal-smart-account/libraries/ExecutionLib.sol";
import { ModeLib, ModeCode } from "minimal-smart-account/libraries/ModeLib.sol";

contract SettlerTest is BaseVaultTest {
    using SafeTransferLib for address;

    Settler public settler;
    MockERC7540 metaVault;

    function setUp() public override {
        DeploymentBaseTest.setUp();

        metaVault = new MockERC7540(tokens.usdc, "max usdc", "maxUSDC", 6);
        settler = new Settler(
            users.owner, users.admin, users.relayer, address(minter), address(assetRouter), address(registry)
        );
        vm.prank(users.admin);
        registry.grantRelayerRole(address(settler));
        vault = IkStakingVault(address(dnVault));

        vm.stopPrank();
        BaseVaultTest.setUp();

        _setupTestFees();

        vm.startPrank(users.admin);
        registry.grantManagerRole(address(settler));

        IkRegistry(address(registry))
            .setAdapterAllowedSelector(
                address(minterAdapterUSDC),
                address(metaVault),
                2,
                bytes4(keccak256("requestDeposit(uint256,address,address)")),
                true
            );
        IkRegistry(address(registry))
            .setAdapterAllowedSelector(
                address(minterAdapterUSDC),
                address(metaVault),
                2,
                bytes4(keccak256("deposit(uint256,address,address)")),
                true
            );

        IkRegistry(address(registry))
            .setAdapterAllowedSelector(
                address(minterAdapterUSDC),
                address(metaVault),
                2,
                bytes4(keccak256("requestRedeem(uint256,address,address)")),
                true
            );

        IkRegistry(address(registry))
            .setAdapterAllowedSelector(
                address(minterAdapterUSDC),
                address(metaVault),
                2,
                bytes4(keccak256("redeem(uint256,address,address)")),
                true
            );

        IkRegistry(address(registry))
            .setAdapterAllowedSelector(
                address(minterAdapterUSDC), address(tokens.usdc), 2, bytes4(keccak256("approve(address,uint256)")), true
            );

        IkRegistry(address(registry))
            .setAdapterAllowedSelector(
                address(minterAdapterUSDC), address(metaVault), 2, bytes4(keccak256("approve(address,uint256)")), true
            );

        IkRegistry(address(registry))
            .setAdapterAllowedSelector(
                address(DNVaultAdapterUSDC),
                address(metaVault),
                2,
                bytes4(keccak256("transferFrom(address,address,uint256)")),
                true
            );

        vm.stopPrank();

        vm.startPrank(users.relayer);
        
        // First execution: approve USDC to metaVault
        Execution[] memory executions1 = new Execution[](1);
        executions1[0] = Execution({
            target: tokens.usdc,
            value: 0,
            callData: abi.encodeWithSignature("approve(address,uint256)", address(metaVault), type(uint256).max)
        });
        bytes memory executionCalldata1 = ExecutionLib.encodeBatch(executions1);
        ModeCode mode1 = ModeLib.encodeSimpleBatch();
        minterAdapterUSDC.execute(mode1, executionCalldata1);
        
        // Second execution: approve metaVault to DNVaultAdapter
        Execution[] memory executions2 = new Execution[](1);
        executions2[0] = Execution({
            target: address(metaVault),
            value: 0,
            callData: abi.encodeWithSignature("approve(address,uint256)", address(DNVaultAdapterUSDC), type(uint256).max)
        });
        bytes memory executionCalldata2 = ExecutionLib.encodeBatch(executions2);
        ModeCode mode2 = ModeLib.encodeSimpleBatch();
        minterAdapterUSDC.execute(mode2, executionCalldata2);

        // Third execution: requestDeposit and deposit
        uint256 balance = tokens.usdc.balanceOf(address(minterAdapterUSDC));
        Execution[] memory executions3 = new Execution[](2);
        executions3[0] = Execution({
            target: address(metaVault),
            value: 0,
            callData: abi.encodeWithSignature(
                "requestDeposit(uint256,address,address)", balance, address(minterAdapterUSDC), address(minterAdapterUSDC)
            )
        });
        executions3[1] = Execution({
            target: address(metaVault),
            value: 0,
            callData: abi.encodeWithSignature(
                "deposit(uint256,address,address)", balance, address(minterAdapterUSDC), address(minterAdapterUSDC)
            )
        });
        bytes memory executionCalldata3 = ExecutionLib.encodeBatch(executions3);
        ModeCode mode3 = ModeLib.encodeSimpleBatch();
        minterAdapterUSDC.execute(mode3, executionCalldata3);
    }

    function test_settler_kminter_empty_batch() public {
        bytes32 proposalId = _closeMinterBatch();
        assertEq(proposalId, bytes32(0));
    }

    function test_settler_kminter_netted_positive() public {
        uint256 depositAmount = 100e6;
        uint256 requestAmount = 50e6;
        uint256 netted = depositAmount - requestAmount;

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

        uint256 metaVaultBalanceBefore = tokens.usdc.balanceOf(address(metaVault));
        bytes32 proposalId = _closeMinterBatch();
        assertNotEq(proposalId, bytes32(0));
        uint256 metaVaultBalanceAfter = tokens.usdc.balanceOf(address(metaVault));

        assertEq(metaVaultBalanceAfter - metaVaultBalanceBefore, netted);
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
        uint256 nettedNegative = requestAmount - depositAmount;

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

        uint256 metaVaultBalanceBefore = tokens.usdc.balanceOf(address(metaVault));
        bytes32 currentBatchId = minter.getBatchId(tokens.usdc);
        bytes32 proposalId = _closeMinterBatch();
        assertEq(proposalId, bytes32(0));

        proposalId = _proposeMinterBatch(currentBatchId);

        uint256 metaVaultBalanceAfter = tokens.usdc.balanceOf(address(metaVault));

        assertEq(metaVaultBalanceBefore - metaVaultBalanceAfter, nettedNegative);
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
        uint256 adapterBalanceBefore = metaVault.balanceOf(address(DNVaultAdapterUSDC));
        bytes32 proposalId = _closeAndProposeDeltaNeutralBatch();
        uint256 adapterBalanceAfter = metaVault.balanceOf(address(DNVaultAdapterUSDC));
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
        vault.requestUnstake(users.alice, depositAmount);

        proposalId = _closeAndProposeDeltaNeutralBatch();
    }

    function _closeMinterBatch() internal returns (bytes32 proposalId) {
        vm.startPrank(users.relayer);
        proposalId = settler.closeMinterBatch(tokens.usdc);
        vm.stopPrank();
    }

    function _proposeMinterBatch(bytes32 batchId) internal returns (bytes32 proposalId) {
        vm.startPrank(users.relayer);
        proposalId = settler.proposeMinterSettleBatch(tokens.usdc, batchId);
        vm.stopPrank();
    }

    function _closeAndProposeDeltaNeutralBatch() internal returns (bytes32 proposalId) {
        vm.startPrank(users.relayer);
        proposalId = settler.closeAndProposeDNVaultBatch(tokens.usdc);
        vm.stopPrank();
    }
}
