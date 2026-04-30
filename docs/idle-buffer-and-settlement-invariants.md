# Idle Buffer Management & Settlement Invariants

## Problem Statement

During DN vault settlement, the kSettler orchestrates fund movements across the MetaWallet, adapters, and vaults. Two categories of risk need explicit on-chain guards:

1. **Idle buffer exhaustion**: The MetaWallet must retain enough idle (non-strategy) assets to cover pending withdrawals. If a settlement operation redeems from the MetaWallet without checking idle sufficiency, the `VAULTMODULE_INSUFFICIENT_IDLE` revert blocks settlement, or worse, a rebalance could leave the MetaWallet unable to serve pending unstakes.
2. **Accounting drift**: `adapter.totalAssets`, `vault.totalAssets`, and `kToken.balanceOf(vault)` must stay consistent. Any divergence indicates a bug or manipulation and should be caught at settlement time rather than compounding silently.

## Current State

### MetaWallet idle enforcement

The `VaultModule` (MetaWallet) enforces idle sufficiency at redemption time:

```solidity
// metawallet/src/modules/VaultModule.sol
function redeem(...) public override nonReentrant returns (uint256 assets) {
    _checkNotPaused();
    assets = convertToAssets(shares);
    require(assets <= totalIdle(), VAULTMODULE_INSUFFICIENT_IDLE);
    ...
}

function totalIdle() public view returns (uint256) {
    return asset().balanceOf(address(this));
}
```

This is a hard revert: if insufficient idle, the entire operation fails. The kSettler's `closeAndProposeMinterBatch` has an implicit dependency on this ("Money should always be idle if not revert and divest 1st"), but there is **no pre-check in kSettler** before attempting the redemption.

### DN vault settlement has no idle check

`_closeAndProposeDNVaultBatch` does NOT perform any MetaWallet withdrawal. It only transfers shares between adapters (rebalance + netting). The `settleTotalAssets` call updates virtual accounting. So the DN vault path does not directly interact with the idle buffer. However, the **kMinter settlement** (`closeAndProposeMinterBatch`) DOES redeem from the MetaWallet when netting is negative (more requests than deposits), and this redemption competes with the idle buffer.

### No cross-layer invariant checks

Nothing in the current settlement flow validates that:
- `vaultAdapter.totalAssets()` matches the vault's `totalAssets()` after settlement
- `kToken.balanceOf(vault)` is consistent with the vault's internal accounting
- The sum of all adapter claims on the MetaWallet does not exceed `virtualTotalAssets`

### KAM-side accounting dependency

The KAM vault will expose settled-but-unclaimed unstake reserves directly:

```solidity
function totalPendingStake() external view returns (uint128);
function totalPendingUnstake() external view returns (uint128);
function expectedKTokenBalance() external view returns (uint256);
```

The canonical vault reconciliation invariant is:

```solidity
kToken.balanceOf(address(vault)) == vault.expectedKTokenBalance()
vault.expectedKTokenBalance() == vault.totalAssets() + vault.totalPendingStake() + vault.totalPendingUnstake()
```

kSettler should use these getters. Do not infer unclaimed unstake exposure from
`kToken.balanceOf(vault) - vault.totalAssets()` because that makes kSettler depend on the vault's private accounting
layout and breaks if new reserve buckets are introduced.

---

## Plan

### 1. Pre-flight idle sufficiency check in kMinter settlement

**File**: `kam-settler/src/kSettler.sol` — `closeAndProposeMinterBatch`

**What**: Reorder `closeAndProposeMinterBatch` so idle sufficiency is checked before closing the kMinter batch and
before executing any MetaWallet withdrawal. The current code closes the batch before attempting the redemption; the
new flow should compute all preconditions first, then close and execute.

Implementation flow:

1. Read the current kMinter batch ID and batch info.
2. Validate it is not closed and not settled.
3. Resolve the kMinter adapter and MetaWallet target.
4. Read deposited/requested balances and compute `_nettedAmount`.
5. If `_nettedAmount < 0`, compute the total idle requirement using `_requiredIdleForMinterRedemption`.
6. Revert with a kSettler-specific error if the MetaWallet cannot satisfy the requirement.
7. Only after the pre-flight check passes, close the kMinter batch and execute the withdraw/deposit flow.

This produces a clear, revertible error instead of relying on the opaque `VAULTMODULE_INSUFFICIENT_IDLE` bubble-up.

```solidity
if (_nettedAmount < 0) {
    uint256 _abs = _nettedAmount.abs();

    _checkIdleBuffer(_asset, _target, _abs);

    // Close only after all pre-flight checks passed.
    kMinter.closeBatch(_batchInfo.batchId, true);

    Execution[] memory _executions =
        ExecutionDataLibrary.getWithdrawExecutionData(_target, address(_adapter), address(_adapter), _abs);
    _executeAdapterCall(_adapter, _executions);
} else {
    kMinter.closeBatch(_batchInfo.batchId, true);
    ...
}
```

**Error**: Add `KSETTLER_INSUFFICIENT_IDLE` to `errors/Errors.sol`.

**Why**: The MetaWallet's own revert is a safety net, but the kSettler should validate the preconditions it depends on. This also lets the relayer/operator know that a strategy divestment is needed before settlement can proceed, rather than failing mid-execution after the batch is already closed.

### 2. Idle buffer reservation formula

**File**: `kam-settler/src/kSettler.sol` — `closeAndProposeMinterBatch`

**What**: The idle buffer check must cover:

1. the immediate kMinter redemption amount,
2. DN vault settled-but-unclaimed unstake reserves, and
3. the governance-configured minimum idle buffer.

The DN vault path does not itself redeem from MetaWallet; it only transfers MetaWallet shares between adapters.
However, once DN users claim kTokens, those kTokens can later be redeemed through kMinter. The relayer should not
drain all idle liquidity with the current kMinter batch while known DN unstake reserves are outstanding.

Use this formula:

```solidity
requiredIdle = minterRedemptionAssets + dnVault.totalPendingUnstake() + minIdleAssets
```

Implementation:

```solidity
function _requiredIdleForMinterRedemption(
    address _asset,
    address _metawallet,
    uint256 _minterRedemptionAssets
)
    internal
    view
    returns (uint256)
{
    IkStakingVault _dnVault =
        IkStakingVault(registry.getVaultByAssetAndType(_asset, uint8(IRegistryBase.VaultType.DN)));

    uint256 _dnPendingUnstakes = _dnVault.totalPendingUnstake();
    uint256 _minIdleAssets = _minIdleAssets(_asset, _metawallet);

    return _minterRedemptionAssets + _dnPendingUnstakes + _minIdleAssets;
}
```

Then check:

```solidity
function _checkIdleBuffer(address _asset, address _metawallet, uint256 _minterRedemptionAssets) internal view {
    uint256 _requiredIdle = _requiredIdleForMinterRedemption(_asset, _metawallet, _minterRedemptionAssets);
    uint256 _idle = IVaultModule(_metawallet).totalIdle();
    require(_idle >= _requiredIdle, KSETTLER_INSUFFICIENT_IDLE);
}
```

### 3. Settlement invariant checks

**File**: `kam-settler/src/kSettler.sol` — `_closeAndProposeDNVaultBatch`

**What**: Before proposing a DN vault settlement to kAssetRouter, validate the vault-side kToken reconciliation
invariant and compare the newly computed MetaWallet adapter assets to the value that will be proposed.

Important ordering detail: before `kAssetRouter.executeSettleBatch`, `vaultAdapter.totalAssets()` still contains the
previous router-accounted value. The post-rebalance MetaWallet share value is `_assetData._newTotalAssets`, not
necessarily the current `vaultAdapter.totalAssets()`. Therefore the pre-proposal check should not require
`vaultAdapter.totalAssets() == vault.totalAssets()`.

**Implementation**:

```solidity
// In _closeAndProposeDNVaultBatch, after _calculateAssetData, before proposeSettleBatch:

address _kToken = registry.assetToKToken(_asset);
uint256 _vaultAssets = _vault.totalAssets();
uint256 _vaultKTokenBalance = IkToken(_kToken).balanceOf(address(_vault));

require(
    _vaultKTokenBalance == _vault.expectedKTokenBalance(),
    KSETTLER_SETTLEMENT_INVARIANT_KTOKEN_BACKING
);

require(
    _vaultKTokenBalance >= _vaultAssets + _vault.totalPendingUnstake(),
    KSETTLER_SETTLEMENT_INVARIANT_KTOKEN_BACKING
);
```

**Why**: The exact reconciliation check catches accounting drift before the settlement proposal is created. The second
check is redundant with `expectedKTokenBalance()` but documents the settlement safety property explicitly: active vault
assets and settled unstake reserves must both be backed by kTokens held by the vault.

### 4. Post-execution invariant verification

**File**: `kam-settler/src/kSettler.sol` — `executeSettleBatch`

**What**: After `kAssetRouter.executeSettleBatch` succeeds, verify that the invariant holds in the post-settlement state:

```solidity
function executeSettleBatch(bytes32 _proposalId) external payable {
    _lockReentrant();
    _checkRoles(RELAYER_ROLE);

    // Capture pre-state for the vault in the proposal
    IkAssetRouter.VaultSettlementProposal memory _proposal = kAssetRouter.getSettlementProposal(_proposalId);
    address _vault = _proposal.vault;
    address _asset = _proposal.asset;

    kAssetRouter.executeSettleBatch(_proposalId);

    // Post-execution invariant check (only for DN vaults)
    if (registry.getVaultType(_vault) == uint8(IRegistryBase.VaultType.DN)) {
        address _kToken = registry.assetToKToken(_asset);
        IMinimalSmartAccount _vaultAdapter = IMinimalSmartAccount(registry.getAdapter(_vault, _asset));

        uint256 _adapterAssets = IVaultAdapter(address(_vaultAdapter)).totalAssets();
        uint256 _vaultAssets = IkStakingVault(_vault).totalAssets();
        uint256 _vaultKTokenBalance = IkToken(_kToken).balanceOf(_vault);

        require(_adapterAssets == _vaultAssets, KSETTLER_POST_SETTLEMENT_INVARIANT_ADAPTER_VAULT);
        require(
            _vaultKTokenBalance == IkStakingVault(_vault).expectedKTokenBalance(),
            KSETTLER_POST_SETTLEMENT_INVARIANT_KTOKEN_BACKING
        );
    }

    _unlockReentrant();
}
```

**Why**: This catches any inconsistency introduced by the kAssetRouter's settlement execution itself (mint/burn, adapter update, vault balance change). If the router's `_executeSettlement` produces a state where `adapter.totalAssets != vault.totalAssets`, something went wrong inside the router.

### 5. Idle buffer configuration in registry

**File**: `kam/src/kRegistry/kRegistry.sol`

**What**: Add a configurable per-asset `minIdleBps` parameter to the KAM registry, representing the minimum percentage
of the MetaWallet's `virtualTotalAssets` that must remain as idle (non-strategy) assets. This gives governance control
over the idle buffer target and lets different assets use different liquidity buffers.

```solidity
// In kRegistry storage:
mapping(address asset => uint16 minIdleBps) minIdleBps; // e.g. 500 = 5% minimum idle

function getMinIdleBps(address asset) external view returns (uint16);
function setMinIdleBps(address asset, uint16 minIdleBps) external;
```

Helper:

```solidity
function _minIdleAssets(address _asset, address _metawallet) internal view returns (uint256) {
    uint256 _totalAssets = IVaultModule(_metawallet).totalAssets();
    uint16 _minIdleBps = registry.getMinIdleBps(_asset);
    return (_totalAssets * _minIdleBps) / 10_000;
}
```

The kSettler's DN settlement should validate the post-`settleTotalAssets` idle threshold:

```solidity
uint256 _idle = IVaultModule(_target).totalIdle();
require(_idle >= _minIdleAssets(_asset, _target), KSETTLER_IDLE_BELOW_MINIMUM);
```

This check runs after `settleTotalAssets` updates the virtual total assets, ensuring the post-settlement state still respects the idle buffer requirement.

### 6. Error constants

**File**: `kam-settler/src/errors/Errors.sol`

```solidity
string constant KSETTLER_INSUFFICIENT_IDLE = "KS9";
string constant KSETTLER_SETTLEMENT_INVARIANT_ADAPTER_VAULT = "KS10";
string constant KSETTLER_SETTLEMENT_INVARIANT_KTOKEN_BACKING = "KS11";
string constant KSETTLER_POST_SETTLEMENT_INVARIANT_ADAPTER_VAULT = "KS12";
string constant KSETTLER_POST_SETTLEMENT_INVARIANT_KTOKEN_BACKING = "KS13";
string constant KSETTLER_IDLE_BELOW_MINIMUM = "KS14";
```

### 7. Interface dependencies

**File**: `kam-settler/src/interfaces/IkSettler.sol`

Ensure the imported KAM interfaces expose the methods kSettler will call:

```solidity
interface IkStakingVault {
    function totalAssets() external view returns (uint256);
    function totalPendingUnstake() external view returns (uint128);
    function expectedKTokenBalance() external view returns (uint256);
}

interface IRegistry {
    function getMinIdleBps(address asset) external view returns (uint16);
}
```

If the dependency uses the real KAM interfaces, no local duplicate declarations should be added. The point is to keep
kSettler compiled against the same interface surface that will be deployed.

---

## Invariant Summary

The following invariants should hold at every settlement boundary:

| # | Invariant | When Checked | Failure Action |
|---|-----------|-------------|----------------|
| I1 | `metawallet.totalIdle() >= kMinterNetRedemptions + dnPendingUnstakes + minIdleAssets` | Before kMinter batch close/redemption | Revert, operator must divest strategies first |
| I2 | `kToken.balanceOf(vault) == vault.expectedKTokenBalance()` | Before proposing DN settlement | Revert, accounting drift detected |
| I3 | `kToken.balanceOf(vault) >= vault.totalAssets() + vault.totalPendingUnstake()` | Before proposing DN settlement | Revert, kToken backing insufficient |
| I4 | `vaultAdapter.totalAssets() == vault.totalAssets()` | After executing settlement | Revert, settlement corrupted state |
| I5 | `kToken.balanceOf(vault) == vault.expectedKTokenBalance()` | After executing settlement | Revert, kToken backing lost |
| I6 | `metawallet.totalIdle() >= (totalAssets * minIdleBps) / 10000` | After settleTotalAssets | Revert, idle buffer below governance threshold |

## Execution Order

1. Add error constants (item 6) — zero risk, prerequisite for all items.
2. Add pre-flight idle check in kMinter settlement (item 1) — small, targeted guard.
3. Add pre-settlement invariant checks (item 3) — catches accounting drift before it propagates.
4. Add post-settlement invariant checks (item 4) — catches corruption from the router execution.
5. Add idle buffer reservation for pending unstakes (item 2) — uses KAM's `totalPendingUnstake()` getter.
6. Add configurable per-asset `minIdleBps` in registry (item 5) — governance parameter, requires deployment config.
7. Update kSettler interfaces and dependency versions (item 7) — ensures kSettler compiles against deployed KAM.

## Test Plan

```
test_closeAndProposeMinterBatch_insufficientIdle_reverts
test_closeAndProposeMinterBatch_idleCoversRedemption_succeeds
test_closeAndProposeDNVaultBatch_adapterVaultMismatch_reverts
test_closeAndProposeDNVaultBatch_kTokenBackingInsufficient_reverts
test_closeAndProposeDNVaultBatch_invariantsHold_succeeds
test_executeSettleBatch_postInvariantAdapterVault_reverts
test_executeSettleBatch_postInvariantKTokenBacking_reverts
test_executeSettleBatch_invariantsHold_succeeds
test_idleBufferReservation_coversDNUnstakes
test_closeAndProposeMinterBatch_doesNotCloseBatchWhenIdleInsufficient
test_minIdleBps_belowThreshold_reverts
test_minIdleBps_atThreshold_succeeds
test_preDNSettlement_expectedKTokenBalanceMismatch_reverts
test_postSettlement_expectedKTokenBalanceMismatch_reverts
```
