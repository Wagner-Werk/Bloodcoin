# Deploy: new /stake page (scroll design, no APY)

Approved by Michel on 2026-10-19 (decision card "Live, unverlinkt" in thread "Stake-Seite anpassen").

| Source | Goes live as |
|---|---|
| `/mnt/project-files/webseite-buch/stake-rollen/stake.html` | exchange.bloodcoin-us.com `/stake` (replaces the current stake.html served by `server.py`) |

## Steps for the server

1. Back up the current stake page as `stake.html.bak-20261019`.
2. Diff the server copy against the new file. The new page uses the same endpoints as before: `/api/staking-config` (fields `testnet`, `chainName`, `chainId`, `rpcUrl`, `explorer`, `token`, `staking`, `emission`) and `/api/staking-stats` (reads `total`, `factor`, `lastWeek`, `base`; `rate`/`finish` are no longer used). If the server copy has newer fields, addresses or fixes (S9 rewiring from 2026-10-18), port them into the new page instead of dropping them.
3. The page loads `/assets/rollen/fonts.css` (already served on exchange.bloodcoin-us.com since the scroll deploy).
4. The page shows sample numbers on any host other than `*.bloodcoin-us.com`. On the real domain it reads live data.
5. Do NOT add a Staking link anywhere (no menu entry, no link from exchange or landing page). The link comes after the mining test on 2026-10-26.

## Test after deploy

1. `https://exchange.bloodcoin-us.com/stake` opens in the parchment design; footer does not say "Preview with sample numbers".
2. No "% per year" or reward rate anywhere on the page.
3. The three figures show live values (total staked, BCUS to stakers this week = half of the weekly emission, factor).
4. Connect MetaMask on Base Sepolia: position appears; stake/unstake buttons respond (a small test stake and unstake is fine).
5. No CSP errors in the browser console.
