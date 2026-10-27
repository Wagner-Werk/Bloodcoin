# Security and bug bounty

## Status

The BCUS contracts have **not been externally audited**. They were reviewed internally
(27 October 2026, no critical or high findings). The contracts have no owner, no pause and no
upgrade path: a bug that reaches mainnet stays there forever. That is why outside eyes matter.

## Scope

Contracts in `src/` as deployed on **Base Sepolia** (testnet) from this repository:

- `BloodcoinToken`
- `MortalityEmission`
- `BcusStaking`
- `BcusMining`
- `SignedMortalityOracle`
- `FounderLock`

Out of scope: `CreMortalityOracle` (not deployed), the websites, the server, the oracle script,
and anything that requires the oracle signing key. Known issues listed below do not count.

## Rewards

Paid in BCUS after mainnet launch:

| Severity | Example | Reward |
|---|---|---|
| Critical | Theft of tokens, minting beyond the cap, permanent loss of staked tokens | 5,000 BCUS |
| High | Stealing or blocking rewards, breaking emission or mining | 2,000 BCUS |
| Medium | Unfair distribution or griefing with real impact | 500 BCUS |

BCUS has no market value today. Rewards are paid from the founder allocation as it vests
(100,000 BCUS per year), so a large number of valid reports may be paid out over time.

## Rules

1. Report privately to **contact@bloodcoin-us.com**. Do not open a public issue for a vulnerability.
2. Include a Foundry test or exact steps that show the problem.
3. The first valid report of an issue gets the reward. Duplicates do not.
4. Test only on Base Sepolia or a local fork. No attacks on other users or on the servers.
5. Not open to US persons or to persons in sanctioned countries.
6. The project decides the severity. Reasons are given in writing.
7. A reward is not paid where paying it would be unlawful for the project or the recipient.

## Known issues (no reward)

- **Oracle key loss:** if the oracle signing key is lost (not stolen), `retire()` can no longer be
  called and the mortality factor stays at its last value. Mitigation: a retire signature is kept offline.
- **Share at sync time:** `BcusStaking` computes the stakers' share of each emission at the moment
  of the sync, not as an average over the week. Timing (for example calling `FounderLock.release()`
  just before) can shift part of it to mining. The 1 % weekly cap bounds this.
- **Deposit resets the week counter:** any deposit, even 1 wei, resets `lastSyncAt`, which can lower
  the staker cap after missed weeks.
- **Mining start:** the first hour after launch has low difficulty; a fast miner can collect most
  solutions until difficulty adjusts (about 1/168 of the mining pool).
- **Trusted oracle:** whoever holds the signing key can report plausible but false numbers within the
  contract limits (factor 0.5 to 1.0, at most 0.05 per report). See README, "Trust model".
