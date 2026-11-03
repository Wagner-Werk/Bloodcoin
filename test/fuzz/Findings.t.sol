// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {S11Setup} from "./S11Setup.sol";

/// Befunde aus den Fuzz- und Invariantentests vom 3.11.2026, als nachvollziehbare Szenarien.
/// Beide sind seit dem zeitgewichteten Einsatz in BcusStaking behoben; die Tests zeigen das.
/// Vorher ergab B1 10.000 statt 5.000 BCUS und B2 999 statt 1 BCUS.
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

    /// Befund 1 (behoben): Der Deckel rundete die Wochen seit der letzten Synchronisation AUF.
    /// Wer jede Woche eine Sekunde später synchronisierte, bekam dauerhaft 2 % statt 1 %.
    /// Jetzt ist der Deckel sekundengenau: eine Sekunde mehr gibt eine Sekunde mehr.
    function testBefund1_DeckelRundetNichtMehrAuf() public {
        uint256 normal = tenWeeks(0);
        uint256 drift = tenWeeks(1);
        emit Measured("10 Wochen, Sync exakt woechentlich", normal / 1e18);
        emit Measured("10 Wochen, Sync jede Woche 1 s spaeter", drift / 1e18);
        // exakt wöchentlich: 10 x 1 % von 50.000 = 5.000 BCUS
        vmx.assertEq(normal, 5_000e18, "Kontrollfall nicht 1 %/Woche");
        // eine Sekunde Versatz pro Woche: 10 Sekunden mehr, also praktisch dasselbe (vorher 10.000)
        vmx.assertLe(drift, 5_000e18 + 1e17, "Deckel ueber 1 %/Woche");
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

    /// Befund 2 (behoben; war Punkt M2 der Vorprüfung vom 27.10.): Anteil und Deckel wurden im
    /// Augenblick der Synchronisation berechnet. Ein Wal stakte einen Block vor der Wochengrenze,
    /// löste nach der Grenze die Verteilung aus und hob einen Block später ab; die erhöhte
    /// Wochenmenge floss an die übrigen Staker (z. B. seine Zweitadresse). Jetzt zählt der
    /// zeitgewichtete Einsatz: 6 Sekunden mit 99.900 BCUS zählen wie rund 1 BCUS eine Woche lang.
    function testBefund2_WalBringtNichtsMehr() public {
        (uint256 alone,) = bobWeek(false);
        (uint256 withWhale, uint256 whaleNet) = bobWeek(true);
        emit Measured("BOB, Woche ohne Wal", alone / 1e18);
        emit Measured("BOB, Woche mit 6-Sekunden-Wal", withWhale / 1e18);
        // Ohne Wal: Deckel 1 % von 100 BCUS = 1 BCUS.
        vmx.assertLe(alone, 1.01e18, "Kontrollfall ueber 1 BCUS");
        // Mit Wal: praktisch dasselbe (vorher 999 BCUS).
        vmx.assertLe(withWhale, 1.02e18, "Wal hebt Anteil oder Deckel");
        // Der Wal bekommt seinen Einsatz voll zurück (plus Staub).
        vmx.assertGe(whaleNet, 99_900e18, "Wal verliert Einsatz");
    }

    // ------------------------------------------------------------------ Befund 3

    /// Was ALICE (50.000 BCUS gestakt, Hälfte des Umlaufs) in einer Woche bekommt, wenn jemand
    /// eine Sekunde vor der Wochengrenze 1 wei ans Staking schickt und pull() aufruft.
    function griefedWeek(bool grief) internal returns (uint256 got) {
        freshS11();
        vmx.prank(ALICE);
        st.stake(50_000e18);
        vmx.prank(ALICE);
        token.transfer(BOB, 1e18);
        vmx.warp(START + 53 weeks);
        st.pull();
        uint256 r0 = st.reserved();
        if (grief) {
            vmx.warp(START + 54 weeks - 1);
            vmx.prank(BOB);
            token.transfer(address(st), 1);         // 1 wei Spende
            st.pull();
        }
        vmx.warp(START + 54 weeks + 1);
        st.pull();
        got = st.reserved() - r0;
    }

    /// Befund 3 (entstand mit der ersten Fassung der Korrektur, behoben): Wenn jede Spende das
    /// Zeitfenster neu startet, kann jemand (etwa ein Miner, dem der Rest zufliesst) mit 1 wei pro
    /// Woche das Fenster kurz vor der Ausgabe zurücksetzen. Dann gilt die Obergrenze nur für zwei
    /// Sekunden, und fast die ganze Staking-Hälfte geht ans Mining. Jetzt beginnt ein neues
    /// Fenster nur, wenn eine neue Emissions-Woche angekommen ist.
    function testBefund3_SpendeSetztFensterNichtZurueck() public {
        uint256 normal = griefedWeek(false);
        uint256 griefed = griefedWeek(true);
        emit Measured("Woche normal", normal / 1e18);
        emit Measured("Woche mit 1-wei-Spende kurz vor der Grenze", griefed / 1e18);
        vmx.assertGe(normal, 499e18, "Kontrollfall nicht rund 1 %");
        vmx.assertGe(griefed, normal - 1e18, "Spende drueckt die Staker");
    }
}
