// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {S11Setup} from "./S11Setup.sol";
import {SignedMortalityOracle} from "../../src/SignedMortalityOracle.sol";
import {BcusStaking} from "../../src/BcusStaking.sol";

/// Fuzz-Tests (zufällige Eingaben) für die S11-Contracts im Aufbau von DeploySigned.
/// Jede Funktion mit Parametern läuft mit vielen zufälligen Werten (foundry.toml: [fuzz] runs).
contract S11FuzzTest is S11Setup {
    bool public IS_TEST = true;

    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);
    uint256 constant SECP_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    function setUp() public {
        deployS11(ALICE);
        vmx.prank(ALICE);
        token.approve(address(st), type(uint256).max);
        vmx.prank(BOB);
        token.approve(address(st), type(uint256).max);
    }

    // ================================================================ Sterbe-Faktor

    function validDeaths(uint256 r, uint256 b) internal pure returns (uint256 recent, uint256 baseline) {
        baseline = clamp(b, 80_000, 1_000_000);
        uint256 lo = baseline / 2 + 1;
        uint256 hi = 2 * baseline;
        if (lo < 80_000) lo = 80_000;
        if (hi > 1_000_000) hi = 1_000_000;
        recent = clamp(r, lo, hi);
    }

    /// Ziel immer zwischen 0,5 und 1,0; weniger oder gleich viele Tote wie üblich ergeben 1,0.
    function testFuzz_TargetInRangeAndNeverAboveOne(uint256 r, uint256 b) public view {
        (uint256 recent, uint256 baseline) = validDeaths(r, b);
        uint256 t = em.targetFor(recent, baseline);
        vmx.assertGe(t, 500, "Ziel unter 0,5");
        vmx.assertLe(t, 1000, "Ziel ueber 1,0");
        if (recent <= baseline) vmx.assertEq(t, 1000, "Untersterblichkeit gibt kein Extra");
    }

    /// Mehr Tote führen nie zu einem höheren Ziel (monoton fallend).
    function testFuzz_TargetMonotonic(uint256 r, uint256 b, uint256 d) public view {
        (uint256 recent, uint256 baseline) = validDeaths(r, b);
        uint256 more = recent + d % 200_000;
        vmx.assertLe(em.targetFor(more, baseline), em.targetFor(recent, baseline), "mehr Tote, hoeheres Ziel");
    }

    /// Ein Schritt bewegt den Faktor höchstens 0,05 und nie über das Ziel hinaus.
    function testFuzz_StepAtMost50(uint256 c, uint256 t) public view {
        uint256 cur = clamp(c, 500, 1000);
        uint256 target = clamp(t, 500, 1000);
        uint256 next = em.stepToward(cur, target);
        uint256 diff = next > cur ? next - cur : cur - next;
        vmx.assertLe(diff, 50, "Schritt groesser als 0,05");
        if (target >= cur) vmx.assertTrue(next >= cur && next <= target, "ueber das Ziel");
        else vmx.assertTrue(next <= cur && next >= target, "unter das Ziel");
    }

    /// Eine Folge zufälliger, gültig signierter Meldungen: Faktor bleibt in [0,5; 1,0], jeder Schritt
    /// höchstens 0,05, und der Faktor stimmt mit stepToward(alt, targetFor(...)) überein.
    function testFuzz_ReportSequence(uint256 seed) public {
        uint256 t = START + 9 weeks;
        for (uint256 i = 0; i < 25; i++) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            t += 1 weeks;
            vmx.warp(t);
            uint256 we = latestReportableSaturday(t);
            (uint256 recent, uint256 baseline) = validDeaths(seed, seed >> 128);
            uint256 before = em.factorMilli();
            uint256 expect = em.stepToward(before, em.targetFor(recent, baseline));
            oracle.submit(we, recent, baseline, sig(SIGNER_PK, oracle.reportDigest(we, recent, baseline)));
            uint256 f = em.factorMilli();
            vmx.assertEq(f, expect, "Faktor falsch");
            vmx.assertLe(f, 1000, "Faktor ueber 1,0");
            vmx.assertGe(f, 500, "Faktor unter 0,5");
            vmx.assertLe(f > before ? f - before : before - f, 50, "Sprung > 0,05");
        }
    }

    // ================================================================ Melder

    function testFuzz_WrongSignerRejected(uint256 pk, uint256 r, uint256 b) public {
        pk = clamp(pk, 1, SECP_N - 1);
        vmx.assume(pk != SIGNER_PK);
        vmx.warp(START + 10 weeks);
        uint256 we = latestReportableSaturday(block.timestamp);
        (uint256 recent, uint256 baseline) = validDeaths(r, b);
        bytes memory s = sig(pk, oracle.reportDigest(we, recent, baseline));
        vmx.expectRevert(SignedMortalityOracle.BadSignature.selector);
        oracle.submit(we, recent, baseline, s);
    }

    /// Eine gültige Signatur passt nur zu genau den signierten Zahlen.
    function testFuzz_TamperedReportRejected(uint256 r, uint256 b, uint256 dr) public {
        vmx.warp(START + 10 weeks);
        uint256 we = latestReportableSaturday(block.timestamp);
        (uint256 recent, uint256 baseline) = validDeaths(r, b);
        bytes memory s = sig(SIGNER_PK, oracle.reportDigest(we, recent, baseline));
        uint256 other = recent + 1 + dr % 1000;
        vmx.expectRevert(SignedMortalityOracle.BadSignature.selector);
        oracle.submit(we, other, baseline, s);
    }

    function testFuzz_OutOfRangeRejected(uint256 r, uint256 b) public {
        vmx.warp(START + 10 weeks);
        uint256 we = latestReportableSaturday(block.timestamp);
        uint256 baseline = clamp(b, 80_000, 1_000_000);
        uint256 recent = r % 2 == 0 ? r % 80_000 : 1_000_001 + r % 1e30;
        bytes memory s = sig(SIGNER_PK, oracle.reportDigest(we, recent, baseline));
        vmx.expectRevert(SignedMortalityOracle.OutOfRange.selector);
        oracle.submit(we, recent, baseline, s);
    }

    /// Wer den Faktor mit dem Schlüssel nach unten treibt und dann abschaltet, schreibt ihn nicht fest.
    function testFuzz_RetireResetsFactor(uint8 n) public {
        uint256 reports = uint256(n) % 12;
        uint256 t = START + 9 weeks;
        for (uint256 i = 0; i < reports; i++) {
            t += 1 weeks;
            vmx.warp(t);
            uint256 we = latestReportableSaturday(t);
            oracle.submit(we, 400_000, 200_000, sig(SIGNER_PK, oracle.reportDigest(we, 400_000, 200_000)));
        }
        oracle.retire(sig(SIGNER_PK, oracle.retireDigest()));
        vmx.assertEq(em.factorMilli(), 1000, "Faktor nach retire nicht 1,0");
        vmx.assertEq(em.targetMilli(), 1000, "Ziel nach retire nicht 1,0");
        t += 1 weeks;
        vmx.warp(t);
        uint256 we2 = latestReportableSaturday(t);
        bytes memory s = sig(SIGNER_PK, oracle.reportDigest(we2, 200_000, 200_000));
        vmx.expectRevert(SignedMortalityOracle.IsRetired.selector);
        oracle.submit(we2, 200_000, 200_000, s);
    }

    // ================================================================ Emission und Token

    /// Bis zur 63. Halbierung (rund 500 Jahre) halbiert sich die Wochenmenge exakt. Ab der 64.
    /// Halbierung gibt der Contract 0 aus, obwohl rechnerisch noch einige tausend wei übrig wären;
    /// das ist Staub und spielt wegen der 21-Mio.-Grenze ohnehin keine Rolle.
    function testFuzz_HalvingSchedule(uint256 e) public view {
        e = e % (63 * 416);
        vmx.assertEq(em.epochEmission(e + 416), em.epochEmission(e) >> 1, "Halbierung falsch");
    }

    /// Plan bei Faktor 1,0: Summe der Wochenmengen aller abgelaufenen Epochen.
    function planned(uint256 epochs) internal view returns (uint256 s) {
        for (uint256 e = 0; e < epochs; e++) {
            uint256 x = em.epochEmission(e);
            if (x == 0) break;
            s += x;
        }
    }

    /// Wann und wie oft gemintet wird, ändert die Menge nicht, und sie überschreitet weder den Plan
    /// noch die 21 Mio.
    function testFuzz_SupplyFollowsPlanAndCap(uint256 a, uint256 b) public {
        uint256 t1 = START + a % (60 * 365 days);
        uint256 t2 = t1 + b % (60 * 365 days);
        vmx.warp(t1);
        em.mint();
        vmx.warp(t2);
        em.mint();
        uint256 supply = token.totalSupply();
        uint256 plan = planned(em.completedEpochs());
        vmx.assertLe(supply, 21_000_000e18, "ueber 21 Mio.");
        vmx.assertLe(supply - INITIAL, plan, "ueber dem Plan");
        if (supply < token.cap()) vmx.assertEq(supply - INITIAL, plan, "Menge haengt vom Zeitpunkt ab");
    }

    /// Jede Ausgabe geht je zur Hälfte an Mining und Staking (auf 1 wei pro Ausgabe genau).
    function testFuzz_MintSplitHalfHalf(uint256 a) public {
        vmx.warp(START + 1 weeks + a % (20 * 365 days));
        em.mint();
        uint256 m = token.balanceOf(address(mn));
        uint256 s = token.balanceOf(address(st));
        vmx.assertLe(m, s, "Mining bekam mehr");
        vmx.assertLe(s - m, 1, "Aufteilung nicht halb/halb");
    }

    // ================================================================ FounderLock

    function testFuzz_FounderReleaseLinear(uint256 t, address caller) public {
        t = t % (12 * 365 days);
        vmx.warp(START + t);
        vmx.prank(caller);                              // auslösen darf jeder
        lock.release(address(token));
        uint256 dur = lock.VESTING_DURATION();
        uint256 expect = t >= dur ? INITIAL : INITIAL * t / dur;
        vmx.assertEq(lock.released(address(token)), expect, "Freigabe nicht linear");
        vmx.assertEq(token.balanceOf(ALICE), expect, "nicht beim Empfaenger");
        vmx.assertEq(token.balanceOf(address(lock)), INITIAL - expect, "Rest im Lock falsch");
    }

    /// In keinem Zeitfenster wird mehr als 100.000 BCUS pro Jahr frei (plus 1 wei Rundung).
    function testFuzz_FounderMax100kPerYear(uint256 a, uint256 d) public {
        uint256 t1 = START + a % (11 * 365 days);
        uint256 dt = d % (3 * 365 days);
        vmx.warp(t1);
        lock.release(address(token));
        uint256 r1 = lock.released(address(token));
        vmx.warp(t1 + dt);
        lock.release(address(token));
        uint256 r2 = lock.released(address(token));
        vmx.assertLe(r2 - r1, 100_000e18 * dt / 365 days + 1, "mehr als 100k pro Jahr");
    }

    function testFuzz_FounderBeneficiaryFixed(address to) public {
        vmx.prank(ALICE);
        vmx.expectRevert(bytes4(keccak256("BeneficiaryFixed()")));
        lock.transferOwnership(to);
    }

    // ================================================================ Staking

    /// ALICE holt sich ein Jahr Gründer-Freigabe (100.000 BCUS), damit sie etwas zum Staken hat.
    function fundAlice() internal returns (uint256 bal) {
        vmx.warp(START + 365 days);
        lock.release(address(token));
        bal = token.balanceOf(ALICE);
    }

    function testFuzz_WithdrawNeverMoreThanStake(uint256 amt, uint256 extra, uint256 wait) public {
        uint256 bal = fundAlice();
        amt = clamp(amt, 1, bal);
        vmx.prank(ALICE);
        st.stake(amt);
        vmx.warp(block.timestamp + wait % (30 days));
        uint256 tooMuch = amt + 1 + extra % 1e30;
        vmx.prank(ALICE);
        vmx.expectRevert(BcusStaking.InsufficientStake.selector);
        st.withdraw(tooMuch);
        uint256 before = token.balanceOf(ALICE);
        vmx.prank(ALICE);
        st.withdraw(amt);
        vmx.assertEq(token.balanceOf(ALICE) - before, amt, "Einsatz nicht genau zurueck");
        vmx.assertEq(st.stakedOf(ALICE), 0, "Rest-Einsatz");
    }

    /// Ein Staker allein: Was eine Abrechnung den Stakern gibt, ist nie mehr als 1 % pro Woche
    /// seines Einsatzes, sekundengenau bis zur echten Wochengrenze gerechnet.
    function testFuzz_CapPerCloseExact(uint256 amt, uint256 wait) public {
        uint256 bal = fundAlice();
        amt = clamp(amt, 1e18, bal);
        vmx.prank(ALICE);
        st.stake(amt);
        uint256 t0 = block.timestamp;
        uint256 r0 = st.reserved();
        vmx.warp(block.timestamp + 1 + wait % (10 weeks));
        st.pull();
        uint256 part = st.reserved() - r0;
        (uint256 end,,) = st.periods(st.current());
        if (end <= t0) vmx.assertEq(part, 0, "Verteilung ohne neue Woche");
        else vmx.assertLe(part, amt * (end - t0) / (100 * 1 weeks), "Deckel ueberschritten");
    }
}
