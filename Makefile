# KAM kSettler Deployment Makefile
# Usage: make deploy-mainnet, make deploy-sepolia, make deploy-localhost
-include .env
export

# Paths
KAM_DIR := dependencies/kam-v1
KAM_PARENT_DIR := ../KAM
KAM_OUTPUT := $(KAM_DIR)/deployments/output/localhost/addresses.json
KAM_PARENT_OUTPUT := $(KAM_PARENT_DIR)/deployments/output/localhost/addresses.json
SETTLER_CONFIG := deployments/config/localhost.json

.PHONY: help deploy-mainnet deploy-mainnet-dry-run deploy-sepolia deploy-sepolia-dry-run deploy-localhost deploy-localhost-dry-run deploy-kam-localhost sync-kam-localhost deploy-settler-localhost verify-mainnet verify-sepolia verify clean clean-all test coverage build format

# Default target
help:
	@echo "KAM kSettler Deployment Commands"
	@echo "================================"
	@echo ""
	@echo "Deploy kSettler contract:"
	@echo "  make deploy-mainnet          - Deploy to mainnet"
	@echo "  make deploy-mainnet-dry-run  - Simulate deployment to mainnet (no broadcast)"
	@echo "  make deploy-sepolia          - Deploy to Sepolia testnet"
	@echo "  make deploy-sepolia-dry-run  - Simulate deployment to Sepolia (no broadcast)"
	@echo "  make deploy-localhost        - Deploy KAM + kSettler to localhost (full stack)"
	@echo "  make deploy-settler-localhost- Deploy only kSettler to localhost (KAM must exist)"
	@echo ""
	@echo "Localhost helpers:"
	@echo "  make deploy-kam-localhost    - Deploy KAM protocol to localhost"
	@echo "  make sync-kam-localhost      - Sync KAM registry address to kSettler config"
	@echo ""
	@echo "Verify contracts on Etherscan:"
	@echo "  make verify-mainnet          - Verify kSettler on mainnet Etherscan"
	@echo "  make verify-sepolia          - Verify kSettler on Sepolia Etherscan"
	@echo ""
	@echo "Other commands:"
	@echo "  make build                   - Build the project"
	@echo "  make test                    - Run tests"
	@echo "  make coverage                - Run coverage"
	@echo "  make format                  - Format Solidity files"
	@echo "  make verify                  - Check deployment files exist"
	@echo "  make clean                   - Clean localhost deployment files"
	@echo "  make clean-all               - Clean ALL deployment files (DANGER)"

# Network-specific deployments
deploy-mainnet:
	@echo "🔴 Deploying kSettler to MAINNET..."
	DEPLOYMENT_BASE_PATH=deployments forge script script/DeploykSettler.s.sol --sig "run()" --rpc-url ${RPC_MAINNET} --broadcast --account keyDeployer --sender ${DEPLOYER_ADDRESS} --slow -vvv
	@$(MAKE) format-output

deploy-mainnet-dry-run:
	@echo "🔴 [DRY-RUN] Simulating kSettler deployment to MAINNET..."
	DEPLOYMENT_BASE_PATH=deployments forge script script/DeploykSettler.s.sol --sig "run()" --rpc-url ${RPC_MAINNET} --account keyDeployer --sender ${DEPLOYER_ADDRESS} --slow -vvv

deploy-sepolia:
	@echo "🟡 Deploying kSettler to SEPOLIA..."
	DEPLOYMENT_BASE_PATH=deployments forge script script/DeploykSettler.s.sol --sig "run()" --rpc-url ${RPC_SEPOLIA} --broadcast --account keyDeployer --sender ${DEPLOYER_ADDRESS} --slow -vvv
	@$(MAKE) format-output

deploy-sepolia-dry-run:
	@echo "🟡 [DRY-RUN] Simulating kSettler deployment to SEPOLIA..."
	DEPLOYMENT_BASE_PATH=deployments forge script script/DeploykSettler.s.sol --sig "run()" --rpc-url ${RPC_SEPOLIA} --account keyDeployer --sender ${DEPLOYER_ADDRESS} --slow -vvv

# Localhost deployment (full stack: KAM + kSettler)
deploy-localhost: deploy-kam-localhost sync-kam-localhost deploy-settler-localhost
	@echo "✅ Full localhost deployment complete!" 

# Deploy KAM protocol to localhost (uses parent KAM repo)
deploy-kam-localhost:
	@echo "🟢 Deploying KAM protocol to LOCALHOST..."
	@CURRENT_DIR=$$(pwd); \
	if [ -d "$(KAM_PARENT_DIR)" ]; then \
		echo "📦 Found parent KAM repo at $(KAM_PARENT_DIR)"; \
		cd $(KAM_PARENT_DIR) && $(MAKE) deploy-localhost; \
		cd "$$CURRENT_DIR"; \
		echo "📋 Copying KAM output to dependency..."; \
		mkdir -p $(KAM_DIR)/deployments/output/localhost; \
		cp $(KAM_PARENT_OUTPUT) $(KAM_OUTPUT); \
		echo "✅ KAM deployment complete"; \
	else \
		echo "⚠️  Parent KAM repo not found at $(KAM_PARENT_DIR)"; \
		echo "   Please deploy KAM manually or clone the KAM repo"; \
		exit 1; \
	fi

# Sync KAM registry address to kSettler config
sync-kam-localhost:
	@echo "🔄 Syncing KAM registry address to kSettler config..."
	@if [ ! -f "$(KAM_OUTPUT)" ]; then \
		echo "❌ KAM deployment not found at $(KAM_OUTPUT)"; \
		echo "   Run 'make deploy-kam-localhost' first"; \
		exit 1; \
	fi
	@REGISTRY=$$(jq -r '.contracts.kRegistry' $(KAM_OUTPUT)); \
	if [ "$$REGISTRY" = "null" ] || [ -z "$$REGISTRY" ]; then \
		echo "❌ kRegistry not found in KAM output"; \
		exit 1; \
	fi; \
	echo "  Registry address: $$REGISTRY"; \
	jq --arg registry "$$REGISTRY" '.kam.registry = $$registry' $(SETTLER_CONFIG) > $(SETTLER_CONFIG).tmp && \
	mv $(SETTLER_CONFIG).tmp $(SETTLER_CONFIG); \
	echo "✅ Updated $(SETTLER_CONFIG) with registry address"

# Deploy only kSettler to localhost (assumes KAM is already deployed)
deploy-settler-localhost:
	@echo "🟢 Deploying kSettler to LOCALHOST..."
	@if [ ! -f "$(SETTLER_CONFIG)" ]; then \
		echo "❌ kSettler config not found at $(SETTLER_CONFIG)"; \
		exit 1; \
	fi
	@REGISTRY=$$(jq -r '.kam.registry' $(SETTLER_CONFIG)); \
	if [ "$$REGISTRY" = "null" ] || [ "$$REGISTRY" = "0x0000000000000000000000000000000000000000" ]; then \
		echo "❌ Registry address not set in $(SETTLER_CONFIG)"; \
		echo "   Run 'make sync-kam-localhost' first"; \
		exit 1; \
	fi
	DEPLOYMENT_BASE_PATH=deployments forge script script/DeploykSettler.s.sol --sig "run()" --rpc-url http://localhost:8545 --broadcast --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 --sender 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 --slow
	@$(MAKE) format-output

deploy-localhost-dry-run:
	@echo "🟢 [DRY-RUN] Simulating kSettler deployment to LOCALHOST..."
	DEPLOYMENT_BASE_PATH=deployments forge script script/DeploykSettler.s.sol --sig "run()" --rpc-url http://localhost:8545 --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 --sender 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 --slow

# Etherscan verification (mainnet)
verify-mainnet:
	@echo "🔍 Verifying kSettler on MAINNET Etherscan..."
	@if [ ! -f "deployments/output/mainnet/addresses.json" ]; then \
		echo "❌ No mainnet deployment found"; \
		exit 1; \
	fi
	@echo "Verifying kSettler..."
	@SETTLER=$$(jq -r '.contracts.settler' deployments/output/mainnet/addresses.json); \
	REGISTRY=$$(jq -r '.kam.registry' deployments/config/mainnet.json); \
	KMINTER=$$(cast call $$REGISTRY "getCoreContracts()(address,address)" --rpc-url ${RPC_MAINNET} | head -1); \
	KASSETROUTER=$$(cast call $$REGISTRY "getCoreContracts()(address,address)" --rpc-url ${RPC_MAINNET} | tail -1); \
	OWNER=$$(jq -r '.roles.owner' deployments/config/mainnet.json); \
	ADMIN=$$(jq -r '.roles.admin' deployments/config/mainnet.json); \
	RELAYER=$$(jq -r '.roles.relayer' deployments/config/mainnet.json); \
	forge verify-contract $$SETTLER src/kSettler.sol:kSettler \
		--chain-id 1 \
		--etherscan-api-key ${ETHERSCAN_MAINNET_KEY} \
		--constructor-args $$(cast abi-encode "constructor(address,address,address,address,address,address)" $$OWNER $$ADMIN $$RELAYER $$KMINTER $$KASSETROUTER $$REGISTRY) \
		--watch || true
	@echo "✅ Mainnet verification complete!"

# Etherscan verification (sepolia)
verify-sepolia:
	@echo "🔍 Verifying kSettler on SEPOLIA Etherscan..."
	@if [ ! -f "deployments/output/sepolia/addresses.json" ]; then \
		echo "❌ No sepolia deployment found"; \
		exit 1; \
	fi
	@echo "Verifying kSettler..."
	@SETTLER=$$(jq -r '.contracts.settler' deployments/output/sepolia/addresses.json); \
	REGISTRY=$$(jq -r '.kam.registry' deployments/config/sepolia.json); \
	KMINTER=$$(cast call $$REGISTRY "getCoreContracts()(address,address)" --rpc-url ${RPC_SEPOLIA} | head -1); \
	KASSETROUTER=$$(cast call $$REGISTRY "getCoreContracts()(address,address)" --rpc-url ${RPC_SEPOLIA} | tail -1); \
	OWNER=$$(jq -r '.roles.owner' deployments/config/sepolia.json); \
	ADMIN=$$(jq -r '.roles.admin' deployments/config/sepolia.json); \
	RELAYER=$$(jq -r '.roles.relayer' deployments/config/sepolia.json); \
	forge verify-contract $$SETTLER src/kSettler.sol:kSettler \
		--chain-id 11155111 \
		--etherscan-api-key ${ETHERSCAN_SEPOLIA_KEY} \
		--constructor-args $$(cast abi-encode "constructor(address,address,address,address,address,address)" $$OWNER $$ADMIN $$RELAYER $$KMINTER $$KASSETROUTER $$REGISTRY) \
		--watch || true
	@echo "✅ Sepolia verification complete!"

# Format JSON output files
format-output:
	@echo "📝 Formatting JSON output files..."
	@for file in deployments/output/*/*.json; do \
		if [ -f "$$file" ]; then \
			echo "Formatting $$file"; \
			jq . "$$file" > "$$file.tmp" && mv "$$file.tmp" "$$file"; \
		fi; \
	done
	@echo "✅ JSON files formatted!"

# Verification
verify:
	@echo "🔍 Verifying deployment..."
	@if [ ! -f "deployments/output/localhost/addresses.json" ] && [ ! -f "deployments/output/mainnet/addresses.json" ] && [ ! -f "deployments/output/sepolia/addresses.json" ]; then \
		echo "❌ No deployment files found"; \
		exit 1; \
	fi
	@echo "✅ Deployment files exist"
	@echo "📄 Check deployments/output/ for contract addresses"

# Development helpers
build:
	forge fmt
	forge build

test:
	@echo "⚡ Running tests..."
	forge test

coverage:
	forge coverage

format:
	forge fmt

clean:
	forge clean
	rm -rf deployments/output/localhost/addresses.json

clean-kam-localhost:
	@echo "🧹 Cleaning KAM localhost deployment..."
	rm -rf $(KAM_OUTPUT)
	@echo "✅ KAM localhost output removed"

clean-all:
	forge clean
	rm -rf deployments/output/*/addresses.json
	rm -rf $(KAM_OUTPUT)
