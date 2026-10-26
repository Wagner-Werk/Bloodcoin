# Login box on bloodcoin-us.com (Michel chose "Beides", 2026-10-26)

Mockup: login-vorlage.jpg. UI CSS/HTML: genlogin.py (CSS and PANEL strings; panel hidden until the "Sign in" button is clicked, closes on Esc/outside click).

## 1. Email login = existing demo-exchange accounts
- No new account system on bloodcoin-us.com. Same users, same password + TOTP as exchange.bloodcoin-us.com.
- Preferred: the form posts to the exchange's existing login API with `fetch(..., {credentials:'include'})`.
  Server side: CORS on the exchange for origin https://bloodcoin-us.com only (Allow-Credentials), session cookie `Domain=.bloodcoin-us.com; Secure; HttpOnly; SameSite=Lax`, existing rate limit and 2FA unchanged. CSP connect-src on the site: add https://exchange.bloodcoin-us.com.
- After login: button shows the account email + links "Open exchange" and "Sign out". No balances on the book page.
- If CORS/cookie sharing is not wanted: the "Sign in" button simply opens https://exchange.bloodcoin-us.com login instead (fallback, no credentials on the book page).
- "Create account" / "Forgot password?" link to the exchange's existing pages.

## 2. Connect wallet = read-only
- Injected wallet only (window.ethereum, e.g. MetaMask): `eth_requestAccounts`, then switch/check Base Sepolia (chainId 84532).
- Show only: address (shortened), BCUS balance, own mining solutions, own stake (via public RPC reads, the token/mining/staking addresses the server already uses). No signing, no transactions, nothing stored on the server.
- CSP connect-src: add the public Base Sepolia RPC the site already uses (or https://sepolia.base.org).
- No wallet → text "No wallet found. Install a wallet like MetaMask to view your BCUS." No WalletConnect cloud service (third-party, privacy).

## Must stay
- Disclaimer line in the panel: "Demo exchange with test money only. BCUS is not yet available for purchase."
- No yield/APY, no buy button, no US targeting.
