# Bloodcoin book (landing page)

The landing page for bloodcoin-us.com as an old book with turning pages.

- `index.html`: the page. No external requests: fonts are self-hosted under `assets/book/fonts/` (SIL Open Font License: IM Fell English, EB Garamond, JetBrains Mono).
- `assets/book/`: coin, Plate I, signature, fonts.

The page expects, on the same host:

- `/oracle` and `/oracle-data/index.json`: the register on page V reads the newest four reports (`week_ending`, `recent_deaths`, `tx`).
- `POST /api/newsletter`: the signup form sends `{"email": "..."}` as JSON.
- `/legal.html` (with `#newsletter`) and `/favicon.png`.

Deploy: copy `index.html` and `assets/` into the site root, replacing the old `index.html` (keep a backup).
