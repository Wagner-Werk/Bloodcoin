// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IMortalityEmission {
    function report(uint256 weekEnding, uint256 recentDeaths, uint256 baselineDeaths) external;
}

/// @dev Schnittstelle, die der Chainlink-Forwarder aufruft (Chainlink Runtime Environment, CRE).
interface IReceiver {
    function onReport(bytes calldata metadata, bytes calldata report) external;
}

interface IERC165 {
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}

/// @title CDC-Sterbezahlen über Chainlink CRE
/// @notice Ein CRE-Workflow (oracle/cre-workflow/) läuft auf einem Netz unabhängiger Chainlink-Knoten,
///         holt die Zahlen bei data.cdc.gov, die Knoten einigen sich auf ein Ergebnis und signieren es.
///         Der Chainlink-Forwarder prüft die Signaturen und ruft dann `onReport` auf.
///
///         Angenommen wird nur, was über `forwarder` kommt. Ist `workflowId` festgelegt, nur von genau
///         diesem Workflow; die ID ist ein Hash über Code und Konfiguration, eine geänderte Version
///         wird also abgelehnt. Festlegen kann sie nur der Deployer, genau einmal (`pinWorkflow`).
///         Ohne festgelegte ID nimmt der Contract jeden Bericht des Forwarders an: nur fürs Testnetz
///         mit dem Simulations-Forwarder, nie fürs Mainnet.
contract CreMortalityOracle is IReceiver, IERC165 {
    address public immutable forwarder;
    address private immutable deployer;

    IMortalityEmission public emission;
    bytes32 public workflowId;

    event Reported(uint256 weekEnding, uint256 recentDeaths, uint256 baselineDeaths);
    event Rejected(bytes reason);

    error AlreadyBound();
    error NotBound();
    error OnlyForwarder();
    error WrongWorkflow();
    error BadReport();

    constructor(address forwarder_) {
        forwarder = forwarder_;
        deployer = msg.sender;
    }

    function bind(address emission_) external {
        if (msg.sender != deployer || address(emission) != address(0)) revert AlreadyBound();
        emission = IMortalityEmission(emission_);
    }

    /// @notice Legt den einzigen erlaubten Workflow fest. Geht erst nach dem Workflow-Deployment,
    ///         weil die ID von der Konfiguration abhängt und die die Adresse dieses Contracts enthält.
    function pinWorkflow(bytes32 id) external {
        if (msg.sender != deployer || workflowId != bytes32(0) || id == bytes32(0)) revert AlreadyBound();
        workflowId = id;
    }

    /// @param metadata Workflow-ID (32 Bytes), Name (10 Bytes), Besitzer (20 Bytes)
    /// @param report abi.encode(uint256 weekEnding, uint256 recentDeaths, uint256 baselineDeaths), weekEnding in
    ///        Sekunden; recentDeaths = Tote der 4 Wochen bis weekEnding, baselineDeaths = Durchschnitt derselben
    ///        4 Wochen in den 3 Vorjahren (siehe MortalityEmission)
    /// @dev Unplausible Zahlen werden nicht zurückgewiesen, sondern als `Rejected` protokolliert,
    ///      damit ein fehlerhafter Bericht nichts blockiert. Nur fremde Absender führen zum Abbruch.
    function onReport(bytes calldata metadata, bytes calldata report) external {
        if (msg.sender != forwarder) revert OnlyForwarder();
        if (address(emission) == address(0)) revert NotBound();
        bytes32 pinned = workflowId;
        if (pinned != bytes32(0) && (metadata.length < 32 || bytes32(metadata[:32]) != pinned)) revert WrongWorkflow();
        if (report.length != 96) revert BadReport();

        (uint256 weekEnding, uint256 recent, uint256 baseline) = abi.decode(report, (uint256, uint256, uint256));
        try emission.report(weekEnding, recent, baseline) {
            emit Reported(weekEnding, recent, baseline);
        } catch (bytes memory reason) {
            emit Rejected(reason);
        }
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IReceiver).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}
