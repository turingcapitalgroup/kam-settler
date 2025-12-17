// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import { SettlerSetUp } from "./helpers/SettlerSetUp.t.sol";

contract SettlerInvariants is SettlerSetUp {
    function setUp() public override {
        _setUp();
        _setUpSettler();
        _setUpSettlerHandler();
        _setUnlimitedBatchLimits();
        _setMaxTotalAssets();
        _setUpVaultFees(dnVault);
        _setUpInstitutionalMint();
    }

    function invariant_SETTLER_MinterTotalLockedAssets() public view {
        settlerHandler.INVARIANT_MINTER_TOTAL_LOCKED_ASSETS();
    }

    function invariant_SETTLER_MinterAdapterBalance() public view {
        settlerHandler.INVARIANT_MINTER_ADAPTER_BALANCE();
    }

    function invariant_SETTLER_MinterAdapterTotalAssets() public view {
        settlerHandler.INVARIANT_MINTER_ADAPTER_TOTAL_ASSETS();
    }

    function invariant_SETTLER_DNTotalAssets() public view {
        settlerHandler.INVARIANT_DN_TOTAL_ASSETS();
    }

    function invariant_SETTLER_DNAdapterTotalAssets() public view {
        settlerHandler.INVARIANT_DN_ADAPTER_TOTAL_ASSETS();
    }

    function invariant_SETTLER_DNSharePrice() public view {
        settlerHandler.INVARIANT_DN_SHARE_PRICE();
    }

    function invariant_SETTLER_DNTotalNetAssets() public view {
        settlerHandler.INVARIANT_DN_TOTAL_NET_ASSETS();
    }

    function invariant_SETTLER_DNSupply() public view {
        settlerHandler.INVARIANT_DN_SUPPLY();
    }

    function invariant_SETTLER_DNSharePriceDelta() public view {
        settlerHandler.INVARIANT_DN_SHARE_PRICE_DELTA();
    }
}
