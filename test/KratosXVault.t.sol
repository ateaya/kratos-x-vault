// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import {Test, console2} from "forge-std/Test.sol";
import {AteayaWhitelist} from "ateaya-whitelist/AteayaWhitelist.sol";
import {KratosXDeposit, DepositData} from "kratos-x-deposit/KratosXDeposit.sol";
import {KratosXVault} from "../src/KratosXVault.sol";
import {MockUSDC} from "./mock/MockUSDC.sol";


contract KratosXVaultTest is Test {
    error InvalidAddress();
    error DepositorNotWhitelisted(address depositor);
    error NotDepositOwner(address account);
    error SlotsNotSupplied();
    error NotEnoughSlotsAvailable();
    error InvalidRefundValue(uint256 usdValue);

    error ERC20InsufficientAllowance(address spender, uint256 allowance, uint256 needed);       // from ERC20
    error ERC721NonexistentToken(uint256 tokenId);       // from ERC721

    AteayaWhitelist public whitelist;
    KratosXDeposit  public deposit;
    KratosXVault    public vault;

    MockUSDC public token;

    address public deployer;
    address public admin;
    address public operator;
    address public user1;
    address public user2;

    address public multisig;

    function setUp() public {
        string memory mnemonic = "test test test test test test test test test test test junk";
        uint256 privateKey = vm.deriveKey(mnemonic, 0);
        deployer = msg.sender;
        admin = vm.addr(privateKey);
        operator = vm.addr(privateKey + 1);
        user1 = vm.addr(privateKey + 2);
        user2 = vm.addr(privateKey + 3);

        multisig = vm.addr(privateKey + 10);

        whitelist = new AteayaWhitelist(admin, operator);
        token = new MockUSDC();
        deposit = new KratosXDeposit(address(token), admin, operator);
        vault = new KratosXVault(multisig, address(whitelist), address(deposit), address(token), admin, operator);
        vm.prank(admin);
        deposit.grantRole(keccak256("OPERATOR_ROLE"), address(vault));

        token.transfer(multisig, wad(10000000));
        token.transfer(user1, wad(1000000));
        token.transfer(user2, wad(100000));
    }

    function test_InitializedCorrectly() public {
        assertEq(address(vault.underlyingToken()), address(token), "invalid token");
        assertEq(vault.slotUSDValue(), 5000, "invalid slot usd value");
        
        assertTrue(whitelist.hasRole(keccak256("ADMIN_ROLE"), admin), "invalid whitelist admin");
        assertTrue(whitelist.hasRole(keccak256("OPERATOR_ROLE"), operator), "invalid whitelist operator");
        assertTrue(deposit.hasRole(keccak256("ADMIN_ROLE"), admin), "invalid deposit admin");
        assertTrue(deposit.hasRole(keccak256("OPERATOR_ROLE"), operator), "invalid deposit operator");
        assertTrue(deposit.hasRole(keccak256("OPERATOR_ROLE"), address(vault)), "invalid deposit vault operator");
        assertTrue(vault.hasRole(keccak256("ADMIN_ROLE"), admin), "invalid vault admin");
        assertTrue(vault.hasRole(keccak256("OPERATOR_ROLE"), operator), "invalid vault operator");

        assertEq(token.balanceOf(multisig), wad(10000000), "invalid multisig initial balance");
        assertEq(token.balanceOf(user1), wad(1000000), "invalid user1 initial balance");
        assertEq(token.balanceOf(user2), wad(100000), "invalid user2 initial balance");
    }

    function test_YieldCalculation(uint256 dayCount, bool hasBonus) public {
        uint256 yield = vault.calculateYield(dayCount, hasBonus);
        uint256 percent = 0;
        if (dayCount > 180) {
            if (dayCount <= 730) percent = 5;
            else if (dayCount <= 1095) percent = 6;
            else if (dayCount <= 1460) percent = 7;
            else if (dayCount <= 1825) percent = 8;
            else percent = 9;
            if (hasBonus) percent++;
        }
        uint256 validDays = dayCount > 1825 ? 1825 : dayCount;
        uint256 calc = vault.slotUSDValue() * percent * validDays / (100 * 365);
        assertEq(calc, yield, "not the same yield");
    }

    function test_Deposit_ERR_NoSlots() public {
        makeDeposit(user1, 0, true, 0, abi.encodePacked(SlotsNotSupplied.selector));        
    }

    function test_Deposit_ERR_NotWhitelisted() public {
        makeDeposit(user1, 1, false, 0, abi.encodeWithSelector(DepositorNotWhitelisted.selector, user1));
        makeDeposit(user1, 10, false, 0, abi.encodeWithSelector(DepositorNotWhitelisted.selector, user1));
        makeDeposit(user1, 100, false, 0, abi.encodeWithSelector(DepositorNotWhitelisted.selector, user1));
    }

    function test_Deposit_ERR_NotEnoughAllowance() public {
        makeDeposit(user1, 1, true, wad(vault.slotUSDValue()) - 1, abi.encodeWithSelector(ERC20InsufficientAllowance.selector, address(vault), wad(vault.slotUSDValue()) - 1, wad(vault.slotUSDValue())));
        makeDeposit(user1, 10, true, 10*wad(vault.slotUSDValue()) - 1, abi.encodeWithSelector(ERC20InsufficientAllowance.selector, address(vault), 10*wad(vault.slotUSDValue()) - 1, 10*wad(vault.slotUSDValue())));
        makeDeposit(user1, 100, true, 100*wad(vault.slotUSDValue()) - 1, abi.encodeWithSelector(ERC20InsufficientAllowance.selector, address(vault), 100*wad(vault.slotUSDValue()) - 1, 100*wad(vault.slotUSDValue())));
    }

    function test_Deposit_ERR_NotEnoughSlots() public {
        makeDeposit(user1, 101, true, 101*wad(vault.slotUSDValue()), abi.encodeWithSelector(NotEnoughSlotsAvailable.selector));
        makeDeposit(user1, 10, true, 10*wad(vault.slotUSDValue()), "");
        makeDeposit(user1, 100, true, 100*wad(vault.slotUSDValue()), abi.encodeWithSelector(NotEnoughSlotsAvailable.selector));
    }

    function test_Deposit_OK(uint8 slots) public {
        if (slots == 0) return;     // Already tested

        while (slots > vault.availableSlots()) slots /= 2;
        uint256 amount =  slots*wad(vault.slotUSDValue());
        makeDeposit(user1, slots, true, amount, "");
    }

    function test_RefundDeposit_ERR_InvalidAmount() public {
        makeDeposit(user1, 1, true, wad(vault.slotUSDValue()), "");
        uint256 amount = vault.slotUSDValue() + 1;
        refundDeposit(user1, 0, amount, wad(amount), abi.encodeWithSelector(InvalidRefundValue.selector, amount));
    }

    function test_RefundDeposit_ERR_NotEnoughAllowance() public {
        makeDeposit(user1, 1, true, wad(vault.slotUSDValue()), "");
        uint256 amount = vault.slotUSDValue();
        refundDeposit(user1, 0, amount, wad(amount - 1), abi.encodeWithSelector(ERC20InsufficientAllowance.selector, address(vault), wad(amount - 1), wad(amount)));
    }

    function test_RefundDeposit_ERR_NonExistant() public {
        uint256 amount = vault.slotUSDValue();
        refundDeposit(user2, 0, amount, wad(amount), abi.encodeWithSelector(ERC721NonexistentToken.selector, 0));
    }

    function test_RefundDeposit_OK(uint8 slots) public {
        if (slots == 0) return;

        while (slots > vault.availableSlots()) slots /= 2;
        uint256 amount =  slots*wad(vault.slotUSDValue());
        makeDeposit(user1, slots, true, amount, "");
        for (uint256 i = slots; i > 0; ) {
            unchecked {
                --i;
            }
            refundDeposit(user1, i, vault.slotUSDValue(), wad(vault.slotUSDValue()), "");
        }
    }

    function test_RequestWithdrawal_ERR_NonExistant() public {
        uint256 amount = vault.slotUSDValue();
        requestWithdrawal(user2, 0, abi.encodeWithSelector(ERC721NonexistentToken.selector, 0));
    }

   function test_RequestWithdrawal_OK(uint8 slots) public {
        if (slots == 0) return;

        while (slots > vault.availableSlots()) slots /= 2;
        uint256 amount =  slots*wad(vault.slotUSDValue());
        makeDeposit(user1, slots, true, amount, "");
        for (uint256 i = slots; i > 0; ) {
            unchecked {
                --i;
            }
            requestWithdrawal(user1, i, "");
        }
    }

    function test_ExecuteWithdrawal_ERR_NonExistant() public {
        uint256 amount = wad(vault.slotUSDValue());
        executeWithdrawal(user2, 0, amount, abi.encodeWithSelector(ERC721NonexistentToken.selector, 0));
    }

    function test_ExecuteWithdrawal_ERR_NotEnoughAllowance() public {
        makeDeposit(user1, 1, true, wad(vault.slotUSDValue()), "");
        uint256 amount = vault.slotUSDValue();
        executeWithdrawal(user1, 0, wad(amount - 1), abi.encodeWithSelector(ERC20InsufficientAllowance.selector, address(vault), wad(amount - 1), wad(amount)));
    }

   function test_ExecuteWithdrawal_OK(uint8 slots) public {
        if (slots == 0) return;

        while (slots > vault.availableSlots()) slots /= 2;
        uint256 amount =  slots*wad(vault.slotUSDValue());
        makeDeposit(user1, slots, true, amount, "");
        for (uint256 i = slots; i > 0; ) {
            unchecked {
                --i;
            }
            executeWithdrawal(user1, i, wad(vault.slotUSDValue()), "");
        }
    }

   function test_ExecuteWithdrawal_OK_5YearsAway(uint8 slots) public {
        if (slots == 0) return;

        while (slots > vault.availableSlots()) slots /= 2;
        uint256 amount =  slots*wad(vault.slotUSDValue());
        makeDeposit(user1, slots, true, amount, "");
        vm.warp(1825 days);
        for (uint256 i = slots; i > 0; ) {
            unchecked {
                --i;
            }
            executeWithdrawal(user1, i, token.balanceOf(multisig), "");
        }
    }

    // Helper to make deopsits
    function makeDeposit(address user, uint256 slots, bool wl, uint256 approve, bytes memory encodedError) internal {
        if (wl) {
            vm.prank(operator);
            whitelist.update(hash(user), true);
        }
        if (approve > 0) {
            vm.prank(user);
            token.approve(address(vault), approve);
        }
        if (encodedError.length > 0) {
            vm.expectRevert(encodedError);
        } else {
            vm.expectEmit(false, true, false, false);
            emit KratosXVault.DepositCreated(0, user, DepositData(vault.slotUSDValue(), uint32(block.timestamp), true));
        }
        vm.prank(user);
        vault.deposit(slots);
    }

    // Helper to refund a deposit
    function refundDeposit(address user, uint256 id, uint256 refund, uint256 approve, bytes memory encodedError) internal {
        if (approve > 0) {
            vm.prank(multisig);
            token.approve(address(vault), approve);
        }
        if (encodedError.length > 0) {
            vm.expectRevert(encodedError);
        } else {
            vm.expectEmit(true, true, false, false);
            emit KratosXVault.DepositRefunded(id, user, refund, DepositData(vault.slotUSDValue(), uint32(block.timestamp), true));
        }
        vm.prank(operator);
        vault.refundDeposit(id, refund);
    }

    // Helper to request a withdrawal
    function requestWithdrawal(address user, uint256 id, bytes memory encodedError) internal {
        if (encodedError.length > 0) {
            vm.expectRevert(encodedError);
        } else {
            vm.expectEmit(true, true, false, false);
            emit KratosXVault.WithdrawalRequested(id, user, DepositData(vault.slotUSDValue(), uint32(block.timestamp), true), 0);
        }
        vm.prank(user);
        vault.requestWithdrawal(id);
    }

    // Helper to execute a withdrawal
    function executeWithdrawal(address user, uint256 id, uint256 approve, bytes memory encodedError) internal {
        if (approve > 0) {
            vm.prank(multisig);
            token.approve(address(vault), approve);
        }
        if (encodedError.length > 0) {
            vm.expectRevert(encodedError);
        } else {
            vm.expectEmit(true, true, false, false);
            emit KratosXVault.WithdrawalExecuted(id, user, DepositData(vault.slotUSDValue(), uint32(block.timestamp), true), 0);
        }
        vm.prank(operator);
        vault.executeWithdrawal(id);
    }

    // Helper for hashing the addresses for whitelist
    function hash(address account) internal pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(account)));
    }

    // Helper for transforming dollars into token units
    function wad(uint256 dollars) internal view returns (uint256) {
        return dollars * 10**uint256(vault.underlyingDecimals());
    }

}
