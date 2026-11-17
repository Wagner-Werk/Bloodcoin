"""Sicheres Speichern und Laden der Chain-Datei.

Hintergrund (15.11.2026): `chain.json` wurde direkt mit open(path, "w") überschrieben.
Wird der Prozess dabei beendet (Neustart, OOM, voller Datenträger), bleibt eine
abgeschnittene, ungültige Datei zurück und der Knoten startet nie mehr.

Jetzt gilt:
  * Schreiben geht in eine Temp-Datei im selben Verzeichnis, mit flush + fsync,
    und ersetzt die alte Datei danach atomar mit os.replace. Entweder liegt die
    alte oder die neue Datei vollständig da, nie eine halbe.
  * Vor dem Ersetzen wird die bisherige Datei als `<datei>.bak` behalten
    (Hardlink, kostet keine Kopie). Das ist immer die letzte vollständige Version.
  * Beim Laden: ist die Hauptdatei kaputt, wird sie NICHT gelöscht oder
    überschrieben, sondern als `<datei>.kaputt-<zeit>` beiseitegelegt, und die
    `.bak` wird geladen. Sind beide kaputt, bricht der Start mit klarer Meldung ab,
    statt still eine neue Chain ab Genesis zu beginnen.
"""
from __future__ import annotations

import json
import os
import tempfile
import time
from typing import Any, Callable, Optional


class ChainFileError(Exception):
    """Chain-Datei vorhanden, aber weder sie noch die Sicherung ist lesbar."""


def backup_path(path: str) -> str:
    return path + ".bak"


def _fsync_dir(directory: str) -> None:
    # Damit auch das Umbenennen selbst nach einem Stromausfall Bestand hat.
    try:
        fd = os.open(directory, os.O_RDONLY)
    except OSError:
        return
    try:
        os.fsync(fd)
    except OSError:
        pass
    finally:
        os.close(fd)


def _keep_backup(path: str, log: Callable[[str], None]) -> None:
    """Hält die aktuelle (vollständige) Datei als .bak fest, per Hardlink."""
    if not os.path.exists(path):
        return
    bak = backup_path(path)
    tmp_link = bak + ".neu"
    try:
        if os.path.exists(tmp_link):
            os.unlink(tmp_link)
        os.link(path, tmp_link)
        os.replace(tmp_link, bak)   # auch .bak wird nie halb ersetzt
    except OSError as e:
        # Ohne Hardlink-Unterstützung lieber keine .bak als bei jedem Block 50 MB kopieren.
        log(f"WARNUNG: konnte {bak} nicht anlegen ({e}); Speichern läuft trotzdem atomar weiter")


def atomic_write_json(path: str, obj: Any, keep_backup: bool = True,
                      log: Callable[[str], None] = print) -> None:
    """Schreibt `obj` als JSON nach `path`, ohne dass je eine halbe Datei entstehen kann."""
    directory = os.path.dirname(os.path.abspath(path))
    fd, tmp = tempfile.mkstemp(prefix=os.path.basename(path) + ".", suffix=".tmp", dir=directory)
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(obj, f)
            f.flush()
            os.fsync(f.fileno())
        if keep_backup:
            _keep_backup(path, log)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    _fsync_dir(directory)


def cleanup_temp_files(path: str, log: Callable[[str], None] = print) -> None:
    """Entfernt liegengebliebene Temp-Dateien eines abgebrochenen Schreibvorgangs."""
    directory = os.path.dirname(os.path.abspath(path))
    prefix = os.path.basename(path) + "."
    for name in os.listdir(directory):
        if name.startswith(prefix) and (name.endswith(".tmp") or name.endswith(".bak.neu")):
            try:
                os.unlink(os.path.join(directory, name))
                log(f"Alte Temp-Datei entfernt: {name}")
            except OSError:
                pass


def quarantine(path: str, log: Callable[[str], None] = print) -> str:
    """Legt eine kaputte Datei beiseite, ohne sie zu löschen. Gibt den neuen Namen zurück."""
    target = f"{path}.kaputt-{time.strftime('%Y%m%d-%H%M%S', time.gmtime())}"
    n = 1
    while os.path.exists(target):
        n += 1
        target = f"{path}.kaputt-{time.strftime('%Y%m%d-%H%M%S', time.gmtime())}-{n}"
    os.replace(path, target)
    log(f"Kaputte Datei beiseitegelegt als {target} (nicht gelöscht)")
    return target


def load_with_fallback(path: str, build: Callable[[Any], Any],
                       log: Callable[[str], None] = print) -> Optional[Any]:
    """Lädt `path`, bei Fehler die `.bak`.

    `build` bekommt das geparste JSON und baut daraus das Objekt (z. B. die Chain);
    wirft `build` einen Fehler, gilt die Datei ebenfalls als kaputt.

    Rückgabe: das gebaute Objekt, oder None, wenn weder Datei noch Sicherung existieren
    (echter Erststart). Existiert eine Datei, ist aber keine brauchbar: ChainFileError.
    """
    if os.path.isdir(os.path.dirname(os.path.abspath(path))):
        cleanup_temp_files(path, log)
    bak = backup_path(path)
    errors = []
    main_broken = False
    for candidate in (path, bak):
        if not os.path.exists(candidate):
            continue
        try:
            with open(candidate) as f:
                data = json.load(f)
            result = build(data)
        except Exception as e:  # JSON kaputt, abgeschnitten, ungültige Blöcke ...
            size = os.path.getsize(candidate)
            msg = f"{candidate} unbrauchbar ({size} Bytes): {type(e).__name__}: {e}"
            log(f"FEHLER: {msg}")
            errors.append(msg)
            if candidate == path:
                main_broken = True
            continue
        if candidate == bak:
            log(f"WARNUNG: {path} war kaputt oder fehlte, Chain aus Sicherung {bak} geladen. "
                f"Die neuesten Blöcke seit der Sicherung fehlen und werden neu gemint/synchronisiert.")
            if main_broken:
                quarantine(path, log)
        return result
    if errors:
        raise ChainFileError(
            "Chain-Datei und Sicherung sind beide unbrauchbar. Der Knoten startet absichtlich NICHT "
            "mit einer neuen Chain, damit nichts überschrieben wird. Aus dem Backup wiederherstellen. "
            "Details: " + " | ".join(errors))
    return None
