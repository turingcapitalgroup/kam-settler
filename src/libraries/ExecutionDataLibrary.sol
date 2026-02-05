// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import { IERC20 } from "forge-std/interfaces/IERC20.sol";
import { IERC7540 } from "kam/src/interfaces/IERC7540.sol";
import { Execution } from "minimal-smart-account/interfaces/IMinimalSmartAccount.sol";

/// @title ExecutionDataLibrary
/// @notice Pure functions for generating Execution arrays for token operations
/// @dev Generates calldata for ERC20 transfers, ERC7540 deposits and redemptions
///      executed through vault adapters via the MinimalSmartAccount interface.
library ExecutionDataLibrary {
    /// @notice Generates execution data for a standard ERC20 transfer
    /// @param _target The token contract address
    /// @param _to The recipient address
    /// @param _amount The amount to transfer
    /// @return _executions Array containing a single transfer Execution
    function getTransferExecutionData(
        address _target,
        address _to,
        uint256 _amount
    )
        internal
        pure
        returns (Execution[] memory _executions)
    {
        _executions = new Execution[](1);
        _executions[0] = Execution({
            target: _target, value: 0, callData: abi.encodeWithSelector(IERC20.transfer.selector, _to, _amount)
        });
    }

    /// @notice Generates execution data for a standard ERC20 transferFrom
    /// @param _target The token contract address
    /// @param _from The address to transfer from
    /// @param _to The recipient address
    /// @param _amount The amount to transfer
    /// @return _executions Array containing a single transferFrom Execution
    function getTransferFromExecutionData(
        address _target,
        address _from,
        address _to,
        uint256 _amount
    )
        internal
        pure
        returns (Execution[] memory _executions)
    {
        _executions = new Execution[](1);
        _executions[0] = Execution({
            target: _target,
            value: 0,
            callData: abi.encodeWithSelector(IERC20.transferFrom.selector, _from, _to, _amount)
        });
    }

    /// @notice Generates execution data for an ERC7540 requestRedeem
    /// @param _target The ERC7540 vault contract address
    /// @param _controller The controller for the redeem request
    /// @param _owner The owner of the shares to redeem
    /// @param _shares The amount of shares to request for redemption
    /// @return _executions Array containing a single requestRedeem Execution
    function getRequestRedeemExecutionData(
        address _target,
        address _controller,
        address _owner,
        uint256 _shares
    )
        internal
        pure
        returns (Execution[] memory _executions)
    {
        _executions = new Execution[](1);
        _executions[0] = Execution({
            target: _target,
            value: 0,
            callData: abi.encodeWithSelector(IERC7540.requestRedeem.selector, _shares, _controller, _owner)
        });
    }

    /// @notice Generates execution data for an ERC7540 redeem
    /// @param _target The ERC7540 vault contract address
    /// @param _receiver The address that will receive the assets
    /// @param _controller The controller address
    /// @param _shares The amount of shares to redeem
    /// @return _executions Array containing a single redeem Execution
    function getRedeemExecutionData(
        address _target,
        address _receiver,
        address _controller,
        uint256 _shares
    )
        internal
        pure
        returns (Execution[] memory _executions)
    {
        _executions = new Execution[](1);
        _executions[0] = Execution({
            target: _target,
            value: 0,
            callData: abi.encodeWithSelector(IERC7540.redeem.selector, _shares, _receiver, _controller)
        });
    }

    /// @notice Generates execution data for an ERC7540 deposit (requestDeposit + deposit)
    /// @param _target The ERC7540 vault contract address
    /// @param _receiver The address that will receive the shares
    /// @param _controller The controller address
    /// @param _assets The amount of assets to deposit
    /// @return _executions Array containing two Execution structs for requestDeposit and deposit
    function getDepositExecutionData(
        address _target,
        address _receiver,
        address _controller,
        uint256 _assets
    )
        internal
        pure
        returns (Execution[] memory _executions)
    {
        _executions = new Execution[](2);

        _executions[0] = Execution({
            target: _target,
            value: 0,
            callData: abi.encodeWithSelector(IERC7540.requestDeposit.selector, _assets, _controller, _receiver)
        });

        _executions[1] = Execution({
            target: _target,
            value: 0,
            callData: abi.encodeWithSignature("deposit(uint256,address,address)", _assets, _receiver, _controller)
        });
    }
}
