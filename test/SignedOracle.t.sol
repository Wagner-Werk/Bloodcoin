// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "./Test.sol";
import {MortalityEmission} from "../src/MortalityEmission.sol";
import {SignedMortalityOracle} from "../src/SignedMortalityOracle.sol";

contract SignedOracleTest is Test {
    uint256 constant START = 1_800_000_000;          // 2027-01-15
    uint256 constant SAT = 1_790_985_600;            // 2026-10-03, ein Samstag 00:00 UTC
    uint256 constant KEY = 0xB10D;
    uint256 constant OTHER_KEY = 0xBAD;
    uint256 constant GKEY = 0x6A2D;
    address immutable GUARD = vm.addr(GKEY);

    SignedMortalityOracle oracle;
    MortalityEmission em;

    function setUp() public {
        vm.warp(START);
        oracle = new SignedMortalityOracle(vm.addr(KEY), GUARD);
        em = new MortalityEmission(address(oracle), address(0xBEEF), address(0), address(0xCAFE), 1_000_000e18);
        oracle.bind(address(em));
    }

    function sig(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    /// Vorschlagen (frühestens 6 Tage nach dem letzten), Frist abwarten, wirksam machen.
    function submit(uint256 week, uint256 deaths, uint256 prev) internal {
        uint256 last = oracle.lastProposedAt();
        if (last != 0 && block.timestamp < last + 6 days) vm.warp(last + 6 days);
        oracle.propose(week, deaths, prev, sig(KEY, oracle.reportDigest(week, deaths, prev)));
        vm.warp(oracle.executableAt());
        oracle.execute();
    }

    function propose(uint256 week, uint256 deaths, uint256 prev) internal {
        oracle.propose(week, deaths, prev, sig(KEY, oracle.reportDigest(week, deaths, prev)));
    }

    function testSignedReportReachesEmission() public {
        submit(SAT, 252_000, 240_000);
        assertEq(em.targetMilli(), 900);
        assertEq(em.factorMilli(), 950);
        assertEq(em.lastWeekEnding(), SAT);
    }

    function testAnyoneCanRelay() public {
        bytes memory s = sig(KEY, oracle.reportDigest(SAT, 252_000, 240_000));
        vm.prank(address(0x1234));
        oracle.propose(SAT, 252_000, 240_000, s);
        vm.warp(START + 48 hours);
        vm.prank(address(0x5678));
        oracle.execute();
        assertEq(em.lastWeekEnding(), SAT);
    }

    function testWrongKeyRejected() public {
        bytes memory s = sig(OTHER_KEY, oracle.reportDigest(SAT, 252_000, 240_000));
        vm.expectRevert(SignedMortalityOracle.BadSignature.selector);
        oracle.propose(SAT, 252_000, 240_000, s);
    }

    function testTamperedNumbersRejected() public {
        bytes memory s = sig(KEY, oracle.reportDigest(SAT, 252_000, 240_000));
        vm.expectRevert(SignedMortalityOracle.BadSignature.selector);
        oracle.propose(SAT, 253_000, 240_000, s);
    }

    function testSignatureBoundToContract() public {
        // Gleicher Schlüssel, zweiter Contract: die Signatur für den ersten gilt dort nicht.
        SignedMortalityOracle other = new SignedMortalityOracle(vm.addr(KEY), GUARD);
        MortalityEmission em2 = new MortalityEmission(address(other), address(0xBEEF), address(0), address(0xCAFE), 0);
        other.bind(address(em2));
        bytes memory s = sig(KEY, oracle.reportDigest(SAT, 252_000, 240_000));
        vm.expectRevert(SignedMortalityOracle.BadSignature.selector);
        other.propose(SAT, 252_000, 240_000, s);
    }

    function testReplayRejected() public {
        bytes memory s = sig(KEY, oracle.reportDigest(SAT, 252_000, 240_000));
        oracle.propose(SAT, 252_000, 240_000, s);
        vm.expectRevert(SignedMortalityOracle.PendingExists.selector);
        oracle.propose(SAT, 252_000, 240_000, s);
        vm.warp(START + 48 hours);
        oracle.execute();
        vm.warp(START + 6 days);
        vm.expectRevert(SignedMortalityOracle.WeekNotNewer.selector);
        oracle.propose(SAT, 252_000, 240_000, s);
    }

    function testEmissionRulesStillApply() public {
        uint256 tooRecent = 1_795_219_200;            // 2026-11-21, juenger als 8 Wochen
        bytes memory s = sig(KEY, oracle.reportDigest(tooRecent, 240_000, 240_000));
        vm.expectRevert(SignedMortalityOracle.WeekTooRecent.selector);
        oracle.propose(tooRecent, 240_000, 240_000, s);
    }

    function testOutOfRange() public {
        bytes memory s = sig(KEY, oracle.reportDigest(SAT, 79_999, 240_000));
        vm.expectRevert(SignedMortalityOracle.OutOfRange.selector);
        oracle.propose(SAT, 79_999, 240_000, s);
        s = sig(KEY, oracle.reportDigest(SAT, 240_000, 1_000_001));
        vm.expectRevert(SignedMortalityOracle.OutOfRange.selector);
        oracle.propose(SAT, 240_000, 1_000_001, s);
    }

    function testFormatErrorRejected() public {
        // Versehentlich eine Woche statt vier gemeldet: Verhältnis 1:4, MortalityEmission lehnt ab.
        bytes memory s = sig(KEY, oracle.reportDigest(SAT, 240_000, 960_000));
        vm.expectRevert(SignedMortalityOracle.OutOfRange.selector);
        oracle.propose(SAT, 240_000, 960_000, s);
    }

    function testFakeReportMovesFactorOnlyOneStep() public {
        // Der Schlüssel meldet eine erfundene Katastrophe: Ziel 0,5, Faktor nur 0,95.
        submit(SAT, 400_000, 240_000);
        assertEq(em.targetMilli(), 500);
        assertEq(em.factorMilli(), 950);
    }

    function testGapIsFine() public {
        // Fällt eine Woche aus, blockiert das nichts.
        submit(SAT, 252_000, 240_000);
        submit(SAT + 2 weeks, 240_000, 240_000);
        assertEq(em.lastWeekEnding(), SAT + 2 weeks);
        assertEq(em.factorMilli(), 1000);
    }

    function testRetireStopsReports() public {
        oracle.retire(sig(KEY, oracle.retireDigest()));
        assertTrue(oracle.retired());
        bytes memory s = sig(KEY, oracle.reportDigest(SAT, 252_000, 240_000));
        vm.expectRevert(SignedMortalityOracle.IsRetired.selector);
        oracle.propose(SAT, 252_000, 240_000, s);
    }

    function testRetireResetsFactor() public {
        // Ein Dieb des Schlüssels drückt den Faktor mit erfundenen Zahlen nach unten ...
        submit(SAT, 400_000, 240_000);
        submit(SAT + 1 weeks, 400_000, 240_000);
        submit(SAT + 2 weeks, 400_000, 240_000);
        assertEq(em.factorMilli(), 850);
        // ... das Abschalten schreibt das aber nicht fest, sondern setzt auf 1,0 zurück.
        oracle.retire(sig(KEY, oracle.retireDigest()));
        assertEq(em.factorMilli(), 1000);
        assertEq(em.targetMilli(), 1000);
    }

    function testRetireSettlesOldEpochsWithOldFactor() public {
        submit(SAT, 400_000, 240_000);                   // Faktor 0,95
        vm.warp(START + 2 weeks);
        oracle.retire(sig(KEY, oracle.retireDigest()));
        assertEq(em.pending(), 2 * (em.BASE_EMISSION() * 950 / 1000));
    }

    function testRetireOnlyOnce() public {
        bytes memory s = sig(KEY, oracle.retireDigest());
        oracle.retire(s);
        vm.expectRevert(SignedMortalityOracle.IsRetired.selector);
        oracle.retire(s);
    }

    function testResetFactorOnlyOracle() public {
        vm.expectRevert(MortalityEmission.OnlyOracle.selector);
        em.resetFactor();
    }

    function testRetireNeedsKey() public {
        bytes memory s = sig(OTHER_KEY, oracle.retireDigest());
        vm.expectRevert(SignedMortalityOracle.BadSignature.selector);
        oracle.retire(s);
    }

    function testBindOnlyOnceAndOnlyDeployer() public {
        vm.expectRevert(SignedMortalityOracle.AlreadyBound.selector);
        oracle.bind(address(1));
        SignedMortalityOracle o = new SignedMortalityOracle(vm.addr(KEY), GUARD);
        vm.prank(address(0x1234));
        vm.expectRevert(SignedMortalityOracle.AlreadyBound.selector);
        o.bind(address(1));
    }

    function testUnboundRejects() public {
        SignedMortalityOracle o = new SignedMortalityOracle(vm.addr(KEY), GUARD);
        bytes memory s = sig(KEY, o.reportDigest(SAT, 252_000, 240_000));
        vm.expectRevert(SignedMortalityOracle.NotBound.selector);
        o.propose(SAT, 252_000, 240_000, s);
    }

    function testZeroSignerRejected() public {
        vm.expectRevert(SignedMortalityOracle.BadSignature.selector);
        new SignedMortalityOracle(address(0), GUARD);
    }

    // ================================================================ S6: Frist, Abstand, Wächter

    function vsig(uint256 key) internal view returns (bytes memory) {
        (uint64 w, uint64 at,,) = oracle.pending();
        return sig(key, oracle.vetoDigest(w, at));
    }

    function testConstructorReverts() public {
        vm.expectRevert(SignedMortalityOracle.BadSignature.selector);
        new SignedMortalityOracle(address(0), GUARD);
        vm.expectRevert(SignedMortalityOracle.BadGuardian.selector);
        new SignedMortalityOracle(vm.addr(KEY), address(0));
        vm.expectRevert(SignedMortalityOracle.BadGuardian.selector);
        new SignedMortalityOracle(vm.addr(KEY), vm.addr(KEY));
    }

    function testProposeWaitsChallengePeriod() public {
        propose(SAT, 400_000, 240_000);
        assertEq(oracle.executableAt(), START + 48 hours);
        assertEq(em.lastWeekEnding(), 0);
        assertEq(em.factorMilli(), 1000);
        vm.warp(START + 48 hours - 1);                  // 47:59:59
        vm.expectRevert(SignedMortalityOracle.ChallengeOpen.selector);
        oracle.execute();
        vm.warp(START + 48 hours);
        oracle.execute();
        assertEq(em.factorMilli(), 950);
        assertEq(em.lastWeekEnding(), SAT);
        assertEq(oracle.executableAt(), 0);
        vm.expectRevert(SignedMortalityOracle.NothingPending.selector);
        oracle.execute();
    }

    function testPendingExists() public {
        propose(SAT, 252_000, 240_000);
        vm.warp(START + 7 days);                         // Abstand wäre um, aber noch offen
        bytes memory s = sig(KEY, oracle.reportDigest(SAT + 1 weeks, 252_000, 240_000));
        vm.expectRevert(SignedMortalityOracle.PendingExists.selector);
        oracle.propose(SAT + 1 weeks, 252_000, 240_000, s);
    }

    function testTooSoonAlsoAfterVeto() public {
        propose(SAT, 252_000, 240_000);
        vm.warp(START + 48 hours);
        oracle.execute();
        bytes memory s = sig(KEY, oracle.reportDigest(SAT + 1 weeks, 252_000, 240_000));
        vm.warp(START + 6 days - 1);
        vm.expectRevert(SignedMortalityOracle.TooSoon.selector);
        oracle.propose(SAT + 1 weeks, 252_000, 240_000, s);
        vm.warp(START + 6 days);
        oracle.propose(SAT + 1 weeks, 252_000, 240_000, s);
        vm.prank(GUARD);
        oracle.veto();
        // Nach dem Veto gilt der Abstand weiter, gemessen am verworfenen Vorschlag.
        s = sig(KEY, oracle.reportDigest(SAT + 1 weeks, 250_000, 240_000));
        vm.warp(START + 12 days - 1);
        vm.expectRevert(SignedMortalityOracle.TooSoon.selector);
        oracle.propose(SAT + 1 weeks, 250_000, 240_000, s);
        vm.warp(START + 12 days);
        oracle.propose(SAT + 1 weeks, 250_000, 240_000, s);
    }

    function testGuardianVetoDirect() public {
        propose(SAT, 400_000, 240_000);
        vm.warp(START + 47 hours);
        vm.prank(GUARD);
        oracle.veto();
        assertEq(oracle.executableAt(), 0);
        vm.warp(START + 48 hours);
        vm.expectRevert(SignedMortalityOracle.NothingPending.selector);
        oracle.execute();
        assertEq(em.factorMilli(), 1000);
    }

    function testGuardianVetoBySignatureAnyoneSubmits() public {
        propose(SAT, 400_000, 240_000);
        bytes memory v = vsig(GKEY);
        vm.prank(address(0x1234));
        oracle.vetoWithSig(v);
        vm.warp(START + 48 hours);
        vm.expectRevert(SignedMortalityOracle.NothingPending.selector);
        oracle.execute();
        assertEq(em.factorMilli(), 1000);
    }

    function testVetoAfterDeadlineUntilExecuted() public {
        propose(SAT, 400_000, 240_000);
        vm.warp(START + 3 days);
        vm.prank(GUARD);
        oracle.veto();
        vm.expectRevert(SignedMortalityOracle.NothingPending.selector);
        oracle.execute();
    }

    function testOldVetoSignatureNotValidForNewProposal() public {
        propose(SAT, 400_000, 240_000);
        bytes memory old = vsig(GKEY);
        vm.prank(GUARD);
        oracle.veto();
        // Gleiche Woche, gleiche Zahlen, neuer Vorschlag (anderes proposedAt)
        vm.warp(START + 6 days);
        propose(SAT, 400_000, 240_000);
        vm.expectRevert(SignedMortalityOracle.BadSignature.selector);
        oracle.vetoWithSig(old);
        oracle.vetoWithSig(vsig(GKEY));
        assertEq(oracle.executableAt(), 0);
    }

    function testVetoBySignerOrStrangerReverts() public {
        propose(SAT, 400_000, 240_000);
        vm.prank(vm.addr(KEY));
        vm.expectRevert(SignedMortalityOracle.OnlyGuardian.selector);
        oracle.veto();
        vm.prank(address(0x1234));
        vm.expectRevert(SignedMortalityOracle.OnlyGuardian.selector);
        oracle.veto();
        bytes memory bad = vsig(KEY);
        vm.expectRevert(SignedMortalityOracle.BadSignature.selector);
        oracle.vetoWithSig(bad);
        bad = vsig(OTHER_KEY);
        vm.expectRevert(SignedMortalityOracle.BadSignature.selector);
        oracle.vetoWithSig(bad);
        assertTrue(oracle.executableAt() != 0);
    }

    function testVetoWithoutPending() public {
        vm.prank(GUARD);
        vm.expectRevert(SignedMortalityOracle.NothingPending.selector);
        oracle.veto();
        bytes memory v = sig(GKEY, oracle.vetoDigest(0, 0));
        vm.expectRevert(SignedMortalityOracle.NothingPending.selector);
        oracle.vetoWithSig(v);
    }

    function testGuardianCannotReport() public {
        bytes memory s = sig(GKEY, oracle.reportDigest(SAT, 252_000, 240_000));
        vm.expectRevert(SignedMortalityOracle.BadSignature.selector);
        oracle.propose(SAT, 252_000, 240_000, s);
    }

    function _retireCase(uint256 how) internal {
        submit(SAT, 400_000, 240_000);
        submit(SAT + 1 weeks, 400_000, 240_000);
        assertEq(em.factorMilli(), 900);
        vm.warp(block.timestamp + 6 days);
        propose(SAT + 2 weeks, 400_000, 240_000);
        if (how == 0) {
            oracle.retire(sig(KEY, oracle.retireDigest()));
        } else if (how == 1) {
            vm.prank(address(0x1234));
            oracle.retire(sig(GKEY, oracle.retireDigest()));
        } else {
            vm.prank(GUARD);
            oracle.retire();
        }
        assertTrue(oracle.retired());
        assertEq(oracle.executableAt(), 0);
        assertEq(em.factorMilli(), 1000);
        assertEq(em.targetMilli(), 1000);

        // Danach geht nichts mehr.
        vm.warp(block.timestamp + 7 days);
        bytes memory s = sig(KEY, oracle.reportDigest(SAT + 3 weeks, 400_000, 240_000));
        vm.expectRevert(SignedMortalityOracle.IsRetired.selector);
        oracle.propose(SAT + 3 weeks, 400_000, 240_000, s);
        vm.expectRevert(SignedMortalityOracle.IsRetired.selector);
        oracle.execute();
        vm.prank(GUARD);
        vm.expectRevert(SignedMortalityOracle.IsRetired.selector);
        oracle.veto();
        vm.prank(GUARD);
        vm.expectRevert(SignedMortalityOracle.IsRetired.selector);
        oracle.retire();
    }

    function testRetireBySignerSignature() public { _retireCase(0); }
    function testRetireByGuardianSignature() public { _retireCase(1); }
    function testRetireByGuardianDirect() public { _retireCase(2); }

    function testRetireDirectOnlyGuardian() public {
        vm.prank(vm.addr(KEY));
        vm.expectRevert(SignedMortalityOracle.OnlyGuardian.selector);
        oracle.retire();
    }

    function testThiefVetoedTenTimes() public {
        // Ein Dieb hat den Melde-Schlüssel und schlägt zehnmal eine erfundene Katastrophe vor.
        for (uint256 i = 0; i < 10; i++) {
            if (i > 0) vm.warp(oracle.lastProposedAt() + 6 days);
            propose(SAT + i * 1 weeks, 400_000, 200_000);
            vm.prank(GUARD);
            oracle.veto();
        }
        assertEq(em.factorMilli(), 1000);
        assertEq(em.lastWeekEnding(), 0);
    }

    function testThiefWithoutVetoNeedsAtLeast54Days() public {
        // Ohne Wächter: zehn Schritte zu 0,05, jeder frühestens 6 Tage nach dem letzten Vorschlag.
        uint256 t0 = block.timestamp;
        for (uint256 i = 0; i < 10; i++) submit(SAT + i * 1 weeks, 400_000, 200_000);
        assertEq(em.factorMilli(), 500);
        assertTrue(block.timestamp >= t0 + 54 days + 48 hours);
        // Grenzen bleiben: nie unter 0,5, nie über 1,0.
        submit(SAT + 10 weeks, 400_000, 200_000);
        assertEq(em.factorMilli(), 500);
        for (uint256 i = 11; i < 25; i++) submit(SAT + i * 1 weeks, 150_000, 200_000);
        assertEq(em.factorMilli(), 1000);
    }

    function testProposeChecksWeekEarly() public {
        bytes memory s = sig(KEY, oracle.reportDigest(SAT + 1 days, 240_000, 240_000));
        vm.expectRevert(SignedMortalityOracle.NotASaturday.selector);
        oracle.propose(SAT + 1 days, 240_000, 240_000, s);
        submit(SAT, 240_000, 240_000);
        vm.warp(block.timestamp + 6 days);
        s = sig(KEY, oracle.reportDigest(SAT - 1 weeks, 240_000, 240_000));
        vm.expectRevert(SignedMortalityOracle.WeekNotNewer.selector);
        oracle.propose(SAT - 1 weeks, 240_000, 240_000, s);
    }
}
