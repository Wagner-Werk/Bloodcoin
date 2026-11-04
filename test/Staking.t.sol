// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "./Test.sol";
import {BloodcoinToken} from "../src/BloodcoinToken.sol";
import {MortalityEmission} from "../src/MortalityEmission.sol";
import {BcusStaking} from "../src/BcusStaking.sol";

/// Nur für Tests: Obergrenze setzen können (im Echtbetrieb gibt es keinen Setter).
contract StakingHarness is BcusStaking {
    function setMax(uint256 v) external { maxWeeklyBp = v; }
}

contract StakingTest is Test {
    uint256 constant START = 1_800_000_000;
    address constant HOLDER = address(0xCAFE);
    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);

    BcusStaking st;
    MortalityEmission em;
    BloodcoinToken token;
    uint256 base;

    function setUp() public {
        vm.warp(START);
        StakingHarness h = new StakingHarness();
        h.setMax(1e12);                                // Obergrenze für die meisten Tests praktisch aus
        st = h;
        em = new MortalityEmission(address(0x0A), address(st), address(0), HOLDER, 1_000_000e18);
        st.bind(address(em));
        token = em.token();
        base = em.BASE_EMISSION();
        give(ALICE, 300_000e18);
        give(BOB, 300_000e18);
    }

    function give(address to, uint256 amount) internal {
        vm.prank(HOLDER);
        token.transfer(to, amount);
        vm.prank(to);
        token.approve(address(st), type(uint256).max);
    }

    /// Schickt alles über `keep` hinaus an den Start-Halter (zählt nicht zum Umlauf). So ist der
    /// Umlauf genau das, was die Test-Konten behalten, und die Anteils-Regel gibt dem Staker
    /// seinen Anteil davon.
    function trim(address who, uint256 keep) internal {
        uint256 bal = token.balanceOf(who);
        if (bal > keep) {
            vm.prank(who);
            token.transfer(HOLDER, bal - keep);
        }
    }

    function stake(address who, uint256 amount) internal {
        vm.prank(who);
        st.stake(amount);
    }

    function claim(address who) internal returns (uint256) {
        uint256 before = token.balanceOf(who);
        vm.prank(who);
        st.claim();
        return token.balanceOf(who) - before;
    }

    /// |a - b| <= tol
    function assertNear(uint256 a, uint256 b, uint256 tol) internal pure {
        assertLe(a > b ? a - b : b - a, tol);
    }

    function assertSolvent() internal view {
        assertLe(st.totalStaked() + st.reserved(), token.balanceOf(address(st)));
    }

    // ---------------------------------------------------------------- Aufbau

    function testBindChecks() public {
        BcusStaking other = new BcusStaking();
        vm.expectRevert(BcusStaking.WrongRecipient.selector);
        other.bind(address(em));
        vm.expectRevert(BcusStaking.AlreadyBound.selector);
        st.bind(address(em));
    }

    function testUnboundCannotBeUsed() public {
        BcusStaking other = new BcusStaking();
        vm.expectRevert(BcusStaking.NotBound.selector);
        other.pull();
    }

    function testBindTooLate() public {
        BcusStaking other = new BcusStaking();
        MortalityEmission e2 = new MortalityEmission(address(0x0A), address(other), address(0), HOLDER, 0);
        vm.warp(block.timestamp + 1 weeks);
        vm.expectRevert(BcusStaking.TooLate.selector);
        other.bind(address(e2));
    }

    // ---------------------------------------------------------------- Verteilung

    function testSingleStakerGetsWholeWeekAtWeekEnd() public {
        trim(ALICE, 100e18);
        trim(BOB, 0);                                    // Umlauf = nur Alice, Anteil 100 %
        stake(ALICE, 100e18);
        vm.warp(START + 1 weeks - 1);
        st.pull();                                       // Woche läuft noch: nichts verteilt
        assertEq(st.earned(ALICE), 0);
        assertEq(st.reserved(), 0);
        vm.warp(START + 1 weeks);
        st.pull();                                       // Woche abgeschlossen
        assertNear(st.earned(ALICE), base, 1e12);
        assertNear(claim(ALICE), base, 1e12);            // sofort abholbar, kein Strom
        assertSolvent();
    }

    function testSplitByStakeSize() public {
        trim(ALICE, 100e18);
        trim(BOB, 300e18);
        stake(ALICE, 100e18);
        stake(BOB, 300e18);
        vm.warp(START + 1 weeks);
        st.pull();
        assertNear(claim(ALICE), base / 4, 1e12);
        assertNear(claim(BOB), base * 3 / 4, 1e12);
        assertSolvent();
    }

    function testFlashStakerGetsAlmostNothing() public {
        trim(ALICE, 100e18);
        trim(BOB, 100_000e18);
        stake(ALICE, 100e18);
        vm.warp(START + 1 weeks - 1);
        stake(BOB, 100_000e18);                          // riesiger Einsatz eine Sekunde vor der Grenze
        vm.warp(START + 1 weeks + 1);
        vm.prank(BOB);
        st.exit();                                       // Woche wird abgeschlossen, Bob geht
        assertLe(token.balanceOf(BOB), 100_000e18 + base / 100_000);
        uint256 a = claim(ALICE);
        // Bobs Sekunde zählt zeitgewichtet kaum: Anteil rund 100 von 100.100.
        assertNear(a, base * 100 / 100_100, base / 10_000);
        assertSolvent();
    }

    function testDirectMintByOutsiderStillDistributed() public {
        trim(ALICE, 100e18);
        trim(BOB, 0);
        stake(ALICE, 100e18);
        vm.warp(START + 1 weeks);
        em.mint();                                       // jemand ruft direkt am Emissions-Contract
        assertEq(st.reserved(), 0);
        st.pull();                                       // wird trotzdem erkannt
        assertNear(claim(ALICE), base, 1e12);
        assertSolvent();
    }

    function testWeekWithoutStakersGoesAway() public {
        trim(ALICE, 100e18);
        trim(BOB, 0);
        vm.warp(START + 1 weeks);
        st.pull();                                       // niemand stakt: alles weg (hier: verbrannt)
        assertNear(token.balanceOf(st.BURN()), base, 1e12);
        assertEq(st.reserved(), 0);
        vm.warp(START + 1 weeks + 7 days);
        stake(ALICE, 100e18);                            // Woche 2 wird abgeschlossen, bevor Alice zählt
        assertNear(token.balanceOf(st.BURN()), 2 * base, 1e12);
        assertEq(st.earned(ALICE), 0);
        vm.warp(START + 3 weeks);
        st.pull();                                       // Woche 3: Alice hat 100 % des Umlaufs
        assertNear(claim(ALICE), base, base / 100);
        assertSolvent();
    }

    function testStakerJoiningMidWeekGetsTimeShare() public {
        trim(ALICE, 100e18);
        trim(BOB, 100e18);
        stake(ALICE, 100e18);
        vm.warp(START + 3.5 days);
        stake(BOB, 100e18);                              // halbe Woche dabei
        vm.warp(START + 1 weeks);
        st.pull();
        // Durchschnitt 150 von 200 im Umlauf: 75 % der Woche an die Staker, davon Alice 2/3, Bob 1/3.
        assertNear(claim(ALICE), base / 2, 1e12);
        assertNear(claim(BOB), base / 4, 1e12);
        assertNear(token.balanceOf(st.BURN()), base / 4, 1e12);
        assertSolvent();
    }

    /// KI-Prüfung 4.11. (ChatGPT BCUS-01, Mistral F2): Wer erst nach der Woche einsteigt, bekommt
    /// aus ihr nichts, auch nicht als Strom in der Folgewoche.
    function testLateJoinerGetsNothingFromClosedWeek() public {
        trim(ALICE, 100e18);
        trim(BOB, 100_000e18);
        stake(ALICE, 100e18);
        vm.warp(START + 1 weeks + 1);
        stake(BOB, 100_000e18);                          // schliesst Woche 1 ab, dann zählt Bob
        uint256 a = st.earned(ALICE);
        assertTrue(a > 0);
        assertEq(st.earned(BOB), 0);
        vm.warp(START + 1 weeks + 6 days);
        assertEq(claim(BOB), 0);
        assertEq(claim(ALICE), a);
        assertSolvent();
    }

    /// KI-Prüfung 4.11. (ChatGPT BCUS-03): Wer mitten in der Woche aussteigt, behält seinen
    /// Anteil für die Zeit, in der er gestakt war. Ist bei Wochenende niemand mehr gestakt, geht
    /// der Topf an die, die in der Woche gestakt waren, nicht an den nächsten Einsteiger.
    function testLeaverKeepsClaimNobodyElseGetsIt() public {
        trim(ALICE, 100e18);
        trim(BOB, 100e18);
        stake(ALICE, 100e18);
        vm.warp(START + 3.5 days);
        vm.prank(ALICE);
        st.withdraw(100e18);                             // halbe Woche, dann raus
        vm.warp(START + 1 weeks + 1);
        stake(BOB, 100e18);                              // schliesst die Woche ab
        // Durchschnitt 50 von 200 im Umlauf: 25 % der Woche, alles für Alice.
        assertNear(st.earned(ALICE), base / 4, 1e12);
        assertEq(st.earned(BOB), 0);
        assertNear(claim(ALICE), base / 4, 1e12);
        assertSolvent();
    }

    /// KI-Prüfung 4.11. (Mistral F1, ChatGPT BCUS-02): Stille Wochen werden an den echten
    /// Wochengrenzen abgerechnet und gehen an die, die in diesen Wochen gestakt waren.
    function testQuietWeeksGoToThoseWhoStaked() public {
        trim(ALICE, 100e18);
        trim(BOB, 100_000e18);
        stake(ALICE, 100e18);
        vm.warp(START + 3 weeks + 1);
        stake(BOB, 100_000e18);                          // erster Aufruf nach drei stillen Wochen
        assertEq(st.earned(BOB), 0);
        // Umlauf 100.100, Alice 100 gestakt: Anteil exakt 100/100.100 von 3 Wochen.
        assertNear(claim(ALICE), 3 * base * 100 / 100_100, 1e12);
        assertSolvent();
    }

    /// KI-Prüfung 4.11. (Mistral F1): Ein pull() kurz vor der Wochengrenze verschiebt nichts.
    function testPullTimingDoesNotMatter() public {
        trim(ALICE, 100e18);
        trim(BOB, 0);
        stake(ALICE, 100e18);
        vm.warp(START + 2 weeks - 1);
        st.pull();                                       // schliesst Woche 1 ab
        vm.warp(START + 2 weeks + 60);
        st.pull();                                       // schliesst Woche 2 ab
        assertNear(claim(ALICE), 2 * base, 1e12);
        assertSolvent();
    }

    /// KI-Prüfung Runde 2 (F-03): Der Anteil wird nicht auf Basispunkte abgerundet. Ein Staker mit
    /// weniger als 0,01 % des Umlaufs bekommt trotzdem seinen genauen Anteil.
    function testShareBelowOneBasisPointNotRoundedAway() public {
        trim(ALICE, 1e18);
        trim(BOB, 20_000e18);                            // Alice: 1 von 20.001, also rund 0,5 Basispunkte
        stake(ALICE, 1e18);
        vm.warp(START + 1 weeks);
        st.pull();
        uint256 got = claim(ALICE);
        assertTrue(got > 0);
        assertNear(got, base * 1 / 20_001, 1e12);
        assertSolvent();
    }

    // ---------------------------------------------------------------- Anteils-Regel

    function testShareFollowsCirculatingSupply() public {
        trim(ALICE, 100e18);
        trim(BOB, 300e18);
        stake(ALICE, 100e18);                            // 100 von 400 im Umlauf
        assertEq(st.circulating(), 400e18);
        assertEq(st.stakerShareBp(), 2500);
        vm.warp(START + 1 weeks);
        st.pull();
        assertNear(claim(ALICE), base / 4, base / 100_000);
        assertNear(token.balanceOf(st.BURN()), base * 3 / 4, base / 100_000);
        assertSolvent();
    }

    function testDustStakerCannotTakeTheWeek() public {
        stake(ALICE, 1e18);                              // 1 von 600.000 im Umlauf
        vm.warp(START + 1 weeks);
        st.pull();
        vm.warp(START + 2 weeks - 1);                    // vor der 2. Ausgabe
        assertLe(claim(ALICE), base / 100_000);
        assertNear(token.balanceOf(st.BURN()), base, base / 100_000);
        assertSolvent();
    }

    // ---------------------------------------------------------------- Obergrenze

    function testWeeklyCapLimitsEarlyStakers() public {
        BcusStaking cs = new BcusStaking();              // echte Grenze: 1 % pro Woche
        MortalityEmission ce = new MortalityEmission(address(0x0A), address(cs), address(0), HOLDER, 1_000_000e18);
        cs.bind(address(ce));
        BloodcoinToken t = ce.token();
        vm.prank(HOLDER);
        t.transfer(ALICE, 100e18);
        vm.prank(ALICE);
        t.approve(address(cs), type(uint256).max);
        vm.prank(ALICE);
        cs.stake(100e18);                                // gesamter Umlauf, Anteil 100 %
        vm.warp(START + 1 weeks);
        cs.pull();
        vm.warp(START + 2 weeks - 1);
        vm.prank(ALICE);
        cs.claim();
        assertNear(t.balanceOf(ALICE), 1e18, 1e16);           // Belohnung höchstens 1 % von 100 (Einsatz bleibt gestakt)
        assertNear(t.balanceOf(cs.BURN()), base - 1e18, 1e16); // Rest verbrannt (kein Mining)
    }

    function testCapScalesWithWeeksSinceLastSync() public {
        BcusStaking cs = new BcusStaking();
        MortalityEmission ce = new MortalityEmission(address(0x0A), address(cs), address(0), HOLDER, 1_000_000e18);
        cs.bind(address(ce));
        BloodcoinToken t = ce.token();
        vm.prank(HOLDER);
        t.transfer(ALICE, 100e18);
        vm.prank(ALICE);
        t.approve(address(cs), type(uint256).max);
        vm.prank(ALICE);
        cs.stake(100e18);
        vm.warp(START + 3 weeks);                        // 3 Wochen aufgelaufen, ein Sync
        cs.pull();
        vm.warp(START + 4 weeks - 1);
        vm.prank(ALICE);
        cs.claim();
        assertNear(t.balanceOf(ALICE), 3e18, 1e16);
    }

    function testFounderLockAndBurnDoNotCount() public {
        trim(ALICE, 100e18);
        trim(BOB, 0);
        // Alles andere liegt beim Start-Halter (im Mainnet der FounderLock): zählt nicht.
        stake(ALICE, 100e18);
        assertEq(st.circulating(), 100e18);
        assertEq(st.stakerShareBp(), 10_000);
    }

    function testRestGoesToMiningWhenThereIsAMiner() public {
        address minerAddr = address(0xBEEF);
        StakingHarness st2 = new StakingHarness();
        st2.setMax(1e12);
        MortalityEmission em2 = new MortalityEmission(address(0x0A), address(st2), minerAddr, HOLDER, 1_000_000e18);
        st2.bind(address(em2));
        BloodcoinToken t2 = em2.token();
        vm.prank(HOLDER);
        t2.transfer(ALICE, 100e18);
        vm.prank(HOLDER);
        t2.transfer(BOB, 300e18);
        vm.prank(ALICE);
        t2.approve(address(st2), type(uint256).max);
        vm.prank(ALICE);
        st2.stake(100e18);                               // 100 von 400 im Umlauf
        vm.warp(START + 1 weeks);
        st2.pull();
        uint256 b = em2.BASE_EMISSION();
        // Mining-Hälfte b/2 plus 75 % der Staking-Hälfte, die Alice nicht beansprucht.
        assertNear(t2.balanceOf(minerAddr), b / 2 + (b / 2) * 3 / 4, 1e12);
        assertNear(st2.sentToMining(), (b / 2) * 3 / 4, 1e12);
        assertEq(t2.balanceOf(st2.BURN()), 0);
    }

    // ---------------------------------------------------------------- Einsatz

    function testWithdrawReturnsStake() public {
        stake(ALICE, 100e18);
        vm.prank(ALICE);
        vm.expectRevert(BcusStaking.InsufficientStake.selector);
        st.withdraw(101e18);
        vm.prank(ALICE);
        st.withdraw(100e18);
        assertEq(token.balanceOf(ALICE), 300_000e18);
        assertEq(st.totalStaked(), 0);
    }

    function testZeroAmountsRejected() public {
        vm.prank(ALICE);
        vm.expectRevert(BcusStaking.ZeroAmount.selector);
        st.stake(0);
    }

    function testLongRunStaysSolvent() public {
        stake(ALICE, 100e18);
        stake(BOB, 100e18);
        for (uint256 i = 1; i <= 30; i++) {
            vm.warp(START + i * 1 weeks + i * 3 hours);
            if (i % 3 == 0) claim(ALICE);
            if (i % 5 == 0) {
                vm.prank(BOB);
                st.withdraw(10e18);
            }
            if (i % 7 == 0) stake(ALICE, 1e18);
            st.pull();
        }
        vm.warp(START + 40 weeks);
        vm.prank(ALICE);
        st.exit();
        vm.prank(BOB);
        st.exit();
        assertSolvent();
        assertEq(st.totalStaked(), 0);
    }
}
