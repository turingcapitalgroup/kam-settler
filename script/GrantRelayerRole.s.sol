// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.34;

import { kSettler } from "../src/kSettler.sol";
import { DeploymentManager } from "./utils/DeploymentManager.sol";
import { console2 as console } from "forge-std/console2.sol";

/// @title GrantRelayerRoleScript
/// @notice Script to grant the relayer role to an address on the kSettler contract
/// @dev Reads deployed kSettler from JSON output and grants relayer role via admin
contract GrantRelayerRoleScript is DeploymentManager {
    /// @notice Main entry point for granting relayer role
    /// @dev Reads config and output, then grants relayer role to the specified address
    /// @param _newRelayer The address to grant the relayer role to
    function run(address _newRelayer) public {
        require(_newRelayer != address(0), "New relayer address is zero");

        // 1. Read network config and deployment output
        NetworkConfig memory config = readNetworkConfig();
        DeploymentOutput memory output = readDeploymentOutput();

        // 2. Validate kSettler is deployed
        require(output.settler != address(0), "kSettler not deployed");

        // 3. Log configuration
        logScriptHeader("GrantRelayerRole");
        logRoles(config);
        console.log("kSettler:", output.settler);
        console.log("New Relayer:", _newRelayer);
        console.log("");
        logBroadcaster(config.roles.admin);
        logExecutionStart();

        // 4. Grant relayer role (must be called by admin)
        vm.startBroadcast(config.roles.admin);

        kSettler settler = kSettler(output.settler);
        settler.grantRelayerRole(_newRelayer);

        vm.stopBroadcast();

        // 5. Log result
        console.log("  Granted SETTLER_RELAYER_ROLE to:", _newRelayer);
        logExecutionEnd();
    }
}
