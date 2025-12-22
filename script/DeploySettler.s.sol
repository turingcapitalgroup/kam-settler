// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import { Settler } from "../src/Settler.sol";
import { DeploymentManager } from "./utils/DeploymentManager.sol";
import { IkRegistry } from "kam/src/interfaces/IkRegistry.sol";

/// @title DeploySettlerScript
/// @notice Deployment script for the Settler contract
/// @dev Reads configuration from JSON and writes deployed addresses to JSON output
contract DeploySettlerScript is DeploymentManager {
    /// @notice Deployment result struct
    struct SettlerDeployment {
        address settler;
    }

    /// @notice Main entry point for deployment
    /// @dev Reads config from JSON, deploys Settler, writes output to JSON
    /// @return deployment The deployed contract addresses
    function run() public returns (SettlerDeployment memory deployment) {
        // 1. Read network config
        NetworkConfig memory config = readNetworkConfig();

        // 2. Fetch kMinter and kAssetRouter from registry
        (address kMinter, address kAssetRouter) = IkRegistry(config.kam.registry).getCoreContracts();
        config.kam.kMinter = kMinter;
        config.kam.kAssetRouter = kAssetRouter;

        // 3. Validate config
        validateConfig(config);

        // 4. Log configuration
        logScriptHeader("DeploySettler");
        logRoles(config);
        logKamAddresses(config);
        logBroadcaster(config.roles.owner);
        logExecutionStart();

        // 5. Deploy Settler
        vm.startBroadcast(config.roles.owner);

        Settler settler = new Settler(
            config.roles.owner,
            config.roles.admin,
            config.roles.relayer,
            config.kam.kMinter,
            config.kam.kAssetRouter,
            config.kam.registry
        );

        // 6. Grant roles to Settler in registry
        IkRegistry(config.kam.registry).grantRelayerRole(address(settler));
        IkRegistry(config.kam.registry).grantManagerRole(address(settler));

        vm.stopBroadcast();

        // 7. Log deployed contract
        logDeployedContract("Settler", address(settler));
        logExecutionEnd();

        // 8. Write to JSON
        writeContractAddress("settler", address(settler));

        deployment.settler = address(settler);
    }

    /// @notice Test-only deployment with all parameters provided directly
    /// @dev Use this variant in tests where contracts are mocked and roles come from test setup
    /// @param _owner Owner address for the Settler contract
    /// @param _admin Admin address for the Settler contract
    /// @param _relayer Relayer address for the Settler contract
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
        returns (SettlerDeployment memory deployment)
    {
        // 1. Validate inputs
        require(_owner != address(0), "Owner address is zero");
        require(_admin != address(0), "Admin address is zero");
        require(_relayer != address(0), "Relayer address is zero");
        require(_kMinter != address(0), "kMinter address is zero");
        require(_kAssetRouter != address(0), "kAssetRouter address is zero");
        require(_registry != address(0), "Registry address is zero");

        // 2. Deploy Settler
        vm.startBroadcast(_owner);

        Settler settler = new Settler(_owner, _admin, _relayer, _kMinter, _kAssetRouter, _registry);

        // 3. Grant roles to Settler in registry
        IkRegistry(_registry).grantRelayerRole(address(settler));
        IkRegistry(_registry).grantManagerRole(address(settler));

        vm.stopBroadcast();

        deployment.settler = address(settler);
    }
}
