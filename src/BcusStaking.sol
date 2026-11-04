// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IEmission {
    function token() external view returns (IERC20);
    function recipient() external view returns (address);
    function miner() external view returns (address);
    function initialHolder() external view returns (address);
    function mint() external returns (uint256);
    function settledEpochs() external view returns (uint256);
    function completedEpochs() external view returns (uint256);
    function start() external view returns (uint256);
    function EPOCH() external view returns (uint256);
}

/// @title BCUS-Staking
/// @notice Wer BCUS hier sperrt, bekommt die wöchentlich neu ausgegebenen BCUS anteilig, und zwar
///         genau nach seinem eigenen Einsatz in genau der Emissions-Woche, aus der die Coins stammen.
///
///         Abrechnungs-Woche: Die Wochen liegen fest auf den Grenzen des Emissions-Contracts
///         (start + n * 1 Woche). Wann jemand den Contract aufruft, verschiebt keine Grenze. Haben
///         mehrere Wochen lang alle geschwiegen, werden diese Wochen zusammen als eine Abrechnung
///         behandelt (gleiche Regeln, nur länger).
///
///         Topf einer Woche: Was in der Woche ankommt (Staking-Hälfte der Emission und allfällige
///         Spenden), wird am Wochenende geteilt.
///         - Anteils-Regel: Staker bekommen den Teil, der ihrem Anteil an den frei umlaufenden Coins
///           entspricht (durchschnittlicher Einsatz in der Woche geteilt durch Umlauf, höchstens 1).
///         - Obergrenze: höchstens 1 % des durchschnittlichen Einsatzes pro Woche.
///         - Der Rest geht ans Mining.
///
///         Verteilung des Topfs: Jeder Staker bekommt so viel vom Topf, wie sein Einsatz mal Sekunden
///         in dieser Woche an der Summe aller Einsätze mal Sekunden ausmacht. Wer erst nach der Woche
///         einsteigt, bekommt aus ihr nichts. Wer mitten in der Woche aussteigt, behält seinen Anspruch
///         für die Zeit, in der er gestakt war, und kann ihn nach dem Wochenende abholen. Es gibt
///         keinen nachlaufenden Auszahlungsstrom mehr: Der Anspruch steht mit dem Wochenabschluss fest.
///
///         Hat in einer Woche niemand gestakt, geht der ganze Topf ans Mining.
///
///         Zum Umlauf zählt nicht: der FounderLock (noch nicht freigegebene Gründer-Coins), der
///         Mining-Vorrat, die Verbrennungsadresse und Belohnungen in diesem Contract. Gestakte
///         Coins zählen mit.
///
///         Einzahlen, Abheben und Abholen geht jederzeit und ohne Sperrfrist. Es gibt keinen
///         Besitzer. `bind` kann nur der Deployer genau einmal aufrufen, bevor die erste
///         Emissions-Woche abgelaufen ist.
contract BcusStaking is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// Obergrenze für die Staker: höchstens 1 % des durchschnittlichen Einsatzes pro Woche.
    /// Technische Grenze, kein Versprechen. Was darüber liegt, geht ans Mining. Es gibt keinen
    /// Setter; der Wert ist nur für Test-Ableitungen nicht `constant`.
    uint256 public maxWeeklyBp = 100;
    /// Rechengenauigkeit für die Belohnung pro Einsatz-Sekunde.
    uint256 internal constant PREC = 1e30;
    /// Übliche Verbrennungsadresse; zu ihr gibt es keinen Schlüssel.
    address public constant BURN = 0x000000000000000000000000000000000000dEaD;

    address private immutable deployer;
    IEmission public emission;
    IERC20 public token;
    address public mining;                  // bekommt den Teil, den Staker nicht beanspruchen
    address public founderLock;             // hält die noch gesperrten Gründer-Coins
    uint256 public epochStart;              // Beginn der Emission (Grenze der Woche 0)
    uint256 public epochLength;             // 1 Woche

    uint256 public totalStaked;
    mapping(address => uint256) public stakedOf;

    // ---- Abrechnungs-Wochen ("Perioden"). Periode `current` läuft noch.
    struct Period {
        uint256 start;      // Beginn (eine Emissions-Grenze)
        uint256 index;      // aufsummierte Belohnung pro Einsatz-Einheit bis zum Beginn (mal PREC)
        uint256 rate;       // Belohnung pro Einsatz-Einheit und Sekunde in dieser Periode (mal PREC)
    }
    mapping(uint256 => Period) public periods;
    uint256 public current;                 // Nummer der laufenden Periode
    uint256 public seenEpochs;              // so viele Emissions-Wochen sind abgeschlossen
    uint256 public stakeSeconds;            // Summe Einsatz mal Sekunden in der laufenden Periode bis lastStakeUpdate
    uint256 public lastStakeUpdate;

    // ---- pro Nutzer
    mapping(address => uint256) public userPeriod;       // Periode der letzten Aktion
    mapping(address => uint256) public userLastTime;     // Zeit der letzten Aktion
    mapping(address => uint256) public userStakeSeconds; // eigener Einsatz mal Sekunden in userPeriod bis userLastTime
    mapping(address => uint256) public rewards;          // fest zugeteilt, noch nicht abgeholt

    uint256 public reserved;                // alle BCUS im Contract, die Belohnung sind (nicht Einsatz)
    uint256 public sentToMining;            // Summe, die wegen Anteils-Regel/Obergrenze ans Mining ging
    uint256 public burned;                  // Summe, die verbrannt wurde (nur ohne Mining-Contract)

    event Bound(address emission, address token);
    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 amount);
    event PeriodClosed(uint256 indexed period, uint256 end, uint256 stakeSeconds, uint256 toStakers, uint256 rest);
    event ToMining(uint256 amount);
    event Burned(uint256 amount);

    error AlreadyBound();
    error NotBound();
    error WrongRecipient();
    error TooLate();
    error ZeroAmount();
    error InsufficientStake();

    constructor() {
        deployer = msg.sender;
    }

    function bind(address emission_) external {
        if (msg.sender != deployer || address(emission) != address(0)) revert AlreadyBound();
        IEmission e = IEmission(emission_);
        if (e.recipient() != address(this)) revert WrongRecipient();
        // Woche 0 muss noch laufen, sonst fehlte der Einsatz für bereits abgelaufene Wochen.
        if (e.completedEpochs() != 0) revert TooLate();
        emission = e;
        token = e.token();
        mining = e.miner();
        founderLock = e.initialHolder();
        epochStart = e.start();
        epochLength = e.EPOCH();
        periods[0].start = epochStart;
        lastStakeUpdate = block.timestamp;
        emit Bound(emission_, address(token));
    }

    // ------------------------------------------------------------------ Ansichten

    /// @notice Frei umlaufende Coins: alles Ausgegebene ohne FounderLock, Mining-Vorrat,
    ///         Verbrennungsadresse und die Belohnungen in diesem Contract (gestaktes BCUS zählt mit).
    function circulating() public view returns (uint256) {
        uint256 held = token.balanceOf(BURN) + token.balanceOf(founderLock) + token.balanceOf(mining)
            + (token.balanceOf(address(this)) - totalStaked);
        uint256 supply = token.totalSupply();
        return supply > held ? supply - held : 0;
    }

    /// @notice Anteil der jetzt gestakten Coins am Umlauf in Basispunkten (10000 = alles).
    function stakerShareBp() public view returns (uint256) {
        return _shareBp(totalStaked);
    }

    /// @notice Einsatz mal Sekunden in der laufenden Periode, bis jetzt.
    function stakeSecondsNow() public view returns (uint256) {
        return stakeSeconds + totalStaked * (block.timestamp - lastStakeUpdate);
    }

    /// @notice Anteil, mit dem die laufende Periode jetzt abgerechnet würde.
    function nextShareBp() public view returns (uint256) {
        uint256 elapsed = block.timestamp - periods[current].start;
        if (elapsed == 0) return 0;
        return _shareBp(stakeSecondsNow() / elapsed);
    }

    /// @notice Obergrenze für die Staker in der laufenden Periode, bis jetzt.
    function nextCap() public view returns (uint256) {
        return stakeSecondsNow() * maxWeeklyBp / (10_000 * epochLength);
    }

    /// @notice Fest zugeteilte, noch nicht abgeholte Belohnung (aus bereits abgeschlossenen Wochen).
    ///         Der Anteil an der laufenden Woche steht erst nach ihrem Ende fest.
    function earned(address user) public view returns (uint256) {
        uint256 p = userPeriod[user];
        if (p >= current) return rewards[user];
        return rewards[user] + _credit(user, p);
    }

    /// @notice Eigener Einsatz mal Sekunden in der laufenden Woche (Grundlage für den nächsten Anteil).
    function userStakeSecondsNow(address user) external view returns (uint256) {
        uint256 s = stakedOf[user];
        if (userPeriod[user] < current) return s * (block.timestamp - periods[current].start);
        return userStakeSeconds[user] + s * (block.timestamp - userLastTime[user]);
    }

    function _shareBp(uint256 staked) internal view returns (uint256) {
        uint256 c = circulating();
        if (staked == 0 || c == 0) return 0;
        if (staked >= c) return 10_000;
        return staked * 10_000 / c;
    }

    /// Anspruch eines Nutzers aus der abgeschlossenen Periode p und allen folgenden abgeschlossenen
    /// Perioden bis `current` (sein Einsatz war seit userLastTime unverändert).
    function _credit(address user, uint256 p) internal view returns (uint256) {
        uint256 s = stakedOf[user];
        Period storage next = periods[p + 1];
        uint256 inP = userStakeSeconds[user] + s * (next.start - userLastTime[user]);
        return inP * periods[p].rate / PREC + s * (periods[current].index - next.index) / PREC;
    }

    // ------------------------------------------------------------------ Aktionen

    function stake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        _sync(msg.sender);
        totalStaked += amount;
        stakedOf[msg.sender] += amount;
        token.safeTransferFrom(msg.sender, address(this), amount);
        emit Staked(msg.sender, amount);
    }

    function withdraw(uint256 amount) public nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (amount > stakedOf[msg.sender]) revert InsufficientStake();
        _sync(msg.sender);
        totalStaked -= amount;
        stakedOf[msg.sender] -= amount;
        token.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    function claim() public nonReentrant {
        _sync(msg.sender);
        uint256 r = rewards[msg.sender];
        if (r > 0) {
            rewards[msg.sender] = 0;
            reserved -= r;
            token.safeTransfer(msg.sender, r);
            emit RewardPaid(msg.sender, r);
        }
    }

    function exit() external {
        if (stakedOf[msg.sender] > 0) withdraw(stakedOf[msg.sender]);
        claim();
    }

    /// @notice Holt fällige neue BCUS beim Emissions-Contract ab und schließt abgelaufene Wochen ab.
    ///         Darf jeder aufrufen; passiert auch bei jedem Stake, Abheben und Abholen. Wann das
    ///         passiert, ändert an den Beträgen nichts.
    function pull() external nonReentrant {
        _sync(address(0));
    }

    // ------------------------------------------------------------------ intern

    function _sync(address user) internal {
        if (address(emission) == address(0)) revert NotBound();
        emission.mint();
        uint256 settled = emission.settledEpochs();
        if (settled > seenEpochs) _close(settled);
        // Einsatz mal Sekunden der laufenden Periode bis jetzt nachführen (vor jeder Änderung am Einsatz).
        stakeSeconds += totalStaked * (block.timestamp - lastStakeUpdate);
        lastStakeUpdate = block.timestamp;
        if (user != address(0)) _updateUser(user);
    }

    /// Schließt die laufende Periode an der Emissions-Grenze `settled` ab und verteilt ihren Topf.
    function _close(uint256 settled) internal {
        uint256 end = epochStart + settled * epochLength;
        // Seit lastStakeUpdate (vor der Grenze) war der Einsatz unverändert.
        uint256 ss = stakeSeconds + totalStaked * (end - lastStakeUpdate);
        Period storage p = periods[current];
        uint256 len = end - p.start;

        uint256 fresh = token.balanceOf(address(this)) - totalStaked - reserved;
        uint256 part;
        if (ss > 0 && fresh > 0) {
            // Anteil exakt (durchschnittlicher Einsatz / Umlauf), ohne Abrunden auf Basispunkte;
            // sonst verlören kleine Staker bis zu einem ganzen Basispunkt (KI-Prüfung Runde 2, F-03).
            uint256 avg = ss / len;
            uint256 c = circulating();
            part = avg >= c ? fresh : fresh * avg / c;
            uint256 cap = ss * maxWeeklyBp / (10_000 * epochLength);
            if (part > cap) part = cap;
        }
        uint256 rate = ss > 0 ? part * PREC / ss : 0;
        p.rate = rate;
        Period storage n = periods[current + 1];
        n.start = end;
        n.index = p.index + rate * len;
        current += 1;
        seenEpochs = settled;
        stakeSeconds = 0;
        lastStakeUpdate = end;
        reserved += part;

        uint256 rest = fresh - part;
        emit PeriodClosed(current - 1, end, ss, part, rest);
        if (rest > 0) {
            if (mining == address(0)) {
                burned += rest;
                token.safeTransfer(BURN, rest);
                emit Burned(rest);
            } else {
                sentToMining += rest;
                token.safeTransfer(mining, rest);
                emit ToMining(rest);
            }
        }
    }

    function _updateUser(address user) internal {
        uint256 p = userPeriod[user];
        uint256 s = stakedOf[user];
        if (p < current) {
            uint256 c = _credit(user, p);
            if (c > 0) rewards[user] += c;
            userPeriod[user] = current;
            userStakeSeconds[user] = s * (block.timestamp - periods[current].start);
        } else {
            userStakeSeconds[user] += s * (block.timestamp - userLastTime[user]);
        }
        userLastTime[user] = block.timestamp;
    }
}
