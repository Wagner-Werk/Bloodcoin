# Plate I alone on the last spread (Michel, 2026-10-24)

Apply to the LIVE index.html on the server (afterword version live since 2026-10-24 08:15 UTC), not to this repo copy:

    cp index.html index.html.bak-20261024-plate
    python3 patch_plate.py index.html

The script inserts two blank pages (`data-spread-only`) before Colophon and before Plate I, and adjusts the page script so phones skip them and folios/TOC stay unchanged. It aborts with an AssertionError if the live markup differs; then apply the same 5 replacements by hand (see the script).
