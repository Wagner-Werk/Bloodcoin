// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {S11Handler} from "./S11Handler.sol";
import {VmX} from "./S11Setup.sol";
import {BloodcoinToken} from "../../src/BloodcoinToken.sol";
import {MortalityEmission} from "../../src/MortalityEmission.sol";
import {SignedMortalityOracle} from "../../src/SignedMortalityOracle.sol";
import {BcusStaking} from "../../src/BcusStaking.sol";
import {FounderLock} from "../../src/FounderLock.sol";
import {BcusMining} from "../../src/BcusMining.sol";

/// Invariantentests: Foundry ruft zufällige Folgen von Handler-Aktionen auf (foundry.toml:
/// [invariant] runs x depth) und prüft nach jeder Aktion alle invariant_-Funktionen.
contract S11InvariantTest {
    bool public IS_TEST = true;
    VmX internal constant vm = VmX(address(uint160(uint256(keccak256("hevm cheat code")))));
    address constant BURN = 0x000000000000000000000000000000000000dEaD;
    uint256 constant INITIAL = 1_000_000e18;

    S11Handler h;
    BloodcoinToken token;
    MortalityEmission em;
    SignedMortalityOracle oracle;
    BcusStaking st;
    FounderLock lock;
    BcusMining mn;

    function setUp() public {
        h = new S11Handler();
        (token, em, oracle, st, lock, mn) = h.c();
    }

    /// Nur der Handler wird aufgerufen (nicht die Contracts direkt).
    function targetContracts() public view returns (address[] memory t) {
        t = new address[](1);
        t[0] = address(h);
    }

    function _sync() internal {
        vm.warp(h.now_());
    }

    function _actors() internal view returns (address[3] memory a) {
        for (uint256 i = 0; i < 3; i++) a[i] = h.actors(i);
    }

    // ================================================================ Token und Emission

    /// Nie mehr als 21 Mio. BCUS.
    function invariant_SupplyBelowCap() public view {
        vm.assertLe(token.totalSupply(), 21_000_000e18, "ueber 21 Mio.");
        vm.assertLe(token.totalSupply(), token.cap(), "ueber cap()");
    }

    /// Ausgegeben + abgerechnet-aber-offen + noch-nicht-abgerechnet ist genau das, was der Plan mit
    /// den jeweils gültigen Faktoren ergibt (Schattenrechnung im Handler). Also nie mehr als der
    /// Emissionsplan, egal wer wann mint() aufruft oder meldet.
    function invariant_EmissionFollowsPlan() public {
        _sync();
        uint256 done = em.completedEpochs();
        uint256 f = em.factorMilli();
        uint256 contractSide = token.totalSupply() - INITIAL + em.pending();
        for (uint256 e = em.settledEpochs(); e < done; e++) contractSide += em.epochEmission(e) * f / 1000;
        uint256 ghostSide = h.ghostSettled();
        for (uint256 e = h.ghostSettledEpochs(); e < done; e++) ghostSide += em.epochEmission(e) * f / 1000;
        if (token.totalSupply() < token.cap()) vm.assertEq(contractSide, ghostSide, "Emission weicht vom Plan ab");
        else vm.assertLe(contractSide, ghostSide, "Emission ueber dem Plan");
        // Bei Faktor 1,0 wäre es höchstens der volle Plan.
        uint256 full;
        for (uint256 e = 0; e < done; e++) full += em.epochEmission(e);
        vm.assertLe(token.totalSupply() - INITIAL, full, "ueber dem vollen Plan");
    }

    /// Faktor und Ziel bleiben in [0,5; 1,0]; nach dem Abschalten ist der Faktor 1,0.
    function invariant_FactorBounds() public view {
        vm.assertLe(em.factorMilli(), 1000, "Faktor ueber 1,0");
        vm.assertGe(em.factorMilli(), 500, "Faktor unter 0,5");
        vm.assertLe(em.targetMilli(), 1000, "Ziel ueber 1,0");
        vm.assertGe(em.targetMilli(), 500, "Ziel unter 0,5");
        if (oracle.retired()) vm.assertEq(em.factorMilli(), 1000, "Faktor nach retire nicht 1,0");
        vm.assertTrue(oracle.retired() == h.ghostRetired(), "retired-Status falsch");
    }

    /// Jede Ausgabe geht halb/halb an Mining und Staking (höchstens 1 wei Rundung pro Aktion).
    function invariant_MintSplitHalfHalf() public view {
        uint256 minted = token.totalSupply() - INITIAL;
        uint256 toMining = token.balanceOf(address(mn)) + h.ghostMined() - st.sentToMining();
        uint256 toStaking = minted - toMining;
        vm.assertLe(toMining, toStaking, "Mining bekam mehr als Staking");
        vm.assertLe(toStaking - toMining, h.calls() + 1, "Aufteilung nicht halb/halb");
    }

    /// Kein BCUS taucht aus dem Nichts auf oder verschwindet: alles liegt bei bekannten Haltern.
    function invariant_Conservation() public view {
        address[3] memory a = _actors();
        uint256 sum = token.balanceOf(address(lock)) + token.balanceOf(address(mn)) + token.balanceOf(address(st))
            + token.balanceOf(BURN);
        for (uint256 i = 0; i < 3; i++) sum += token.balanceOf(a[i]);
        vm.assertEq(sum, token.totalSupply(), "BCUS bei unbekanntem Halter");
        vm.assertEq(token.balanceOf(BURN), st.burned(), "burned stimmt nicht mit BURN-Saldo");
    }

    /// Jeder Nutzer hat genau das, was die Schattenbuchhaltung sagt (Mining, Freigabe, Einsatz,
    /// Abheben, Abholen, Überweisungen). Abheben gibt also nie mehr und nie weniger als verlangt.
    function invariant_BalancesMatchGhost() public view {
        address[3] memory a = _actors();
        for (uint256 i = 0; i < 3; i++) vm.assertEq(token.balanceOf(a[i]), h.ghostBal(a[i]), "Nutzer-Saldo falsch");
    }

    // ================================================================ Staking

    /// Gesamteinsatz = Summe der Einzeleinsätze = Schattenbuchhaltung.
    function invariant_StakeSum() public view {
        address[3] memory a = _actors();
        uint256 sum;
        uint256 ghost;
        for (uint256 i = 0; i < 3; i++) {
            sum += st.stakedOf(a[i]);
            ghost += h.ghostStake(a[i]);
            vm.assertEq(st.stakedOf(a[i]), h.ghostStake(a[i]), "Einzeleinsatz falsch");
        }
        vm.assertEq(st.totalStaked(), sum, "totalStaked != Summe stakedOf");
        vm.assertEq(sum, ghost, "Einsatz != Schatten");
    }

    /// Das Staking kann immer jeden Einsatz und alle zugesagten Belohnungen auszahlen.
    function invariant_StakingSolvent() public view {
        vm.assertLe(st.totalStaked() + st.reserved(), token.balanceOf(address(st)), "Staking zahlungsunfaehig");
    }

    /// Verdiente, offene Belohnungen sind durch die Reserve gedeckt.
    function invariant_EarnedCoveredByReserve() public {
        _sync();
        address[3] memory a = _actors();
        uint256 sum;
        for (uint256 i = 0; i < 3; i++) sum += st.earned(a[i]);
        vm.assertLe(sum, st.reserved(), "offene Belohnungen nicht gedeckt");
    }

    /// Was beim Staking ankam (Staking-Hälfte der Emission + Spenden), ist vollständig aufgeteilt:
    /// ans Mining, verbrannt, abgeholt, in der Reserve oder noch nicht verteilt. Insbesondere ist
    /// die Summe aller Claims nie größer als die gemintete Staking-Hälfte plus Spenden.
    function invariant_StakingBooksBalance() public view {
        uint256 minted = token.totalSupply() - INITIAL;
        uint256 toMining = token.balanceOf(address(mn)) + h.ghostMined() - st.sentToMining();
        uint256 inflow = minted - toMining + h.ghostDonated();
        uint256 outflow = st.sentToMining() + st.burned() + h.ghostClaimed()
            + (token.balanceOf(address(st)) - st.totalStaked());
        vm.assertEq(inflow, outflow, "Staking-Buchhaltung geht nicht auf");
        vm.assertLe(h.ghostClaimed(), minted - toMining + h.ghostDonated(), "mehr abgeholt als angekommen");
    }

    /// Über die ganze Laufzeit bekommen die Staker zusammen nie mehr als 1 % pro Woche ihres
    /// tatsächlichen, sekundengenau gemessenen Einsatzes (eigene Rechnung des Handlers, unabhängig
    /// vom Contract). Das deckt beide Befunde vom 3.11. ab: Aufrunden (B1) und Kurz-Staken (B2).
    function invariant_StakersNeverAboveOnePercentPerWeek() public view {
        vm.assertLe(h.ghostParts(), h.ghostStakeIntegral() / (100 * 1 weeks), "Staker ueber 1 %/Woche");
    }

    function invariant_ShareAtMostAll() public view {
        vm.assertLe(st.stakerShareBp(), 10_000, "Anteil > 100 %");
        vm.assertLe(st.nextShareBp(), 10_000, "zeitgewichteter Anteil > 100 %");
    }

    // ================================================================ FounderLock

    /// Der Lock gibt linear frei (100.000 pro Jahr) und nur an den Empfänger.
    function invariant_FounderLockLinear() public {
        _sync();
        uint256 rel = lock.released(address(token));
        vm.assertEq(token.balanceOf(address(lock)) + rel, INITIAL, "Lock hat Coins verloren");
        uint256 elapsed = block.timestamp - lock.start();
        uint256 dur = lock.duration();
        vm.assertLe(rel, elapsed >= dur ? INITIAL : INITIAL * elapsed / dur, "mehr frei als linear");
    }

    // ================================================================ während der Aktionen

    function invariant_NoViolationsDuringActions() public view {
        string memory why = h.lastViolation();
        vm.assertEq(h.capViolations(), 0, why);
        vm.assertEq(h.shareViolations(), 0, why);
        vm.assertEq(h.stepViolations(), 0, why);
        vm.assertEq(h.unexpectedReverts(), 0, why);
        vm.assertEq(h.unexpectedSuccess(), 0, why);
        vm.assertEq(h.mineRewardViolations(), 0, why);
        vm.assertEq(h.releaseViolations(), 0, why);
    }
}
