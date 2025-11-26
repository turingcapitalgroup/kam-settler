// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import { IProcessRouterModule } from "./IProcessRouterModule.sol";
import { IkRegistry } from "./IkRegistry.sol";
import { IAdapterGuardian } from "./modules/IAdapterGuardian.sol";
import { IVaultReader } from "./modules/IVaultReader.sol";

interface IRegistry is IkRegistry, IVaultReader, IAdapterGuardian, IProcessRouterModule { }
