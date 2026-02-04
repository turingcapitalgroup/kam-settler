// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import { kSettler } from "../src/kSettler.sol";
import { DeploymentManager } from "./utils/DeploymentManager.sol";
import { IkRegistry } from "kam/src/interfaces/IkRegistry.sol";

/// @title DeploykSettlerScript
/// @notice Deployment script for the kSettler contract
/// @dev Reads configuration from JSON and writes deployed addresses to JSON output
contract DeploykSettlerScript is DeploymentManager {
    /// @notice Deployment result struct
    struct kSettlerDeployment {
        address settler;
    }

    /// @notice Main entry point for deployment
    /// @dev Reads config from JSON, deploys kSettler, writes output to JSON
    /// @return deployment The deployed contract addresses
    function run() public returns (kSettlerDeployment memory deployment) {
        // 1. Read network config
        NetworkConfig memory config = readNetworkConfig();

        // 2. Fetch kMinter and kAssetRouter from registry
        (address kMinter, address kAssetRouter) = IkRegistry(config.kam.registry).getCoreContracts();
        config.kam.kMinter = kMinter;
        config.kam.kAssetRouter = kAssetRouter;

        // 3. Validate config
        validateConfig(config);

        // 4. Log configuration
        logScriptHeader("DeploykSettler");
        logRoles(config);
        logKamAddresses(config);
        logBroadcaster(config.roles.owner);
        logExecutionStart();

        // 5. Deploy kSettler
        vm.startBroadcast(config.roles.owner);

        kSettler settler = new kSettler(
            config.roles.owner,
            config.roles.admin,
            config.roles.relayer,
            config.kam.kMinter,
            config.kam.kAssetRouter,
            config.kam.registry
        );

        // 6. Grant roles to kSettler in registry
        IkRegistry(config.kam.registry).grantRelayerRole(address(settler));
        IkRegistry(config.kam.registry).grantManagerRole(address(settler));

        vm.stopBroadcast();

        // 7. Log deployed contract
        logDeployedContract("kSettler", address(settler));
        logExecutionEnd();

        // 8. Write to JSON
        writeContractAddress("settler", address(settler));

        deployment.settler = address(settler);
    }

    /// @notice Test-only deployment with all parameters provided directly
    /// @dev Use this variant in tests where contracts are mocked and roles come from test setup
    /// @param _owner Owner address for the kSettler contract
    /// @param _admin Admin address for the kSettler contract
    /// @param _relayer Relayer address for the kSettler contract
    /// @param _kMinter kMinter contract address
    /// @param _kAssetRouter kAssetRouter contract address
    /// @param _registry Registry contract address
    /// @return deployment The deployed contract addresses
    function runTest(
        address _owner,
        address _admin,
        address _relayer,
        address _kMinter,
        address _kAssetRouter,
        address _registry
    )
        public
        returns (kSettlerDeployment memory deployment)
    {
        // 1. Validate inputs
        require(_owner != address(0), "Owner address is zero");
        require(_admin != address(0), "Admin address is zero");
        require(_relayer != address(0), "Relayer address is zero");
        require(_kMinter != address(0), "kMinter address is zero");
        require(_kAssetRouter != address(0), "kAssetRouter address is zero");
        require(_registry != address(0), "Registry address is zero");

        // 2. Deploy kSettler
        vm.startBroadcast(_owner);

        kSettler settler = new kSettler(_owner, _admin, _relayer, _kMinter, _kAssetRouter, _registry);

        // 3. Grant roles to kSettler in registry
        IkRegistry(_registry).grantRelayerRole(address(settler));
        IkRegistry(_registry).grantManagerRole(address(settler));

        vm.stopBroadcast();

        deployment.settler = address(settler);
    }
}
