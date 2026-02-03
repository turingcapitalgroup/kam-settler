# KAM Settler - System Overview

## Introduction

The Settler contract moves backend settlement math on-chain, making vault batch settlement deterministic, auditable, and trustless. Previously, settlement calculations (netting, fee computation, profit distribution) lived in off-chain services. The Settler replaces that with verifiable Solidity logic.

Within the KAM ecosystem, the Settler sits between the vaults (kMinter, DN vaults, Alpha/Beta vaults) and the `kAssetRouter`. It orchestrates batch closing, calculates net deposit/redemption flows, distributes profit according to a fixed priority, computes management and performance fees, and proposes settlements for execution through the router.

The contract is non-upgradeable. All transactions sent to the Settler are triggered on-chain by a ForDefi MPC wallet acting as the relayer, which drives the settlement lifecycle by calling the Settler's public functions in sequence.

---

## File-by-File Breakdown

### `src/Settler.sol`
Core orchestration contract. Inherits `OptimizedOwnableRoles` (Solady) for gas-efficient role management. Contains all settlement logic:
- **kMinter batch**: `closeAndProposeMinterBatch` closes the kMinter batch, calculates netting (deposited - requested), rebalances with the MetaWallet (deposit or requestRedeem+redeem), and proposes settlement.
- **DN vault batch**: `_closeAndProposeDNVaultBatch` closes the DN vault batch, computes depeg (profit/loss), distributes profit (insurance -> treasury -> vault adapter), calculates fees, executes netting transfers between adapters, and proposes settlement.
- **Execution helpers**: `executeSettleBatch`, `acceptProposal`, `cancelProposal` for proposal lifecycle.
- **Alpha/Beta**: `finaliseCustodialSettlement` handles post-settlement fund movement to/from CEFFU custody.
- **Insurance**: `liquidateInsurance` redeems insurance's MetaWallet shares to underlying assets.
- **Fees**: `_fees` / `_calculateFees` compute management and performance fees, `_executeFeeTransfer` sends fee shares to treasury.
- **Profit distribution**: `_distributeProfitShares` implements the insurance -> treasury -> vault adapter priority.

### `src/interfaces/ISettler.sol`
Public interface defining all external functions, events, errors, and structs:
- **Errors**: `BatchAlreadyClosed`, `BatchAlreadySettled`, `AddressZero`, `InsufficientBalance`, `InvalidProfitShareBps`, `NettedAssetsPositive`
- **Events**: `ProfitDistributed(insuranceShares, treasuryShares, vaultAdapterShares)`, `InsuranceLiquidated(asset, shares, assets)`
- **Structs**: `BatchInfo` (batch state), `VaultAddresses` (address bundle), `AssetData` (settlement calculations)

### `src/libraries/VaultMathLibrary.sol`
Pure math library for fee calculations using Solady's `OptimizedFixedPointMathLib`:
- **Management fee**: `(totalAssets * duration * managementFeeBps) / (SECS_PER_YEAR * MAX_BPS)` -- time-prorated per second
- **Performance fee**: Only charged when `assetsDelta > 0` (profit exists) and `totalReturn > hurdleReturn`. Supports hard hurdle (fees on excess only) and soft hurdle (fees on total return if above hurdle). Uses `sharePriceWatermark` to prevent fee reset gaming.

> **Note**: In the Solidity code, the MetaWallet is referenced via the variable `_metavault` typed as `IERC7540`. The product name is MetaWallet; the code name is `metavault`.

### `src/libraries/ExecutionDataLibrary.sol`
Pure library generating `Execution[]` calldata for `MinimalSmartAccount.execute()`:
- `getTransferExecutionData` -- ERC20 `transfer`
- `getTransferFromExecutionData` -- ERC20 `transferFrom`
- `getRequestRedeemExecutionData` -- ERC7540 `requestRedeem`
- `getRedeemExecutionData` -- ERC7540 `redeem`
- `getDepositExecutionData` -- ERC7540 `requestDeposit` + `deposit` (two executions)

### `script/DeploySettler.s.sol`
Deployment script using `DeploymentManager` base. Reads network config from JSON, fetches `kMinter` and `kAssetRouter` from the registry, deploys `Settler`, and grants it `RELAYER_ROLE` and `MANAGER_ROLE` in the registry. Outputs deployed address to JSON.

### `script/GrantRelayerRole.s.sol`
Post-deployment role management. Reads the deployed Settler address from JSON output, then calls `settler.grantRelayerRole(newRelayer)` via the admin account.

---

## Settlement Flow

The settlement lifecycle is a multi-step process driven by the relayer and backend services:

```
                      ForDefi MPC Wallet (Relayer)          Backend / Cronjob
                            |                                      |
  Step 1  closeAndProposeMinterBatch(asset)                        |
                  |                                                |
                  v                                                |
          [kMinter batch closed]                                   |
          [netting calculated]                                     |
          [rebalance with MetaWallet]                               |
          [proposalId returned]                                    |
                  |                                                |
  Step 2  closeAndProposeDNVaultBatch(asset, profitShareBps)       |
                  |                                                |
                  v                                                |
          [DN vault batch closed]                                  |
          [depeg calculated (profit/loss)]                         |
          [profit distributed: insurance->treasury->adapter]       |
          [fees calculated & transferred]                          |
          [netting transfers between adapters]                     |
          [kAssetRouter.proposeSettleBatch() called]               |
          [proposalId returned]                                    |
                  |                                                |
                  v                                                |
          [kAssetRouter checks: abs(yield) > maxAllowedDelta?]     |
                  |                                                |
           +------+------+                                         |
           |             |                                         |
       YES (high delta)  NO (within delta)                         |
           |             |                                         |
           v             +--- requiresApproval = false ---+        |
  requiresApproval = true                                 |        |
  YieldExceedsMaxDeltaWarning emitted                     |        |
           |                                              |        |
  Step 3   v                                              |        |
  [Backend sends acceptProposal to ForDefi]               |        |
  [ForDefi requires manual approval]                      |        |
           |                                              |        |
     +-----+-----+                                       |        |
     |           |                                        |        |
  APPROVED    ABORTED                                     |        |
     |           |                                        |        |
     v           v                                        |        |
  acceptProposal()   cancelProposal()                     |        |
  [proposal accepted]  [proposal removed]                 |        |
     |                  |                                 |        |
     |                  v                                 |        |
     |         [re-trigger proposeSettleBatch             |        |
     |          with corrected parameters]                |        |
     |                                                    |        |
     +--------------------+-------------------------------+        |
                          |                                        |
  Step 4                  |                   canExecuteProposal()?
                          |                          |
                          |                          v
                          |                  executeSettleBatch(proposalId)
                          |                          |
                          |                          v
                          |                  [batches finalized in kAssetRouter]
                          |                  [kToken minted/burned for yield]
                          |                  [adapter totalAssets updated]
                          |                          |
  Step 5                  |           finaliseCustodialSettlement(proposalId)
  (Alpha/Beta             |                          |
   only)                  |                          v
                          |                  [shares redeemed from MetaWallet]
                          |                  [assets transferred to CEFFU]
```

**Step 1 -- kMinter Batch** (`closeAndProposeMinterBatch`):
Closes the kMinter batch and calculates `nettedAmount = deposited - requested`. If negative (more redemptions than deposits), redeems shares from the MetaWallet to cover. If positive, deposits excess assets into the MetaWallet. Returns a `proposalId` (or `bytes32(0)` if netting is zero).

**Step 2 -- DN Vault Batch** (`closeAndProposeDNVaultBatch`):
Closes the DN vault batch. Calculates depeg: `actualKMinterAssets - expectedKMinterAssets` (positive = profit, negative = loss). On profit: distributes to insurance, treasury, and vault adapter in priority order, then transfers remaining profit shares to the DN adapter. On loss: transfers shares from the DN adapter to the kMinter adapter to cover the deficit. Calculates management and performance fees, transfers fee shares from DN adapter to treasury. Finally, executes netting transfers between kMinter and DN adapters and calls `kAssetRouter.proposeSettleBatch()`.

During `proposeSettleBatch`, the router calculates `yield = totalAssets - lastTotalAssets` and checks it against the `maxAllowedDelta` threshold (default 10%). If `abs(yield) > lastTotalAssets * maxAllowedDelta / 10_000`, the proposal is flagged with `requiresApproval = true` and a `YieldExceedsMaxDeltaWarning` event is emitted. This acts as a circuit breaker for anomalous yield values that could indicate calculation errors or manipulation.

**Step 3 -- Conditional Approval** (only when `requiresApproval = true`):
When yield breaks the delta threshold in either direction, the backend sends an `acceptProposal` transaction to ForDefi for manual approval. This requires human review before the settlement can proceed.

- **If approved**: ForDefi signs and broadcasts `acceptProposal(proposalId)`. The proposal is marked as accepted in `kAssetRouter` and can proceed to execution after the cooldown period.
- **If aborted**: ForDefi rejects the transaction. The backend calls `cancelProposal(proposalId)`, which removes the proposal from the pending queue and un-registers the `batchId`. A new `proposeSettleBatch` must then be triggered with corrected parameters to re-create the settlement proposal for that batch.

If yield is within the delta threshold, no approval step is needed -- the proposal can be executed directly after the cooldown period.

**Step 4 -- Execute Settlement** (`executeSettleBatch`):
A cronjob queries `kAssetRouter.getPendingProposals(vault)` for pending proposal IDs, checks `canExecuteProposal(proposalId)` (verifies cooldown has passed and approval status), and if ready, calls `settler.executeSettleBatch(proposalId)`. This finalizes the batch in the router: mints/burns kTokens to distribute yield or socialize losses, updates adapter `totalAssets`, notifies the vault of fee timestamps, and marks the batch as settled.

**Step 5 -- Custodial Finalization** (`finaliseCustodialSettlement`, Alpha/Beta only):
For custodial vaults (Alpha/Beta), redeems the netted shares from the MetaWallet via the kMinter adapter and transfers the underlying assets to the custodial target (CEFFU). If netting is negative, deposits assets into the MetaWallet instead.

---

## Fund Flow

```
  Users
    |
    | deposit/redeem requests
    v
+------------------+       +------------------+
|    kMinter       |       |   DN Vault       |
|  (kToken mint/   |       | (staking vault)  |
|   burn)          |       |                  |
+--------+---------+       +--------+---------+
         |                          |
         v                          v
+------------------+       +------------------+
|  kAssetRouter    |       |  kAssetRouter    |
| (virtual acctg)  |       | (virtual acctg)  |
+--------+---------+       +--------+---------+
         |                          |
         v                          v
+------------------+       +------------------+
| kMinter Adapter  |       | DN Vault Adapter |      Both are MinimalSmartAccount
| (MSA - physical  |       | (MSA - virtual   |      contracts that execute via
|  asset holder)   |       |  share holder)   |      batched Execution[] calls
+--------+---------+       +--------+---------+
         |                          |
         |  MetaWallet shares      |  MetaWallet shares
         +----------+---------------+
                    |
                    v
            +---------------+
            |  MetaWallet   |       ERC7540 vault holding
            |  (ERC7540)    |       the actual strategy assets
            +---------------+
```

**kMinter Adapter** is the central physical hub. It is the only adapter that physically holds and moves underlying assets. Its `totalAssets()` reflects the kToken total supply -- what the system owes depositors.

**DN Vault Adapter** is a virtual share holder. It holds MetaWallet shares representing the DN vault's claim on strategy returns. It does not directly hold underlying assets. It shares the same external strategy position as the kMinter adapter (both hold shares in the same MetaWallet).

**Alpha/Beta Adapters** are also virtual. Their assets are physically held at CEFFU (custodial). Fund movement between on-chain and custody goes through the kMinter adapter via `finaliseCustodialSettlement`.

**Netting direction**:
- Positive netting (deposited > requested): kMinter adapter's MetaWallet shares are transferred to DN adapter via `transferFrom`
- Negative netting (requested > deposited): DN adapter's MetaWallet shares are transferred to kMinter adapter via `transfer`

---

## Profit Distribution Priority

When depeg is positive (kMinter's actual MetaWallet assets exceed expected assets based on kToken supply), profit is distributed as MetaWallet shares from the kMinter adapter in strict priority order:

1. **Insurance**: Fills the insurance deficit up to target. Target = `insuranceBps / 10_000 * kMinterAdapter.totalAssets()`. Only distributes if current insurance balance is below target.
2. **Treasury**: `treasuryBps / 10_000` of remaining profit (after insurance).
3. **Vault Adapter**: `profitShareBps / 10_000` of what remains (after insurance + treasury). Only applies during vault settlements (`_isVaultSettlement = true`).
4. **kMinter**: Keeps the remainder implicitly -- no transfer needed, the shares stay in the kMinter adapter to maintain the 1:1 peg between kToken supply and backing assets.

Insurance and treasury addresses and basis points are read from the registry via `getSettlementConfig()`.

---

## Fee Model

Fees are calculated in `VaultMathLibrary` and charged during DN vault batch settlement (`_fees` in `Settler.sol`).

**Management Fee**: Time-based, prorated per second. Formula:
```
managementFee = (totalAssets * durationSecs * managementFeeBps) / (SECS_PER_YEAR * 10_000)
```
Charged on total vault assets regardless of performance. Only applied when `block.timestamp > nextManagementFeeTimestamp`.

**Performance Fee**: Only charged when there is profit (`assetsDelta > 0`) and the total return exceeds the hurdle return. Two modes:
- **Hard hurdle**: Fees charged only on the excess return above the hurdle (`excessReturn * performanceFeeBps / 10_000`)
- **Soft hurdle**: If return exceeds hurdle, fees charged on the entire return (`totalReturn * performanceFeeBps / 10_000`)

Uses `sharePriceWatermark` to track the high-water mark -- prevents charging performance fees on recovery from a drawdown (no fee until a new all-time high share price is reached).

**Fee transfer**: Fee shares are calculated as vault shares (not MetaWallet shares). They are transferred as MetaWallet shares from the DN vault adapter to the treasury address.

---

## Honest Assessment

### Strengths
- **On-chain determinism**: All settlement math is verifiable on-chain. No off-chain black box for netting, fee calculation, or profit distribution.
- **Clear separation of concerns**: Settler handles orchestration, `VaultMathLibrary` handles fee math, `ExecutionDataLibrary` handles calldata encoding. Each has a single responsibility.
- **Gas efficiency**: Uses Solady's `OptimizedOwnableRoles` and `OptimizedFixedPointMathLib`. Role checks use bitmask operations. No storage bloat.
- **Production-grade role system**: Three-tier access (owner, admin, relayer) with explicit `RELAYER_ROLE` checks on every mutative function.
- **Comprehensive test suite**: The project includes invariant tests validating settlement math invariants.

### Considerations and Risks

- **Relayer trust assumptions**: The relayer (a ForDefi MPC wallet) controls batch closing timing and proposal creation. A compromised relayer could manipulate settlement timing (e.g., closing batches at favorable/unfavorable share prices). The MPC setup reduces single-key risk, but the relayer remains a centralized trust point in the settlement lifecycle.

- **No explicit reentrancy guards**: The contract relies on the CEI pattern and the adapter execution model (calls go through `MinimalSmartAccount.execute`) rather than explicit `nonReentrant` modifiers. This is a deliberate design choice but requires careful reasoning about all external call paths.

- **External state dependency**: Fee calculations depend on vault state (`sharePriceWatermark`, `totalAssets`, `totalSupply`, `managementFee`, `hurdleRate`) read from external contracts. If any of these return manipulated values (oracle risk, compromised vault), fee calculations will be incorrect.

- **Dust adjustment loop**: The pattern `while (convertToAssets(shares) < desired) shares++` appears in multiple places (`closeAndProposeMinterBatch:138`, `_closeAndProposeDNVaultBatch:261`, `_distributeProfitShares:838`). These loops are bounded in practice (share-to-asset rounding is typically off by 1-2 wei) but have no explicit iteration cap. In edge cases with extreme share price ratios, gas cost could spike.

- **`profitShareBps` as a call parameter**: The profit share percentage is passed per call rather than stored on-chain. The relayer could theoretically vary it between settlements. This is mitigated by access control and off-chain monitoring, but it is a trust surface worth noting.

- **Virtual vs. physical state gap**: Settlement is bookkeeping-only -- it updates virtual accounting in `kAssetRouter`. Actual fund movement (e.g., moving assets to/from CEFFU in Alpha/Beta) happens in a separate step (`finaliseCustodialSettlement`). This temporal gap between virtual and physical state is by design but requires operational discipline to keep in sync.

- **Non-upgradeable**: The Settler has no proxy or upgrade mechanism. Any bug or logic change requires deploying a new contract and re-granting all roles across the ecosystem (registry relayer/manager roles, adapter permissions). This is a security strength (no upgrade risk) but an operational consideration.

- **`Unauthorized` error vs. role check pattern**: The contract uses `hasAnyRole` in two different patterns -- as a revert-on-false check (`if (!hasAnyRole(...)) revert Unauthorized()`) and as a bare call (`hasAnyRole(msg.sender, ADMIN_ROLE)` in `grantRelayerRole` at line 89). The bare call pattern in `grantRelayerRole` relies on Solady's `hasAnyRole` reverting internally on failure, which is correct but stylistically inconsistent with the rest of the contract.
