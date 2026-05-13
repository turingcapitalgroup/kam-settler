// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import { BaseHandler } from "kam/test/invariant/handlers/BaseHandler.t.sol";
import { AddressSet, LibAddressSet } from "kam/test/invariant/helpers/AddressSet.sol";
import { Bytes32Set, LibBytes32Set } from "kam/test/invariant/helpers/Bytes32Set.sol";
import { OptimizedFixedPointMathLib } from "solady/utils/OptimizedFixedPointMathLib.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";

import { IVaultAdapter } from "kam/src/interfaces/IVaultAdapter.sol";
import { IkAssetRouter } from "kam/src/interfaces/IkAssetRouter.sol";
import { IkMinter } from "kam/src/interfaces/IkMinter.sol";
import { IkStakingVault } from "kam/src/interfaces/IkStakingVault.sol";
import { BaseVaultTypes } from "kam/src/kStakingVault/types/BaseVaultTypes.sol";
import { IERC4626 } from "metawallet/src/interfaces/IERC4626.sol";
import { kSettler } from "src/kSettler.sol";

contract kSettlerHandler is BaseHandler {
    using OptimizedFixedPointMathLib for int256;
    using OptimizedFixedPointMathLib for uint256;
    using SafeTransferLib for address;
    using LibBytes32Set for Bytes32Set;
    using LibAddressSet for AddressSet;

    // Core contracts
    kSettler settler;
    IkMinter kMinter;
    IkStakingVault dnVault;
    IkAssetRouter assetRouter;
    IVaultAdapter minterAdapter;
    IVaultAdapter dnVaultAdapter;
    IERC4626 metawallet;

    // State
    address token;
    address kToken;
    address relayer;
    address guardian;
    AddressSet minterActors;
    AddressSet vaultActors;

    // Request tracking
    mapping(address actor => Bytes32Set pendingRequestIds) actorStakeRequests;
    mapping(address actor => Bytes32Set pendingRequestIds) actorUnstakeRequests;
    mapping(address actor => Bytes32Set pendingRequestIds) actorBurnRequests;

    // Batch tracking
    mapping(bytes32 batchId => uint256) depositedInBatch;
    mapping(bytes32 batchId => uint256) requestedInBatch;
    mapping(bytes32 batchId => int256 yieldInBatch) totalYieldInBatch;
    mapping(bytes32 batchId => uint256 pendingStake) pendingStakeInBatch;

    Bytes32Set pendingMinterUnsettledBatches;
    Bytes32Set pendingMinterSettlementProposals;
    Bytes32Set pendingDNUnsettledBatches;
    Bytes32Set pendingDNSettlementProposals;

    // //////////////////////////////////////////////////////////////
    // / GHOST VARS ///
    // //////////////////////////////////////////////////////////////

    // Minter ghost vars
    int256 public minterNettedInBatch;
    int256 public minterTotalNetted;
    uint256 public minterExpectedTotalLockedAssets;
    uint256 public minterActualTotalLockedAssets;
    uint256 public minterExpectedAdapterBalance;
    uint256 public minterActualAdapterBalance;
    uint256 public minterExpectedAdapterTotalAssets;
    uint256 public minterActualAdapterTotalAssets;

    // DN Vault ghost vars
    uint256 public dnExpectedTotalAssets;
    uint256 public dnActualTotalAssets;
    uint256 public dnExpectedNetTotalAssets;
    uint256 public dnActualNetTotalAssets;
    uint256 public dnExpectedAdapterTotalAssets;
    uint256 public dnActualAdapterTotalAssets;
    uint256 public dnExpectedAdapterBalance;
    uint256 public dnActualAdapterBalance;
    uint256 public dnExpectedSupply;
    uint256 public dnActualSupply;
    uint256 public dnExpectedSharePrice;
    uint256 public dnActualSharePrice;
    int256 public dnSharePriceDelta;

    constructor(
        address _settler,
        address _kMinter,
        address _dnVault,
        address _assetRouter,
        address _minterAdapter,
        address _dnVaultAdapter,
        address _metawallet,
        address _token,
        address _kToken,
        address _relayer,
        address _guardian,
        address[] memory _minterActors,
        address[] memory _vaultActors
    )
        BaseHandler(_vaultActors)
    {
        settler = kSettler(_settler);
        kMinter = IkMinter(_kMinter);
        dnVault = IkStakingVault(_dnVault);
        assetRouter = IkAssetRouter(_assetRouter);
        minterAdapter = IVaultAdapter(_minterAdapter);
        dnVaultAdapter = IVaultAdapter(_dnVaultAdapter);
        metawallet = IERC4626(_metawallet);
        token = _token;
        kToken = _kToken;
        relayer = _relayer;
        guardian = _guardian;

        for (uint256 i = 0; i < _minterActors.length; i++) {
            minterActors.add(_minterActors[i]);
        }
    }

    // //////////////////////////////////////////////////////////////
    // / HELPERS ///
    // //////////////////////////////////////////////////////////////

    function getEntryPoints() public pure override returns (bytes4[] memory) {
        bytes4[] memory _entryPoints = new bytes4[](10);
        _entryPoints[0] = this.settler_mint.selector;
        _entryPoints[1] = this.settler_requestBurn.selector;
        _entryPoints[2] = this.settler_burn.selector;
        _entryPoints[3] = this.settler_closeMinterBatch.selector;
        _entryPoints[4] = this.settler_executeSettleBatch.selector;
        _entryPoints[5] = this.settler_requestStake.selector;
        _entryPoints[6] = this.settler_requestUnstake.selector;
        _entryPoints[7] = this.settler_closeAndProposeDNVaultBatch.selector;
        _entryPoints[8] = this.settler_claimStakedShares.selector;
        _entryPoints[9] = this.settler_claimUnstakedAssets.selector;
        return _entryPoints;
    }

    // //////////////////////////////////////////////////////////////
    // / MINTER OPERATIONS ///
    // //////////////////////////////////////////////////////////////

    function settler_mint(uint256 actorSeed, uint256 amount) public {
        address actor = minterActors.rand(actorSeed);
        vm.startPrank(actor);
        amount = bound(amount, 0, token.balanceOf(actor));
        if (amount == 0) {
            vm.stopPrank();
            return;
        }
        token.safeApprove(address(kMinter), amount);
        kMinter.mint(token, actor, amount);
        vm.stopPrank();

        minterExpectedTotalLockedAssets += amount;
        minterActualTotalLockedAssets = kMinter.getTotalLockedAssets(token);

        minterExpectedAdapterBalance += amount;
        minterActualAdapterBalance = token.balanceOf(address(minterAdapter));

        minterActualAdapterTotalAssets = minterAdapter.totalAssets();
        minterNettedInBatch += int256(amount);
        minterTotalNetted += int256(amount);
    }

    function settler_requestBurn(uint256 actorSeed, uint256 amount) public {
        address actor = minterActors.rand(actorSeed);
        vm.startPrank(actor);
        amount = bound(amount, 0, kToken.balanceOf(actor));
        if (amount == 0) {
            vm.stopPrank();
            return;
        }
        kToken.safeApprove(address(kMinter), amount);

        // Mirror kAssetRouter.kAssetRequestPull -> _checkSufficientVirtualBalance.
        // Verified against dependencies/kam-v1/src/kAssetRouter.sol:186-189 and 814-819, and
        // dependencies/kam-v1/test/invariant/handlers/kMinterHandler.t.sol:110-141.
        // The router checks cross-batch global pending requests, adjusted by netting of all open
        // proposals. Per-batch `requestedSharesInBatch` is insufficient.
        if (_willRequestBurnRevert(amount)) {
            vm.expectRevert();
            kMinter.requestBurn(token, actor, amount);
            vm.stopPrank();
            return;
        }
        bytes32 requestId = kMinter.requestBurn(token, actor, amount);
        vm.stopPrank();

        actorBurnRequests[actor].add(requestId);
        minterActualTotalLockedAssets = kMinter.getTotalLockedAssets(token);
        minterActualAdapterBalance = token.balanceOf(address(minterAdapter));
        minterActualAdapterTotalAssets = minterAdapter.totalAssets();
        minterNettedInBatch -= int256(amount);
        minterTotalNetted -= int256(amount);
    }

    /// @notice Predicts whether `kMinter.requestBurn(token, _, amount)` would revert with A6
    /// @dev Mirrors `kAssetRouter._checkSufficientVirtualBalance` semantics: virtual balance
    ///      adjusted by signed netting of every pending proposal must cover the global pending
    ///      request total after adding `amount`.
    function _willRequestBurnRevert(uint256 amount) internal view returns (bool) {
        uint256 virtualBal = assetRouter.virtualBalance(address(kMinter), token);
        uint256 globalPending = assetRouter.getGlobalPendingRequests(address(kMinter), token);
        uint256 totalRequested = globalPending + amount;

        int256 virtualBalInt = int256(virtualBal);
        if (assetRouter.getPendingProposalCount(address(kMinter)) > 0) {
            bytes32[] memory pendingProposals = assetRouter.getPendingProposals(address(kMinter));
            for (uint256 i = 0; i < pendingProposals.length; i++) {
                IkAssetRouter.VaultSettlementProposal memory openProposal =
                    assetRouter.getSettlementProposal(pendingProposals[i]);
                if (openProposal.asset == token) {
                    virtualBalInt += openProposal.netted;
                }
            }
        }
        if (virtualBalInt < 0) return true;
        return uint256(virtualBalInt) < totalRequested;
    }

    function settler_burn(uint256 actorSeed, uint256 requestSeedIndex) public {
        address actor = minterActors.rand(actorSeed);
        vm.startPrank(actor);
        if (actorBurnRequests[actor].count() == 0) {
            vm.stopPrank();
            return;
        }
        bytes32 requestId = actorBurnRequests[actor].rand(requestSeedIndex);
        actorBurnRequests[actor].remove(requestId);
        uint256 amount = kMinter.getBurnRequest(requestId).amount;
        address batchReceiver = kMinter.getBatchReceiver(kMinter.getBurnRequest(requestId).batchId);
        if (token.balanceOf(batchReceiver) == 0) {
            vm.expectRevert();
            kMinter.burn(requestId);
            vm.stopPrank();
            return;
        }
        kMinter.burn(requestId);
        vm.stopPrank();

        // NOTE: kMinter.burn() does NOT mutate $.totalLockedAssets on-chain (verified against
        // dependencies/kam-v1/src/kMinter.sol:224-262). The decrement of locked assets happens
        // exclusively in kMinter.settleBatch() during executeSettleBatch — tracked there.
        // Therefore the expected total stays unchanged here; just refresh the actual reading.
        amount; // silence unused local: kept for parity with `kMinter.getBurnRequest(_).amount`
        minterActualTotalLockedAssets = kMinter.getTotalLockedAssets(token);
        minterActualAdapterBalance = token.balanceOf(address(minterAdapter));
        minterActualAdapterTotalAssets = minterAdapter.totalAssets();
    }

    function settler_closeMinterBatch() public {
        vm.startPrank(relayer);
        bytes32 batchId = kMinter.getBatchId(token);
        if (pendingMinterUnsettledBatches.count() != 0) {
            vm.stopPrank();
            return;
        }
        if (batchId == bytes32(0)) {
            vm.stopPrank();
            return;
        }
        if (pendingMinterUnsettledBatches.contains(batchId)) {
            vm.stopPrank();
            return;
        }

        // Record balance before closing
        uint256 balanceBefore = token.balanceOf(address(minterAdapter));

        // Use settler to close batch - may fail if virtual balance is insufficient
        try settler.closeAndProposeMinterBatch(token) returns (bytes32 proposalId) {
            pendingMinterUnsettledBatches.add(batchId);
            if (proposalId != bytes32(0)) {
                pendingMinterSettlementProposals.add(proposalId);
            }
        } catch {
            vm.stopPrank();
            return;
        }
        vm.stopPrank();

        // Use actual balance change to account for precision in share math
        uint256 balanceAfter = token.balanceOf(address(minterAdapter));
        if (balanceBefore > balanceAfter) {
            // Positive netting case: tokens deposited to metawallet
            minterExpectedAdapterBalance -= (balanceBefore - balanceAfter);
        } else if (balanceAfter > balanceBefore) {
            // Negative netting case: tokens redeemed from metawallet (sync settlement)
            minterExpectedAdapterBalance += (balanceAfter - balanceBefore);
        }

        minterNettedInBatch = 0;
        minterActualAdapterBalance = balanceAfter;
        minterActualAdapterTotalAssets = minterAdapter.totalAssets();
    }

    function settler_executeSettleBatch() public {
        // First try minter settlements
        if (pendingMinterSettlementProposals.count() != 0) {
            bytes32 proposalId = pendingMinterSettlementProposals.at(0);
            IkAssetRouter.VaultSettlementProposal memory proposal = assetRouter.getSettlementProposal(proposalId);

            // Record balance before settlement
            uint256 balanceBefore = token.balanceOf(address(minterAdapter));

            // Accept proposal if it requires approval
            if (proposal.requiresApproval && !assetRouter.isProposalAccepted(proposalId)) {
                vm.prank(guardian);
                assetRouter.acceptProposal(proposalId);
            }

            vm.startPrank(relayer);
            try settler.executeSettleBatch(proposalId) {
                pendingMinterSettlementProposals.remove(proposalId);
                pendingMinterUnsettledBatches.remove(proposal.batchId);

                minterExpectedAdapterTotalAssets = proposal.totalAssets;
                // Use actual balance change to account for precision
                uint256 balanceAfter = token.balanceOf(address(minterAdapter));
                uint256 actualTransferred = balanceBefore - balanceAfter;
                minterExpectedAdapterBalance -= actualTransferred;
                minterActualAdapterBalance = balanceAfter;
                minterActualAdapterTotalAssets = minterAdapter.totalAssets();

                // kMinter.settleBatch() (called by router.executeSettleBatch) decrements
                // $.totalLockedAssets by `requestedSharesInBatch`. Mirror it.
                // Verified against dependencies/kam-v1/src/kMinter.sol:308-309 and
                // dependencies/kam-v1/test/invariant/handlers/kMinterHandler.t.sol:289-292.
                minterExpectedTotalLockedAssets -= kMinter.getBatchInfo(proposal.batchId).requestedSharesInBatch;
                minterActualTotalLockedAssets = kMinter.getTotalLockedAssets(token);
            } catch {
                // Settlement failed - skip this proposal
            }
            vm.stopPrank();
            return;
        }

        // Then try DN vault settlements
        if (pendingDNSettlementProposals.count() != 0) {
            bytes32 proposalId = pendingDNSettlementProposals.at(0);
            IkAssetRouter.VaultSettlementProposal memory proposal = assetRouter.getSettlementProposal(proposalId);
            uint256 totalRequestedShares = assetRouter.getRequestedShares(address(dnVault), proposal.batchId);
            int256 netted = proposal.netted;

            // Record minter adapter balance before DN settlement
            uint256 minterBalanceBefore = token.balanceOf(address(minterAdapter));

            // Accept proposal if it requires approval
            if (proposal.requiresApproval && !assetRouter.isProposalAccepted(proposalId)) {
                vm.prank(guardian);
                assetRouter.acceptProposal(proposalId);
            }

            vm.startPrank(relayer);
            try settler.executeSettleBatch(proposalId) {
            // Settlement succeeded - continue with state tracking
            }
            catch {
                // Settlement failed - skip this proposal
                vm.stopPrank();
                return;
            }
            vm.stopPrank();

            pendingDNSettlementProposals.remove(proposalId);
            pendingDNUnsettledBatches.remove(proposal.batchId);

            dnExpectedAdapterTotalAssets = proposal.totalAssets;
            dnActualAdapterTotalAssets = assetRouter.virtualBalance(address(dnVault), token);

            // dnExpectedTotalAssets tracks the vault's totalAssets() which excludes pending stake deposits
            // netted = deposited - requested (in kToken terms)
            // pendingStakeInBatch = kTokens deposited via requestStake but not yet claimed
            // When shares are claimed later, claimStakedShares will add kTokenAmount to dnExpectedTotalAssets
            // So here we subtract pendingStake to avoid double counting
            dnExpectedTotalAssets = uint256(
                int256(dnExpectedTotalAssets) + netted + proposal.yield - int256(pendingStakeInBatch[proposal.batchId])
            );

            (,,,, uint256 totalAssets,,,) = dnVault.getBatchIdInfo(proposal.batchId);
            uint256 totalNetAssets = totalAssets;
            uint256 expectedSharesToBurn;
            if (totalRequestedShares != 0) {
                uint256 netRequestedShares = totalRequestedShares.fullMulDiv(totalNetAssets, totalAssets);
                expectedSharesToBurn = totalRequestedShares - netRequestedShares;
            }

            dnExpectedSupply -= expectedSharesToBurn;
            dnActualTotalAssets = dnVault.totalAssets();
            dnExpectedNetTotalAssets = dnExpectedTotalAssets;
            dnActualNetTotalAssets = dnVault.totalAssets();

            uint256 shares = 10 ** dnVault.decimals();
            uint256 totalSupply_ = dnVault.totalSupply();
            dnActualSupply = totalSupply_;
            if (totalSupply_ == 0) {
                dnExpectedSharePrice = shares;
            } else {
                dnExpectedSharePrice = shares.fullMulDiv(dnExpectedTotalAssets, totalSupply_);
            }
            dnActualAdapterBalance = metawallet.balanceOf(address(dnVaultAdapter));
            dnActualSharePrice = dnVault.sharePrice();

            // Update minter adapter tracking
            uint256 oldExpectedAdapterTotalAssets = minterExpectedAdapterTotalAssets;
            uint256 newExpectedAdapterTotalAssets = uint256(int256(oldExpectedAdapterTotalAssets) - netted);
            minterExpectedAdapterTotalAssets = newExpectedAdapterTotalAssets;
            minterActualAdapterTotalAssets = minterAdapter.totalAssets();
            // Use actual balance change to account for precision
            uint256 minterBalanceAfter = token.balanceOf(address(minterAdapter));
            if (minterBalanceBefore > minterBalanceAfter) {
                minterExpectedAdapterBalance -= (minterBalanceBefore - minterBalanceAfter);
            } else if (minterBalanceAfter > minterBalanceBefore) {
                minterExpectedAdapterBalance += (minterBalanceAfter - minterBalanceBefore);
            }
            minterActualAdapterBalance = minterBalanceAfter;
        }
    }

    // //////////////////////////////////////////////////////////////
    // / DN VAULT OPERATIONS ///
    // //////////////////////////////////////////////////////////////

    function settler_requestStake(uint256 actorSeed, uint256 amount) public useActor(actorSeed) {
        amount = _buyFromInstitution(actorSeed, currentActor, amount);
        vm.startPrank(currentActor);
        if (amount == 0) {
            vm.stopPrank();
            return;
        }
        // Check if stake will fail due to insufficient adapter balance
        if (minterAdapter.totalAssets() < amount) {
            vm.stopPrank();
            return;
        }
        uint256 sharePriceBefore = dnVault.sharePrice();
        kToken.safeApprove(address(dnVault), amount);
        try dnVault.requestStake(currentActor, currentActor, amount) returns (bytes32 requestId) {
            actorStakeRequests[currentActor].add(requestId);
            depositedInBatch[dnVault.getBatchId()] += amount;
            pendingStakeInBatch[dnVault.getBatchId()] += amount;
            uint256 sharePriceAfter = dnVault.sharePrice();
            dnSharePriceDelta = int256(sharePriceAfter) - int256(sharePriceBefore);
        } catch {
            // Stake failed, skip tracking
        }
        vm.stopPrank();
    }

    function _buyFromInstitution(uint256 actorSeed, address buyer, uint256 amount) internal returns (uint256) {
        address institution = minterActors.rand(actorSeed);
        uint256 kTokenBalance = kToken.balanceOf(institution);
        amount = bound(amount, 0, kTokenBalance);
        if (kTokenBalance == 0) {
            return 0;
        }
        vm.prank(institution);
        kToken.safeTransfer(buyer, amount);
        return amount;
    }

    function settler_requestUnstake(uint256 actorSeed, uint256 amount) public useActor(actorSeed) {
        vm.startPrank(currentActor);
        amount = bound(amount, 0, dnVault.balanceOf(currentActor));
        if (amount == 0) {
            vm.stopPrank();
            return;
        }
        uint256 sharePriceBefore = dnVault.sharePrice();
        requestedInBatch[dnVault.getBatchId()] += amount;
        bytes32 requestId = dnVault.requestUnstake(currentActor, currentActor, amount);
        actorUnstakeRequests[currentActor].add(requestId);
        uint256 sharePriceAfter = dnVault.sharePrice();
        dnSharePriceDelta = int256(sharePriceAfter) - int256(sharePriceBefore);
        vm.stopPrank();
    }

    function settler_closeAndProposeDNVaultBatch() public {
        bytes32 batchId = dnVault.getBatchId();
        uint256 deposited = depositedInBatch[batchId];
        uint256 requested = requestedInBatch[batchId];
        int256 yieldAmount = totalYieldInBatch[batchId];

        int256 newTotalAssetsInt = int256(dnExpectedAdapterTotalAssets) + yieldAmount;
        if (newTotalAssetsInt <= 0) return;

        uint256 newTotalAssets = uint256(newTotalAssetsInt);

        requested = dnVault.convertToAssetsWithTotals(requested, newTotalAssets, dnVault.totalSupply());
        int256 netted = int256(deposited) - int256(requested);

        if (netted < 0 && netted.abs() > dnExpectedAdapterTotalAssets) {
            return;
        }

        int256 newTotalAssetsAdjustedInt = int256(newTotalAssets) + netted;
        if (newTotalAssetsAdjustedInt <= 0) return;

        vm.startPrank(relayer);
        if (pendingDNUnsettledBatches.count() != 0) {
            vm.stopPrank();
            return;
        }
        if (batchId == bytes32(0)) {
            vm.stopPrank();
            return;
        }
        if (pendingDNUnsettledBatches.contains(batchId)) {
            vm.stopPrank();
            return;
        }

        // Use settler to close and propose DN vault batch
        uint256 _metawalletTotalAssets = token.balanceOf(address(metawallet));
        bytes32 _rootHash = keccak256(abi.encodePacked(address(metawallet), _metawalletTotalAssets));
        try settler.closeAndProposeDNVaultBatch(token, _metawalletTotalAssets, _rootHash) returns (bytes32 proposalId) {
            pendingDNSettlementProposals.add(proposalId);
            pendingDNUnsettledBatches.add(batchId);

            // Update adapter balance tracking
            dnActualAdapterBalance = metawallet.balanceOf(address(dnVaultAdapter));
            uint256 minterAdapterMetawalletBalance = metawallet.balanceOf(address(minterAdapter));
            minterActualAdapterBalance = token.balanceOf(address(minterAdapter));
        } catch {
            // Batch close failed - skip
        }
        vm.stopPrank();
    }

    function settler_claimStakedShares(uint256 actorSeed, uint256 requestSeedIndex) public useActor(actorSeed) {
        vm.startPrank(currentActor);
        if (actorStakeRequests[currentActor].count() == 0) {
            vm.stopPrank();
            return;
        }
        bytes32 requestId = actorStakeRequests[currentActor].rand(requestSeedIndex);
        BaseVaultTypes.StakeRequest memory stakeRequest = dnVault.getStakeRequest(requestId);
        bytes32 batchId = stakeRequest.batchId;
        (,, bool isSettled,, uint256 totalAssets, uint256 totalSupply,,) = dnVault.getBatchIdInfo(batchId);
        uint256 totalNetAssets = totalAssets;
        if (!isSettled) {
            vm.expectRevert();
            dnVault.claimStakedShares(requestId);
            vm.stopPrank();
            return;
        }
        uint256 sharesToMint = dnVault.convertToSharesWithTotals(stakeRequest.kTokenAmount, totalNetAssets, totalSupply);
        if (sharesToMint == 0) {
            vm.expectRevert(bytes("SV9"));
            dnVault.claimStakedShares(requestId);
            vm.stopPrank();
            return;
        }
        uint256 sharePriceBefore = dnVault.sharePrice();
        dnVault.claimStakedShares(requestId);
        actorStakeRequests[currentActor].remove(requestId);
        pendingStakeInBatch[batchId] -= stakeRequest.kTokenAmount;
        dnExpectedTotalAssets += stakeRequest.kTokenAmount;
        dnActualTotalAssets = dnVault.totalAssets();
        dnExpectedSupply += sharesToMint;
        dnActualSupply = dnVault.totalSupply();
        dnExpectedNetTotalAssets = dnExpectedTotalAssets;
        dnActualNetTotalAssets = dnVault.totalAssets();
        uint256 sharePriceAfter = dnVault.sharePrice();
        dnSharePriceDelta = int256(sharePriceAfter) - int256(sharePriceBefore);
        vm.stopPrank();
    }

    function settler_claimUnstakedAssets(uint256 actorSeed, uint256 requestSeedIndex) public useActor(actorSeed) {
        vm.startPrank(currentActor);
        if (actorUnstakeRequests[currentActor].count() == 0) {
            vm.stopPrank();
            return;
        }
        bytes32 requestId = actorUnstakeRequests[currentActor].rand(requestSeedIndex);
        BaseVaultTypes.UnstakeRequest memory unstakeRequest = dnVault.getUnstakeRequest(requestId);
        bytes32 batchId = unstakeRequest.batchId;
        (,, bool isSettled,, uint256 totalAssets, uint256 totalSupply,,) = dnVault.getBatchIdInfo(batchId);
        uint256 totalNetAssets = totalAssets;
        if (!isSettled) {
            vm.expectRevert();
            dnVault.claimUnstakedAssets(requestId);
            vm.stopPrank();
            return;
        }
        uint256 totalKTokensNet =
            dnVault.convertToAssetsWithTotals(unstakeRequest.stkTokenAmount, totalNetAssets, totalSupply);
        if (totalKTokensNet == 0) {
            vm.expectRevert(bytes("SV9"));
            dnVault.claimUnstakedAssets(requestId);
            vm.stopPrank();
            return;
        }
        uint256 sharePriceBefore = dnVault.sharePrice();
        dnVault.claimUnstakedAssets(requestId);
        actorUnstakeRequests[currentActor].remove(requestId);
        uint256 sharesToBurn = uint256(unstakeRequest.stkTokenAmount).fullMulDiv(totalNetAssets, totalAssets);
        dnExpectedSupply -= sharesToBurn;
        dnActualSupply = dnVault.totalSupply();
        dnExpectedTotalAssets -= totalKTokensNet;
        dnActualTotalAssets = dnVault.totalAssets();
        dnExpectedNetTotalAssets = dnExpectedTotalAssets;
        dnActualNetTotalAssets = dnVault.totalAssets();
        uint256 sharePriceAfter = dnVault.sharePrice();
        dnSharePriceDelta = int256(sharePriceAfter) - int256(sharePriceBefore);
        vm.stopPrank();
    }

    // //////////////////////////////////////////////////////////////
    // / YIELD SIMULATION ///
    // //////////////////////////////////////////////////////////////

    function settler_gain(uint256 amount) public {
        amount = bound(amount, 0, dnActualTotalAssets);
        if (amount == 0) return;
        // Simulate yield in metawallet
        uint256 newBalance = token.balanceOf(address(metawallet)) + amount;
        deal(token, address(metawallet), newBalance);
        totalYieldInBatch[dnVault.getBatchId()] += int256(amount);
    }

    function settler_lose(uint256 amount) public {
        int256 maxLoss = int256(dnExpectedAdapterTotalAssets) + totalYieldInBatch[dnVault.getBatchId()];
        if (maxLoss <= 0) return;

        uint256 currentBalance = token.balanceOf(address(metawallet));
        uint256 maxLossUint = uint256(maxLoss);
        if (maxLossUint > currentBalance) {
            maxLossUint = currentBalance;
        }

        amount = bound(amount, 0, maxLossUint);
        if (amount == 0) return;

        uint256 newBalance = currentBalance - amount;
        deal(token, address(metawallet), newBalance);
        totalYieldInBatch[dnVault.getBatchId()] -= int256(amount);
    }

    function settler_advanceTime(uint256 amount) public {
        amount = bound(amount, 0, 30 days);
        vm.warp(block.timestamp + amount);
        dnExpectedNetTotalAssets = dnExpectedTotalAssets;
        dnActualNetTotalAssets = dnVault.totalAssets();
    }

    // //////////////////////////////////////////////////////////////
    // / SETTER FUNCTIONS ///
    // //////////////////////////////////////////////////////////////

    function set_minterExpectedTotalLockedAssets(uint256 _value) public {
        minterExpectedTotalLockedAssets = _value;
    }

    function set_minterActualTotalLockedAssets(uint256 _value) public {
        minterActualTotalLockedAssets = _value;
    }

    function set_minterExpectedAdapterBalance(uint256 _value) public {
        minterExpectedAdapterBalance = _value;
    }

    function set_minterActualAdapterBalance(uint256 _value) public {
        minterActualAdapterBalance = _value;
    }

    function set_minterExpectedAdapterTotalAssets(uint256 _value) public {
        minterExpectedAdapterTotalAssets = _value;
    }

    function set_minterActualAdapterTotalAssets(uint256 _value) public {
        minterActualAdapterTotalAssets = _value;
    }

    function set_dnExpectedTotalAssets(uint256 _value) public {
        dnExpectedTotalAssets = _value;
    }

    function set_dnActualTotalAssets(uint256 _value) public {
        dnActualTotalAssets = _value;
    }

    function set_dnExpectedAdapterTotalAssets(uint256 _value) public {
        dnExpectedAdapterTotalAssets = _value;
    }

    function set_dnActualAdapterTotalAssets(uint256 _value) public {
        dnActualAdapterTotalAssets = _value;
    }

    // //////////////////////////////////////////////////////////////
    // / INVARIANTS ///
    // //////////////////////////////////////////////////////////////

    function INVARIANT_MINTER_TOTAL_LOCKED_ASSETS() public view {
        assertEq(
            minterExpectedTotalLockedAssets,
            minterActualTotalLockedAssets,
            "SETTLER: INVARIANT_MINTER_TOTAL_LOCKED_ASSETS"
        );
    }

    function INVARIANT_MINTER_ADAPTER_BALANCE() public view {
        assertEq(minterExpectedAdapterBalance, minterActualAdapterBalance, "SETTLER: INVARIANT_MINTER_ADAPTER_BALANCE");
    }

    function INVARIANT_MINTER_ADAPTER_TOTAL_ASSETS() public view {
        assertEq(
            minterExpectedAdapterTotalAssets,
            minterActualAdapterTotalAssets,
            "SETTLER: INVARIANT_MINTER_ADAPTER_TOTAL_ASSETS"
        );
    }

    function INVARIANT_DN_TOTAL_ASSETS() public view {
        // Skip this invariant if no DN settlement has happened yet
        if (dnExpectedTotalAssets == 0 && dnExpectedSupply == 0) return;
        assertEq(dnExpectedTotalAssets, dnActualTotalAssets, "SETTLER: INVARIANT_DN_TOTAL_ASSETS");
    }

    function INVARIANT_DN_ADAPTER_TOTAL_ASSETS() public view {
        // Skip this invariant if no DN settlement has happened yet
        if (dnExpectedTotalAssets == 0 && dnExpectedSupply == 0) return;
        assertEq(dnExpectedAdapterTotalAssets, dnActualAdapterTotalAssets, "SETTLER: INVARIANT_DN_ADAPTER_TOTAL_ASSETS");
    }

    function INVARIANT_DN_SHARE_PRICE() public view {
        // Skip this invariant if no DN settlement has happened yet
        if (dnExpectedTotalAssets == 0 && dnExpectedSupply == 0) return;
        assertEq(dnExpectedSharePrice, dnActualSharePrice, "SETTLER: INVARIANT_DN_SHARE_PRICE");
    }

    function INVARIANT_DN_TOTAL_NET_ASSETS() public view {
        // Skip this invariant if no DN settlement has happened yet
        // (both expected and actual tracking variables are 0 before first settlement)
        if (dnExpectedTotalAssets == 0 && dnExpectedSupply == 0) return;
        assertEq(dnExpectedNetTotalAssets, dnActualNetTotalAssets, "SETTLER: INVARIANT_DN_TOTAL_NET_ASSETS");
    }

    function INVARIANT_DN_SUPPLY() public view {
        // Skip this invariant if no DN settlement has happened yet
        if (dnExpectedTotalAssets == 0 && dnExpectedSupply == 0) return;
        assertEq(dnExpectedSupply, dnActualSupply, "SETTLER: INVARIANT_DN_SUPPLY");
    }

    function INVARIANT_DN_SHARE_PRICE_DELTA() public view {
        // Skip this invariant if no DN settlement has happened yet
        if (dnExpectedTotalAssets == 0 && dnExpectedSupply == 0) return;
        assertEq(dnSharePriceDelta, 0, "SETTLER: INVARIANT_DN_SHARE_PRICE_DELTA");
    }
}
