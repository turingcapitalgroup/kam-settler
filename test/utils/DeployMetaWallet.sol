// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import { IERC20 } from "forge-std/interfaces/IERC20.sol";
import { ERC20ExecutionValidator } from "kam/src/adapters/parameters/ERC20ExecutionValidator.sol";
import { IExecutionGuardian } from "kam/src/interfaces/modules/IExecutionGuardian.sol";
import { MockERC4626 } from "kam/test/mocks/MockERC4626.sol";
import { DeploymentBaseTest } from "kam/test/utils/DeploymentBaseTest.sol";
import { MetaWallet } from "metawallet/src/MetaWallet.sol";
import { IERC4626 } from "metawallet/src/interfaces/IERC4626.sol";
import { IVaultModule } from "metawallet/src/interfaces/IVaultModule.sol";
import { VaultModule } from "metawallet/src/modules/VaultModule.sol";

/// @title DeployMetaWallet
/// @notice Shared helper that deploys a real MetaWallet proxy (with VaultModule) and swaps it
///         in place of the MockERC4626 deployed by DeploymentBaseTest.
abstract contract DeployMetaWallet is DeploymentBaseTest {
    /// @notice Deploy a real MetaWallet + VaultModule proxy, reconfigure registry targets and
    ///         parameter-checker, then reassign `metawalletUsdc`.
    /// @param _settler Address of the kSettler contract (needs MANAGER_ROLE for settleTotalAssets)
    function _deployAndSwapMetaWallet(address _settler) internal {
        address mockAddr = address(metawalletUSDC);

        // --- 1. Deploy implementations directly from source ---
        MetaWallet metaWalletImpl = new MetaWallet();
        VaultModule vaultModuleImpl = new VaultModule();

        address proxy = _createProxy(metaWalletImpl, vaultModuleImpl, _settler);

        // Retrieve ERC20ExecutionValidator BEFORE swapping selectors (it gets deleted during USDC reorder)
        ERC20ExecutionValidator pc = ERC20ExecutionValidator(
            IExecutionGuardian(address(registry))
                .getExecutionValidator(address(minterAdapterUSDC), tokens.usdc, IERC20.approve.selector)
        );

        // --- 2. Registry executor permissions ---
        _swapAllowedSelectors(proxy, mockAddr, address(pc));
        _setValidatorsAndParamChecker(proxy, pc);

        // --- 3. Reassign reference ---
        metawalletUSDC = MockERC4626(proxy);
        vm.label(proxy, "RealMetaWallet");
    }

    function _createProxy(
        MetaWallet metaWalletImpl,
        VaultModule vaultModuleImpl,
        address _settler
    )
        private
        returns (address proxy)
    {
        bytes memory initData = abi.encodeWithSignature(
            "initialize(address,address,string)", users.owner, address(registry), "kam.metawallet.1.0"
        );
        proxy = factory.deployDeterministicAndCall(address(metaWalletImpl), keccak256("metawallet-usdc-test"), initData);

        MetaWallet mw = MetaWallet(payable(proxy));

        vm.startPrank(users.owner);

        // Grant ADMIN_ROLE (1) to owner so we can addFunctions and initializeVault
        mw.grantRoles(users.owner, 1);

        // Get VaultModule selectors and add them to the proxy
        bytes4[] memory sels = vaultModuleImpl.selectors();
        mw.addFunctions(sels, address(vaultModuleImpl), false);

        // Initialize the vault module
        IVaultModule(proxy).initializeVault(tokens.usdc, "MetaWallet USDC", "mwUSDC");

        // WHITELISTED_ROLE (_ROLE_2 = 4) – adapters that call deposit/redeem
        mw.grantRoles(address(minterAdapterUSDC), 4);
        mw.grantRoles(address(DNVaultAdapterUSDC), 4);
        mw.grantRoles(address(ALPHAVaultAdapterUSDC), 4);
        mw.grantRoles(address(BETHAVaultAdapterUSDC), 4);

        // MANAGER_ROLE (16) – settler calls settleTotalAssets directly
        if (_settler != address(0)) {
            mw.grantRoles(_settler, 16);
        }
        vm.stopPrank();
    }

    function _swapAllowedSelectors(address real, address mock, address validator) private {
        IExecutionGuardian g = IExecutionGuardian(address(registry));

        bytes4 approveSel = IERC20.approve.selector;
        bytes4 transferSel = IERC20.transfer.selector;
        bytes4 transferFromSel = IERC20.transferFrom.selector;
        bytes4 depSel = IERC4626.deposit.selector;
        bytes4 withdrawSel = IERC4626.withdraw.selector;
        bytes4 mockRedeemSel = IERC4626.redeem.selector;

        vm.startPrank(users.admin);

        // ---- A. ADD real MetaWallet selectors ----
        IExecutionGuardian.TargetType metawalletTarget = IExecutionGuardian.TargetType.METAWALLET;
        IExecutionGuardian.TargetType assetTarget = IExecutionGuardian.TargetType.ASSET;

        // kMinterAdapter – ERC4626 operations
        g.setAllowedSelector(address(minterAdapterUSDC), real, metawalletTarget, approveSel, true);
        g.setAllowedSelector(address(minterAdapterUSDC), real, metawalletTarget, transferSel, true);
        g.setAllowedSelector(address(minterAdapterUSDC), real, metawalletTarget, transferFromSel, true);
        g.setAllowedSelector(address(minterAdapterUSDC), real, metawalletTarget, depSel, true);
        g.setAllowedSelector(address(minterAdapterUSDC), real, metawalletTarget, withdrawSel, true);

        // DNVaultAdapter
        g.setAllowedSelector(address(DNVaultAdapterUSDC), real, metawalletTarget, approveSel, true);
        g.setAllowedSelector(address(DNVaultAdapterUSDC), real, metawalletTarget, transferSel, true);
        g.setAllowedSelector(address(DNVaultAdapterUSDC), real, metawalletTarget, transferFromSel, true);

        // ALPHAVaultAdapter
        g.setAllowedSelector(address(ALPHAVaultAdapterUSDC), real, metawalletTarget, approveSel, true);
        g.setAllowedSelector(address(ALPHAVaultAdapterUSDC), real, metawalletTarget, transferSel, true);
        g.setAllowedSelector(address(ALPHAVaultAdapterUSDC), real, metawalletTarget, transferFromSel, true);

        // BETHAVaultAdapter
        g.setAllowedSelector(address(BETHAVaultAdapterUSDC), real, metawalletTarget, approveSel, true);
        g.setAllowedSelector(address(BETHAVaultAdapterUSDC), real, metawalletTarget, transferSel, true);
        g.setAllowedSelector(address(BETHAVaultAdapterUSDC), real, metawalletTarget, transferFromSel, true);

        // ---- B. REMOVE mock selectors ----

        // kMinterAdapter mock – remove ALL selectors (ERC20 + ERC4626)
        g.setAllowedSelector(address(minterAdapterUSDC), mock, metawalletTarget, approveSel, false);
        g.setAllowedSelector(address(minterAdapterUSDC), mock, metawalletTarget, transferSel, false);
        g.setAllowedSelector(address(minterAdapterUSDC), mock, metawalletTarget, transferFromSel, false);
        g.setAllowedSelector(address(minterAdapterUSDC), mock, metawalletTarget, depSel, false);
        g.setAllowedSelector(address(minterAdapterUSDC), mock, metawalletTarget, mockRedeemSel, false);
        // Legacy selectors added by the original deployment for kMinterAdapter
        g.setAllowedSelector(
            address(minterAdapterUSDC),
            mock,
            metawalletTarget,
            bytes4(keccak256("requestDeposit(uint256,address,address)")),
            false
        );
        g.setAllowedSelector(
            address(minterAdapterUSDC),
            mock,
            metawalletTarget,
            bytes4(keccak256("deposit(uint256,address,address)")),
            false
        );
        g.setAllowedSelector(
            address(minterAdapterUSDC),
            mock,
            metawalletTarget,
            bytes4(keccak256("requestRedeem(uint256,address,address)")),
            false
        );
        g.setAllowedSelector(
            address(minterAdapterUSDC),
            mock,
            metawalletTarget,
            bytes4(keccak256("withdraw(uint256,address,address)")),
            false
        );

        // DNVaultAdapter mock
        g.setAllowedSelector(address(DNVaultAdapterUSDC), mock, metawalletTarget, approveSel, false);
        g.setAllowedSelector(address(DNVaultAdapterUSDC), mock, metawalletTarget, transferSel, false);
        g.setAllowedSelector(address(DNVaultAdapterUSDC), mock, metawalletTarget, transferFromSel, false);

        // ALPHAVaultAdapter mock
        g.setAllowedSelector(address(ALPHAVaultAdapterUSDC), mock, metawalletTarget, approveSel, false);
        g.setAllowedSelector(address(ALPHAVaultAdapterUSDC), mock, metawalletTarget, transferSel, false);
        g.setAllowedSelector(address(ALPHAVaultAdapterUSDC), mock, metawalletTarget, transferFromSel, false);

        // BETHAVaultAdapter mock
        g.setAllowedSelector(address(BETHAVaultAdapterUSDC), mock, metawalletTarget, approveSel, false);
        g.setAllowedSelector(address(BETHAVaultAdapterUSDC), mock, metawalletTarget, transferSel, false);
        g.setAllowedSelector(address(BETHAVaultAdapterUSDC), mock, metawalletTarget, transferFromSel, false);

        // ---- C. Fix kMinterAdapter target ordering ----
        // Solady's OptimizedAddressEnumerableSetLib uses left-shift on removal,
        // so after removing mock from [mock, USDC, real] we get [USDC, real].
        // Remove and re-add USDC so the final order is [real, USDC].
        // _getTarget(adapter, METAWALLET) returns the first MetaWallet target.
        g.setAllowedSelector(address(minterAdapterUSDC), tokens.usdc, assetTarget, transferSel, false);
        g.setAllowedSelector(address(minterAdapterUSDC), tokens.usdc, assetTarget, approveSel, false);
        g.setAllowedSelector(address(minterAdapterUSDC), tokens.usdc, assetTarget, transferFromSel, false);
        g.setAllowedSelector(address(minterAdapterUSDC), tokens.usdc, assetTarget, transferSel, true);
        g.setAllowedSelector(address(minterAdapterUSDC), tokens.usdc, assetTarget, approveSel, true);
        g.setAllowedSelector(address(minterAdapterUSDC), tokens.usdc, assetTarget, transferFromSel, true);

        // Restore USDC execution validators (deleted during removal above)
        g.setExecutionValidator(address(minterAdapterUSDC), tokens.usdc, transferSel, validator);
        g.setExecutionValidator(address(minterAdapterUSDC), tokens.usdc, approveSel, validator);
        g.setExecutionValidator(address(minterAdapterUSDC), tokens.usdc, transferFromSel, validator);

        vm.stopPrank();
    }

    function _setValidatorsAndParamChecker(address real, ERC20ExecutionValidator pc) private {
        bytes4 approveSel = IERC20.approve.selector;
        bytes4 transferSel = IERC20.transfer.selector;
        bytes4 transferFromSel = IERC20.transferFrom.selector;

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
        (address _treasury, address _insurance,,) = registry.getSettlementConfig();
        pc.setAllowedReceiver(real, _treasury, true);
        pc.setAllowedReceiver(real, _insurance, true);

        // Sources (for transferFrom)
        pc.setAllowedSource(real, address(minterAdapterUSDC), true);
        pc.setAllowedSource(real, address(ALPHAVaultAdapterUSDC), true);
        pc.setAllowedSource(real, address(BETHAVaultAdapterUSDC), true);

        // Max single transfer
        pc.setMaxSingleTransfer(real, type(uint128).max);

        vm.stopPrank();
    }
}
