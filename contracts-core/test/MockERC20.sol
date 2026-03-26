// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockERC20
 * @notice Simple mock ERC20 token for testing purposes
 */
contract MockERC20 is ERC20 {
    constructor(
        string memory name_,
        string memory symbol_,
        uint256 initialSupply,
        address recipient
    ) ERC20(name_, symbol_) {
        _mint(recipient, initialSupply);
    }
}
