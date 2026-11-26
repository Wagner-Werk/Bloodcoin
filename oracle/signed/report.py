#!/usr/bin/env python3
"""Wöchentliche CDC-Meldung an SignedMortalityOracle (Plan B ohne Chainlink), mit S6-Härtung.

Holt die US-Sterbezahlen bei data.cdc.gov und rechnet nach derselben Regel wie
cre-workflow/cdc.js: Tote der letzten 4 Wochen (recent) und Durchschnitt derselben 4 Wochen in den
3 Vorjahren (baseline). Prüft die Zahlen, signiert sie mit dem Melde-Schlüssel (EIP-712, über
`cast`) und schlägt sie mit dem getrennten Gas-Schlüssel vor. Wirksam wird der Vorschlag erst nach
48 Stunden Einspruchsfrist mit `execute`. Jede Meldung wird samt CDC-Rohdaten als JSON abgelegt,
damit jeder sie nachprüfen kann.

    report.py send    --rpc URL --oracle 0x.. --signer-keystore F --signer-password-file F
                      --sender-keystore F --sender-password-file F --out-dir DIR [--dry-run]
    report.py execute --rpc URL --oracle 0x.. --sender-keystore F --sender-password-file F --out-dir DIR
    report.py verify  DATEI.json   # vergleicht eine abgelegte Meldung mit den heutigen CDC-Zahlen

Vor dem Signieren (Stufe A):
- dieselben Grenzen wie im Contract: 80.000 bis 1.000.000, Verhältnis 1:2 bis 2:1,
- Vergleich mit den letzten 8 eigenen Meldungen: weicht eine dort verwendete CDC-Woche heute um mehr
  als --max-drift (Standard 3 %) ab, wird nicht gemeldet.

Jeder Fehler endet mit Exit-Code ungleich 0 und geht, wenn NTFY_URL gesetzt ist oder --ntfy-file
eine Adresse enthält, als Alarm aufs Handy.

Braucht nur Python 3 und Foundry (`cast`).
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import subprocess
import sys
import urllib.parse
import urllib.request
from pathlib import Path

CDC_BASE = "https://data.cdc.gov/resource/r8kw-7aab.json"
LAG_DAYS = 56
WINDOW_WEEKS = 4
BASELINE_YEARS = 3
DAY = 86400

# Wie SignedMortalityOracle
MIN_DEATHS = 80_000
MAX_DEATHS = 1_000_000
CHALLENGE_PERIOD = 48 * 3600

DRIFT_FILES = 8
DEFAULT_MAX_DRIFT = 0.03


class ReportError(Exception):
    """Fehler, der den Lauf abbricht und Alarm auslöst."""


def check_plausible(recent: int, baseline: int) -> None:
    """Gleiche Grenzen wie der Contract. Schlägt das fehl, wird nicht signiert."""
    for name, v in (("recent", recent), ("baseline", baseline)):
        if not MIN_DEATHS <= v <= MAX_DEATHS:
            raise ReportError(f"{name} = {v} liegt ausserhalb {MIN_DEATHS} bis {MAX_DEATHS}")
    if recent > 2 * baseline or 2 * recent < baseline:
        raise ReportError(f"Verhältnis recent/baseline = {recent / baseline:.3f} ausserhalb 1:2 bis 2:1")


def drift_check(out_dir: Path, weeks_now: dict[int, int], max_drift: float = DEFAULT_MAX_DRIFT) -> list[str]:
    """Vergleicht die Wochen der letzten 8 abgelegten Meldungen mit der heutigen CDC-Antwort.
    Rückgabe: Liste der Probleme (leer = in Ordnung). Wochen, die heute fehlen, zählen nicht.
    Eine unlesbare Meldedatei ist ein Problem."""
    problems = []
    files = sorted(Path(out_dir).glob("????-??-??.json"), reverse=True)[:DRIFT_FILES]
    for f in files:
        try:
            used = json.loads(f.read_text())["weeks_used"]
            items = [(day_of(k), int(v)) for k, v in used.items()]
        except (OSError, ValueError, KeyError, TypeError, AttributeError) as e:
            problems.append(f"{f.name}: unlesbar ({e})")
            continue
        for day, reported in items:
            now = weeks_now.get(day)
            if now is None:
                continue
            drift = (now - reported) / reported
            if abs(drift) > max_drift:
                problems.append(f"{f.name}: Woche {iso(day * DAY)} damals {reported}, CDC heute {now} ({drift:+.2%})")
    return problems


def day_of(iso_date: str) -> int:
    return (dt.date.fromisoformat(str(iso_date)[:10]) - dt.date(1970, 1, 1)).days


def alarm(text: str, ntfy_file: str | None = None) -> None:
    """Push an ntfy, wenn eine Adresse bekannt ist. Fehler beim Senden brechen nichts ab."""
    url = os.environ.get("NTFY_URL", "").strip()
    if not url and ntfy_file:
        try:
            url = Path(ntfy_file).read_text().strip()
        except OSError:
            url = ""
    if not url:
        print("Hinweis: kein ntfy-Ziel, Alarm nur hier im Log.", file=sys.stderr)
        return
    req = urllib.request.Request(url, text.encode(), {"Title": "Bloodcoin Melder-Alarm", "Priority": "high",
                                                      "Tags": "warning"})
    try:
        urllib.request.urlopen(req, timeout=30).close()
    except OSError as e:
        print(f"Warnung: ntfy nicht erreichbar: {e}", file=sys.stderr)


def cdc_url(today: dt.date) -> str:
    cutoff = (today - dt.timedelta(days=LAG_DAYS)).isoformat()
    q = {
        "state": "United States",
        "$select": "week_ending_date,total_deaths",
        # "group" ist in SoQL reserviert, deshalb im $where mit Backticks.
        "$where": f"`group` = 'By Week' AND week_ending_date <= '{cutoff}T00:00:00.000'",
        "$order": "week_ending_date DESC",
        "$limit": "180",   # 3 Jahre plus 4 Wochen plus Spielraum
    }
    return CDC_BASE + "?" + urllib.parse.urlencode(q, quote_via=urllib.parse.quote)


def fetch(url: str) -> list:
    req = urllib.request.Request(url, headers={"Accept": "application/json", "User-Agent": "bloodcoin-oracle"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read())


def parse_rows(rows: list) -> dict[int, int]:
    """CDC-Zeilen -> {Tag seit 1970: Tote}. Kaputte Zeilen werden übergangen."""
    weeks: dict[int, int] = {}
    for r in rows:
        try:
            day = (dt.date.fromisoformat(str(r["week_ending_date"])[:10]) - dt.date(1970, 1, 1)).days
            deaths = int(float(r["total_deaths"]))
        except (KeyError, ValueError, TypeError):
            continue
        if 0 < deaths < 10_000_000:
            weeks[day] = deaths
    return weeks


def window_days(day: int) -> list[list[int]]:
    """Die 4 Wochen bis `day`, danach dieselben 4 Wochen in jedem der 3 Vorjahre (je 52 Wochen zurück)."""
    return [[day - 364 * k - 7 * j for j in range(WINDOW_WEEKS)] for k in range(BASELINE_YEARS + 1)]


def pick_window(rows: list, today: dt.date) -> tuple[int, int, int]:
    """Neueste Woche, die mindestens 8 Wochen alt ist und für die alle 16 Wochen vorliegen.
    Rückgabe: (weekEnding in Sekunden, recent, baseline)."""
    weeks = parse_rows(rows)
    limit = (today - dt.date(1970, 1, 1)).days - LAG_DAYS
    for day in sorted(weeks, reverse=True):
        if day > limit:
            continue
        groups = window_days(day)
        if all(d in weeks for g in groups for d in g):
            recent = sum(weeks[d] for d in groups[0])
            past = sum(weeks[d] for g in groups[1:] for d in g)
            return day * DAY, recent, (past + 1) // BASELINE_YEARS
    raise ReportError("keine ausreichend alte Woche mit vollständigen Vorjahren in den CDC-Daten")


def target_milli(recent: int, baseline: int) -> int:
    """Ziel-Faktor in Promille, gleiche Formel wie MortalityEmission.targetFor.
    Weniger Tote als üblich ergeben 1000, nie mehr."""
    if recent <= baseline:
        return 1000
    bp = ((recent - baseline) * 10_000 + baseline // 2) // baseline
    if bp <= 300:
        return 1000
    return max(500, 1000 - 5 * (bp - 300) // 10)


def step_toward(current: int, target: int) -> int:
    """Wie MortalityEmission.stepToward: höchstens 50 Promille pro Meldung."""
    return current + max(-50, min(50, target - current))


def cast(*args: str) -> str:
    r = subprocess.run(["cast", *args], capture_output=True, text=True)
    if r.returncode != 0:
        raise ReportError(f"cast {args[0]}: {r.stderr.strip()}")
    return r.stdout.strip()


def call_uints(rpc: str, to: str, sig: str, *args: str) -> list[int]:
    """Ruft eine view-Funktion auf; jede Ausgabezeile ist eine Zahl (cast hängt evtl. " [1e18]" an)."""
    out = cast("call", "--rpc-url", rpc, to, sig, *args)
    return [int(line.split()[0]) for line in out.splitlines() if line.strip()]


def call_uint(rpc: str, to: str, sig: str, *args: str) -> int:
    return call_uints(rpc, to, sig, *args)[0]


def iso(week_ending: int) -> str:
    return dt.datetime.fromtimestamp(week_ending, dt.timezone.utc).date().isoformat()


def iso_time(ts: int) -> str:
    return dt.datetime.fromtimestamp(ts, dt.timezone.utc).isoformat(timespec="minutes")


class Chain:
    """Lesezugriff auf Orakel und Emission."""

    def __init__(self, rpc: str, oracle: str):
        self.rpc, self.oracle = rpc, oracle
        self.emission = cast("call", "--rpc-url", rpc, oracle, "emission()(address)")

    def retired(self) -> bool:
        return cast("call", "--rpc-url", self.rpc, self.oracle, "retired()(bool)") == "true"

    def pending(self) -> tuple[int, int, int, int]:
        """(weekEnding, proposedAt, recent, baseline); weekEnding 0 = nichts offen."""
        w, at, r, b = call_uints(self.rpc, self.oracle, "pending()(uint64,uint64,uint64,uint64)")
        return w, at, r, b

    def executable_at(self) -> int:
        return call_uint(self.rpc, self.oracle, "executableAt()(uint256)")

    def last_proposed_at(self) -> int:
        return call_uint(self.rpc, self.oracle, "lastProposedAt()(uint256)")

    def last_week(self) -> int:
        return call_uint(self.rpc, self.emission, "lastWeekEnding()(uint256)")

    def factor(self) -> int:
        return call_uint(self.rpc, self.emission, "factorMilli()(uint256)")

    def now(self) -> int:
        return int(cast("block", "--rpc-url", self.rpc, "latest", "--field", "timestamp"), 0)


def wallet_args(keystore: str, password_file: str) -> list[str]:
    return ["--keystore", keystore, "--password-file", password_file]


def send_tx(a, *call: str) -> str:
    """Sendet mit dem Gas-Schlüssel und gibt den Transaktions-Hash zurück."""
    out = cast("send", "--rpc-url", a.rpc, *wallet_args(a.sender_keystore, a.sender_password_file), "--json",
               a.oracle, *call)
    receipt = json.loads(out)
    if receipt.get("status") not in ("0x1", 1, "1"):
        raise ReportError(f"Transaktion fehlgeschlagen: {receipt.get('transactionHash')}")
    return receipt["transactionHash"]


def record_path(out: Path, week: int) -> Path:
    return out / f"{iso(week)}.json"


def update_record(out: Path, week: int, **fields) -> None:
    path = record_path(out, week)
    if not path.exists():
        return
    rec = json.loads(path.read_text())
    rec.update(fields)
    path.write_text(json.dumps(rec, indent=2) + "\n")


def reconcile(out: Path, chain: Chain) -> None:
    """Gleicht offene Meldedateien mit der Chain ab: ausgeführt (auch von Dritten) oder verworfen."""
    pend_week = chain.pending()[0]
    last = chain.last_week()
    for f in sorted(out.glob("????-??-??.json"), reverse=True)[:DRIFT_FILES]:
        try:
            rec = json.loads(f.read_text())
        except (OSError, ValueError):
            continue
        if not rec.get("proposed_tx") or rec.get("executed_tx") or rec.get("executed") or rec.get("vetoed"):
            continue
        week = rec["week_ending_unix"]
        if week == pend_week:
            continue
        if last >= week:
            update_record(out, week, executed=True)
        else:
            update_record(out, week, vetoed=True)


def execute_due(a, chain: Chain, out: Path, *, strict: bool) -> bool:
    """Führt einen fälligen Vorschlag aus. Rückgabe: ob danach nichts mehr offen ist.
    strict: ein offener, noch nicht fälliger Vorschlag ist ein Fehler."""
    week, _, recent, baseline = chain.pending()
    if week == 0:
        return True
    due = chain.executable_at()
    now = chain.now()
    if now < due:
        if strict:
            raise ReportError(f"Vorschlag Woche {iso(week)} ist offen und erst ab {iso_time(due)} fällig")
        print(f"Vorschlag Woche {iso(week)} offen, fällig ab {iso_time(due)}.")
        return False
    if a.dry_run:
        print(f"Probelauf: würde Vorschlag Woche {iso(week)} ausführen.")
        return False
    tx = send_tx(a, "execute()")
    update_record(out, week, executed_tx=tx, executed_at=iso_time(chain.now()))
    print(f"Ausgeführt: Woche {iso(week)} ({recent} / {baseline}), Faktor jetzt {chain.factor()}, {tx}")
    return True


def cmd_send(a) -> None:
    today = dt.datetime.now(dt.timezone.utc).date()
    url = cdc_url(today)
    rows = json.loads(Path(a.cdc_file).read_text()) if a.cdc_file else fetch(url)
    week, recent, baseline = pick_window(rows, today)
    target = target_milli(recent, baseline)
    print(f"CDC: 4 Wochen bis {iso(week)}: {recent} Tote, Vorjahre {baseline} "
          f"({(recent - baseline) / baseline:+.2%}), Ziel-Faktor {target}")

    # Stufe A: prüfen, bevor irgendetwas signiert wird.
    check_plausible(recent, baseline)
    out = Path(a.out_dir)
    drift = drift_check(out, parse_rows(rows), a.max_drift)
    if drift:
        raise ReportError("CDC-Zahlen weichen von eigenen früheren Meldungen ab, nicht gemeldet: " + "; ".join(drift))

    chain = Chain(a.rpc, a.oracle)
    if chain.retired():
        raise ReportError("Melder ist abgeschaltet (retire).")
    reconcile(out, chain)
    if not execute_due(a, chain, out, strict=True):
        return
    last = chain.last_week()
    if week <= last:
        print(f"Nichts zu tun: {iso(last)} ist schon gemeldet.")
        return
    last_prop = chain.last_proposed_at()
    if last_prop and chain.now() < last_prop + 6 * DAY:
        raise ReportError(f"Letzter Vorschlag {iso_time(last_prop)} liegt keine 6 Tage zurück")
    factor_now = chain.factor()
    print(f"Faktor jetzt {factor_now}, nach dieser Meldung {step_toward(factor_now, target)}")

    digest = cast("call", "--rpc-url", a.rpc, a.oracle,
                  "reportDigest(uint256,uint256,uint256)(bytes32)", str(week), str(recent), str(baseline))
    signer_w = wallet_args(a.signer_keystore, a.signer_password_file)
    signer = cast("wallet", "address", *signer_w)
    sender = cast("wallet", "address", *wallet_args(a.sender_keystore, a.sender_password_file))
    if signer.lower() == sender.lower():
        raise ReportError("Melde- und Gas-Schlüssel sind dieselbe Adresse. Getrennte Schlüssel verwenden.")
    signature = cast("wallet", "sign", "--no-hash", digest, *signer_w)

    record = {
        "week_ending": iso(week),
        "week_ending_unix": week,
        "recent_deaths": recent,
        "baseline_deaths": baseline,
        "weeks_used": {iso(d * DAY): parse_rows(rows)[d] for g in window_days(week // DAY) for d in g},
        "target_milli": target,
        "cdc_query": url,
        "cdc_rows": rows,
        "fetched_at": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
        "chain_id": int(cast("chain-id", "--rpc-url", a.rpc)),
        "oracle": a.oracle,
        "signer": signer,
        "sender": sender,
        "eip712_digest": digest,
        "signature": signature,
        "tx": None,
        "proposed_tx": None,
        "proposed_at": None,
        "executable_at": None,
    }
    out.mkdir(parents=True, exist_ok=True)
    path = record_path(out, week)

    if not a.dry_run:
        try:
            tx = send_tx(a, "propose(uint256,uint256,uint256,bytes)", str(week), str(recent), str(baseline), signature)
        except ReportError:
            path.write_text(json.dumps(record, indent=2) + "\n")
            raise
        due = chain.executable_at()
        record.update(tx=tx, proposed_tx=tx, proposed_at=iso_time(due - CHALLENGE_PERIOD),
                      executable_at=iso_time(due))
        print(f"Vorgeschlagen: {tx}, wirksam ab {iso_time(due)} (execute)")
    else:
        print("Probelauf: nichts gesendet.")
    path.write_text(json.dumps(record, indent=2) + "\n")
    write_index(out)
    print(f"Abgelegt: {path}")


def cmd_execute(a) -> None:
    out = Path(a.out_dir)
    chain = Chain(a.rpc, a.oracle)
    if chain.retired():
        raise ReportError("Melder ist abgeschaltet (retire).")
    if chain.pending()[0] == 0:
        reconcile(out, chain)
        write_index(out)
        print("Nichts offen.")
        return
    execute_due(a, chain, out, strict=True)
    reconcile(out, chain)
    write_index(out)


def status_of(rec: dict) -> str:
    if rec.get("vetoed"):
        return "verworfen"
    if rec.get("executed_tx") or rec.get("executed"):
        return "ausgeführt"
    if rec.get("proposed_tx"):
        return "offen"
    # Meldungen vor S6 (submit wirkte sofort)
    return "ausgeführt" if rec.get("tx") else "nicht gesendet"


def write_index(out: Path) -> None:
    """index.json für die öffentliche Prüfseite (oracle.html): alle Meldungen ohne Rohdaten, neueste zuerst."""
    keep = ("week_ending", "recent_deaths", "baseline_deaths", "target_milli", "weeks_used",
            "fetched_at", "chain_id", "oracle", "signer", "signature", "tx", "proposed_tx",
            "proposed_at", "executable_at", "executed_tx", "vetoed")
    items = []
    for f in sorted(out.glob("????-??-??.json"), reverse=True):
        rec = json.loads(f.read_text())
        items.append({k: rec.get(k) for k in keep} | {"file": f.name, "status": status_of(rec)})
    tmp = out / "index.json.tmp"
    tmp.write_text(json.dumps(items, indent=1) + "\n")
    tmp.replace(out / "index.json")


def cmd_verify(a) -> None:
    rec = json.loads(Path(a.file).read_text())
    days = ",".join(f"'{d}T00:00:00.000'" for d in rec["weeks_used"])
    q = {
        "state": "United States",
        "$select": "week_ending_date,total_deaths",
        "$where": f"`group` = 'By Week' AND week_ending_date in({days})",
    }
    now = parse_rows(fetch(CDC_BASE + "?" + urllib.parse.urlencode(q, quote_via=urllib.parse.quote)))
    ok = True
    for day, reported in rec["weeks_used"].items():
        cdc = now.get((dt.date.fromisoformat(day) - dt.date(1970, 1, 1)).days)
        diff = "fehlt" if cdc is None else f"{(reported - cdc) / cdc:+.2%}"
        print(f"Woche {day}: gemeldet {reported}, CDC heute {cdc} ({diff})")
        ok &= cdc is not None
    groups = window_days(rec["week_ending_unix"] // DAY)
    used = {(dt.date.fromisoformat(d) - dt.date(1970, 1, 1)).days: v for d, v in rec["weeks_used"].items()}
    recent = sum(used[d] for d in groups[0])
    baseline = (sum(used[d] for g in groups[1:] for d in g) + 1) // BASELINE_YEARS
    if (recent, baseline) != (rec["recent_deaths"], rec["baseline_deaths"]):
        print("Summen passen nicht zu den einzelnen Wochen!")
        ok = False
    if target_milli(recent, baseline) != rec["target_milli"]:
        print("Ziel-Faktor passt nicht zu den Zahlen!")
        ok = False
    print("Hinweis: Die CDC korrigiert jüngere Wochen oft noch um ein bis zwei Prozent nach oben.")
    sys.exit(0 if ok else 1)


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--ntfy-file", help="Datei mit der ntfy-Adresse für Alarme (sonst NTFY_URL)")
    sub = p.add_subparsers(dest="cmd", required=True)

    def chain_args(x, signer: bool) -> None:
        x.add_argument("--rpc", required=True)
        x.add_argument("--oracle", required=True)
        if signer:
            x.add_argument("--signer-keystore", required=True, help="Melde-Schlüssel, signiert nur, braucht kein ETH")
            x.add_argument("--signer-password-file", required=True)
        x.add_argument("--sender-keystore", required=True, help="Gas-Schlüssel, sendet propose/execute")
        x.add_argument("--sender-password-file", required=True)
        x.add_argument("--out-dir", required=True)
        x.add_argument("--dry-run", action="store_true")

    s = sub.add_parser("send")
    chain_args(s, signer=True)
    s.add_argument("--max-drift", type=float, default=DEFAULT_MAX_DRIFT,
                   help="erlaubte Abweichung einer schon gemeldeten CDC-Woche (Standard 0.03)")
    s.add_argument("--cdc-file", help="CDC-Antwort aus Datei statt Abruf (nur für Tests)")
    e = sub.add_parser("execute")
    chain_args(e, signer=False)
    v = sub.add_parser("verify")
    v.add_argument("file")
    a = p.parse_args()
    try:
        {"send": cmd_send, "execute": cmd_execute, "verify": cmd_verify}[a.cmd](a)
    except (ReportError, OSError, ValueError, KeyError) as err:
        msg = f"report.py {a.cmd}: {err}"
        print(f"Fehler: {msg}", file=sys.stderr)
        if a.cmd != "verify":
            alarm(msg, a.ntfy_file)
        sys.exit(1)


if __name__ == "__main__":
    main()
