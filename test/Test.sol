// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// Kleine Testbasis ohne forge-std: Foundry-Cheatcodes plus die nötigen Vergleiche.
interface Vm {
    function warp(uint256) external;
    function prank(address) external;
    function startPrank(address) external;
    function stopPrank() external;
    function expectRevert() external;
    function expectRevert(bytes4) external;
    function expectRevert(bytes calldata) external;
    function assertEq(uint256, uint256) external pure;
    function assertEq(address, address) external pure;
    function assertEq(bytes32, bytes32) external pure;
    function assertEq(string calldata, string calldata) external pure;
    function assertLe(uint256, uint256) external pure;
    function assertTrue(bool) external pure;
    function assertFalse(bool) external pure;
    function addr(uint256) external pure returns (address);
    function sign(uint256, bytes32) external pure returns (uint8, bytes32, bytes32);
}

abstract contract Test {
    bool public IS_TEST = true;
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function assertEq(uint256 a, uint256 b) internal pure { vm.assertEq(a, b); }
    function assertEq(address a, address b) internal pure { vm.assertEq(a, b); }
    function assertEq(bytes32 a, bytes32 b) internal pure { vm.assertEq(a, b); }
    function assertEq(string memory a, string memory b) internal pure { vm.assertEq(a, b); }
    function assertLe(uint256 a, uint256 b) internal pure { vm.assertLe(a, b); }
    function assertTrue(bool a) internal pure { vm.assertTrue(a); }
    function assertFalse(bool a) internal pure { vm.assertFalse(a); }
}
