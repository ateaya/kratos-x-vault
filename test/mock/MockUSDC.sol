// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("MockUSDC", "USDC") {
        _mint(msg.sender, 1000000000000000);
    }

    function decimals() public view virtual override returns (uint8) {
        return 6;
    }

}
