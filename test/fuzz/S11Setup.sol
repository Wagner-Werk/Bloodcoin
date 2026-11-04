// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BloodcoinToken} from "../../src/BloodcoinToken.sol";
import {MortalityEmission} from "../../src/MortalityEmission.sol";
import {SignedMortalityOracle} from "../../src/SignedMortalityOracle.sol";
import {BcusStaking} from "../../src/BcusStaking.sol";
import {FounderLock} from "../../src/FounderLock.sol";
import {BcusMining} from "../../src/BcusMining.sol";

/// Cheatcodes, die die Fuzz- und Invariantentests zusätzlich zu test/Test.sol brauchen.
interface VmX {
    function warp(uint256) external;
    function prank(address) external;
    function store(address, bytes32, bytes32) external;
    function load(address, bytes32) external view returns (bytes32);
    function sign(uint256, bytes32) external pure returns (uint8, bytes32, bytes32);
    function addr(uint256) external pure returns (address);
    function assume(bool) external pure;
    function expectRevert(bytes4) external;
    function expectRevert() external;
    function assertEq(uint256, uint256, string calldata) external pure;
    function assertLe(uint256, uint256, string calldata) external pure;
    function assertGe(uint256, uint256, string calldata) external pure;
    function assertTrue(bool, string calldata) external pure;
}

/// Gleicher Aufbau wie script/DeploySigned.s.sol (S11): signierter Melder, Staking mit
/// Anteils-Regel und 1-%-Deckel, FounderLock mit der Startmenge, Mining auf Base.
abstract contract S11Setup {
    VmX internal constant vmx = VmX(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint256 internal constant START = 1_800_000_000;
    uint256 internal constant INITIAL = 1_000_000e18;
    uint256 internal constant SIGNER_PK = 0xB10D;

    // Speicherplätze in BcusMining (forge inspect BcusMining storageLayout).
    bytes32 internal constant MINING_TARGET_SLOT = bytes32(uint256(3));
    bytes32 internal constant MINING_PERIOD_START_SLOT = bytes32(uint256(4));
    bytes32 internal constant MINING_PERIOD_SOLUTIONS_SLOT = bytes32(uint256(5));

    SignedMortalityOracle internal oracle;
    BcusStaking internal st;
    FounderLock internal lock;
    BcusMining internal mn;
    MortalityEmission internal em;
    BloodcoinToken internal token;

    function deployS11(address beneficiary) internal {
        vmx.warp(START);
        oracle = new SignedMortalityOracle(vmx.addr(SIGNER_PK));
        st = new BcusStaking();
        lock = new FounderLock(beneficiary);
        mn = new BcusMining();
        em = new MortalityEmission(address(oracle), address(st), address(mn), address(lock), INITIAL);
        oracle.bind(address(em));
        st.bind(address(em));
        mn.bind(address(em));
        token = em.token();
    }

    function sig(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vmx.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    /// Letzter Samstag 00:00 UTC, der mindestens LAG (8 Wochen) zurückliegt.
    function latestReportableSaturday(uint256 t) internal pure returns (uint256) {
        uint256 x = t - 8 weeks - 2 days;
        return 2 days + (x / 1 weeks) * 1 weeks;
    }

    /// Macht die nächste Mining-Lösung mit nonce 0 gültig, ohne echte Arbeit, und verhindert die
    /// Schwierigkeits-Anpassung in diesem Aufruf. Geprüft wird damit die Belohnungs-Buchhaltung,
    /// nicht die Schwierigkeit (die hat eigene Tests in test/Mining.t.sol).
    function makeNextSolutionFree() internal {
        vmx.store(address(mn), MINING_TARGET_SLOT, bytes32(type(uint256).max));
        vmx.store(address(mn), MINING_PERIOD_START_SLOT, bytes32(block.timestamp));
        vmx.store(address(mn), MINING_PERIOD_SOLUTIONS_SLOT, bytes32(0));
    }

    function clamp(uint256 x, uint256 lo, uint256 hi) internal pure returns (uint256) {
        if (hi <= lo) return lo;
        return lo + x % (hi - lo + 1);
    }
}
