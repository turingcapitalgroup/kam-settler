# KAM Settler

Batch settlement orchestration contract for the [KAM (Keyrock Asset Management)](https://github.com/turingcapitalgroup/KAM) protocol. The Settler contract manages complex batch settlement processes including rebalancing, fee calculations, asset netting, and profit distribution for delta-neutral vaults.

For detailed technical documentation including architecture, settlement flows, and fee models, see [docs/overview.md](docs/overview.md).

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
