// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import { IERC20 } from "forge-std/interfaces/IERC20.sol";
import { IERC4626 } from "metawallet/src/interfaces/IERC4626.sol";
import { Execution } from "minimal-smart-account/interfaces/IMinimalSmartAccount.sol";

/// @title ExecutionDataLibrary
/// @notice Pure functions for generating Execution arrays for token operations
/// @dev Generates calldata for ERC20 transfers, ERC4626 deposits and redemptions
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

    /// @notice Generates execution data for an ERC4626 redeem
    /// @param _target The ERC4626 vault contract address
    /// @param _receiver The address that will receive the assets
    /// @param _owner The owner of the shares
    /// @param _shares The amount of shares to redeem
    /// @return _executions Array containing a single redeem Execution
    function getWithdrawExecutionData(
        address _target,
        address _receiver,
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
            callData: abi.encodeWithSelector(IERC4626.redeem.selector, _shares, _receiver, _owner)
        });
    }

    /// @notice Generates execution data for an ERC4626 deposit
    /// @param _target The ERC4626 vault contract address
    /// @param _receiver The address that will receive the shares
    /// @param _assets The amount of assets to deposit
    /// @return _executions Array containing a single deposit Execution
    function getDepositExecutionData(
        address _target,
        address _receiver,
        uint256 _assets
    )
        internal
        pure
        returns (Execution[] memory _executions)
    {
        _executions = new Execution[](1);

        _executions[0] = Execution({
            target: _target, value: 0, callData: abi.encodeWithSelector(IERC4626.deposit.selector, _assets, _receiver)
        });
    }
}
