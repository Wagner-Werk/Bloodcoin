// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Capped} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Capped.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @title Bloodcoin (BCUS)
/// @notice ERC-20 mit harter Obergrenze von 21 Mio. Neue Coins kann ausschließlich der
///         Emissions-Contract erzeugen, der diesen Token selbst deployt. Es gibt keinen
///         Besitzer, keine Pause, keine Sperrliste und keine Möglichkeit, das zu ändern.
contract BloodcoinToken is ERC20Capped, ERC20Permit {
    uint256 public constant MAX_SUPPLY = 21_000_000e18;

    address public immutable minter;

    error OnlyMinter();

    constructor(address minter_, address initialHolder, uint256 initialMint)
        ERC20("Bloodcoin", "BCUS")
        ERC20Capped(MAX_SUPPLY)
        ERC20Permit("Bloodcoin")
    {
        minter = minter_;
        if (initialMint > 0) _mint(initialHolder, initialMint);
    }

    function mint(address to, uint256 amount) external {
        if (msg.sender != minter) revert OnlyMinter();
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Capped) {
        super._update(from, to, value);
    }
}
