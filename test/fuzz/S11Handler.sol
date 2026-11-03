// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {S11Setup} from "./S11Setup.sol";
import {BloodcoinToken} from "../../src/BloodcoinToken.sol";
import {MortalityEmission} from "../../src/MortalityEmission.sol";
import {SignedMortalityOracle} from "../../src/SignedMortalityOracle.sol";
import {BcusStaking} from "../../src/BcusStaking.sol";
import {FounderLock} from "../../src/FounderLock.sol";
import {BcusMining} from "../../src/BcusMining.sol";

/// Spielt zufällige Folgen echter Nutzer-Aktionen gegen einen S11-Aufbau: Zeit vergeht, Leute
/// schürfen, staken, heben ab, holen ab, schicken sich BCUS, der Melder meldet (gültig und
/// gefälscht), der FounderLock gibt frei, selten wird der Melder abgeschaltet.
///
/// Der Handler führt Schattenbuchhaltung (ghost) und zählt Verstöße, die sich nur während einer
/// Aktion prüfen lassen (Deckel pro Ausgabe, Faktor-Schritt, unerwartete Reverts). Die
/// Invarianten in S11Invariant.t.sol prüfen nach jeder Aktion, dass alles stimmt.
contract S11Handler is S11Setup {
    address[3] public actors;
    uint256 public now_;
    uint256 public calls;

    // ---------------------------------------------------------------- Schattenbuchhaltung
    mapping(address => uint256) public ghostBal;     // erwarteter Token-Stand je Nutzer
    mapping(address => uint256) public ghostStake;   // erwarteter Einsatz je Nutzer
    uint256 public ghostClaimed;                     // Summe aller abgeholten Belohnungen
    uint256 public ghostDonated;                     // direkt ans Staking geschickt
    uint256 public ghostSettled;                     // erwartete abgerechnete Emission
    uint256 public ghostSettledEpochs;
    uint256 public ghostMined;                       // an Miner ausgezahlt
    uint256 public ghostMaxFactor = 1000;
    uint256 public ghostMinFactor = 1000;
    uint256 public syncsWithFresh;                   // Ausgaben, die beim Staking ankamen
    uint256 public reportsOk;
    uint256 public solutions;
    bool public ghostRetired;

    // ---------------------------------------------------------------- Verstöße
    uint256 public capViolations;          // Staker-Teil > 1 % * aufgerundete Wochen * Einsatz
    uint256 public shareViolations;        // Staker-Teil > Anteil am Umlauf
    uint256 public stepViolations;         // Faktor-Sprung > 0,05, Faktor außerhalb [0,5; 1,0], falsches Ziel
    uint256 public unexpectedReverts;      // eine Aktion, die gehen muss, ging nicht
    uint256 public unexpectedSuccess;      // eine Aktion, die scheitern muss, ging durch
    uint256 public mineRewardViolations;   // Mining-Belohnung > Vorrat * 40 min / Woche
    uint256 public releaseViolations;      // FounderLock gab mehr frei als linear erlaubt
    string public lastViolation;

    constructor() {
        actors[0] = address(0xA11CE);        // zugleich Empfänger des FounderLock (Gründer)
        actors[1] = address(0xB0B);
        actors[2] = address(0xC4A2);
        deployS11(actors[0]);
        now_ = block.timestamp;
        for (uint256 i = 0; i < 3; i++) {
            vmx.prank(actors[i]);
            token.approve(address(st), type(uint256).max);
        }
    }

    // ---------------------------------------------------------------- Zugriff für die Tests
    function c() external view returns (
        BloodcoinToken, MortalityEmission, SignedMortalityOracle, BcusStaking, FounderLock, BcusMining
    ) {
        return (token, em, oracle, st, lock, mn);
    }

    // ---------------------------------------------------------------- Hilfen

    function _violate(string memory what) internal {
        lastViolation = what;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % 3];
    }

    /// Rechnet die Emission so ab, wie der Contract es tun muss: jede abgelaufene Epoche mit dem
    /// Faktor, der vor der aktuellen Aktion galt.
    function _begin() internal {
        vmx.warp(now_);
        calls++;
        uint256 done = (now_ - em.start()) / 1 weeks;
        uint256 f = em.factorMilli();
        for (uint256 e = ghostSettledEpochs; e < done; e++) {
            uint256 b = em.epochEmission(e);
            if (b == 0) break;
            ghostSettled += b * f / 1000;
        }
        ghostSettledEpochs = done;
    }

    struct Snap {
        uint256 reserved;
        uint256 sent;
        uint256 burned;
        uint256 totalStaked;
        uint256 shareBp;
        uint256 lastSync;
    }

    function _snap() internal view returns (Snap memory s) {
        s.reserved = st.reserved();
        s.sent = st.sentToMining();
        s.burned = st.burned();
        s.totalStaked = st.totalStaked();
        s.shareBp = st.stakerShareBp();
        s.lastSync = st.lastSyncAt();
    }

    /// Nach einer Staking-Aktion: Was ist bei dieser Synchronisation an die Staker gegangen, und
    /// hält das Deckel und Anteils-Regel ein?
    function _checkSync(Snap memory b, uint256 claimed) internal {
        uint256 part = st.reserved() + claimed + (st.burned() - b.burned) - b.reserved;
        uint256 rest = st.sentToMining() - b.sent;
        if (part + rest == 0) return;
        syncsWithFresh++;
        uint256 weeks_ = (now_ - b.lastSync + 1 weeks - 1) / 1 weeks;
        if (weeks_ == 0) weeks_ = 1;
        if (part > b.totalStaked * st.maxWeeklyBp() * weeks_ / 10_000) {
            capViolations++;
            _violate("Staker-Teil ueber dem Deckel");
        }
        if (part > (part + rest) * b.shareBp / 10_000) {
            shareViolations++;
            _violate("Staker-Teil ueber dem Anteil am Umlauf");
        }
    }

    // ---------------------------------------------------------------- Aktionen

    function warp(uint256 dt) external {
        // meist Stunden bis Tage, manchmal Wochen am Stück ohne jede Aktivität
        dt = dt % 10 == 0 ? 1 + dt % (60 days) : 1 + dt % (3 days);
        now_ += dt;
        vmx.warp(now_);
    }

    function mine(uint256 who) external {
        _begin();
        address a = _actor(who);
        uint256 supplyBefore = token.totalSupply();
        uint256 poolBefore = token.balanceOf(address(mn));
        makeNextSolutionFree();
        uint256 balBefore = token.balanceOf(a);
        vmx.prank(a);
        try mn.mine(0) returns (uint256 reward) {
            // Vorrat nach dem mint() im Aufruf ist höchstens poolBefore + neu gemintetes
            uint256 pool = poolBefore + (token.totalSupply() - supplyBefore);
            if (reward * 1 weeks > pool * 40 minutes) {
                mineRewardViolations++;
                _violate("Mining-Belohnung ueber 40 Minuten Anteil");
            }
            if (token.balanceOf(a) - balBefore != reward) {
                mineRewardViolations++;
                _violate("Mining-Belohnung nicht ausgezahlt");
            }
            ghostBal[a] += reward;
            ghostMined += reward;
            solutions++;
        } catch (bytes memory err) {
            // NothingToMine ist erlaubt (kein Vorrat oder zweite Lösung in derselben Sekunde)
            if (bytes4(err) != BcusMining.NothingToMine.selector) {
                unexpectedReverts++;
                _violate("mine() unerwartet gescheitert");
            }
        }
    }

    function stake(uint256 who, uint256 amt) external {
        _begin();
        address a = _actor(who);
        uint256 bal = token.balanceOf(a);
        if (bal == 0) return;
        amt = clamp(amt, 1, bal);
        Snap memory b = _snap();
        vmx.prank(a);
        try st.stake(amt) {
            ghostBal[a] -= amt;
            ghostStake[a] += amt;
            _checkSync(b, 0);
        } catch {
            unexpectedReverts++;
            _violate("stake() unerwartet gescheitert");
        }
    }

    function withdraw(uint256 who, uint256 amt) external {
        _begin();
        address a = _actor(who);
        uint256 s = st.stakedOf(a);
        if (s == 0) return;
        amt = clamp(amt, 1, s);
        Snap memory b = _snap();
        uint256 balBefore = token.balanceOf(a);
        vmx.prank(a);
        try st.withdraw(amt) {
            if (token.balanceOf(a) - balBefore != amt) {
                unexpectedSuccess++;
                _violate("withdraw() zahlte nicht genau den Betrag");
            }
            ghostBal[a] += amt;
            ghostStake[a] -= amt;
            _checkSync(b, 0);
        } catch {
            unexpectedReverts++;
            _violate("withdraw() unerwartet gescheitert (Einsatz fest)");
        }
    }

    function withdrawTooMuch(uint256 who, uint256 extra) external {
        _begin();
        address a = _actor(who);
        uint256 amt = st.stakedOf(a) + 1 + extra % 1e24;
        vmx.prank(a);
        try st.withdraw(amt) {
            unexpectedSuccess++;
            _violate("withdraw() ueber dem Einsatz ging durch");
        } catch {}
    }

    function claim(uint256 who) external {
        _begin();
        address a = _actor(who);
        Snap memory b = _snap();
        uint256 balBefore = token.balanceOf(a);
        vmx.prank(a);
        try st.claim() {
            uint256 got = token.balanceOf(a) - balBefore;
            ghostBal[a] += got;
            ghostClaimed += got;
            _checkSync(b, got);
        } catch {
            unexpectedReverts++;
            _violate("claim() unerwartet gescheitert");
        }
    }

    function exit(uint256 who) external {
        _begin();
        address a = _actor(who);
        uint256 s = st.stakedOf(a);
        Snap memory b = _snap();
        uint256 balBefore = token.balanceOf(a);
        vmx.prank(a);
        try st.exit() {
            uint256 got = token.balanceOf(a) - balBefore;
            if (got < s) {
                unexpectedSuccess++;
                _violate("exit() gab weniger als den Einsatz zurueck");
            }
            ghostBal[a] += got;
            ghostStake[a] = 0;
            ghostClaimed += got - s;
            // exit synchronisiert zweimal (withdraw, claim), die zweite Runde hat aber nie Neues.
            _checkSync(b, got - s);
        } catch {
            unexpectedReverts++;
            _violate("exit() unerwartet gescheitert");
        }
    }

    function pull() external {
        _begin();
        Snap memory b = _snap();
        try st.pull() {
            _checkSync(b, 0);
        } catch {
            unexpectedReverts++;
            _violate("pull() unerwartet gescheitert");
        }
    }

    /// Jemand ruft mint() direkt am Emissions-Contract auf (darf jeder).
    function mintDirect() external {
        _begin();
        try em.mint() {} catch {
            unexpectedReverts++;
            _violate("mint() unerwartet gescheitert");
        }
    }

    /// Jemand schickt BCUS direkt an das Staking (Spende oder Versehen).
    function donate(uint256 who, uint256 amt) external {
        _begin();
        address a = _actor(who);
        uint256 bal = token.balanceOf(a);
        if (bal == 0) return;
        amt = clamp(amt, 1, bal);
        vmx.prank(a);
        token.transfer(address(st), amt);
        ghostBal[a] -= amt;
        ghostDonated += amt;
    }

    function transfer(uint256 from, uint256 to, uint256 amt) external {
        _begin();
        address a = _actor(from);
        address b = _actor(to);
        uint256 bal = token.balanceOf(a);
        if (bal == 0 || a == b) return;
        amt = clamp(amt, 1, bal);
        vmx.prank(a);
        token.transfer(b, amt);
        ghostBal[a] -= amt;
        ghostBal[b] += amt;
    }

    function release(uint256 who) external {
        _begin();
        vmx.prank(_actor(who));                         // auslösen darf jeder
        uint256 before = token.balanceOf(actors[0]);
        lock.release(address(token));
        uint256 got = token.balanceOf(actors[0]) - before;
        ghostBal[actors[0]] += got;
        uint256 elapsed = now_ - START;
        uint256 dur = lock.VESTING_DURATION();
        uint256 allowed = elapsed >= dur ? INITIAL : INITIAL * elapsed / dur;
        if (lock.released(address(token)) > allowed) {
            releaseViolations++;
            _violate("FounderLock gab zu viel frei");
        }
    }

    /// Gültig signierte Meldung mit zufälligen, plausiblen Zahlen (auch Extremwerte bis 2:1).
    function report(uint256 r, uint256 bl) external {
        _begin();
        if (now_ < START + 9 weeks) return;
        uint256 we = latestReportableSaturday(now_);
        if (we <= em.lastWeekEnding()) return;
        uint256 baseline = clamp(bl, 80_000, 1_000_000);
        uint256 lo = baseline / 2 + 1;
        uint256 hi = 2 * baseline;
        if (lo < 80_000) lo = 80_000;
        if (hi > 1_000_000) hi = 1_000_000;
        uint256 recent = clamp(r, lo, hi);
        uint256 before = em.factorMilli();
        uint256 expect = em.stepToward(before, em.targetFor(recent, baseline));
        bytes memory s = sig(SIGNER_PK, oracle.reportDigest(we, recent, baseline));
        try oracle.submit(we, recent, baseline, s) {
            if (ghostRetired) {
                unexpectedSuccess++;
                _violate("Meldung nach retire angenommen");
            }
            uint256 f = em.factorMilli();
            if (f != expect || f > 1000 || f < 500 || (f > before ? f - before : before - f) > 50) {
                stepViolations++;
                _violate("Faktor-Schritt falsch");
            }
            if (f > ghostMaxFactor) ghostMaxFactor = f;
            if (f < ghostMinFactor) ghostMinFactor = f;
            reportsOk++;
        } catch {
            if (!ghostRetired) {
                unexpectedReverts++;
                _violate("gueltige Meldung abgelehnt");
            }
        }
    }

    /// Gefälschte Meldung (falscher Schlüssel): muss immer scheitern.
    function forgedReport(uint256 pk, uint256 recent) external {
        _begin();
        if (now_ < START + 9 weeks) return;
        pk = clamp(pk, 1, 1e70);
        if (pk == SIGNER_PK) pk++;
        uint256 we = latestReportableSaturday(now_);
        recent = clamp(recent, 100_000, 400_000);
        bytes memory s = sig(pk, oracle.reportDigest(we, recent, 200_000));
        try oracle.submit(we, recent, 200_000, s) {
            unexpectedSuccess++;
            _violate("gefaelschte Meldung angenommen");
        } catch {}
    }

    /// Selten: Melder abschalten. Danach muss der Faktor 1,0 sein und bleiben.
    function retire(uint256 seed) external {
        _begin();
        if (ghostRetired || seed % 400 != 0) return;
        try oracle.retire(sig(SIGNER_PK, oracle.retireDigest())) {
            ghostRetired = true;
            if (em.factorMilli() != 1000 || em.targetMilli() != 1000) {
                stepViolations++;
                _violate("retire setzte den Faktor nicht auf 1,0");
            }
        } catch {
            unexpectedReverts++;
            _violate("retire gescheitert");
        }
    }
}
