// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

interface IMortalityEmission {
    function report(uint256 weekEnding, uint256 recentDeaths, uint256 baselineDeaths) external;
    function resetFactor() external;
    function lastWeekEnding() external view returns (uint256);
}

/// @title CDC-Sterbezahlen, signiert vom eigenen Server, mit Einspruchsfrist und Wächter (S6)
/// @notice Der Server holt jeden Montag die CDC-Zahlen, signiert sie mit einem festen Schlüssel
///         (EIP-712) und schlägt sie vor. Einreichen darf jeder, angenommen wird nur, was `signer`
///         signiert hat. Die Signatur gilt nur für diesen Contract auf dieser Chain.
///
///         Gemeldet werden die Toten der letzten 4 Wochen und der Durchschnitt derselben 4 Wochen
///         in den 3 Vorjahren (siehe MortalityEmission).
///
///         Ein Vorschlag wirkt nicht sofort:
///         - Er wartet `CHALLENGE_PERIOD` (48 h). Danach kann ihn jeder mit `execute` wirksam machen.
///         - Bis dahin (und danach, solange er nicht ausgeführt ist) kann der Wächter (`guardian`,
///           ein zweiter Schlüssel, nur offline beim Gründer) ihn verwerfen: direkt mit `veto` oder
///           mit einer Signatur, die jeder per `vetoWithSig` einreichen kann.
///         - Zwischen zwei Vorschlägen liegen mindestens `MIN_INTERVAL` (6 Tage), auch nach einem
///           Veto, und ebenso zwischen zwei Ausführungen. Ein gestohlener Schlüssel kann also nicht
///           mehrere Wochen am selben Tag nachmelden; der Faktor bewegt sich höchstens um 0,05 je
///           6 Tage.
///         - Es ist immer höchstens ein Vorschlag offen.
///
///         Der Wächter kann nicht melden. Er kann verwerfen und den Melder abschalten. Geht sein
///         Schlüssel verloren, fällt nur das Veto weg; Meldungen laufen nach 48 h normal durch.
///
///         Kein Besitzer. `signer` und `guardian` sind unveränderlich. Beim Abschalten (`retire`)
///         geht der Faktor auf 1,0 zurück, und die Emission läuft ohne Sterbe-Anpassung weiter.
contract SignedMortalityOracle is EIP712 {
    bytes32 public constant REPORT_TYPEHASH =
        keccak256("MortalityReport(uint256 weekEnding,uint256 recentDeaths,uint256 baselineDeaths)");
    bytes32 public constant VETO_TYPEHASH = keccak256("Veto(uint256 weekEnding,uint256 proposedAt)");
    bytes32 public constant RETIRE_TYPEHASH = keccak256("Retire()");

    /// Summe über 4 Wochen. US-Wochenwerte lagen seit 2015 zwischen etwa 50.000 und 90.000,
    /// 4 Wochen also zwischen 200.000 und 360.000.
    uint256 public constant MIN_DEATHS = 80_000;
    uint256 public constant MAX_DEATHS = 1_000_000;

    uint256 public constant CHALLENGE_PERIOD = 48 hours;
    uint256 public constant MIN_INTERVAL = 6 days;

    /// Wie MortalityEmission.LAG. Schon beim Vorschlag geprüft, damit ein offener Vorschlag nicht
    /// erst beim Ausführen scheitert und bis zu einem Veto hängen bleibt.
    uint256 public constant LAG = 8 weeks;

    address public immutable signer;
    address public immutable guardian;
    address private immutable deployer;

    IMortalityEmission public emission;
    bool public retired;

    struct Proposal {
        uint64 weekEnding;
        uint64 proposedAt;
        uint64 recentDeaths;
        uint64 baselineDeaths;
    }

    /// Der offene Vorschlag; `weekEnding == 0` heisst: nichts offen.
    Proposal public pending;
    /// Zeitpunkt des letzten Vorschlags, auch wenn er verworfen wurde.
    uint256 public lastProposedAt;
    /// Zeitpunkt der letzten Ausführung. Auch zwei Ausführungen liegen mindestens MIN_INTERVAL
    /// auseinander, selbst wenn ein Vorschlag erst spät ausgeführt wurde.
    uint256 public lastExecutedAt;

    event Proposed(uint256 indexed weekEnding, uint256 recentDeaths, uint256 baselineDeaths, uint256 executableAt);
    event Executed(uint256 indexed weekEnding, uint256 recentDeaths, uint256 baselineDeaths);
    event Vetoed(uint256 indexed weekEnding);
    event Retired(address by);

    error AlreadyBound();
    error NotBound();
    error IsRetired();
    error BadSignature();
    error BadGuardian();
    error OnlyGuardian();
    error OutOfRange();
    error PendingExists();
    error NothingPending();
    error ChallengeOpen();
    error TooSoon();
    error WeekNotNewer();
    error WeekTooRecent();
    error NotASaturday();

    constructor(address signer_, address guardian_) EIP712("Bloodcoin Mortality Oracle", "1") {
        if (signer_ == address(0)) revert BadSignature();
        if (guardian_ == address(0) || guardian_ == signer_) revert BadGuardian();
        signer = signer_;
        guardian = guardian_;
        deployer = msg.sender;
    }

    function bind(address emission_) external {
        if (msg.sender != deployer || address(emission) != address(0)) revert AlreadyBound();
        emission = IMortalityEmission(emission_);
    }

    // ------------------------------------------------------------------ Lesehilfen

    /// @notice Hash, den der Server signiert. Gleich dem EIP-712-Hash von MortalityReport.
    function reportDigest(uint256 weekEnding, uint256 recentDeaths, uint256 baselineDeaths)
        public
        view
        returns (bytes32)
    {
        return _hashTypedDataV4(keccak256(abi.encode(REPORT_TYPEHASH, weekEnding, recentDeaths, baselineDeaths)));
    }

    /// @notice Hash, den der Wächter für ein Veto signiert. Gilt nur für genau diesen Vorschlag.
    function vetoDigest(uint256 weekEnding, uint256 proposedAt) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(VETO_TYPEHASH, weekEnding, proposedAt)));
    }

    function retireDigest() public view returns (bytes32) {
        return _hashTypedDataV4(RETIRE_TYPEHASH);
    }

    /// @notice Ab wann der offene Vorschlag ausgeführt werden kann (0 = nichts offen).
    function executableAt() public view returns (uint256) {
        if (pending.weekEnding == 0) return 0;
        uint256 a = uint256(pending.proposedAt) + CHALLENGE_PERIOD;
        uint256 b = lastExecutedAt == 0 ? 0 : lastExecutedAt + MIN_INTERVAL;
        return a > b ? a : b;
    }

    // ------------------------------------------------------------------ Melden

    /// @notice Schlägt eine signierte Meldung vor. Sie wirkt frühestens nach CHALLENGE_PERIOD.
    function propose(uint256 weekEnding, uint256 recentDeaths, uint256 baselineDeaths, bytes calldata signature)
        external
    {
        if (retired) revert IsRetired();
        if (address(emission) == address(0)) revert NotBound();
        if (ECDSA.recover(reportDigest(weekEnding, recentDeaths, baselineDeaths), signature) != signer) {
            revert BadSignature();
        }
        if (
            recentDeaths < MIN_DEATHS || recentDeaths > MAX_DEATHS || baselineDeaths < MIN_DEATHS
                || baselineDeaths > MAX_DEATHS || recentDeaths > 2 * baselineDeaths || 2 * recentDeaths < baselineDeaths
        ) revert OutOfRange();
        if (pending.weekEnding != 0) revert PendingExists();
        if (lastProposedAt != 0 && block.timestamp < lastProposedAt + MIN_INTERVAL) revert TooSoon();
        if (weekEnding <= emission.lastWeekEnding()) revert WeekNotNewer();
        if (weekEnding + LAG > block.timestamp) revert WeekTooRecent();
        // 1970-01-01 war ein Donnerstag, Samstag ist also Tag 2 modulo 7.
        if (weekEnding % 1 days != 0 || (weekEnding / 1 days) % 7 != 2) revert NotASaturday();

        pending = Proposal(uint64(weekEnding), uint64(block.timestamp), uint64(recentDeaths), uint64(baselineDeaths));
        lastProposedAt = block.timestamp;
        emit Proposed(weekEnding, recentDeaths, baselineDeaths, executableAt());
    }

    /// @notice Macht den offenen Vorschlag wirksam, sobald die Einspruchsfrist um ist. Jeder darf das.
    function execute() external {
        if (retired) revert IsRetired();
        Proposal memory p = pending;
        if (p.weekEnding == 0) revert NothingPending();
        if (block.timestamp < uint256(p.proposedAt) + CHALLENGE_PERIOD) revert ChallengeOpen();
        if (lastExecutedAt != 0 && block.timestamp < lastExecutedAt + MIN_INTERVAL) revert TooSoon();
        delete pending;
        lastExecutedAt = block.timestamp;
        emission.report(p.weekEnding, p.recentDeaths, p.baselineDeaths);
        emit Executed(p.weekEnding, p.recentDeaths, p.baselineDeaths);
    }

    // ------------------------------------------------------------------ Wächter

    /// @notice Der Wächter verwirft den offenen Vorschlag.
    function veto() external {
        if (msg.sender != guardian) revert OnlyGuardian();
        _veto();
    }

    /// @notice Dasselbe mit einer Wächter-Signatur über Veto(weekEnding, proposedAt). Jeder darf sie
    ///         einreichen, der Wächter braucht also kein ETH.
    function vetoWithSig(bytes calldata signature) external {
        Proposal memory p = pending;
        if (p.weekEnding == 0) revert NothingPending();
        if (ECDSA.recover(vetoDigest(p.weekEnding, p.proposedAt), signature) != guardian) revert BadSignature();
        _veto();
    }

    function _veto() internal {
        if (retired) revert IsRetired();
        uint256 week = pending.weekEnding;
        if (week == 0) revert NothingPending();
        delete pending;
        emit Vetoed(week);
    }

    // ------------------------------------------------------------------ Abschalten

    /// @notice Schaltet den Melder endgültig ab und setzt den Faktor auf 1,0 zurück. Braucht eine
    ///         Signatur über Retire() vom Melde-Schlüssel oder vom Wächter.
    function retire(bytes calldata signature) external {
        address by = ECDSA.recover(retireDigest(), signature);
        if (by != signer && by != guardian) revert BadSignature();
        _retire(by);
    }

    /// @notice Dasselbe, direkt vom Wächter aufgerufen.
    function retire() external {
        if (msg.sender != guardian) revert OnlyGuardian();
        _retire(msg.sender);
    }

    function _retire(address by) internal {
        if (retired) revert IsRetired();
        retired = true;
        delete pending;
        if (address(emission) != address(0)) emission.resetFactor();
        emit Retired(by);
    }
}
