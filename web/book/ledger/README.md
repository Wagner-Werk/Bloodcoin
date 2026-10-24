# Ledger strip (Michel chose variant 5, 2026-10-24)

Replaces the four parchment side tiles on bloodcoin-us.com (latest report, project log, next emission, mining/chain).

1. Remove the side tiles (left and right asides). The project log goes away; link to it from the strip if it has its own page.
2. Add `ledger-strip.css` to the page CSS and put `ledger-strip.html` into `<body>` directly after `.controls`, so it is the last flex item.
3. Wire the `lg-*` elements to the same data the tiles used. The texts in the HTML are examples only.
4. In `size()` leave room for the strip: `availH = H - (m === 'single' ? 270 : 240)` instead of `190 : 160`.
5. Numbers use EB Garamond (`--f-body`), never IM Fell SC: it shows "in 1 d 6 h" as "IN I D 6 H".

Preview: /mnt/project-files/webseite-buch/kacheln-vorschlaege/5-hauptbuch.jpg
