// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/**
 * @author  PRC
 * @title   Kratos-X Deposit Certificate NFT Smart Contract
 */
interface IKratosXDeposit is IERC721 {
    struct Deposit {
        uint256 nominal;        // nominal value of the deposit (based on token)
        uint32  timestamp;      // timestamp when the deposit was created
        bool    hasBonus;       // bonus flag for the vault accounting
    }

    /// The underlying token used for this contract
    function underlyingToken() external returns (IERC20);

    /// The deposit internal data
    function depositData(uint256 tokenId) external returns (Deposit memory);

    /**
     * @notice  This function mints a new deposit cerificate
     * @dev     Call this function to mint a new deposit certificate
     * @param   to      The address of the depositer (soul bound)
     * @param   uri     The uri of the deposit metadata (for UI)
     * @param   data    The deposit internal data
     */
    function mint(address to, string calldata uri, Deposit calldata data) external;

    /**
     * @notice  This function burns a deposit certificate
     * @dev     Call this function to burn a deposit certificate
     * @param   tokenId     The deposit certificate token id to burn
     */
    function burn(uint256 tokenId) external;

    /**
     * @dev See {IERC721Enumerable-tokenOfOwnerByIndex}.
     */
    function tokenOfOwnerByIndex(address owner, uint256 index) external view returns (uint256);

    /**
     * @dev See {IERC721Enumerable-totalSupply}.
     */
    function totalSupply() external view returns (uint256);

    /**
     * @dev See {IERC721Enumerable-tokenByIndex}.
     */
    function tokenByIndex(uint256 index) external view returns (uint256);

    function tokenURI(uint256 tokenId) external view returns (string memory);

    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}