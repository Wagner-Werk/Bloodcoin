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

    // ---------------------------------------------------------------- Verteilung

    function testSingleStakerGetsWholeWeekStreamedOver7Days() public {
        trim(ALICE, 100e18);
        trim(BOB, 0);                                    // Umlauf = nur Alice, Anteil 100 %
        stake(ALICE, 100e18);
        vm.warp(START + 1 weeks);
        st.pull();                                       // Woche 1 kommt an, Strom startet
        vm.warp(START + 1 weeks + 3.5 days);
        assertNear(claim(ALICE), base / 2, 1e12);        // nach halber Zeit die Hälfte
        vm.warp(START + 2 weeks);
        st.pull();                                       // Woche 2 kommt dazu
        vm.warp(START + 4 weeks);
        st.pull();
        vm.warp(START + 6 weeks);
        claim(ALICE);
        assertSolvent();
    }

    function testSplitByStakeSize() public {
        trim(ALICE, 100e18);
        trim(BOB, 300e18);
        stake(ALICE, 100e18);
        stake(BOB, 300e18);
        vm.warp(START + 1 weeks);
        st.pull();
        vm.warp(START + 1 weeks + 7 days);
        uint256 a = claim(ALICE);
        uint256 b = claim(BOB);
        assertNear(a, base / 4, 1e12);
        assertNear(b, base * 3 / 4, 1e12);
        assertSolvent();
    }

    function testFlashStakerGetsAlmostNothing() public {
        trim(ALICE, 100e18);
        trim(BOB, 100_000e18);
        stake(ALICE, 100e18);
        vm.warp(START + 1 weeks - 1);
        stake(BOB, 100_000e18);                          // riesiger Einsatz kurz vor der Ausgabe
        vm.warp(START + 1 weeks);
        st.pull();
        vm.warp(START + 1 weeks + 1);
        vm.prank(BOB);
        st.exit();                                       // sofort wieder raus
        assertLe(token.balanceOf(BOB), 100_000e18 + base / 1000);
        vm.warp(START + 2 weeks + 1);
        assertNear(claim(ALICE), base, base / 1000);
        assertSolvent();
    }

    function testDirectMintByOutsiderStillDistributed() public {
        trim(ALICE, 100e18);
        trim(BOB, 0);
        stake(ALICE, 100e18);
        vm.warp(START + 1 weeks);
        em.mint();                                       // jemand ruft direkt am Emissions-Contract
        assertEq(st.rewardRate(), 0);
        st.pull();                                       // wird trotzdem erkannt
        vm.warp(START + 1 weeks + 7 days);
        assertNear(claim(ALICE), base, 1e12);
        assertSolvent();
    }

    function testRewardsWithoutStakersAreBurned() public {
        trim(ALICE, 100e18);
        trim(BOB, 0);
        vm.warp(START + 1 weeks);
        st.pull();                                       // niemand stakt: Anteil 0, alles verbrannt
        assertNear(token.balanceOf(st.BURN()), base, 1e12);
        assertEq(st.rewardRate(), 0);
        vm.warp(START + 1 weeks + 7 days);
        stake(ALICE, 100e18);                            // Woche 2 kommt an, bevor Alice zählt
        assertNear(token.balanceOf(st.BURN()), 2 * base, 1e12);
        vm.warp(START + 3 weeks);
        st.pull();                                       // Woche 3: Alice hat 100 % des Umlaufs
        vm.warp(START + 4 weeks);
        assertNear(claim(ALICE), base, base / 100);      // nur Woche 3, die davor sind weg
        assertSolvent();
    }

    function testStakerJoiningMidStreamGetsOnlyTheRest() public {
        trim(ALICE, 100e18);
        trim(BOB, 100e18);
        stake(ALICE, 100e18);                            // Umlauf 200, gestakt 100: Anteil 50 %
        vm.warp(START + 1 weeks);
        st.pull();
        assertNear(token.balanceOf(st.BURN()), base / 2, 1e12);   // die andere Hälfte
        vm.warp(START + 1 weeks + 3.5 days);
        stake(BOB, 100e18);                              // steigt zur Hälfte des Stroms ein
        vm.warp(START + 1 weeks + 7 days);
        assertNear(claim(ALICE), base * 3 / 8, 1e12);    // 1/4 allein + 1/8 geteilt
        assertNear(claim(BOB), base / 8, 1e12);
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
        vm.warp(START + 2 weeks - 1);                    // vor der 2. Ausgabe
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
