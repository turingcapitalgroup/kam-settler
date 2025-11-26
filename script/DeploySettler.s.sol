// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import { Script } from "forge-std/Script.sol";
import { console2 as console } from "forge-std/console2.sol";

import { Settler } from "src/Settler.sol";
import { IkRegistry } from "src/interfaces/IkRegistry.sol";

interface Roles {
    function grantRelayerRole(address relayer_) external payable;
    function grantManagerRole(address manager_) external payable;
}

contract DeploySettlerScript is Script {
    // forge script src/contracts/script/DeploySettler.sol:DeploySettlerScript --rpc-url sepolia --sig "run(address)"
    // <ADD_REGISTRY_ADDRESS>
    function run(address registry, address owner, address admin, address relayer) public {
        deploySettler(registry, owner, admin, relayer);
    }

    function deploySettler(address registry, address owner, address admin, address relayer) public {
        vm.startBroadcast();
        (address kMinter, address kAssetRouter) = IkRegistry(registry).getCoreContracts();

        Settler settler = new Settler(owner, admin, relayer, kMinter, kAssetRouter, registry);
        Roles(registry).grantRelayerRole(address(settler));
        Roles(registry).grantManagerRole(address(settler));
        vm.stopBroadcast();
        console.log("Settler deployed to", address(settler));
    }
}
