# KAM Settler

Batch settlement orchestration contract for the [KAM (Keyrock Asset Management)](https://github.com/turingcapitalgroup/KAM) protocol. The Settler contract manages complex batch settlement processes including rebalancing, fee calculations, asset netting, and profit distribution for delta-neutral vaults.

## Overview

The Settler contract acts as the orchestrator for:

- **kMinter batch settlements** - Closing and settling batches from the kMinter contract
- **Delta-Neutral (DN) vault batch settlements** - Closing batches with profit distribution and fee calculations
- **Custodial vault settlements** - Asset transfers between custody providers and meta-vaults
- **Insurance liquidation** - Converting insurance shares to underlying assets
- **Profit distribution** - Distributing profits to insurance, treasury, and vault adapters

## Architecture

```
src/
├── Settler.sol                    # Main settlement contract
├── interfaces/
│   ├── ISettler.sol              # Interface definitions
│   └── IRegistry.sol             # Registry interface
└── libraries/
    ├── VaultMathLibrary.sol      # Fee calculation logic
    └── ExecutionDataLibrary.sol  # Execution data generation
```

### Core Components

**Settler.sol** - Main contract that orchestrates:
- Batch closing and settlement proposals
- Asset netting between kMinter and DN vault adapters
- Fee calculation and profit distribution
- Transaction execution through MinimalSmartAccount adapters
- Rebalancing operations and insurance liquidation

**VaultMathLibrary.sol** - Handles fee computations:
- Time-based management fees (prorated by seconds)
- Performance fees with hurdle rate support
- Hard vs. soft hurdle rate differentiation

**ExecutionDataLibrary.sol** - Generates execution data for:
- ERC20 token transfers
- ERC7540 vault deposit/redeem operations

## Settlement Flow

1. **Close batch** - kMinter/vault closes pending operations
2. **Calculate netting** - Determine difference between deposits and requests
3. **Handle rebalancing** - Transfer shares between adapters as needed
4. **Charge fees** - Calculate management and performance fees
5. **Distribute profits** - Share gains with insurance, treasury, vault adapter
6. **Propose settlement** - Create settlement proposal in asset router
7. **Execute settlement** - Finalize the batch

### Profit Distribution Priority

1. **Insurance** - Receives up to its target amount (configurable basis points)
2. **Treasury** - Receives percentage of remaining profit
3. **Vault Adapter** - Receives configurable portion for settled vaults
4. **kMinter** - Keeps remaining balance

## Installation

```bash
git clone https://github.com/turingcapitalgroup/kam-settler.git
cd kam-settler
forge install
```

## Usage

### Build

```bash
make build
# or
forge build
```

### Test

```bash
make test
# or
forge test
```

### Format

```bash
make format
# or
forge fmt
```

### Coverage

```bash
make coverage
```

## Deployment

### Configuration

Network configurations are stored in `deployments/config/`:
- `mainnet.json` - Ethereum mainnet settings
- `sepolia.json` - Sepolia testnet settings
- `localhost.json` - Local development settings

Each config specifies:
- KAM registry address
- Role addresses (owner, admin, relayer)

### Environment Variables

Create a `.env` file:

```bash
RPC_MAINNET=<mainnet-rpc-url>
RPC_SEPOLIA=<sepolia-rpc-url>
DEPLOYER_ADDRESS=<deployer-address>
ETHERSCAN_MAINNET_KEY=<etherscan-api-key>
ETHERSCAN_SEPOLIA_KEY=<etherscan-api-key>
```

### Deploy Commands

```bash
# Mainnet
make deploy-mainnet
make deploy-mainnet-dry-run    # Simulate without broadcasting

# Sepolia
make deploy-sepolia
make deploy-sepolia-dry-run

# Localhost (full stack: KAM + Settler)
make deploy-localhost

# Localhost (Settler only, requires existing KAM deployment)
make deploy-settler-localhost
```

### Verify on Etherscan

```bash
make verify-mainnet
make verify-sepolia
```

## Access Control

The contract uses role-based access control:

- **Owner** - Contract owner, can grant roles
- **Admin** - Administrative operations, can grant relayer role
- **Relayer** - Executes settlement operations (main operator role)

## Dependencies

- [forge-std](https://github.com/foundry-rs/forge-std) v1.10.0
- [KAM](https://github.com/turingcapitalgroup/KAM) v1
- [minimal-smart-account](https://github.com/turingcapitalgroup/minimal-smart-account) v1.0

## Technical Details

- **Solidity**: 0.8.30
- **Framework**: Foundry
- **Optimizer**: Enabled with 10,000 runs
- **Via IR**: Enabled

## License

MIT
