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

string constant KSETTLER_BATCH_ALREADY_CLOSED = "KS1";
string constant KSETTLER_BATCH_ALREADY_SETTLED = "KS2";
string constant KSETTLER_ADDRESS_ZERO = "KS3";
string constant KSETTLER_NETTED_ASSETS_POSITIVE = "KS4";
string constant KSETTLER_INSUFFICIENT_BALANCE = "KS5";
string constant KSETTLER_INVALID_PROFIT_SHARE_BPS = "KS6";
