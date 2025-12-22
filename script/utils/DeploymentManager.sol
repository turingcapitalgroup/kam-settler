// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import { Script } from "forge-std/Script.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { console2 as console } from "forge-std/console2.sol";

/// @title DeploymentManager
/// @notice Utility contract for reading deployment configs and writing deployment outputs
/// @dev Inherited by deployment scripts to manage JSON-based configuration
abstract contract DeploymentManager is Script {
    using stdJson for string;

    /*//////////////////////////////////////////////////////////////
                            DATA STRUCTURES
    //////////////////////////////////////////////////////////////*/

    /// @notice Role addresses for the Settler contract
    struct RoleAddresses {
        address owner;
        address admin;
        address relayer;
    }

    /// @notice KAM protocol contract addresses
    struct KamAddresses {
        address registry;
        address kMinter;
        address kAssetRouter;
    }

    /// @notice Full network configuration
    struct NetworkConfig {
        string network;
        uint256 chainId;
        RoleAddresses roles;
        KamAddresses kam;
    }

    /// @notice Deployed contract addresses
    struct DeploymentOutput {
        uint256 chainId;
        string network;
        uint256 timestamp;
        address settler;
    }

    /*//////////////////////////////////////////////////////////////
                            NETWORK DETECTION
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the current network name based on chain ID
    function getCurrentNetwork() internal view returns (string memory) {
        if (block.chainid == 1) return "mainnet";
        if (block.chainid == 11_155_111) return "sepolia";
        if (block.chainid == 31_337) return "localhost";
        revert("Unsupported network");
    }

    /// @notice Returns the base path for deployments directory
    function getDeploymentsPath() internal view returns (string memory) {
        string memory basePath = vm.envOr("DEPLOYMENT_BASE_PATH", string("deployments"));
        return basePath;
    }

    /*//////////////////////////////////////////////////////////////
                            CONFIG READING
    //////////////////////////////////////////////////////////////*/

    /// @notice Reads the network configuration from JSON
    function readNetworkConfig() internal view returns (NetworkConfig memory _config) {
        string memory network = getCurrentNetwork();
        string memory configPath = string.concat(getDeploymentsPath(), "/config/", network, ".json");

        string memory json = vm.readFile(configPath);

        // Read basic info
        _config.network = json.readString(".network");
        _config.chainId = json.readUint(".chainId");

        // Read roles
        _config.roles.owner = json.readAddress(".roles.owner");
        _config.roles.admin = json.readAddress(".roles.admin");
        _config.roles.relayer = json.readAddress(".roles.relayer");

        // Read KAM addresses
        _config.kam.registry = json.readAddress(".kam.registry");
    }

    /*//////////////////////////////////////////////////////////////
                            OUTPUT READING
    //////////////////////////////////////////////////////////////*/

    /// @notice Reads the deployment output from JSON
    function readDeploymentOutput() internal view returns (DeploymentOutput memory _output) {
        string memory network = getCurrentNetwork();
        string memory outputPath = string.concat(getDeploymentsPath(), "/output/", network, "/addresses.json");

        try vm.readFile(outputPath) returns (string memory json) {
            if (bytes(json).length == 0) return _output;

            _output.chainId = json.readUint(".chainId");
            _output.network = json.readString(".network");
            _output.timestamp = json.readUint(".timestamp");

            // Read settler address if it exists
            if (_keyExists(json, ".contracts.settler")) {
                _output.settler = json.readAddress(".contracts.settler");
            }
        } catch {
            // File doesn't exist, return empty struct
        }
    }

    /// @notice Checks if a key exists in JSON
    function _keyExists(string memory _json, string memory _key) internal pure returns (bool) {
        try vm.parseJsonAddress(_json, _key) returns (address) {
            return true;
        } catch {
            return false;
        }
    }

    /*//////////////////////////////////////////////////////////////
                            OUTPUT WRITING
    //////////////////////////////////////////////////////////////*/

    /// @notice Writes a contract address to the deployment output
    function writeContractAddress(string memory _contractName, address _contractAddress) internal {
        DeploymentOutput memory output = readDeploymentOutput();

        // Update the struct based on contract name
        if (_isEqual(_contractName, "settler")) {
            output.settler = _contractAddress;
        }

        // Update metadata
        output.chainId = block.chainid;
        output.network = getCurrentNetwork();
        output.timestamp = block.timestamp;

        // Write to file
        _writeDeploymentOutput(output);
    }

    /// @notice Serializes and writes the deployment output to JSON
    function _writeDeploymentOutput(DeploymentOutput memory _output) internal {
        string memory network = getCurrentNetwork();
        string memory outputPath = string.concat(getDeploymentsPath(), "/output/", network, "/addresses.json");

        string memory json = _serializeDeploymentOutput(_output);
        vm.writeFile(outputPath, json);
    }

    /// @notice Serializes the deployment output struct to JSON string
    function _serializeDeploymentOutput(DeploymentOutput memory _output) internal pure returns (string memory) {
        string memory json = "{\n";
        json = string.concat(json, '  "chainId": ', vm.toString(_output.chainId), ",\n");
        json = string.concat(json, '  "network": "', _output.network, '",\n');
        json = string.concat(json, '  "timestamp": ', vm.toString(_output.timestamp), ",\n");
        json = string.concat(json, '  "contracts": {\n');
        json = string.concat(json, '    "settler": "', vm.toString(_output.settler), '"\n');
        json = string.concat(json, "  }\n");
        json = string.concat(json, "}");
        return json;
    }

    /// @notice String equality check
    function _isEqual(string memory _a, string memory _b) internal pure returns (bool) {
        return keccak256(bytes(_a)) == keccak256(bytes(_b));
    }

    /*//////////////////////////////////////////////////////////////
                            LOGGING UTILITIES
    //////////////////////////////////////////////////////////////*/

    /// @notice Logs the script header with network info
    function logScriptHeader(string memory _scriptName) internal view {
        console.log("");
        console.log("========================================");
        console.log("  Script:", _scriptName);
        console.log("========================================");
        console.log("  Network:", getCurrentNetwork());
        console.log("  Chain ID:", block.chainid);
        console.log("  Config:", string.concat(getDeploymentsPath(), "/config/", getCurrentNetwork(), ".json"));
        console.log(
            "  Output:", string.concat(getDeploymentsPath(), "/output/", getCurrentNetwork(), "/addresses.json")
        );
        console.log("========================================");
        console.log("");
    }

    /// @notice Logs role addresses
    function logRoles(NetworkConfig memory _config) internal pure {
        console.log("Roles:");
        console.log("  Owner:", _config.roles.owner);
        console.log("  Admin:", _config.roles.admin);
        console.log("  Relayer:", _config.roles.relayer);
        console.log("");
    }

    /// @notice Logs KAM addresses
    function logKamAddresses(NetworkConfig memory _config) internal pure {
        console.log("KAM Protocol:");
        console.log("  Registry:", _config.kam.registry);
        console.log("  kMinter:", _config.kam.kMinter);
        console.log("  kAssetRouter:", _config.kam.kAssetRouter);
        console.log("");
    }

    /// @notice Logs the broadcaster address
    function logBroadcaster(address _broadcaster) internal pure {
        console.log("Broadcaster:", _broadcaster);
        console.log("");
    }

    /// @notice Logs execution start
    function logExecutionStart() internal pure {
        console.log("----------------------------------------");
        console.log("  EXECUTING TRANSACTIONS");
        console.log("----------------------------------------");
        console.log("");
    }

    /// @notice Logs execution end
    function logExecutionEnd() internal pure {
        console.log("");
        console.log("----------------------------------------");
        console.log("  EXECUTION COMPLETE");
        console.log("----------------------------------------");
        console.log("");
    }

    /// @notice Logs a deployed contract
    function logDeployedContract(string memory _name, address _address) internal pure {
        console.log("  Deployed", _name, "at:", _address);
    }

    /*//////////////////////////////////////////////////////////////
                            VALIDATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Validates the network config
    function validateConfig(NetworkConfig memory _config) internal view {
        require(_config.chainId == block.chainid, "Chain ID mismatch");
        require(_config.roles.owner != address(0), "Owner address is zero");
        require(_config.roles.admin != address(0), "Admin address is zero");
        require(_config.roles.relayer != address(0), "Relayer address is zero");
        require(_config.kam.registry != address(0), "Registry address is zero");
    }
}
