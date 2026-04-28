// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

// kSettler Error Constants
// Centralized error string constants for the kSettler protocol.
// Error codes follow the pattern: KS{number}
//   KS1 - Batch already closed
//   KS2 - Batch already settled
//   KS3 - Address is zero
//   KS4 - Netted assets are positive
//   KS5 - Insufficient balance
//   KS6 - Invalid profit share basis points
//   KS7 - Invalid vault type for operation
//   KS8 - Proposal not executed
//   KS9 - Invalid target type
//   KS10 - Missing MetaWallet approval from kMinterAdapter to vaultAdapter
//   KS11 - Proposal already finalised
//   KS12 - Metawallet asset does not match _asset argument

string constant KSETTLER_BATCH_ALREADY_CLOSED = "KS1";
string constant KSETTLER_BATCH_ALREADY_SETTLED = "KS2";
string constant KSETTLER_ADDRESS_ZERO = "KS3";
string constant KSETTLER_NETTED_ASSETS_POSITIVE = "KS4";
string constant KSETTLER_INSUFFICIENT_BALANCE = "KS5";
string constant KSETTLER_INVALID_PROFIT_SHARE_BPS = "KS6";
string constant KSETTLER_INVALID_VAULT_TYPE = "KS7";
string constant KSETTLER_PROPOSAL_NOT_EXECUTED = "KS8";
string constant KSETTLER_INVALID_TARGET_TYPE = "KS9";
string constant KSETTLER_MISSING_ALLOWANCE = "KS10";
string constant KSETTLER_PROPOSAL_ALREADY_FINALISED = "KS11";
string constant KSETTLER_ASSET_MISMATCH = "KS12";
