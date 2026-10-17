"""Give the exchange start page the book look and replace the old slogan.

Usage: python3 apply.py path/to/exchange/web.html
Writes a backup next to the file (web.html.bak-book) and reports every
replacement that did not match, so a newer web.html can be fixed by hand.
"""
import shutil
import sys

REPLACE = [
    ("<title>Bloodcoin Exchange · Death is profitable</title>", "<title>Bloodcoin Exchange · Demo</title>"),
    ('<meta name="theme-color" content="#0c0909">', '<meta name="theme-color" content="#24090b">'),
    ('<h1 class="slogan">Death is<br><em>profitable.</em></h1>', '<h1 class="slogan">The ledger<br><em>is open.</em></h1>'),
    ('<p class="lead">Bloodcoin (BCUS) is a cryptocurrency whose money supply is tied directly to mortality in the United States. '
     'When deaths rise, new coins become scarcer, and every BCUS holder owns a larger share of the whole.</p>',
     '<p class="lead">This is the Bloodcoin exchange, a demo with test money. Open an account, trade BCUS against play dollars '
     'and follow every block in the explorer. Nothing here has monetary value.</p>'),
    ('<div class="step"><b>4</b><h3>Scarcity kicks in</h3><p>Fewer new coins mean lower inflation, so every existing balance makes up '
     'a larger share of the total supply. That is the core of “Death is profitable”.</p></div>',
     '<div class="step"><b>4</b><h3>The record stays</h3><p>Every report and every block is kept for good. Anyone can check the whole '
     'chain in the explorer, from the first block to the latest.</p></div>'),
    ('<h2 class="h2">A currency that responds to reality</h2>', '<h2 class="h2">A chain that responds to reality</h2>'),
    ("</style>\n</head>",
     '</style>\n<link rel="stylesheet" href="https://bloodcoin-us.com/assets/book/fonts.css">\n'
     '<link rel="stylesheet" href="/book-theme.css">\n</head>'),
]

path = sys.argv[1]
html = open(path, encoding="utf-8").read()
shutil.copy(path, path + ".bak-book")
missing = []
for old, new in REPLACE:
    if new in html:
        continue
    if old in html:
        html = html.replace(old, new)
    else:
        missing.append(old[:70])
open(path, "w", encoding="utf-8").write(html)
for m in missing:
    print("NOT FOUND:", m)
left = [w for w in ("profitable", "larger share", "Scarcity") if w in html]
print("still on the page:", left or "nothing")
