// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @author  PRC
 * @title   Ateaya KYC Account Whitelist Smart Contract
 */
interface IAteayaWhitelist {
    /**
     * @notice  This function checks an entry in the whitelist.
     * @dev     Call this function to check an entry hash.
     * @param   hash The address hash to check -> hash = uint256(keccak256(abi.encodePacked(address)))
     * @return  The whitelist state for the address hash.
     */
    function isWhitelisted(uint256 hash) external returns (bool);

}
