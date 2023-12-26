// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

import "ateaya-whitelist/IAteayaWhitelist.sol";
import "kratos-x-deposit/IKratosXDeposit.sol";


/**
 * @author  Miguel Tadeu,PRC
 * @title   Kratos-X Vault Smart Contract
 */
contract KratosXVault is Pausable, AccessControl
{
    using SafeERC20 for IERC20Metadata;

    error InvalidAddress();
    error DepositorNotWhitelisted(address depositor);
    error NotDepositOwner(address account);
    error SlotsNotSupplied();
    error NotEnoughSlotsAvailable();
    error InvalidRefundValue(uint256 usdValue);

    event DepositCreated(uint256 indexed id, address indexed depositor, DepositData data);
    event DepositRefunded(uint256 indexed id, address indexed depositor, uint256 usdRefund, DepositData data);
    event WithdrawalRequested(uint256 indexed id, address indexed depositor, DepositData data, uint256 usdValueEstimated);
    event WithdrawalExecuted(uint256 indexed id, address indexed depositor, DepositData data, uint256 usdValue);

    bytes32 private constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 private constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    address          private multisig;                      // the address of the multisig wallet that holds funds

    IAteayaWhitelist public  whitelist;                     // the KYC whitelist
    IKratosXDeposit  public  depositNFT;                    // the deposit certificates NFT contract
    uint256          public  earlyAdopterBonusSlots = 3;    // the amount of slots that will earn the early adopter bonus

    IERC20Metadata   public  immutable underlyingToken;     // the underlying token contract
    uint8   public immutable underlyingDecimals;            // the underlying token decimals

    uint256 public immutable totalSlots = 100;              // the total number deposit slots
    uint256 public immutable slotUSDValue = 5000;           // the value of each deposit slot in USD

    /**
     * @notice  Constructor
     * @param   wallet      Address of multi-signature wallet that holds funds
     * @param   wl          Address of Ateaya KYC Whitelist contract
     * @param   nft         Address of NFT contract for deposit certificates
     * @param   token       Address of underlying token of the deposits
     * @param   admin       Initial admin (owner)
     * @param   operator    Initial operator (minter/burner)
     */
    constructor(address wallet, address wl, address nft, address token, address admin, address operator) Pausable() {
        multisig = wallet;
        whitelist = IAteayaWhitelist(wl);
        depositNFT = IKratosXDeposit(nft);

        underlyingToken = IERC20Metadata(token);
        underlyingDecimals = underlyingToken.decimals();
    
        _grantRole(ADMIN_ROLE, admin);
        _grantRole(OPERATOR_ROLE, operator);

        _setRoleAdmin(ADMIN_ROLE, ADMIN_ROLE);
        _setRoleAdmin(OPERATOR_ROLE, ADMIN_ROLE);
    }

    ///////////////////////////////////////////////////////
    //  External
    ///////////////////////////////////////////////////////

    /**
     * @notice  Set a specific amount of early adotion deposits available.
     * @dev     Set a specific amount of early adotion deposits available.
     * @param   wallet      Address of multi-signature wallet that holds funds
     */
    function setMultisig(address wallet) external onlyRole(ADMIN_ROLE) whenNotPaused {
        if (wallet == address(0)) revert InvalidAddress();
        multisig = wallet;
    }

    /**
     * @notice  Set a specific amount of early adotion deposits available.
     * @dev     Set a specific amount of early adotion deposits available.
     * @param   wl          Address of Ateaya KYC Whitelist contract
     */
    function setWhitelist(address wl) external onlyRole(ADMIN_ROLE) whenNotPaused {
        if (wl == address(0)) revert InvalidAddress();
        whitelist = IAteayaWhitelist(wl);
    }

    /**
     * @notice  Set a specific amount of early adotion deposits available.
     * @dev     Set a specific amount of early adotion deposits available.
     * @param   nft         Address of NFT contract for deposit certificates
     */
    function setDepositNFT(address nft) external onlyRole(ADMIN_ROLE) whenNotPaused {
        if (nft == address(0)) revert InvalidAddress();
        depositNFT = IKratosXDeposit(nft);
    }

    /**
     * @notice  Set a specific amount of early adotion deposits available.
     * @dev     Set a specific amount of early adotion deposits available.
     * @param   slots  The number os deposit slots to make available.
     */
    function setEarlyAdopterBonusSlots(uint256 slots) external onlyRole(ADMIN_ROLE) whenNotPaused {
        earlyAdopterBonusSlots = slots;
    }

    /**
     * @notice  Allows the user to make a deposit. The user is required be whitelisted,
     * because we need user information to create a writen contract for each deposit.
     * @dev     After the user called ERC20.approve(...), then should call
     * this function to make a deposit.
     * @param   slots  The number of slots of the deposit (total amount = slots * slotUSDValue)
     */
    function deposit(uint256 slots) external whenNotPaused {
        if (slots == 0) revert SlotsNotSupplied();

        address depositor = _msgSender();
        uint256 hash = uint256(keccak256(abi.encodePacked(depositor)));
        if (!whitelist.isWhitelisted(hash)) revert DepositorNotWhitelisted(depositor);

        uint256 amount = slots * slotUSDValue * 10**uint256(underlyingDecimals);

        // make the value transfer from the depositer account to multisig
        underlyingToken.safeTransferFrom(depositor, multisig, amount);

        if (slots > availableSlots()) revert NotEnoughSlotsAvailable();

        for (uint256 i; i < slots; ) {
            DepositData memory data = DepositData(slotUSDValue, uint32(block.timestamp), _hasEarlyAdopterBonus());
            uint256 id = depositNFT.mint(depositor, data);

            emit DepositCreated(id, depositor, data);

            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice  In case a deposit doesn't pass the human verification, the backend may refund the deposit,
     * for example if the user didn't complete the information required to generate the writen contract.
     * @dev     Call this function by the backend when the deposit was not accepted. Requires allowance 
     * from multisig wallet.
     * @param   id  The deposit id.
     * @param   refundUSDValue  The refund value in USD (0 to refund nominal value).
     */
    function refundDeposit(uint256 id, uint256 refundUSDValue) public onlyRole(OPERATOR_ROLE) whenNotPaused {
        if (refundUSDValue > slotUSDValue) revert InvalidRefundValue(refundUSDValue);

        uint256 amount = refundUSDValue > 0 ? refundUSDValue : slotUSDValue;

        // transfer from multisig to refund deposit
        address depositor = depositNFT.ownerOf(id);
        underlyingToken.safeTransferFrom(multisig, depositor, amount * 10**uint256(underlyingDecimals));

        DepositData memory data = depositNFT.depositData(id);

        depositNFT.burn(id);

        emit DepositRefunded(id, depositor, amount, data);
    }

    /**
     * @notice  In case a deposit doesn't pass the human verification, the backend may refund the deposit,
     * for example if the user didn't complete the information required to generate the writen contract.
     * @dev     Call this function by the backend when the deposit was not accepted.
     * @param   ids  The deposit ids to be reverted.
     * @param   refundUSDValue  The refund value in USD (0 to refund nominal value).
     */
    function refundDeposits(uint256[] calldata ids, uint256 refundUSDValue) external {
        for (uint256 i; i < ids.length; ) {
            refundDeposit(ids[i], refundUSDValue);

            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice  The user can, at any time, request to withdraw the funds, and the yield will be calculated for
     * the duration of the deposit and the corresponding rate.
     * @dev     The user may call this function to request a withdraw before the stipulated locking period.
     * @param   id  The id of the deposit to withdraw.
     */
    function requestWithdrawal(uint256 id) public whenNotPaused {
        address depositor = depositNFT.ownerOf(id);
        if (depositor != _msgSender()) revert NotDepositOwner(_msgSender());

        DepositData memory data = depositNFT.depositData(id);

        // account for 7 days of withdrawal time
        uint256 dayCount = _timestampInDays(block.timestamp + 7 days - data.timestamp);
        uint256 estimatedYield = calculateYield(dayCount, data.hasBonus);

        emit WithdrawalRequested(id, depositor, data, slotUSDValue + estimatedYield);
    }

    /**
     * @notice  Request withdrawals for a list of ids.
     * @dev     Calls the requestWidthdrawal(...) for each id in the list.
     * @param   ids  The list of ids to withdraw.
     */
    function requestWithdrawals(uint256[] calldata ids) external {
        for(uint256 i; i < ids.length; ) {
            requestWithdrawal(ids[i]);

            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice  This function will be called by the backend, after 7 days of the user requested to withdraw.
     * @dev     Called by the backend to liquidate the deposit.
     * @param   id  The id of the deposit to liquidate.
     */
    function executeWithdrawal(uint256 id) public onlyRole(OPERATOR_ROLE) whenNotPaused {
        address depositor = depositNFT.ownerOf(id);
        if (depositor != _msgSender()) revert NotDepositOwner(_msgSender());

        DepositData memory data = depositNFT.depositData(id);

        depositNFT.burn(id);

        uint256 calculatedValue = slotUSDValue + calculateYield(_timestampInDays(block.timestamp - data.timestamp), data.hasBonus);
        underlyingToken.safeTransferFrom(multisig, depositor, calculatedValue * 10**uint256(underlyingDecimals));

        emit WithdrawalExecuted(id, depositor, data, calculatedValue);
    }

    /**
     * @notice  Execute several withdrawals in the same call.
     * @dev     Calls executeWithdrawal(...) for each id passed in the list.
     * @param   ids  The list of ids to widthdraw.
     */
    function executeWithdrawals(uint256[] calldata ids) external {
        for(uint256 i; i < ids.length; ) {
            executeWithdrawal(ids[i]);

            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice  Recover tokens sent to this contract by mistake
     * @dev  
     */
    function recover(address token, uint256 amount, address to) external onlyRole(ADMIN_ROLE) returns (bool success) {
        success = IERC20Metadata(token).transfer(to, amount);
    }

    /**
     * @notice  Retrieve the used deposit slots.
     * @dev     Returns a list with the used deposit slots.
     */
    function usedSlots() external view returns(uint256) {
        return depositNFT.totalSupply();
    }

    ///////////////////////////////////////////////////////
    //  Public
    ///////////////////////////////////////////////////////

    /**
     * @notice  Retrieve the available deposit slots.
     * @dev     Returns the available deposit slots.
     */
    function availableSlots() public view returns(uint256) {
        return totalSlots - depositNFT.totalSupply();
    }

    /**
     * @notice  This function pauses the contract in an emergency situation. It will simply not allow new deposits.
     * @dev     Call this function to pause new deposits.
     */
    function pause() public virtual onlyRole(ADMIN_ROLE) {
        _pause();
    }

    /**
     * @notice  This function will resume the normal functionality of the contract.
     * @dev     Call this function to unpause the contract.
     */
    function unpause() public virtual onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    /**
     * @notice  Calculate the yield for a value deposited in time.
     * @dev     Call this function to estimate or calculate the yield for a deposit.
     * @param   dayCount  The numberber of days after the deposit approval.
     * @param   hasEarlyAdopterBonus  If the deposit benefits from the early adoption bonus.
     */
    function calculateYield(uint256 dayCount, bool hasEarlyAdopterBonus) public pure returns(uint256) {
        uint256 ratePercent;

        if (dayCount <= 180) {           // <= 6 months
            return 0;   // no yield here
        } else if (dayCount <= 365) {    //  6 months < dayCount <= 1 year
            ratePercent = 5;
        } else if (dayCount <= 730) {    //  1 years < dayCount <= 2 years
            ratePercent = 5;
        } else if (dayCount <= 1095) {   //  2 years < dayCount <= 3 years
            ratePercent = 6;
        } else if (dayCount <= 1460) {   //  3 years < dayCount <= 4 years
            ratePercent = 7;
        } else if (dayCount <= 1825) {   //  4 years < dayCount <= 5 years
            ratePercent = 8;
        } else {                           //  > 5 years
            dayCount = 1825;             //  cap the day count
            ratePercent = 9;
        }

        if (hasEarlyAdopterBonus) {
            unchecked {
                ++ratePercent;
            }
        }

        return slotUSDValue * ratePercent * dayCount / (100 * 365);
    }

    ///////////////////////////////////////////////////////
    //  Internal
    ///////////////////////////////////////////////////////


    ///////////////////////////////////////////////////////
    //  Private
    ///////////////////////////////////////////////////////
    
    function _hasEarlyAdopterBonus() private returns(bool) {
        if (earlyAdopterBonusSlots > 0) {
            unchecked { --earlyAdopterBonusSlots; }
            return true;
        }
        return false;
    }

    function _timestampInDays(uint256 timestamp) private pure returns(uint256) {
        return timestamp / 1 days;
    }

}
