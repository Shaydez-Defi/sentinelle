// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {mUSDC} from "./mUSDC.sol";
import {MiniSwap} from "./MiniSwap.sol";

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

    function collateralValueUSD(address user) public view returns (uint256) {
        return (collateral[user] * monPriceUSD) / 1e18;
    }

    function healthFactor(address user) public view returns (uint256) {
        if (debt[user] == 0) return type(uint256).max;
        return collateralValueUSD(user) * 100 / debt[user];
    }

    function deposit() external payable {
        require(msg.value > 0, "VaultManager: zero deposit");
        collateral[msg.sender] += msg.value;
        emit Deposited(msg.sender, msg.value);
    }

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

    function repay(uint256 usdcAmount) external {
        require(usdcAmount > 0, "VaultManager: zero repay");
        uint256 actualAmount = usdcAmount > debt[msg.sender]
            ? debt[msg.sender]
            : usdcAmount;
        debt[msg.sender] -= actualAmount;
        musdc.burnFrom(msg.sender, actualAmount);
        emit Repaid(msg.sender, actualAmount);
    }

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
        payable(msg.sender).transfer(monAmount);
        emit Withdrawn(msg.sender, monAmount);
    }

    function setMonPrice(uint256 newPrice) external onlyOwner {
        uint256 oldPrice = monPriceUSD;
        monPriceUSD = newPrice;
        emit PriceUpdated(oldPrice, newPrice);
    }

    function selfRepay(address user) external nonReentrant {
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
