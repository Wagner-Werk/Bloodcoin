#!/usr/bin/env python3
"""Vergleicht alte und neue Sterbe-Faktor-Regel an echten US-Wochenzahlen.

    python3 -I oracle/sim/simulate.py

Daten: us_weekly_2015_2024.json, US-Todesfälle pro Woche 2015 bis Mitte 2024, aus
Our World in Data (github.com/owid/covid-19-data, excess_mortality.csv; Quelle dort: CDC/HMD).
Die neue Regel nutzt exakt target_milli und step_toward aus oracle/signed/report.py.
"""
import json
import statistics as st
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "signed"))
from report import step_toward, target_milli  # noqa: E402

data = json.loads((HERE / "us_weekly_2015_2024.json").read_text())
labels = [l for l, _ in data]
deaths = [v for _, v in data]


def old_factor(i: int) -> int:
    """Bisherige Regel: diese Woche gegen Vorwoche, 1 % mehr Tote = 10 % weniger Coins."""
    a, b = deaths[i], deaths[i - 1]
    adj = (10 * 1000 * abs(a - b) + b // 2) // b
    f = 1000 - adj if a > b else 1000 + adj
    return max(500, min(1500, f))


def recent_baseline(i: int) -> tuple[int, int]:
    recent = sum(deaths[i - 3:i + 1])
    past = sum(sum(deaths[i - 52 * k - 3:i - 52 * k + 1]) for k in (1, 2, 3))
    return recent, (past + 1) // 3


def new_factors(ids: list[int]) -> list[int]:
    f, out = 1000, []
    for i in ids:
        f = step_toward(f, target_milli(*recent_baseline(i)))
        out.append(f)
    return out


def years(a: str, b: str) -> list[int]:
    return [i for i, l in enumerate(labels) if a <= l[:4] <= b]


def show(name: str, fs: list[int]) -> None:
    s = sorted(fs)
    p = lambda q: s[int(q * (len(s) - 1))]
    clamp = sum(f in (500, 1500) for f in fs) / len(fs)
    jump = st.median(abs(fs[i] - fs[i - 1]) for i in range(1, len(fs)))
    print(f"{name:40s} {p(.05):5d} {p(.5):5d} {p(.95):5d} {clamp:7.0%} {jump:8.0f} {st.mean(fs):7.0f}")


print(f"{'':40s} {'p5':>5s} {'Median':>5s} {'p95':>5s} {'Anschlag':>7s} {'Sprung':>8s} {'Mittel':>7s}")
show("ALT  2018-2019 (normale Jahre)", [old_factor(i) for i in years("2018", "2019")])
show("ALT  2020-2021 (Covid)", [old_factor(i) for i in years("2020", "2021")])
normal = years("2018", "2019")
warm = years("2017", "2019")                     # ein Jahr Vorlauf, damit der Faktor nicht bei 1000 startet
show("NEU  2018-2019 (normale Jahre)", new_factors(warm)[-len(normal):])
show("NEU  2020-2021 (Covid)", new_factors(years("2020", "2021")))
print("\nSprung = typische Änderung von einer Woche zur nächsten, Anschlag = Anteil Wochen bei 0,5 oder 1,5")
print("Faktor in Promille: 1000 = normale Ausgabe, 500 = halbe, 1500 = anderthalbfache")
