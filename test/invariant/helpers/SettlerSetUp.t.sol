// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import { SettlerHandler } from "../handlers/SettlerHandler.t.sol";

import { StdInvariant } from "forge-std/StdInvariant.sol";
import { console2 } from "forge-std/console2.sol";

import { ERC20ParameterChecker } from "kam/src/adapters/parameters/ERC20ParameterChecker.sol";
import { IkStakingVault } from "kam/src/interfaces/IkStakingVault.sol";
import { IAdapterGuardian } from "kam/src/interfaces/modules/IAdapterGuardian.sol";
import { BaseVaultTest, DeploymentBaseTest } from "kam/test/utils/BaseVaultTest.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";

import { Execution, ExecutionLib } from "minimal-smart-account/libraries/ExecutionLib.sol";
import { ModeCode, ModeLib } from "minimal-smart-account/libraries/ModeLib.sol";
import { Settler } from "src/Settler.sol";

abstract contract SettlerSetUp is StdInvariant, DeploymentBaseTest {
    using SafeTransferLib for address;

    SettlerHandler public settlerHandler;
    Settler public settler;
    ERC20ParameterChecker public paramChecker;

    uint16 public constant PERFORMANCE_FEE = 2000; // 20%
    uint16 public constant MANAGEMENT_FEE = 100; // 1%

    function _setUp() internal {
        super.setUp();
    }

    function _setUpSettler() internal {
        // Get the paramChecker deployed during DeploymentBaseTest setup
        // We get it from the registry by looking at the approve selector for the minterAdapter
        bytes4 approveSelector = bytes4(keccak256("approve(address,uint256)"));
        paramChecker = ERC20ParameterChecker(
            IAdapterGuardian(address(registry))
                .getAdapterParametersChecker(address(minterAdapterUSDC), tokens.usdc, approveSelector)
        );

        // Deploy settler
        settler = new Settler(
            users.owner, users.admin, users.relayer, address(minter), address(assetRouter), address(registry)
        );

        // Grant relayer role to settler
        vm.startPrank(users.admin);
        registry.grantRelayerRole(address(settler));
        // Grant manager role to settler for adapter execute operations
        registry.grantManagerRole(address(settler));
        vm.stopPrank();

        // Grant roles to settler for adapter operations
        vm.prank(users.owner);
        minterAdapterUSDC.grantRoles(address(settler), 2);

        vm.prank(users.owner);
        DNVaultAdapterUSDC.grantRoles(address(settler), 2);

        // Set up param checker to allow DNVaultAdapter as spender for erc7540USDC
        vm.prank(users.admin);
        paramChecker.setAllowedSpender(address(erc7540USDC), address(DNVaultAdapterUSDC), true);

        // Set up approvals for minter adapter to interact with metavault
        _setupMinterAdapterApprovals();
    }

    function _setupMinterAdapterApprovals() internal {
        vm.startPrank(users.relayer);

        // Grant relayer role to adapters
        vm.stopPrank();
        vm.prank(users.owner);
        minterAdapterUSDC.grantRoles(address(users.relayer), 2);

        vm.prank(users.owner);
        DNVaultAdapterUSDC.grantRoles(address(users.relayer), 2);

        vm.startPrank(users.relayer);

        // Approve USDC to erc7540USDC
        Execution[] memory executions1 = new Execution[](1);
        executions1[0] = Execution({
            target: tokens.usdc,
            value: 0,
            callData: abi.encodeWithSignature("approve(address,uint256)", address(erc7540USDC), type(uint256).max)
        });
        bytes memory executionCalldata1 = ExecutionLib.encodeBatch(executions1);
        ModeCode mode1 = ModeLib.encodeSimpleBatch();
        minterAdapterUSDC.execute(mode1, executionCalldata1);

        // Approve erc7540USDC to DNVaultAdapter
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

        // Initial deposit to metavault
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

        vm.stopPrank();
    }

    function _setUpSettlerHandler() internal {
        address[] memory _minterActors = _getMinterActors();
        address[] memory _vaultActors = _getVaultActors();

        settlerHandler = new SettlerHandler(
            address(settler),
            address(minter),
            address(dnVault),
            address(assetRouter),
            address(minterAdapterUSDC),
            address(DNVaultAdapterUSDC),
            address(erc7540USDC),
            tokens.usdc,
            address(kUSD),
            users.relayer,
            _minterActors,
            _vaultActors
        );

        targetContract(address(settlerHandler));
        bytes4[] memory selectors = settlerHandler.getEntryPoints();
        targetSelector(FuzzSelector({ addr: address(settlerHandler), selectors: selectors }));
        vm.label(address(settlerHandler), "SettlerHandler");
    }

    function _setUpVaultFees(IkStakingVault vault) internal {
        vm.startPrank(users.admin);
        vault.setPerformanceFee(PERFORMANCE_FEE);
        vault.setManagementFee(MANAGEMENT_FEE);
        vm.stopPrank();
    }

    function _getMinterActors() internal view returns (address[] memory) {
        address[] memory _actors = new address[](4);
        _actors[0] = address(users.institution);
        _actors[1] = address(users.institution2);
        _actors[2] = address(users.institution3);
        _actors[3] = address(users.institution4);
        return _actors;
    }

    function _getVaultActors() internal view returns (address[] memory) {
        address[] memory _actors = new address[](3);
        _actors[0] = address(users.alice);
        _actors[1] = address(users.bob);
        _actors[2] = address(users.charlie);
        return _actors;
    }

    function _setUpInstitutionalMint() internal {
        address[] memory minters = _getMinterActors();
        uint256 amount = 10_000_000 * 10 ** 6;
        uint256 totalAmount = amount * minters.length;
        address token = tokens.usdc;

        for (uint256 i = 0; i < minters.length; i++) {
            vm.startPrank(minters[i]);
            console2.log("Minting", minters[i]);
            console2.log("Balance", token.balanceOf(minters[i]));
            token.safeApprove(address(minter), amount);
            minter.mint(token, minters[i], amount);
            vm.stopPrank();
        }

        vm.startPrank(users.relayer);

        // Use settler to close batch - this returns the proposalId if netted is positive
        bytes32 proposalId = settler.closeAndProposeMinterBatch(token);

        // Execute the settlement
        assetRouter.executeSettleBatch(proposalId);
        vm.stopPrank();

        // Update handler ghost vars
        settlerHandler.set_minterActualAdapterBalance(token.balanceOf(address(minterAdapterUSDC)));
        settlerHandler.set_minterExpectedAdapterBalance(token.balanceOf(address(minterAdapterUSDC)));
        settlerHandler.set_minterActualAdapterTotalAssets(totalAmount);
        settlerHandler.set_minterExpectedAdapterTotalAssets(totalAmount);
        settlerHandler.set_minterActualTotalLockedAssets(totalAmount);
        settlerHandler.set_minterExpectedTotalLockedAssets(totalAmount);
    }

    // Set unlimited batch limits for testing
    function _setUnlimitedBatchLimits() internal {
        vm.prank(users.admin);
        registry.setAssetBatchLimits(tokens.usdc, type(uint128).max, type(uint128).max);
    }

    // Set max total assets for DN vault
    function _setMaxTotalAssets() internal {
        vm.prank(users.admin);
        dnVault.setMaxTotalAssets(type(uint128).max);
    }
}
