# Exchange in the book look

`book-theme.css` restyles exchange.bloodcoin-us.com like the book on bloodcoin-us.com: night desk, leather header, paper cards, IM Fell English and EB Garamond. It only overrides the page's own styles.

`apply.py` replaces the old slogan and the value claims on the start page and links the theme.

Needed on the server:

- serve `book-theme.css` at `/book-theme.css` on the exchange (same way as `/coin.webp`);
- the exchange CSP must allow `style-src` and `font-src` from `https://bloodcoin-us.com`;
- Caddy on bloodcoin-us.com must send `Access-Control-Allow-Origin: https://exchange.bloodcoin-us.com` for `/assets/book/fonts/*` (fonts are loaded cross-origin).
