// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {S11Setup} from "./S11Setup.sol";

/// Befunde aus den Fuzz- und Invariantentests, als nachvollziehbare Szenarien.
/// Diese Tests sind GRÜN, SOLANGE DIE SCHWÄCHE BESTEHT: Sie halten fest, wie sich der Code
/// heute verhält. Wird der Contract geändert, müssen sie angepasst werden (dann sollten sie
/// zeigen, dass die Schwäche weg ist). Bericht: siehe PR-Beschreibung.
contract S11FindingsTest is S11Setup {
    bool public IS_TEST = true;

    address constant ALICE = address(0xA11CE);   // Gründer / Wal
    address constant BOB = address(0xB0B);       // kleiner Staker (oder zweite Adresse des Wals)

    event Measured(string what, uint256 bcus);

    function freshS11() internal {
        deployS11(ALICE);
        vmx.prank(ALICE);
        token.approve(address(st), type(uint256).max);
        vmx.prank(BOB);
        token.approve(address(st), type(uint256).max);
        // Ein Jahr Gründer-Freigabe: ALICE hat dann 100.000 BCUS frei.
        vmx.warp(START + 365 days);
        lock.release(address(token));
    }

    // ------------------------------------------------------------------ Befund 1

    /// Misst, was der Staker in 10 Wochen bekommt, wenn jede Woche genau einmal synchronisiert
    /// wird, und zwar `drift` Sekunden später als in der Vorwoche.
    function tenWeeks(uint256 drift) internal returns (uint256 got) {
        freshS11();
        vmx.prank(ALICE);
        st.stake(50_000e18);                    // Hälfte des Umlaufs, Deckel 1 % = 500 BCUS/Woche
        vmx.warp(START + 53 weeks);
        st.pull();
        uint256 r0 = st.reserved();
        for (uint256 k = 1; k <= 10; k++) {
            vmx.warp(START + (53 + k) * 1 weeks + k * drift);
            st.pull();
        }
        got = st.reserved() - r0;              // nichts abgeholt, also alles in der Reserve
    }

    /// Befund 1: Der Deckel rundet die Wochen seit der letzten Synchronisation AUF. Liegen zwischen
    /// zwei Synchronisationen eine Woche und eine Sekunde, gilt der Deckel für zwei Wochen.
    /// Wer (in einem ruhigen Netz) selbst bestimmt, wann synchronisiert wird, verschiebt jede Woche
    /// um eine Sekunde und bekommt dauerhaft 2 % statt 1 % pro Woche.
    function testBefund1_DeckelRundungErlaubtZweiProzent() public {
        uint256 normal = tenWeeks(0);
        uint256 drift = tenWeeks(1);
        emit Measured("10 Wochen, Sync exakt woechentlich", normal / 1e18);
        emit Measured("10 Wochen, Sync jede Woche 1 s spaeter", drift / 1e18);
        // exakt wöchentlich: 10 x 1 % von 50.000 = 5.000 BCUS
        vmx.assertEq(normal, 5_000e18, "Kontrollfall nicht 1 %/Woche");
        // eine Sekunde Versatz pro Woche: 10 x 2 % = 10.000 BCUS, also das Doppelte
        vmx.assertEq(drift, 10_000e18, "Befund 1 nicht mehr reproduzierbar (behoben?)");
    }

    // ------------------------------------------------------------------ Befund 2

    /// Was BOB (100 BCUS gestakt) in der Woche nach einer Ausgabe bekommt.
    function bobWeek(bool whale) internal returns (uint256 got, uint256 whaleGot) {
        freshS11();
        vmx.prank(ALICE);
        token.transfer(BOB, 100e18);
        vmx.prank(BOB);
        st.stake(100e18);
        uint256 boundary = START + 54 weeks;
        vmx.warp(boundary - 1 weeks + 10);
        st.pull();                              // letzte Ausgabe normal verteilt
        vmx.warp(boundary - 3);
        vmx.prank(BOB);
        st.claim();                             // Vorwoche abholen, gemessen wird nur die neue Woche
        if (whale) {
            vmx.warp(boundary - 2);             // Block vor der Wochengrenze
            uint256 all = token.balanceOf(ALICE);
            vmx.prank(ALICE);
            st.stake(all);
        }
        vmx.warp(boundary + 2);                 // Block nach der Grenze: Ausgabe wird verteilt
        st.pull();
        if (whale) {
            vmx.warp(boundary + 4);             // nächster Block: Wal ist wieder draußen
            vmx.prank(ALICE);
            st.exit();
            whaleGot = token.balanceOf(ALICE);
        }
        vmx.warp(boundary + 1 weeks + 1);
        uint256 b0 = token.balanceOf(BOB);
        vmx.prank(BOB);
        st.claim();
        got = token.balanceOf(BOB) - b0;
    }

    /// Befund 2 (bestätigt den bekannten Punkt M2 aus der Vorprüfung vom 27.10. und beziffert ihn):
    /// Anteil und Deckel werden im Augenblick der Synchronisation berechnet. Wer viel BCUS hat,
    /// stakt sie einen Block vor der Wochengrenze, löst nach der Grenze die Verteilung aus und hebt
    /// einen Block später wieder ab. Sein Geld ist rund 6 Sekunden gebunden, er selbst verdient fast
    /// nichts, aber die ganze erhöhte Wochenmenge fließt danach an die übrigen Staker, etwa an
    /// seine eigene zweite Adresse. Anteils-Regel und 1-%-Deckel sind damit für jeden mit
    /// genug freiem Kapital umgehbar, ohne Sperrzeit und ohne Risiko.
    function testBefund2_WalUmgehtAnteilUndDeckelInSechsSekunden() public {
        (uint256 alone,) = bobWeek(false);
        (uint256 withWhale, uint256 whaleNet) = bobWeek(true);
        emit Measured("BOB, Woche ohne Wal", alone / 1e18);
        emit Measured("BOB, Woche mit 6-Sekunden-Wal", withWhale / 1e18);
        // Ohne Wal: Deckel 1 % von 100 BCUS = 1 BCUS.
        vmx.assertLe(alone, 1.01e18, "Kontrollfall ueber 1 BCUS");
        // Mit Wal: fast 1 % von 100.000 BCUS, also rund 1.000 BCUS, das Tausendfache.
        vmx.assertGe(withWhale, 990e18, "Befund 2 nicht mehr reproduzierbar (behoben?)");
        // Der Wal bekommt seinen Einsatz voll zurück (plus Staub).
        vmx.assertGe(whaleNet, 99_900e18, "Wal verliert Einsatz");
    }
}
