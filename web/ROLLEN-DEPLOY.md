# Deploy: exchange, oracle and whitepaper (scroll design)

Approved by Michel on 2026-10-17 ("Gut seiten live schalten").

| File in repo | Goes live as |
|---|---|
| `web/exchange-rollen/web.html` | exchange.bloodcoin-us.com `/` (replaces the exchange `web.html`, served by `server.py` via WEB_HTML) |
| `web/oracle-rollen/oracle.html` | bloodcoin-us.com `/oracle` (replaces the current oracle page) |
| `web/whitepaper/index.html` | bloodcoin-us.com `/whitepaper` (new) |
| `web/rollen-assets/` (fonts.css + fonts/) | `/assets/rollen/` on **both** domains |

## Notes for the server

- The server copies of `web.html` and `oracle.html` are newer than the repo. Diff first; the new exchange page uses the same API as before (`/api/me`, `/api/market`, `/api/info`, `/api/reserves`, `/api/login`, `/api/register`, `/api/logout`, `/api/testmoney`, `/api/order`, `/api/cancel`, `/api/withdraw`). If the server API has fields or endpoints the repo copy lacks, port them into the new page instead of dropping them.
- Fonts are self-hosted (no Google Fonts). The exchange CSP (`default-src 'self'`) allows them only same-origin, so `/assets/rollen/` must be served from exchange.bloodcoin-us.com too (Caddy `handle_path` or a STATIC entry in `server.py`). `.woff2` must be served as `font/woff2`.
- The oracle page reads `/oracle-data/index.json` and its "Check against the CDC" button fetches `https://data.cdc.gov/resource/r8kw-7aab.json` from the browser. The main domain CSP needs `connect-src 'self' https://data.cdc.gov`.
- The oracle page shows sample data on any host other than bloodcoin-us.com (preview mode). On the real domain it loads the real reports.
- The whitepaper links `https://bloodcoin-us.com/legal.html` for the full publisher address. That page must exist.
- No Staking link anywhere (APY text stays off until Michel decides).
- Back up the current files before replacing them.

## Test after deploy

1. Exchange logged out: only About and Log in tabs; `#trade` shows the login gate.
2. Log in, add test money, place and cancel an order, try a withdrawal with a wrong address (error shown), log out.
3. Fonts load (DevTools network: three `.woff2`, no fonts.googleapis.com).
4. Oracle page shows real reports, "Check against the CDC" returns a result (no CSP error in the console).
5. `/whitepaper` opens, white, all links work.
