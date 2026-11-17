"""Tests für atomares Speichern und Laden mit Fallback (Vorfall chain.json 15.11.2026)."""
import glob
import json
import os
import tempfile
import unittest
from unittest import mock

from bloodcoin import storage
from bloodcoin.chain import Blockchain, mine
from bloodcoin.crypto import Wallet
from bloodcoin.node import Node

BITS = 8


def chain_with(height, addr):
    bc = Blockchain(BITS)
    for _ in range(height):
        bc.add_block(mine(bc.block_template(addr)))
    return bc


class StorageTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = self.tmp.name
        self.path = os.path.join(self.dir, "chain.json")
        self.addr = Wallet.generate().address
        self.logs = []
        self.log = self.logs.append

    def tearDown(self):
        self.tmp.cleanup()

    def leftovers(self):
        return [n for n in os.listdir(self.dir) if n.endswith(".tmp") or n.endswith(".neu")]

    # --- Speichern
    def test_save_writes_valid_json_and_keeps_previous_as_bak(self):
        bc = chain_with(2, self.addr)
        bc.save(self.path, log=self.log)
        self.assertFalse(os.path.exists(self.path + ".bak"))   # erstes Speichern: nichts zu sichern
        bc.add_block(mine(bc.block_template(self.addr)))
        bc.save(self.path, log=self.log)
        with open(self.path) as f:
            self.assertEqual(len(json.load(f)), 4)
        with open(self.path + ".bak") as f:
            self.assertEqual(len(json.load(f)), 3)
        self.assertEqual(self.leftovers(), [])

    def test_crash_while_writing_leaves_old_file_intact(self):
        bc = chain_with(3, self.addr)
        bc.save(self.path, log=self.log)
        with open(self.path, "rb") as f:
            before = f.read()
        bc.add_block(mine(bc.block_template(self.addr)))

        def half_dump(obj, f):
            f.write(json.dumps(obj)[:100])   # Prozess stirbt mitten im Schreiben
            raise KeyboardInterrupt("simulierter Abbruch")

        with mock.patch.object(storage.json, "dump", half_dump):
            with self.assertRaises(KeyboardInterrupt):
                bc.save(self.path, log=self.log)
        with open(self.path, "rb") as f:
            self.assertEqual(f.read(), before)
        self.assertEqual(self.leftovers(), [])
        self.assertEqual(Blockchain.load(self.path, BITS, log=self.log).height, 3)

    def test_crash_before_replace_leaves_old_file_intact(self):
        bc = chain_with(2, self.addr)
        bc.save(self.path, log=self.log)
        bc.add_block(mine(bc.block_template(self.addr)))
        with mock.patch.object(storage.os, "replace", side_effect=OSError("Datenträger voll")):
            with self.assertRaises(OSError):
                bc.save(self.path, log=self.log)
        self.assertEqual(Blockchain.load(self.path, BITS, log=self.log).height, 2)

    # --- Laden
    def test_truncated_file_falls_back_to_bak_and_keeps_broken_file(self):
        bc = chain_with(3, self.addr)
        bc.save(self.path, log=self.log)
        bc.add_block(mine(bc.block_template(self.addr)))
        bc.save(self.path, log=self.log)
        # Wie am 15.11.: Datei auf ~74 % abgeschnitten (54.4 MB -> 40.4 MB)
        size = os.path.getsize(self.path)
        with open(self.path, "r+b") as f:
            f.truncate(int(size * 0.74))
        loaded = Blockchain.load(self.path, BITS, log=self.log)
        self.assertEqual(loaded.height, 3)                     # Stand der Sicherung
        broken = glob.glob(self.path + ".kaputt-*")
        self.assertEqual(len(broken), 1)                       # nichts gelöscht
        self.assertEqual(os.path.getsize(broken[0]), int(size * 0.74))
        self.assertTrue(any("FEHLER" in m for m in self.logs))
        self.assertTrue(any("Sicherung" in m for m in self.logs))
        # Danach läuft Speichern normal weiter
        loaded.save(self.path, log=self.log)
        self.assertEqual(Blockchain.load(self.path, BITS, log=self.log).height, 3)

    def test_valid_json_with_tampered_block_falls_back(self):
        bc = chain_with(2, self.addr)
        bc.save(self.path, log=self.log)
        bc.add_block(mine(bc.block_template(self.addr)))
        bc.save(self.path, log=self.log)
        with open(self.path) as f:
            data = json.load(f)
        data[2]["nonce"] += 1                                   # Proof-of-Work kaputt
        with open(self.path, "w") as f:
            json.dump(data, f)
        self.assertEqual(Blockchain.load(self.path, BITS, log=self.log).height, 2)

    def test_both_broken_raises_and_touches_nothing(self):
        for p in (self.path, self.path + ".bak"):
            with open(p, "w") as f:
                f.write('[{"height": 0, "pre')
        with self.assertRaises(storage.ChainFileError) as ctx:
            Blockchain.load(self.path, BITS, log=self.log)
        self.assertIn("NICHT", str(ctx.exception))
        self.assertTrue(os.path.exists(self.path))
        self.assertTrue(os.path.exists(self.path + ".bak"))
        self.assertEqual(glob.glob(self.path + ".kaputt-*"), [])

    def test_no_file_means_fresh_start(self):
        self.assertIsNone(Blockchain.load_or_none(self.path, BITS, log=self.log))
        with self.assertRaises(FileNotFoundError):
            Blockchain.load(self.path, BITS, log=self.log)

    def test_only_bak_present_is_used(self):
        bc = chain_with(2, self.addr)
        bc.save(self.path, log=self.log)
        os.replace(self.path, self.path + ".bak")
        self.assertEqual(Blockchain.load(self.path, BITS, log=self.log).height, 2)

    def test_stale_temp_files_are_removed_on_load(self):
        chain_with(1, self.addr).save(self.path, log=self.log)
        stale = os.path.join(self.dir, "chain.json.abc123.tmp")
        with open(stale, "w") as f:
            f.write("[")
        Blockchain.load(self.path, BITS, log=self.log)
        self.assertFalse(os.path.exists(stale))

    # --- Knoten
    def test_node_starts_from_bak_instead_of_crash_loop(self):
        data = os.path.join(self.dir, "data")
        os.makedirs(data)
        chain_file = os.path.join(data, "chain.json")
        bc = chain_with(3, self.addr)
        bc.save(chain_file, log=self.log)
        bc.add_block(mine(bc.block_template(self.addr)))
        bc.save(chain_file, log=self.log)
        with open(chain_file, "r+b") as f:
            f.truncate(50)
        node = Node("127.0.0.1", 18491, data, [], None, BITS, log=self.log)
        self.assertEqual(node.chain.height, 3)

    def test_node_refuses_to_start_fresh_when_everything_is_broken(self):
        data = os.path.join(self.dir, "data")
        os.makedirs(data)
        with open(os.path.join(data, "chain.json"), "w") as f:
            f.write("[")
        with self.assertRaises(storage.ChainFileError):
            Node("127.0.0.1", 18492, data, [], None, BITS, log=self.log)

    def test_node_survives_failed_save(self):
        data = os.path.join(self.dir, "data")
        node = Node("127.0.0.1", 18493, data, [], None, BITS, log=self.log)
        node.chain.add_block(mine(node.chain.block_template(self.addr)))
        node.save_chain()
        node.chain.add_block(mine(node.chain.block_template(self.addr)))
        with mock.patch.object(storage.os, "replace", side_effect=OSError(28, "No space left on device")):
            node.save_chain()                                   # wirft nicht
        self.assertTrue(any("nicht gespeichert" in m for m in self.logs))
        self.assertEqual(Blockchain.load(node.chain_file, BITS, log=self.log).height, 1)
        node.save_chain()
        self.assertEqual(Blockchain.load(node.chain_file, BITS, log=self.log).height, 2)


if __name__ == "__main__":
    unittest.main()
