# Security and bug bounty

## Status

The BCUS contracts have **not been externally audited**. They were reviewed internally
(27 October 2026, no critical or high findings). The contracts have no owner, no pause and no
upgrade path: a bug that reaches mainnet stays there forever. That is why outside eyes matter.

## Scope

The contracts in `src/` at commit `0d5a10c` of this repository, as deployed on **Base mainnet**
(chain id 8453) with `script/DeploySigned.s.sol`:

| Contract | Base mainnet address |
|---|---|
| `BloodcoinToken` | _added after deployment_ |
| `MortalityEmission` | _added after deployment_ |
| `BcusStaking` | _added after deployment_ |
| `BcusMining` | _added after deployment_ |
| `SignedMortalityOracle` | _added after deployment_ |
| `FounderLock` | _added after deployment_ |

Only the addresses in this table count. Until they are filled in, the bounty covers the same code
at commit `0d5a10c`, tested locally or on a fork.

Out of scope: `CreMortalityOracle` (not deployed), the testnet deployments on Base Sepolia, the
websites, the server, the oracle script and the keeper, and anything that requires the oracle
signing key or the guardian key. Known issues listed below do not count.

## Rewards

Paid in BCUS:

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
4. Test only on a local fork or on your own test deployment. Never exploit a bug on Base mainnet,
   and no attacks on other users or on the servers.
5. Not open to US persons or to persons in sanctioned countries.
6. The project decides the severity. Reasons are given in writing.
7. A reward is not paid where paying it would be unlawful for the project or the recipient.

## Known issues (no reward)

### Oracle

- **Trusted oracle:** whoever holds the signing key can report plausible but false numbers within the
  contract limits (factor 0.5 to 1.0, at most 0.05 per report). See README, "Trust model".
- **Reports are delayed on purpose:** a signed report is only a proposal. It can be executed by anyone
  48 hours after it was proposed (`CHALLENGE_PERIOD`), not earlier. At most one proposal is open at a
  time, and at least 6 days (`MIN_INTERVAL`) must pass between two proposals, also after a veto, and
  between two executions. After an oracle outage the backlog is therefore caught up by at most one
  week per 6 days, and the factor follows the CDC numbers with a delay.
- **Guardian powers:** the guardian is a second, immutable key held offline by the founder. It cannot
  report. It can veto any open proposal (directly or with a signature anyone can submit) and switch the
  oracle off for good with `retire()`, which resets the factor to 1.0. A guardian that vetoes every
  proposal freezes the factor at its last value. This is trust in the founder, not a bug.
- **Stolen signing key:** a thief can propose false numbers within the limits. The guardian has 48 hours
  to veto each proposal. Without a veto the factor still moves by at most 0.05 per 6 days, and the
  guardian can retire the oracle at any time.
- **Lost keys:** if the signing key is lost (not stolen), no new reports are possible and the factor stays
  at its last value until the guardian calls `retire()`. If the guardian key is lost, vetoes are no longer
  possible and reports take effect normally after 48 hours. The signing key can still retire the oracle.
  An offline retire signature is to be prepared right after the mainnet deployment, because it is bound
  to the contract address.
- **Nobody executes:** `execute()` is open to everyone, but nobody is forced to call it. If no one does,
  a proposal waits. The server's gas key normally sends it; that key has no rights in the contract.
- **Off-chain checks are not part of the contracts:** the oracle script refuses to sign if new CDC numbers
  differ from earlier reports by more than 3 %, and a daily job checks open proposals against the CDC.
  These are safeguards on the server, out of scope for this bounty.

### Staking, emission and mining

- **Merged weeks:** `BcusStaking` settles each emission week when the first call after its boundary
  arrives. If a whole week passes without any call, the missed weeks are settled together and their
  1 % caps are applied jointly, so the limit holds on average over those weeks rather than for each
  one. Mitigation: a keeper calls `pull()` within about an hour after every boundary.
- **Circulating supply read at settlement:** the share-of-supply rule reads `circulating()` when a
  week is settled, not exactly at its boundary. Payouts from mining or the founder lock in between
  can shift a small part between stakers and mining. Same mitigation.
- **Rounding dust:** integer division leaves a few wei per week in `reserved` that no one can claim.
- **Mining start:** the first hour after launch has low difficulty; a fast miner can collect most
  solutions until difficulty adjusts (about 1/168 of the mining pool).
