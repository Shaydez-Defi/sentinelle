// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {VaultManager} from "../src/VaultManager.sol";
import {mUSDC} from "../src/mUSDC.sol";
import {MiniSwap} from "../src/MiniSwap.sol";

contract VaultManagerTest is Test {
    mUSDC public musdc;
    MiniSwap public miniSwap;
    VaultManager public vaultManager;

    address public alice = address(0xA11CE);

    uint256 public constant PRICE_2000 = 2000 * 10 ** 6; // $2000 with 6 decimals
    uint256 public constant PRICE_1000 = 1000 * 10 ** 6; // $1000 with 6 decimals

    event AutoRepaid(
        address indexed user,
        uint256 debtRepaid,
        uint256 collateralSold,
        uint256 healthFactorBefore,
        uint256 healthFactorAfter
    );

    function setUp() public {
        // Deploy mUSDC
        musdc = new mUSDC();

        // Deploy MiniSwap
        miniSwap = new MiniSwap(address(musdc));

        // Deploy VaultManager
        vaultManager = new VaultManager(address(musdc), address(miniSwap));

        // Authorize VaultManager as minter on mUSDC
        musdc.setMinter(address(vaultManager), true);

        // Authorize MiniSwap as minter on mUSDC
        musdc.setMinter(address(miniSwap), true);

        // Set initial MON price
        vaultManager.setMonPrice(PRICE_2000);

        // Make the test contract a minter so we can seed pool liquidity
        musdc.setMinter(address(this), true);
        musdc.mint(address(this), 200_000 * 10 ** 6);

        // Fund this contract with MON for liquidity seeding
        vm.deal(address(this), 1000 ether);

        musdc.approve(address(miniSwap), type(uint256).max);

        // Seed MiniSwap with liquidity: 200000 mUSDC and 100 MON
        miniSwap.addLiquidity{value: 100 ether}(200_000 * 10 ** 6);

        // Fund alice with MON
        vm.deal(alice, 100 ether);
    }

    // ──────────────────────────────────────
    //  1. test_DepositAndBorrow
    // ──────────────────────────────────────
    function test_DepositAndBorrow() public {
        uint256 depositAmount = 5 ether;

        vm.prank(alice);
        vaultManager.deposit{value: depositAmount}();

        assertEq(vaultManager.collateral(alice), depositAmount);

        // collateralValue = 5 * 2000 = 10000 mUSDC
        // Borrow 4000 mUSDC => HF = 10000 * 100 / 4000 = 250 (>= 150)
        uint256 borrowAmount = 4000 * 10 ** 6;
        vm.prank(alice);
        vaultManager.borrow(borrowAmount);

        assertEq(vaultManager.debt(alice), borrowAmount);
        assertEq(musdc.balanceOf(alice), borrowAmount);

        uint256 hf = vaultManager.healthFactor(alice);
        assertGe(hf, 150);
    }

    // ──────────────────────────────────────
    //  2. test_BorrowRevertsIfUnderCollateralized
    // ──────────────────────────────────────
    function test_BorrowRevertsIfUnderCollateralized() public {
        uint256 depositAmount = 5 ether;

        vm.prank(alice);
        vaultManager.deposit{value: depositAmount}();

        // collateralValue = 10000 mUSDC
        // Borrow 7000 mUSDC => HF = 10000 * 100 / 7000 = ~142 (< 150)
        uint256 borrowAmount = 7000 * 10 ** 6;
        vm.prank(alice);
        vm.expectRevert("VaultManager: health factor too low");
        vaultManager.borrow(borrowAmount);
    }

    // ──────────────────────────────────────
    //  3. test_SelfRepayTriggersWhenRisky
    // ──────────────────────────────────────
    function test_SelfRepayTriggersWhenRisky() public {
        uint256 depositAmount = 10 ether;

        vm.prank(alice);
        vaultManager.deposit{value: depositAmount}();

        // collateralValue = 10 * 2000 = 20000 mUSDC
        // Borrow 13000 mUSDC => HF = 20000 * 100 / 13000 = ~153 (>= 150)
        uint256 borrowAmount = 13000 * 10 ** 6;
        vm.prank(alice);
        vaultManager.borrow(borrowAmount);

        uint256 hfBeforeDrop = vaultManager.healthFactor(alice);
        assertGe(hfBeforeDrop, 150);

        // Drop MON price to $1000
        // collateralValue = 10 * 1000 = 10000 mUSDC
        // HF = 10000 * 100 / 13000 = ~76 (< 130)
        vaultManager.setMonPrice(PRICE_1000);

        uint256 hfBefore = vaultManager.healthFactor(alice);
        assertLt(hfBefore, 130);

        // Fund VaultManager with MON for the swap
        // monToSell = (13000e6 * 3000 / 10000) * 1e18 / 1000e6 = 3.9 ether
        vm.deal(address(vaultManager), 10 ether);

        uint256 debtBefore = vaultManager.debt(alice);
        uint256 collBefore = vaultManager.collateral(alice);

        // Expect the AutoRepaid event with alice address (check topics only)
        vm.expectEmit(true, true, false, false);
        emit AutoRepaid(alice, 0, 0, 0, 0);
        vaultManager.selfRepay(alice);

        uint256 debtAfter = vaultManager.debt(alice);
        uint256 collAfter = vaultManager.collateral(alice);
        uint256 hfAfter = vaultManager.healthFactor(alice);

        assertLt(debtAfter, debtBefore, "debt should decrease");
        assertLt(collAfter, collBefore, "collateral should decrease");
        assertGt(hfAfter, hfBefore, "health factor should improve");
    }

    // ──────────────────────────────────────
    //  4. test_SelfRepayRevertsWhenSafe
    // ──────────────────────────────────────
    function test_SelfRepayRevertsWhenSafe() public {
        uint256 depositAmount = 10 ether;

        vm.prank(alice);
        vaultManager.deposit{value: depositAmount}();

        // Borrow modestly so HF is well above 130
        // HF = 20000 * 100 / 5000 = 400
        uint256 borrowAmount = 5000 * 10 ** 6;
        vm.prank(alice);
        vaultManager.borrow(borrowAmount);

        vm.expectRevert("VaultManager: health factor is safe");
        vaultManager.selfRepay(alice);
    }

    // ──────────────────────────────────────
    //  5. test_WithdrawRevertsIfUnsafe
    // ──────────────────────────────────────
    function test_WithdrawRevertsIfUnsafe() public {
        uint256 depositAmount = 10 ether;

        vm.prank(alice);
        vaultManager.deposit{value: depositAmount}();

        // collateralValue = 20000 mUSDC
        // Borrow 10000 mUSDC => HF = 200 (safe)
        uint256 borrowAmount = 10000 * 10 ** 6;
        vm.prank(alice);
        vaultManager.borrow(borrowAmount);

        // Withdraw 6 ether => remaining collateral = 4 ether
        // collateralValue = 4 * 2000 = 8000, HF = 8000 * 100 / 10000 = 80 (< 150)
        vm.prank(alice);
        vm.expectRevert("VaultManager: health factor too low");
        vaultManager.withdraw(6 ether);
    }
}
