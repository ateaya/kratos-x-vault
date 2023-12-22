// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

import "./interfaces/IKratosXDeposit.sol";

/**
 * @author  Miguel Tadeu,PRC
 * @title   Kratos-X Vault Smart Contract
 */
contract KratosXVault is Pausable, AccessControl
{
    using SafeERC20 for IERC20;

    error DepositNotFound(uint256 id);
    error NotDepositOwner();
    error NotEnoughSlotsAvailable();
    error NotEnoughAllowance();
    error NotEnoughBalance();
    error NotEnoughFundsToWithdraw();

    event DepositRequested(address owner, uint256 amount);
    event DepositApproved(address owner, uint256 id);
    event DepositsApproved(address owner);
    event DepositRejected(address depositor);
    event WithdrawalRequested(uint256 id, uint256 estimatedAmount);
    event MultipleWithdrawalsRequested(uint256[] ids, uint256 estimatedAmount);
    event WithdrawalExecuted(uint256 id, uint256 calculatedAmount);
    event MultipleWithdrawalsExecuted(uint256[] id);

    bytes32 private constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 private constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    IKratosXDeposit public   depositNFT;                    // the deposit certificates NFT contract
    IERC20  public immutable underlyingToken;               // the underlying token contract

    uint8   public immutable totalSlots = 100;              // the total number deposit slots
    uint8   public immutable earlyAdopterBonusSlots = 3;    // the amount of slots that will earn the early adopter bonus
    uint256 public immutable slotUSDValue = 5000;           // the value of each deposit slot in USD

    /**
     * @notice  Constructor
     * @param   nft         Address of NFT contract for deposit certificates
     * @param   token       Address of underlying token of the deposits
     * @param   admin       Initial admin (owner)
     * @param   operator    Initial operator (minter/burner)
     */
    constructor(address nft, address token, address admin, address operator) Pausable() {
        depositNFT = nft;
        underlyingToken = IERC20(token);
    
        _grantRole(ADMIN_ROLE, admin);
        _grantRole(OPERATOR_ROLE, operator);

        _setRoleAdmin(ADMIN_ROLE, ADMIN_ROLE);
        _setRoleAdmin(OPERATOR_ROLE, ADMIN_ROLE);
    }

    ///////////////////////////////////////////////////////
    //  External
    ///////////////////////////////////////////////////////

    /**
     * @notice  Retrieve the available deposit slots.
     * @dev     Returns the available deposit slots.
     */
    function availableSlots() public view returns(uint256) {
        return totalSlots - depositNFT.totalSupply();
    }

    /**
     * @notice  Retrieve the used deposit slots.
     * @dev     Returns a list with the used deposit slots.
     */
    function usedSlots() external view returns(uint256) {
        return depositNFT.totalSupply();
    }

    /**
     * @notice  Set a specific amount of early adotion deposits available.
     * @dev     Set a specific amount of early adotion deposits available.
     * @param   slots  The number os deposit slots to make available.
     */
    function setEarlyAdopterSlots(uint8 slots) external onlyRole(ADMIN_ROLE) whenNotPaused {
        earlyAdopterBonusSlots = slots;
    }

    /**
     * @notice  Allows the user to request a deposit. This is because we require
     * user information in order to create a writen contract for each deposit.
     * @dev     After the user called ERC20.approve(...), then should call
     * this function to start the deposit request process.
     * @param   depositor  The depositor wallet address on the external token.
     * @param   lockPeriod  The predicted locking period.
     */
    function requestDeposit(address depositor, uint256 amount) external whenNotPaused {
        if (deposits.length >= totalSlots) revert NotEnoughSlotsAvailable();
        if (underlyingToken.allowance(depositor, address(this)) < slotUSDValue) revert NotEnoughAllowance();
        if (underlyingToken.balanceOf(depositor) < slotUSDValue) revert NotEnoughBalance();

        uint16 id = _createDepositId();

        deposits.push(Deposit(id, depositor, uint32(block.timestamp), lockPeriod, _hasEarlyAdoptionBonus(), false));

        // make the value transfer from the depositer account
        underlyingToken.safeTransferFrom(depositor, owner(), slotUSDValue);

        emit DepositRequested(depositor, amount);
    }

    /**
     * @notice  Allows the back-end to approve a deposit. This is because we require
     * user information in order to create a writen contract for each deposit. The deposit will be locked
     * for the specified locking period but the user may withdraw at any time before that.
     * @dev     After the user called ERC20.approve(...), the backend should detect that and call
     * this function if the user already inserted all the necessary information.
     * @param   depositor  The depositor wallet address on the external token.
     * @param   lockPeriod  The predicted locking period.
     */
    function approveDeposit(address depositor, LockPeriod lockPeriod) external onlyOwner whenNotPaused {
        if (deposits.length >= totalSlots) revert NotEnoughSlotsAvailable();
        if (underlyingToken.allowance(depositor, address(this)) < slotUSDValue) revert NotEnoughAllowance();
        if (underlyingToken.balanceOf(depositor) < slotUSDValue) revert NotEnoughBalance();

        uint16 id = _createDepositId();

        deposits.push(Deposit(id, depositor, uint32(block.timestamp), lockPeriod, _hasEarlyAdoptionBonus(), false));

        // make the value transfer from the depositer account
        underlyingToken.safeTransferFrom(depositor, owner(), slotUSDValue);

        emit DepositApproved(depositor, id);
    }

    /**
     * @notice  Approve deposits limited by the amount set by the allowance.
     * @dev     This method will attempt to make deposits limited by the available slots
     * and the allowance set.
     * @param   depositor  The address of the wallet the is requesting the deposit.
     * @param   lockPeriod  The selected locking period.
     */
    function approveDeposits(address depositor, LockPeriod lockPeriod) external onlyOwner whenNotPaused {
        uint256 allowance = underlyingToken.allowance(depositor, address(this));
        uint256 requestedSlots = uint256(allowance / slotUSDValue);
        if (requestedSlots == 0) revert NotEnoughAllowance();
        if (requestedSlots > getAvailableSlotCount()) revert NotEnoughSlotsAvailable();

        for(uint256 index; index < requestedSlots; ++index) {
            uint16 id = _createDepositId();

            deposits.push(Deposit(id, depositor, uint32(block.timestamp), lockPeriod, _hasEarlyAdoptionBonus(), false));
        }

        underlyingToken.safeTransferFrom(depositor, owner(), requestedSlots * slotUSDValue);

        emit DepositsApproved(depositor);
    }

    /**
     * @notice  After the user approve an amount in the external currency, the backend may reject the deposit
     * if the user didn't complete the information required to generate the writen contract. This is the function
     * that should be called in this situation.
     * @dev     Call this function by the backend when the deposit was not accepted.
     * @param   depositor  The depositor wallet address on the external token.
     */
    function rejectDeposit(address depositor) external onlyOwner {      // TODO: remove events for frontend
        emit DepositRejected(depositor);
    }

    /**
     * @notice  The normal case is that the deposit will be automatically resolved when the locking period
     * reaches the end. Dispite that, the user can, at any time, request to withdraw the funds, keeping in
     * mind that, the yiled will be calculated for the amount of time of the deposit and with the corresponding
     * rate.
     * @dev     The user may call this function to request a withdraw before the stipulated locking period.
     * @param   id  The id of the deposit to withdraw.
     */
    function requestWithdrawal(uint256 id) public whenNotPaused {
        Deposit memory deposit = _getDepositById(id);

        if (deposit.owner != _msgSender()) revert NotDepositOwner();

        // account for 7 days of withdrawal time
        uint256 dayCount = _timestampInDays(block.timestamp + 7 days - deposit.approveTimestamp);
        uint256 estimatedYield = calculateYield(dayCount, deposit.hasEarlyAdoptBonus, deposit.hasExtendPeriodBonus);

        emit WithdrawalRequested(id, slotUSDValue + estimatedYield);
    }

    /**
     * @notice  Request withdrawals for a list of ids.
     * @dev     Calls the requestWidthdrawal(...) for each id in the list.
     * @param   ids  The list of ids to withdraw.
     */
    function requestWithdrawals(uint256[] calldata ids) external whenNotPaused {
        for(uint256 index; index < ids.length; ++index) {
            requestWithdrawal(ids[index]);
        }
    }

    /**
     * @notice  This function may be called under 2 situations. The first is, called by the backend, when the locking
     * time reaches the end. The second situation is, when the user requests to withdraw before the locking time, the
     * backend will call this function after 7 days.
     * @dev     Called by the backend to liquidate the deposit.
     * @param   id  The id of the deposit to liquidate.
     */
    function executeWithdrawal(uint256 id) public onlyOwner whenNotPaused {
        Deposit[] memory depositsInMemory = deposits;
        uint256 depositIndex = _findDeposit(depositsInMemory, id);
        Deposit memory deposit = depositsInMemory[depositIndex];

        uint256 calculatedValue = slotUSDValue + calculateYield(_timestampInDays(block.timestamp - deposit.approveTimestamp),
            deposit.hasEarlyAdoptBonus,
            deposit.hasExtendPeriodBonus);

        deposits[depositIndex] = depositsInMemory[depositsInMemory.length - 1];
        deposits.pop();

        underlyingToken.safeTransferFrom(owner(), deposit.owner, calculatedValue);

        emit WithdrawalExecuted(id, calculatedValue);
    }

    /**
     * @notice  Execute several withdrawals in the same call.
     * @dev     Calls executeWithdrawal(...) for each id passed in the list.
     * @param   ids  The list of ids to widthdraw.
     */
    function executeWithdrawals(uint256[] calldata ids) external onlyOwner whenNotPaused {
        for(uint256 index; index < ids.length; ++index) {
            executeWithdrawal(ids[index]);
        }
    }

    /**
     * @notice  Extend the locking period.
     * @dev     Extend the locking period.
     * @param   id  The id of the deposit slot.
     * @param   lockPeriod  The locking period (1 => 1 year, 2 => 2 years, 3 => 3 years, 4 => 4 years, 5 => 5 years)
     */
    function extendLockPeriod(uint256 id, LockPeriod lockPeriod) external whenNotPaused {
        if (lockPeriod <= LockPeriod.SixMonths) revert InvalidLockPeriod();

        Deposit[] memory depositsInMemory = deposits;
        uint256 depositIndex = _findDeposit(depositsInMemory, id);
        Deposit memory deposit = depositsInMemory[depositIndex];

        if (lockPeriod < deposit.lockPeriod) revert InvalidLockPeriod();

        if(extendLockPeriodBonusLimit >= block.timestamp && deposit.lockPeriod == LockPeriod.SixMonths) {
            deposit.hasExtendPeriodBonus = true;
        }

        deposit.lockPeriod = lockPeriod;

        deposits[depositIndex] = deposit;
    }
    ///////////////////////////////////////////////////////
    //  Public
    ///////////////////////////////////////////////////////
    /**
     * @notice  This function pauses the contract in an emergency situation. It will simply not allow new deposits.
     * @dev     Call this function to pause new deposits.
     */
    function pause() public virtual onlyOwner {
        _pause();
    }

    /**
     * @notice  This function will resume the normal functionality of the contract.
     * @dev     Call this function to unpause the contract.
     */
    function unpause() public virtual onlyOwner {
        _unpause();
    }

    /**
     * @notice  Calculate the yield for a value deposited in time.
     * @dev     Call this function to estimate or calculate the yield for a deposit.
     * @param   dayCount  The numberber of days after the deposit approval.
     * @param   hasEarlyAdoptBonus  If the deposit benefits from the early adoption bonus.
     * @param   hasExtendBonus  If the deposit benefits from the time extension bonus.
     */
    function calculateYield(uint256 dayCount, bool hasEarlyAdoptBonus, bool hasExtendBonus)
        public pure returns(uint256) {
        uint256 ratePercent;

        if (dayCount <= LockPeriod6M) {
            return 0;                   // no bonus here
        } else if (dayCount <= LockPeriod1Y) {    //  < 1 year
            ratePercent = 5;
        } else if (dayCount <= LockPeriod2Y) {    //  1 years < dayCount > 2 years
            ratePercent = 5;
        } else if (dayCount <= LockPeriod3Y) {   //  2 years < dayCount > 3 years
            ratePercent = 6;
        } else if (dayCount <= LockPeriod4Y) {   //  3 years < dayCount > 4 years
            ratePercent = 7;
        } else if (dayCount <= LockPeriod5Y) {   //  4 years < dayCount > 5 years
            ratePercent = 8;
        } else {                        //  > 5 years
            dayCount = 1825;            //  cap the day count
            ratePercent = 9;
        }

        if (hasEarlyAdoptBonus) {
            ratePercent = _increment(ratePercent);
        }

        if (hasExtendBonus && dayCount >= LockPeriod1Y) {
            ratePercent = _increment(ratePercent);
        }

        return slotUSDValue * ratePercent * dayCount / (100 * 365);
    }

    ///////////////////////////////////////////////////////
    //  Internal
    ///////////////////////////////////////////////////////


    ///////////////////////////////////////////////////////
    //  Private
    ///////////////////////////////////////////////////////
    function _increment(uint256 value) private pure returns(uint256) {
        unchecked { ++value; }
        return value;
    }

    function _createDepositId() private returns(uint16) {
        unchecked { ++autoIncrementedId; }
        return autoIncrementedId;
    }

    function _hasEarlyAdoptionBonus() private returns(bool) {
        if (earlyAdopterBonusSlots > 0) {
            unchecked { --earlyAdopterBonusSlots; }
            return true;
        }
        return false;
    }

    function _timestampInDays(uint256 timestamp) private pure returns(uint256) {
        return timestamp / 1 days;
    }

    function _findDeposit(Deposit[] memory depositsInMemory, uint256 id) private pure returns(uint256) {
        for (uint256 index = 0; index < depositsInMemory.length; index = _increment(index)) {
            if (depositsInMemory[index].id == id) {
                return index;
            }
        }
        revert DepositNotFound(id);
    }

    function _getDepositById(uint256 id) private view returns(Deposit memory) {
        Deposit[] memory depositsInMemory = deposits;

        for (uint256 index = 0; index < depositsInMemory.length; index = _increment(index)) {
            if (depositsInMemory[index].id == id) {
                return depositsInMemory[index];
            }
        }
        revert DepositNotFound(id);
    }
}
