// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import { IERC20 } from "../interfaces/IERC20.sol";
import { IERC7540 } from "../interfaces/IERC7540.sol";
import { Execution } from "minimal-smart-account/interfaces/IMinimalSmartAccount.sol";

/**
 * @title ExecutionDataLibrary
 * @notice Library containing execution data generation functions for various token operations
 * @dev This library provides pure functions to generate Execution arrays for token transfers,
 *      redeem requests, and other operations that can be executed through vault adapters using
 *      the MinimalSmartAccount interface.
 */
library ExecutionDataLibrary {
    /**
     * @notice Generates execution data for a standard ERC20 transfer operation
     * @dev Creates a single Execution struct for executing a transfer
     * @param target The address of the token contract to transfer from
     * @param to The address to transfer tokens to
     * @param amount The amount of tokens to transfer
     * @return executions Array containing a single Execution struct
     */
    function getTransferExecutionData(
        address target,
        address to,
        uint256 amount
    )
        internal
        pure
        returns (Execution[] memory executions)
    {
        executions = new Execution[](1);
        executions[0] = Execution({
            target: target, value: 0, callData: abi.encodeWithSelector(IERC20.transfer.selector, to, amount)
        });
    }

    /**
     * @notice Generates execution data for a standard ERC20 transferFrom operation
     * @dev Creates a single Execution struct for executing a transferFrom
     * @param target The address of the token contract to transfer from
     * @param from The address to transfer tokens from
     * @param to The address to transfer tokens to
     * @param amount The amount of tokens to transfer
     * @return executions Array containing a single Execution struct
     */
    function getTransferFromExecutionData(
        address target,
        address from,
        address to,
        uint256 amount
    )
        internal
        pure
        returns (Execution[] memory executions)
    {
        executions = new Execution[](1);
        executions[0] = Execution({
            target: target, value: 0, callData: abi.encodeWithSelector(IERC20.transferFrom.selector, from, to, amount)
        });
    }

    /**
     * @notice Generates execution data for an ERC7540 requestRedeem operation
     * @dev Creates a single Execution struct for executing a redeem request
     * @param target The address of the ERC7540 vault contract
     * @param controller The address of the controller for the redeem request
     * @param owner The address of the owner of the shares to be redeemed
     * @param shares The amount of shares to request for redemption
     * @return executions Array containing a single Execution struct
     */
    function getRequestRedeemExecutionData(
        address target,
        address controller,
        address owner,
        uint256 shares
    )
        internal
        pure
        returns (Execution[] memory executions)
    {
        executions = new Execution[](1);
        executions[0] = Execution({
            target: target,
            value: 0,
            callData: abi.encodeWithSelector(IERC7540.requestRedeem.selector, shares, controller, owner)
        });
    }

    /**
     * @notice Generates execution data for an ERC7540 redeem operation
     * @dev Creates a single Execution struct for executing a redeem
     * @param target The address of the ERC7540 vault contract
     * @param receiver The address that will receive the assets
     * @param controller The address of the controller
     * @param shares The amount of shares to redeem
     * @return executions Array containing a single Execution struct
     */
    function getRedeemExecutionData(
        address target,
        address receiver,
        address controller,
        uint256 shares
    )
        internal
        pure
        returns (Execution[] memory executions)
    {
        executions = new Execution[](1);
        executions[0] = Execution({
            target: target,
            value: 0,
            callData: abi.encodeWithSelector(IERC7540.redeem.selector, shares, receiver, controller)
        });
    }

    /**
     * @notice Generates execution data for an ERC7540 deposit operation
     * @dev Creates two Execution structs: one for requestDeposit and one for deposit
     * @param target The address of the ERC7540 vault contract
     * @param receiver The address that will receive the shares
     * @param controller The address of the controller
     * @param assets The amount of assets to deposit
     * @return executions Array containing two Execution structs for requestDeposit and deposit
     */
    function getDepositExecutionData(
        address target,
        address receiver,
        address controller,
        uint256 assets
    )
        internal
        pure
        returns (Execution[] memory executions)
    {
        executions = new Execution[](2);

        // First execution: requestDeposit
        executions[0] = Execution({
            target: target,
            value: 0,
            callData: abi.encodeWithSelector(IERC7540.requestDeposit.selector, assets, controller, receiver)
        });

        // Second execution: deposit
        executions[1] = Execution({
            target: target,
            value: 0,
            callData: abi.encodeWithSignature("deposit(uint256,address,address)", assets, receiver, controller)
        });
    }
}
