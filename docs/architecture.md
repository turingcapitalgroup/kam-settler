# KAM kSettler - Architecture

## Introduction

The kSettler contract moves backend settlement math on-chain, making vault batch settlement deterministic, auditable, and trustless. Previously, settlement calculations (netting, profit distribution) lived in off-chain services. The kSettler replaces that with verifiable Solidity logic.

Within the KAM ecosystem, the kSettler sits between the vaults (kMinter, DN vaults, Alpha/Beta vaults) and the `kAssetRouter`. It orchestrates batch closing, calculates net deposit/redemption flows, distributes profit according to a fixed priority, and proposes settlements for execution through the router.

The contract is non-upgradeable. All transactions sent to the kSettler are triggered on-chain by a ForDefi MPC wallet acting as the relayer, which drives the settlement lifecycle by calling the kSettler's public functions in sequence.

---

## File-by-File Breakdown

### `src/kSettler.sol`
Core orchestration contract. Inherits `OptimizedOwnableRoles` (Solady) for gas-efficient role management. Contains all settlement logic:
- **kMinter batch**: `closeAndProposeMinterBatch` closes the kMinter batch, calculates netting (deposited - requested), and proposes settlement. Netting transfers are deferred to `executeSettleBatch`.
- **DN vault batch**: `_closeAndProposeDNVaultBatch` closes the DN vault batch, computes depeg (profit/loss), distributes profit inline (insurance -> treasury -> vault adapter), and proposes settlement. Netting transfers are deferred to `executeSettleBatch`.
- **Execution helpers**: `executeSettleBatch` reads the proposal from the router and executes deferred netting transfers (minter deposit/withdraw, DN vault share transfer) before calling `kAssetRouter.executeSettleBatch`. `acceptProposal`, `cancelProposal` for proposal lifecycle.
- **Alpha/Beta**: `finaliseCustodialSettlement` handles post-settlement fund movement to/from CEFFU custody.
- **Insurance**: `liquidateInsurance` redeems insurance's MetaWallet shares to underlying assets.
- **Profit distribution**: `_distributeProfitShares` implements the insurance -> treasury -> vault adapter priority.

### `src/interfaces/IkSettler.sol`
Public interface defining all external functions, events, and structs. Error constants are centralized in `src/errors/Errors.sol` using the `KS*` prefix pattern.
- **Events**: `ProfitDistributed(insuranceShares, treasuryShares, vaultAdapterShares)`, `InsuranceLiquidated(asset, shares, assets)`
- **Structs**: `BatchInfo` (batch state), `VaultAddresses` (address bundle), `AssetData` (settlement calculations)

### `src/libraries/ExecutionDataLibrary.sol`
Pure library generating `Execution[]` calldata for `MinimalSmartAccount.execute()`:
- `getTransferExecutionData` -- ERC20 `transfer`
- `getTransferFromExecutionData` -- ERC20 `transferFrom`
- `getRedeemExecutionData` -- ERC4626 `redeem`
- `getDepositExecutionData` -- ERC4626 `deposit`

### `script/DeploykSettler.s.sol`
Deployment script using `DeploymentManager` base. Reads network config from JSON, fetches `kMinter` and `kAssetRouter` from the registry, deploys `kSettler`, and grants it `RELAYER_ROLE` and `MANAGER_ROLE` in the registry. Outputs deployed address to JSON.

### `script/GrantRelayerRole.s.sol`
Post-deployment role management. Reads the deployed kSettler address from JSON output, then calls `settler.grantRelayerRole(newRelayer)` via the admin account.

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
Closes the kMinter batch. The physical MetaWallet deposit/withdrawal based on `nettedAmount = deposited - requested` is deferred to `executeSettleBatch`, which reads the netted amount from the router proposal. Returns a `proposalId`.

**Step 2 -- DN Vault Batch** (`closeAndProposeDNVaultBatch`):
Closes the DN vault batch. Calculates depeg: `actualKMinterAssets - expectedKMinterAssets` (positive = profit, negative = loss). On profit: distributes to insurance, treasury, and vault adapter in priority order **inline**. On loss: transfers shares from the vault adapter to the kMinter adapter **inline**. The netting transfer between adapters is deferred to `executeSettleBatch`. Calls `kAssetRouter.proposeSettleBatch()`.

During `proposeSettleBatch`, the router calculates `yield = totalAssets - lastTotalAssets` and checks it against the `maxAllowedDelta` threshold (default 10%). If `abs(yield) > lastTotalAssets * maxAllowedDelta / 10_000`, the proposal is flagged with `requiresApproval = true` and a `YieldExceedsMaxDeltaWarning` event is emitted. This acts as a circuit breaker for anomalous yield values that could indicate calculation errors or manipulation.

**Step 3 -- Conditional Approval** (only when `requiresApproval = true`):
When yield breaks the delta threshold in either direction, the backend sends an `acceptProposal` transaction to ForDefi for manual approval. This requires human review before the settlement can proceed.

- **If approved**: ForDefi signs and broadcasts `acceptProposal(proposalId)`. The proposal is marked as accepted in `kAssetRouter` and can proceed to execution after the cooldown period.
- **If aborted**: ForDefi rejects the transaction. The backend calls `cancelProposal(proposalId)`, which removes the proposal from the pending queue and un-registers the `batchId`. A new `proposeSettleBatch` must then be triggered with corrected parameters to re-create the settlement proposal for that batch.

If yield is within the delta threshold, no approval step is needed -- the proposal can be executed directly after the cooldown period.

**Step 4 -- Execute Settlement** (`executeSettleBatch`):
A cronjob queries `kAssetRouter.getPendingProposals(vault)` for pending proposal IDs, checks `canExecuteProposal(proposalId)` (verifies cooldown has passed and approval status), and if ready, calls `settler.executeSettleBatch(proposalId)`. This reads the proposal from the router to determine the vault type and executes the deferred netting transfers (minter deposit/withdraw or DN vault share transfer). Then it calls `kAssetRouter.executeSettleBatch` which finalizes the batch: mints/burns kTokens to distribute yield or socialize losses, updates adapter `totalAssets`, and marks the batch as settled.

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
            |  MetaWallet   |       ERC4626 vault holding
            |  (ERC4626)    |       the actual strategy assets
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

## Role Management

The kSettler uses Solady's `OptimizedOwnableRoles` for role-based access control. Each role's revoke authority mirrors its grant authority (TOB-KAM-32 finding #3), so revocation is at least as strong as the original grant.

| Role | Granted by | Revoked by |
|------|------------|------------|
| OWNER | constructor (`_initializeOwner`) | Solady-inherited `transferOwnership` / `renounceOwnership` |
| ADMIN | constructor + `grantAdminRole` (OWNER-gated) | `revokeAdminRole` (OWNER-gated) |
| RELAYER | constructor + `grantRelayerRole` (ADMIN-gated) | `revokeRelayerRole` (ADMIN-gated) |

### Function surface

```solidity
// OWNER-gated
function grantAdminRole(address _admin) external;
function revokeAdminRole(address _admin) external;

// ADMIN-gated
function grantRelayerRole(address _relayer) external payable;
function revokeRelayerRole(address _relayer) external payable;
```

`grantAdminRole` and `grantRelayerRole` revert with `KS3` (zero-address) if the recipient is `address(0)`. The corresponding revoke functions are no-ops if the address does not currently hold the role (Solady semantics).

Solady's inherited `grantRoles(addr, mask)` and `revokeRoles(addr, mask)` (both `onlyOwner`) remain accessible as an emergency escape hatch — same convention as the kRegistry contract in the wider KAM repo.
