# E-4 PoC — SessionRouter direct-pay limiter-truncation user shortfall

Morpheus Bug Bounty v2, candidate E-4 (leg E). Fork-only Foundry test against
the Base LumerinDiamond. Nothing was executed against mainnet.

## Run

```
forge test -vvv
```

Forks Base mainnet at pinned block **56,437,967** via `vm.createSelectFork`
(RPC hardcoded in the test: `https://mainnet.base.org`; alternative public
endpoint: `https://base-rpc.publicnode.com`). No other setup.

## What it proves

In direct-pay sessions, the provider's payment is capped by the 365-day
stake limiter (`_claimForProvider`), but the user's settlement deduction at
close is the **full, uncapped** gross reward
(`_rewardUserAfterClose` → `_getProviderRewards(..., includeWithdrawn=false)`).
When the limiter binds, the difference is kept by the diamond and credited
back to nobody.

Three tests (`test/E4SessionRouter.t.sol`):

1. `test_truncation_preClaim_userShorted` — E-4 as specified: minimum-stake
   provider (0.2 MOR limiter budget), `claimForProvider` on the unclosed
   session after `endsAt` pays a truncated 0.2 MOR of a 29.2126 MOR gross;
   at close the user is refunded stake − full gross; the diamond retains
   **29.0126 MOR** — the user's loss.
2. `test_control_noTruncation_balancesExactly` — provider stake 1,000 MOR:
   no truncation, `providerReceived + userRefund == stake`, diamond retains 0.
3. `test_counterfactual_noPreClaim_sameShortfall` — no pre-claim at all:
   identical shortfall at close, isolating the root cause to the
   uncapped-deduction vs capped-payment pair.

## Setup notes

- All calls go **through the diamond** `0x6aBE1d282f72B474E54527D93b979A4f64d3030a`;
  `setUp` asserts the SessionRouter selectors route to the Appendix A facet
  `0x3a3952F0e57B343F00B31f7da039Ef16389B7260` at the pinned block.
- Actors (provider with its own signing key, model owner, user) are fresh
  addresses. Their MOR balances are funded with `vm.store` on the token's
  balance mapping slot, which the test **discovers** by matching the
  diamond's live `balanceOf` (same technique as the D-01 PoC). Setup only —
  every protocol interaction is a normal call by the actors themselves.
- Facet sources used for the code-path reconstruction are in `lib-src/`
  (MorpheusAIs/Morpheus-Lumerin-Node @ `ba14d2f`, verified identical to the
  copies leg E read).

Full traces: `test-output.txt`. Verdict: `~/workspace/mor-sweep/legs/poc-e4-result.md`.
