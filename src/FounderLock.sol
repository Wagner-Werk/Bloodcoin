// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {VestingWallet} from "@openzeppelin/contracts/finance/VestingWallet.sol";

/// Sperrvertrag für die Gründer-BCUS: alles bleibt 2 Jahre ab Deploy gesperrt, danach geht alles auf
/// einmal an den festen Empfänger. OpenZeppelin-VestingWallet mit Dauer 0 (= Timelock), dazu:
/// - Frist wird im Constructor aus block.timestamp berechnet und ist unveränderlich (kein Admin).
/// - Empfänger ist fest: transferOwnership und renounceOwnership sind abgeschaltet. Sonst könnte der
///   Empfänger die gesperrten Coins vorab verkaufen oder sie durch renounce für immer verlieren.
/// - Abholen vor Fristende scheitert mit StillLocked, statt still 0 auszuzahlen.
/// Auslösen darf jeder (release), die Coins gehen immer an den Empfänger.
contract FounderLock is VestingWallet {
    uint64 public constant LOCK_DURATION = 730 days;

    error StillLocked(uint256 unlockTime);
    error BeneficiaryFixed();

    constructor(address beneficiary) VestingWallet(beneficiary, uint64(block.timestamp) + LOCK_DURATION, 0) {}

    function release(address token) public override {
        if (block.timestamp < end()) revert StillLocked(end());
        super.release(token);
    }

    function release() public override {
        if (block.timestamp < end()) revert StillLocked(end());
        super.release();
    }

    function transferOwnership(address) public pure override {
        revert BeneficiaryFixed();
    }

    function renounceOwnership() public pure override {
        revert BeneficiaryFixed();
    }
}
