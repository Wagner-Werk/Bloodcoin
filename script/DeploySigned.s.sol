// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MortalityEmission} from "../src/MortalityEmission.sol";
import {SignedMortalityOracle} from "../src/SignedMortalityOracle.sol";
import {BcusStaking} from "../src/BcusStaking.sol";

interface VmScript {
    function envAddress(string calldata) external view returns (address);
    function envUint(string calldata) external view returns (uint256);
    function startBroadcast() external;
    function stopBroadcast() external;
}

/// Wie Deploy.s.sol, aber mit dem eigenen signierten Melder statt Chainlink CRE (Plan B).
/// ORACLE_SIGNER ist die Adresse des Server-Schlüssels (oracle/signed/README.md).
contract DeploySigned {
    VmScript internal constant vm = VmScript(address(uint160(uint256(keccak256("hevm cheat code")))));
    bool public IS_SCRIPT = true;

    function run() external returns (address oracle, address staking, address emission, address token) {
        address signer = vm.envAddress("ORACLE_SIGNER");
        address holder = vm.envAddress("INITIAL_HOLDER");
        uint256 initialMint = vm.envUint("INITIAL_MINT_BCUS") * 1e18;

        vm.startBroadcast();
        SignedMortalityOracle o = new SignedMortalityOracle(signer);
        BcusStaking st = new BcusStaking();
        MortalityEmission e = new MortalityEmission(address(o), address(st), holder, initialMint);
        o.bind(address(e));
        st.bind(address(e));
        vm.stopBroadcast();
        return (address(o), address(st), address(e), address(e.token()));
    }
}
