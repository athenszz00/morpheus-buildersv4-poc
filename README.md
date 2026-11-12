# Morpheus BuildersV4 — editSubnet permanently freezes stakers' principal

Foundry proof-of-concept for a bug bounty report to Morpheus (BuildersV4 on Base).

## What it proves

A subnet admin can call `editSubnet` after deposits land and raise
`withdrawLockPeriodAfterDeposit` to `uint128` max. `withdraw` then reverts
with panic 0x11 forever, and existing stakers' principal is permanently
frozen — demonstrated with 100 MOR still locked after a 100-year warp.
No privileged accounts are used: all MOR is dealt to fresh unprivileged
test addresses on the fork.

## Run

Requires [Foundry](https://book.getfoundry.sh/getting-started/installation).

```bash
git clone <this repo>
cd morpheus-buildersv4-poc
forge install foundry-rs/forge-std
forge test --fork-url https://mainnet.base.org --fork-block-number 56046051 --match-test test_H5_lockRaise
```

Expected output: 2 passed, 0 failed.

- `test_H5_lockRaiseFreezes` — lock raised 7d to 365d freezes a victim's 100 MOR.
- `test_H5_lockRaiseToMaxPermanentFreeze` — lock raised to `uint128` max makes
  `withdraw` revert panic 0x11 forever.

## Files

- `test/Lane2Builders.t.sol` — the PoC (self-contained; interfaces defined inline).
- `foundry.toml` — Foundry config (solc 0.8.20, `forge-std` remapping).
- `src/Placeholder.sol` — stub so the project has a `src` directory.
