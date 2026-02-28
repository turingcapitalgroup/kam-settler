// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import { ERC20ExecutionValidator } from "kam/src/adapters/parameters/ERC20ExecutionValidator.sol";
import { IERC7540 } from "kam/src/interfaces/IERC7540.sol";
import { IExecutionGuardian } from "kam/src/interfaces/modules/IExecutionGuardian.sol";
import { MockERC7540 } from "kam/test/mocks/MockERC7540.sol";
import { DeploymentBaseTest } from "kam/test/utils/DeploymentBaseTest.sol";
import { IVaultModule } from "metawallet/src/interfaces/IVaultModule.sol";

/// @title DeployMetaWallet
/// @notice Shared helper that deploys a real MetaWallet proxy (with VaultModule) and swaps it
///         in place of the MockERC7540 deployed by DeploymentBaseTest.
/// @dev Reads pre-built artifacts from metawallet dependency to avoid remapping conflicts.
abstract contract DeployMetaWallet is DeploymentBaseTest {
    /// @dev Deploy a contract from a pre-built artifact JSON file
    function _deployFromArtifact(string memory artifactPath) internal returns (address deployed) {
        string memory json = vm.readFile(artifactPath);
        bytes memory bytecode = vm.parseJsonBytes(json, ".bytecode.object");
        assembly ("memory-safe") {
            deployed := create(0, add(bytecode, 0x20), mload(bytecode))
        }
        require(deployed != address(0), "DeployMetaWallet: deployment failed");
    }

    /// @notice Deploy a real MetaWallet + VaultModule proxy, reconfigure registry targets and
    ///         parameter-checker, then reassign `erc7540USDC`.
    /// @param _settler Address of the kSettler contract (needs MANAGER_ROLE for settleTotalAssets)
    function _deployAndSwapMetaWallet(address _settler) internal {
        address mockAddr = address(erc7540USDC);

        // --- 1. Deploy implementations from pre-built metawallet artifacts ---
        address metaWalletImpl = _deployFromArtifact("dependencies/metawallet-1.0/out/MetaWallet.sol/MetaWallet.json");
        address vaultModuleImpl =
            _deployFromArtifact("dependencies/metawallet-1.0/out/VaultModule.sol/VaultModule.json");

        address proxy = _createProxy(metaWalletImpl, vaultModuleImpl, _settler);

        // Retrieve ERC20ExecutionValidator BEFORE swapping selectors (it gets deleted during USDC reorder)
        ERC20ExecutionValidator pc = ERC20ExecutionValidator(
            IExecutionGuardian(address(registry))
                .getExecutionValidator(address(minterAdapterUSDC), tokens.usdc, IERC7540.approve.selector)
        );

        // --- 2. Registry executor permissions ---
        _swapAllowedSelectors(proxy, mockAddr, address(pc));
        _setValidatorsAndParamChecker(proxy, pc);

        // --- 3. Reassign reference ---
        erc7540USDC = MockERC7540(proxy);
        vm.label(proxy, "RealMetaWallet");
    }

    function _createProxy(
        address metaWalletImpl,
        address vaultModuleImpl,
        address _settler
    )
        private
        returns (address proxy)
    {
        bytes memory initData = abi.encodeWithSignature(
            "initialize(address,address,string)", users.owner, address(registry), "kam.metawallet.1.0"
        );
        proxy = factory.deployDeterministicAndCall(metaWalletImpl, keccak256("metawallet-usdc-test"), initData);

        vm.startPrank(users.owner);

        // Grant ADMIN_ROLE (1) to owner so we can addFunctions and initializeVault
        _call(proxy, abi.encodeWithSignature("grantRoles(address,uint256)", users.owner, 1));

        // Get VaultModule selectors and add them to the proxy
        (bool ok, bytes memory ret) = vaultModuleImpl.staticcall(abi.encodeWithSignature("selectors()"));
        require(ok, "selectors() failed");
        bytes4[] memory sels = abi.decode(ret, (bytes4[]));
        _call(proxy, abi.encodeWithSignature("addFunctions(bytes4[],address,bool)", sels, vaultModuleImpl, false));

        // Initialize the vault module
        IVaultModule(proxy).initializeVault(tokens.usdc, "MetaWallet USDC", "mwUSDC");

        // WHITELISTED_ROLE (2) – adapters that call requestDeposit
        _call(proxy, abi.encodeWithSignature("grantRoles(address,uint256)", address(minterAdapterUSDC), 2));
        _call(proxy, abi.encodeWithSignature("grantRoles(address,uint256)", address(DNVaultAdapterUSDC), 2));
        _call(proxy, abi.encodeWithSignature("grantRoles(address,uint256)", address(ALPHAVaultAdapterUSDC), 2));
        _call(proxy, abi.encodeWithSignature("grantRoles(address,uint256)", address(BETHAVaultAdapterUSDC), 2));

        // MANAGER_ROLE (16) – settler calls settleTotalAssets directly
        if (_settler != address(0)) {
            _call(proxy, abi.encodeWithSignature("grantRoles(address,uint256)", _settler, 16));
        }
        vm.stopPrank();
    }

    /// @dev Low-level call helper that reverts on failure
    function _call(address target, bytes memory data) private {
        (bool s,) = target.call(data);
        require(s, "DeployMetaWallet: call failed");
    }

    function _swapAllowedSelectors(address real, address mock, address validator) private {
        IExecutionGuardian g = IExecutionGuardian(address(registry));

        bytes4 approveSel = IERC7540.approve.selector;
        bytes4 transferSel = IERC7540.transfer.selector;
        bytes4 transferFromSel = IERC7540.transferFrom.selector;
        bytes4 reqDepSel = IERC7540.requestDeposit.selector;
        bytes4 depSel = bytes4(abi.encodeWithSignature("deposit(uint256,address,address)"));
        bytes4 reqRedSel = IERC7540.requestRedeem.selector;
        bytes4 redeemSel = IERC7540.redeem.selector;
        bytes4 withdrawSel = IERC7540.withdraw.selector;

        vm.startPrank(users.admin);

        // ---- A. ADD real MetaWallet selectors ----

        // kMinterAdapter – full ERC7540 operations
        g.setAllowedSelector(address(minterAdapterUSDC), real, 0, approveSel, true);
        g.setAllowedSelector(address(minterAdapterUSDC), real, 0, transferSel, true);
        g.setAllowedSelector(address(minterAdapterUSDC), real, 0, transferFromSel, true);
        g.setAllowedSelector(address(minterAdapterUSDC), real, 0, reqDepSel, true);
        g.setAllowedSelector(address(minterAdapterUSDC), real, 0, depSel, true);
        g.setAllowedSelector(address(minterAdapterUSDC), real, 0, reqRedSel, true);
        g.setAllowedSelector(address(minterAdapterUSDC), real, 0, redeemSel, true);
        g.setAllowedSelector(address(minterAdapterUSDC), real, 0, withdrawSel, true);

        // DNVaultAdapter
        g.setAllowedSelector(address(DNVaultAdapterUSDC), real, 0, approveSel, true);
        g.setAllowedSelector(address(DNVaultAdapterUSDC), real, 0, transferSel, true);
        g.setAllowedSelector(address(DNVaultAdapterUSDC), real, 0, transferFromSel, true);

        // ALPHAVaultAdapter
        g.setAllowedSelector(address(ALPHAVaultAdapterUSDC), real, 0, approveSel, true);
        g.setAllowedSelector(address(ALPHAVaultAdapterUSDC), real, 0, transferSel, true);
        g.setAllowedSelector(address(ALPHAVaultAdapterUSDC), real, 0, transferFromSel, true);

        // BETHAVaultAdapter
        g.setAllowedSelector(address(BETHAVaultAdapterUSDC), real, 0, approveSel, true);
        g.setAllowedSelector(address(BETHAVaultAdapterUSDC), real, 0, transferSel, true);
        g.setAllowedSelector(address(BETHAVaultAdapterUSDC), real, 0, transferFromSel, true);

        // ---- B. REMOVE mock selectors ----

        // kMinterAdapter mock
        g.setAllowedSelector(address(minterAdapterUSDC), mock, 0, approveSel, false);
        g.setAllowedSelector(address(minterAdapterUSDC), mock, 0, transferSel, false);
        g.setAllowedSelector(address(minterAdapterUSDC), mock, 0, transferFromSel, false);
        g.setAllowedSelector(address(minterAdapterUSDC), mock, 0, reqDepSel, false);
        g.setAllowedSelector(address(minterAdapterUSDC), mock, 0, depSel, false);
        g.setAllowedSelector(address(minterAdapterUSDC), mock, 0, reqRedSel, false);
        g.setAllowedSelector(address(minterAdapterUSDC), mock, 0, redeemSel, false);
        g.setAllowedSelector(address(minterAdapterUSDC), mock, 0, withdrawSel, false);

        // DNVaultAdapter mock
        g.setAllowedSelector(address(DNVaultAdapterUSDC), mock, 0, approveSel, false);
        g.setAllowedSelector(address(DNVaultAdapterUSDC), mock, 0, transferSel, false);
        g.setAllowedSelector(address(DNVaultAdapterUSDC), mock, 0, transferFromSel, false);

        // ALPHAVaultAdapter mock
        g.setAllowedSelector(address(ALPHAVaultAdapterUSDC), mock, 0, approveSel, false);
        g.setAllowedSelector(address(ALPHAVaultAdapterUSDC), mock, 0, transferSel, false);
        g.setAllowedSelector(address(ALPHAVaultAdapterUSDC), mock, 0, transferFromSel, false);

        // BETHAVaultAdapter mock
        g.setAllowedSelector(address(BETHAVaultAdapterUSDC), mock, 0, approveSel, false);
        g.setAllowedSelector(address(BETHAVaultAdapterUSDC), mock, 0, transferSel, false);
        g.setAllowedSelector(address(BETHAVaultAdapterUSDC), mock, 0, transferFromSel, false);

        // ---- C. Fix kMinterAdapter target ordering ----
        // Solady's OptimizedAddressEnumerableSetLib uses left-shift on removal,
        // so after removing mock from [mock, USDC, real] we get [USDC, real].
        // Remove and re-add USDC so the final order is [real, USDC].
        // _getTarget(adapter, 0) returns the first type-0 target, which must be the MetaWallet.
        g.setAllowedSelector(address(minterAdapterUSDC), tokens.usdc, 0, transferSel, false);
        g.setAllowedSelector(address(minterAdapterUSDC), tokens.usdc, 0, approveSel, false);
        g.setAllowedSelector(address(minterAdapterUSDC), tokens.usdc, 0, transferFromSel, false);
        g.setAllowedSelector(address(minterAdapterUSDC), tokens.usdc, 0, transferSel, true);
        g.setAllowedSelector(address(minterAdapterUSDC), tokens.usdc, 0, approveSel, true);
        g.setAllowedSelector(address(minterAdapterUSDC), tokens.usdc, 0, transferFromSel, true);

        // Restore USDC execution validators (deleted during removal above)
        g.setExecutionValidator(address(minterAdapterUSDC), tokens.usdc, transferSel, validator);
        g.setExecutionValidator(address(minterAdapterUSDC), tokens.usdc, approveSel, validator);
        g.setExecutionValidator(address(minterAdapterUSDC), tokens.usdc, transferFromSel, validator);

        vm.stopPrank();
    }

    function _setValidatorsAndParamChecker(address real, ERC20ExecutionValidator pc) private {
        bytes4 approveSel = IERC7540.approve.selector;
        bytes4 transferSel = IERC7540.transfer.selector;
        bytes4 transferFromSel = IERC7540.transferFrom.selector;

        IExecutionGuardian g = IExecutionGuardian(address(registry));

        vm.startPrank(users.admin);

        // ---- Execution validators for real MetaWallet ----
        address v = address(pc);
        g.setExecutionValidator(address(minterAdapterUSDC), real, transferSel, v);
        g.setExecutionValidator(address(minterAdapterUSDC), real, approveSel, v);
        g.setExecutionValidator(address(minterAdapterUSDC), real, transferFromSel, v);
        g.setExecutionValidator(address(DNVaultAdapterUSDC), real, transferSel, v);
        g.setExecutionValidator(address(DNVaultAdapterUSDC), real, approveSel, v);
        g.setExecutionValidator(address(ALPHAVaultAdapterUSDC), real, transferSel, v);
        g.setExecutionValidator(address(ALPHAVaultAdapterUSDC), real, approveSel, v);
        g.setExecutionValidator(address(ALPHAVaultAdapterUSDC), real, transferFromSel, v);
        g.setExecutionValidator(address(BETHAVaultAdapterUSDC), real, transferSel, v);
        g.setExecutionValidator(address(BETHAVaultAdapterUSDC), real, approveSel, v);
        g.setExecutionValidator(address(BETHAVaultAdapterUSDC), real, transferFromSel, v);

        // ---- Parameter checker ----

        // Real MetaWallet is a USDC spender (adapters call USDC.approve(metaWallet, ...) before deposits)
        pc.setAllowedSpender(tokens.usdc, real, true);

        // Spenders (adapters that approve on MetaWallet shares)
        pc.setAllowedSpender(real, address(minterAdapterUSDC), true);
        pc.setAllowedSpender(real, address(DNVaultAdapterUSDC), true);
        pc.setAllowedSpender(real, address(ALPHAVaultAdapterUSDC), true);
        pc.setAllowedSpender(real, address(BETHAVaultAdapterUSDC), true);

        // Receivers (who can receive MetaWallet shares via transfer)
        pc.setAllowedReceiver(real, address(minterAdapterUSDC), true);
        pc.setAllowedReceiver(real, address(DNVaultAdapterUSDC), true);
        pc.setAllowedReceiver(real, address(ALPHAVaultAdapterUSDC), true);
        pc.setAllowedReceiver(real, address(BETHAVaultAdapterUSDC), true);
        pc.setAllowedReceiver(real, address(wallet), true);

        // Sources (for transferFrom)
        pc.setAllowedSource(real, address(minterAdapterUSDC), true);
        pc.setAllowedSource(real, address(ALPHAVaultAdapterUSDC), true);
        pc.setAllowedSource(real, address(BETHAVaultAdapterUSDC), true);

        // Max single transfer
        pc.setMaxSingleTransfer(real, type(uint128).max);

        vm.stopPrank();
    }
}
