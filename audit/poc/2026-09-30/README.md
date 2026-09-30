# Proof-of-concept tests of the Stage A internal red team (2026-09-30)

The reviewers' tests behind `audit/2026-09-30-stage-a-red-team.md`, as they ran against `aea5d58`. They compile only
inside `test/poc/` of that commit; several now fail by design, because the findings they demonstrate are fixed.

- `DustRounding.t.sol`: SA-07. `BatchCadence.t.sol`: SA-04 and SA-08. `RebalanceFuzz.t.sol`: the 20,000-run fuzz of
  rebalance cycles that found the band bound sound.
- `FactoryGovernance.poc.t.sol`: SA-02 to SA-05.
- `MintRequestsIssuers.poc.t.sol`: SA-01, SA-09 to SA-11, with mocks copying Tether's and Circle's freeze rules.
  `MintRequestsComposition.poc.t.sol`: SA-12.
