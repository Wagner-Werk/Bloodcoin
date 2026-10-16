// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "./Test.sol";
import {MortalityEmission} from "../src/MortalityEmission.sol";
import {SignedMortalityOracle} from "../src/SignedMortalityOracle.sol";
import {BcusStaking} from "../src/BcusStaking.sol";
import {FounderLock} from "../src/FounderLock.sol";
import {BloodcoinToken} from "../src/BloodcoinToken.sol";

contract FounderLockTest is Test {
    uint256 constant START = 1_800_000_000;          // 2027-01-15
    uint256 constant MINT = 1_000_000e18;
    address constant FOUNDER = address(0xF0F0);
    address constant STRANGER = address(0xBAD);

    FounderLock lock;
    BloodcoinToken token;

    // Gleiche Reihenfolge wie script/DeploySigned.s.sol
    function setUp() public {
        vm.warp(START);
        SignedMortalityOracle o = new SignedMortalityOracle(vm.addr(0xB10D));
        BcusStaking st = new BcusStaking();
        lock = new FounderLock(FOUNDER);
        MortalityEmission e = new MortalityEmission(address(o), address(st), address(lock), MINT);
        o.bind(address(e));
        st.bind(address(e));
        token = e.token();
    }

    function testFounderCoinsGoIntoLock() public view {
        assertEq(token.balanceOf(address(lock)), MINT);
        assertEq(token.balanceOf(FOUNDER), 0);
        assertEq(lock.owner(), FOUNDER);
    }

    function testUnlockIsTwoYearsAfterDeploy() public view {
        assertEq(lock.start(), START + 730 days);
        assertEq(lock.duration(), 0);
        assertEq(lock.end(), START + 730 days);
    }

    function testEarlyReleaseFails() public {
        vm.prank(FOUNDER);
        vm.expectRevert(abi.encodeWithSelector(FounderLock.StillLocked.selector, START + 730 days));
        lock.release(address(token));
    }

    function testReleaseOneSecondBeforeEndFails() public {
        vm.warp(START + 730 days - 1);
        vm.prank(FOUNDER);
        vm.expectRevert(abi.encodeWithSelector(FounderLock.StillLocked.selector, START + 730 days));
        lock.release(address(token));
        assertEq(lock.releasable(address(token)), 0);
        assertEq(token.balanceOf(address(lock)), MINT);
    }

    function testReleaseAfterTwoYears() public {
        vm.warp(START + 730 days);
        assertEq(lock.releasable(address(token)), MINT);
        vm.prank(FOUNDER);
        lock.release(address(token));
        assertEq(token.balanceOf(FOUNDER), MINT);
        assertEq(token.balanceOf(address(lock)), 0);
    }

    function testStrangerCanTriggerButCoinsGoToFounder() public {
        vm.warp(START + 731 days);
        vm.prank(STRANGER);
        lock.release(address(token));
        assertEq(token.balanceOf(FOUNDER), MINT);
        assertEq(token.balanceOf(STRANGER), 0);
    }

    function testSecondReleasePaysNothingMore() public {
        vm.warp(START + 730 days);
        lock.release(address(token));
        lock.release(address(token));
        assertEq(token.balanceOf(FOUNDER), MINT);
        assertEq(lock.released(address(token)), MINT);
    }

    function testBeneficiaryCannotBeChanged() public {
        vm.prank(FOUNDER);
        vm.expectRevert(FounderLock.BeneficiaryFixed.selector);
        lock.transferOwnership(STRANGER);
        vm.prank(FOUNDER);
        vm.expectRevert(FounderLock.BeneficiaryFixed.selector);
        lock.renounceOwnership();
        assertEq(lock.owner(), FOUNDER);
    }

    function testEarlyEthReleaseFails() public {
        vm.expectRevert(abi.encodeWithSelector(FounderLock.StillLocked.selector, START + 730 days));
        lock.release();
    }
}
