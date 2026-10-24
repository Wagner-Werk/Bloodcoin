# Layout v7 (Michel approved 2026-10-24 13:11 UTC, "seiten so live")

Replaces the ledger strip (variant 5) that is live now.

- Desktop (>= 1100 px): info in two dark side columns with gold rules (left: latest report + project log, right: next emission, mining, chain). Book as tall as the screen allows; size() reserves 548 px for the columns.
- Below 1100 px: side columns hidden, one thin scrolling ticker line under the banner (static and swipeable with prefers-reduced-motion).
- Page title (#where) sits just above the book (inside .stage); "Spread x of y" stays below.
- Desktop: prev/next arrows left and right of the book (moved into .stage by placeNav()); phones keep them in the bottom bar.
- Numbers in EB Garamond, never IM Fell SC.

`changes.diff` = exact diff against the plain book build (web/book/index.html with plate fix). `reference-index.html` is the full result with EXAMPLE values.
On the server: remove the ledger strip, apply the same CSS/HTML/JS changes to the live index.html, and wire the side columns and the ticker to the live data the ledger strip uses now (incl. project log entries).

## v8 delta (Michel approved 2026-10-24 13:37 UTC, "so live")
`v8-delta.diff` = changes on top of v7 only:
- Red ribbon (`.ribbon`) removed; single-mode `.clip` height `--ph + 8px` instead of `+ 60px`.
- size(): `availH = Math.max(300, stage.clientHeight - (single ? 70 : 66))` — book sized from the measured stage, so the page title above the book is never clipped.
- `.pg-title` top `50% - ph/2 - 30px` (single: `- 32px`).
- Phones (<= 600 px): banner 10.5px, 2 lines (text unchanged), tighter controls, 40px arrows.
- Trace page: `class="tight"`.
