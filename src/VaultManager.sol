// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {mUSDC} from "./mUSDC.sol";
import {MiniSwap} from "./MiniSwap.sol";

/// @title VaultManager
/// @notice Manages MON collateral vaults: deposit, borrow mUSDC, repay, withdraw, and automated self-repayment.
/// @dev Holds MON collateral and mUSDC debt positions. Uses MiniSwap for automated debt repayment when health factors drop.
contract VaultManager is Ownable, ReentrancyGuard {
    mUSDC public immutable musdc;
    MiniSwap public immutable miniSwap;

    mapping(address => uint256) public collateral;
    mapping(address => uint256) public debt;

    uint256 public monPriceUSD;

    uint256 public constant MIN_COLLATERAL_RATIO = 150;
    uint256 public constant SELF_REPAY_THRESHOLD = 130;
    uint256 public constant REPAY_PERCENT_BPS = 3000;
    uint256 public constant SLIPPAGE_TOLERANCE_BPS = 500;

    event Deposited(address indexed user, uint256 amount);
    event Borrowed(address indexed user, uint256 amount);
    event Repaid(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event PriceUpdated(uint256 oldPrice, uint256 newPrice);
    event AutoRepaid(
        address indexed user,
        uint256 debtRepaid,
        uint256 collateralSold,
        uint256 healthFactorBefore,
        uint256 healthFactorAfter
    );

    constructor(address _musdc, address _miniSwap) Ownable(msg.sender) {
        musdc = mUSDC(_musdc);
        miniSwap = MiniSwap(_miniSwap);
        musdc.approve(address(this), type(uint256).max);
    }

    /// @notice Returns the USD value of a user's MON collateral.
    /// @dev Uses the stored monPriceUSD oracle price, scaled by 1e18.
    /// @param user The address to query.
    /// @return The collateral value in USD (6-decimal mUSDC precision).
    function collateralValueUSD(address user) public view returns (uint256) {
        return (collateral[user] * monPriceUSD) / 1e18;
    }

    /// @notice Returns the health factor for a user's vault position.
    /// @dev healthFactor = (collateralValueUSD * 100) / debt. Returns uint256.max when there is no debt.
    /// @param user The address to query.
    /// @return The health factor as a percentage (100 = 100%).
    function healthFactor(address user) public view returns (uint256) {
        if (debt[user] == 0) return type(uint256).max;
        return collateralValueUSD(user) * 100 / debt[user];
    }

    /// @notice Deposit MON as collateral into the caller's vault.
    /// @dev The deposited amount is tracked in collateral[msg.sender].
    function deposit() external payable {
        require(msg.value > 0, "VaultManager: zero deposit");
        collateral[msg.sender] += msg.value;
        emit Deposited(msg.sender, msg.value);
    }

    /// @notice Borrow mUSDC against deposited MON collateral.
    /// @dev Reverts if the resulting health factor would fall below MIN_COLLATERAL_RATIO (150%).
    /// @param usdcAmount The amount of mUSDC to mint and receive.
    function borrow(uint256 usdcAmount) external {
        require(usdcAmount > 0, "VaultManager: zero borrow");
        uint256 newDebt = debt[msg.sender] + usdcAmount;
        uint256 colValue = collateralValueUSD(msg.sender);
        require(
            colValue * 100 / newDebt >= MIN_COLLATERAL_RATIO,
            "VaultManager: health factor too low"
        );
        debt[msg.sender] = newDebt;
        musdc.mint(msg.sender, usdcAmount);
        emit Borrowed(msg.sender, usdcAmount);
    }

    /// @notice Repay outstanding mUSDC debt with the caller's mUSDC balance.
    /// @dev Burns mUSDC from msg.sender. If usdcAmount exceeds the debt, only the remaining debt is repaid.
    /// @param usdcAmount The amount of mUSDC to repay.
    function repay(uint256 usdcAmount) external {
        require(usdcAmount > 0, "VaultManager: zero repay");
        uint256 actualAmount = usdcAmount > debt[msg.sender]
            ? debt[msg.sender]
            : usdcAmount;
        debt[msg.sender] -= actualAmount;
        musdc.burnFrom(msg.sender, actualAmount);
        emit Repaid(msg.sender, actualAmount);
    }

    /// @notice Withdraw MON collateral from the caller's vault.
    /// @dev Uses a low-level call (not transfer) to avoid the 2300 gas stipend limitation,
    ///      which would break withdrawals for smart-contract wallets. Reverts if the withdrawal
    ///      would violate the minimum collateral ratio.
    /// @param monAmount The amount of MON to withdraw.
    function withdraw(uint256 monAmount) external nonReentrant {
        require(monAmount > 0, "VaultManager: zero withdraw");
        require(
            collateral[msg.sender] >= monAmount,
            "VaultManager: insufficient collateral"
        );
        collateral[msg.sender] -= monAmount;
        if (debt[msg.sender] > 0) {
            require(
                healthFactor(msg.sender) >= MIN_COLLATERAL_RATIO,
                "VaultManager: health factor too low"
            );
        }
        (bool success, ) = payable(msg.sender).call{value: monAmount}("");
        require(success, "VaultManager: MON transfer failed");
        emit Withdrawn(msg.sender, monAmount);
    }

    /// @notice Set the MON/USD oracle price used for collateral valuation.
    /// @dev Only callable by the contract owner. A value of zero disables borrowing and withdrawals.
    /// @param newPrice The new MON price in USD, scaled to 6 decimals, matching mUSDC precision (e.g. 2000000000 represents $2000.00).
    function setMonPrice(uint256 newPrice) external onlyOwner {
        uint256 oldPrice = monPriceUSD;
        monPriceUSD = newPrice;
        emit PriceUpdated(oldPrice, newPrice);
    }

    /// @notice Automatically repay a portion of a user's debt by selling their MON collateral on MiniSwap.
    /// @dev Callable by anyone. Triggers when a position's health factor drops below SELF_REPAY_THRESHOLD (130%).
    ///      Sells REPAY_PERCENT_BPS (30%) of debt worth of MON, swaps for mUSDC, and burns the repaid amount.
    ///      Reverts if monPriceUSD is zero (price oracle not set).
    /// @param user The address of the under-collateralized vault to self-repay.
    function selfRepay(address user) external nonReentrant {
        require(monPriceUSD > 0, "VaultManager: price not set");
        uint256 hf = healthFactor(user);
        require(hf < SELF_REPAY_THRESHOLD, "VaultManager: health factor is safe");
        require(debt[user] > 0, "VaultManager: no debt to repay");

        uint256 healthFactorBefore = hf;
        uint256 usdcToRepay = (debt[user] * REPAY_PERCENT_BPS) / 10000;
        uint256 monToSell = (usdcToRepay * 1e18) / monPriceUSD;
        require(
            collateral[user] >= monToSell,
            "VaultManager: insufficient collateral for self repay"
        );

        uint256 minUsdcOut =
            (usdcToRepay * (10000 - SLIPPAGE_TOLERANCE_BPS)) / 10000;

        uint256 balBefore = musdc.balanceOf(address(this));
        miniSwap.swapMONForUSDC{value: monToSell}(minUsdcOut);
        uint256 usdcReceived = musdc.balanceOf(address(this)) - balBefore;

        collateral[user] -= monToSell;

        uint256 toBurn = usdcReceived > debt[user]
            ? debt[user]
            : usdcReceived;
        musdc.burnFrom(address(this), toBurn);
        debt[user] -= toBurn;

        uint256 healthFactorAfter = healthFactor(user);
        emit AutoRepaid(
            user,
            toBurn,
            monToSell,
            healthFactorBefore,
            healthFactorAfter
        );
    }
}
