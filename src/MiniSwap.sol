// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract MiniSwap is Ownable, ReentrancyGuard {
    IERC20 public immutable mUSDC;

    uint256 public reserveMON;
    uint256 public reserveUSDC;

    event Swap(string indexed direction, uint256 amountIn, uint256 amountOut);

    constructor(address _mUSDC) Ownable(msg.sender) {
        mUSDC = IERC20(_mUSDC);
    }

    function addLiquidity(uint256 usdcAmount) external payable onlyOwner {
        require(usdcAmount > 0, "MiniSwap: zero USDC amount");
        require(msg.value > 0, "MiniSwap: zero MON amount");

        require(mUSDC.transferFrom(msg.sender, address(this), usdcAmount), "MiniSwap: USDC transfer failed");

        reserveMON += msg.value;
        reserveUSDC += usdcAmount;
    }

    function swapMONForUSDC(uint256 minUSDCOut) external payable nonReentrant {
        require(msg.value > 0, "MiniSwap: zero MON input");
        require(reserveMON > 0 && reserveUSDC > 0, "MiniSwap: insufficient liquidity");

        uint256 usdcOut = getAmountOut(msg.value, reserveMON, reserveUSDC);
        require(usdcOut >= minUSDCOut, "MiniSwap: insufficient USDC output");

        reserveMON += msg.value;
        reserveUSDC -= usdcOut;

        require(mUSDC.transfer(msg.sender, usdcOut), "MiniSwap: USDC transfer failed");

        emit Swap("MON->USDC", msg.value, usdcOut);
    }

    function swapUSDCForMON(uint256 usdcIn, uint256 minMONOut) external nonReentrant {
        require(usdcIn > 0, "MiniSwap: zero USDC input");
        require(reserveMON > 0 && reserveUSDC > 0, "MiniSwap: insufficient liquidity");

        uint256 monOut = getAmountOut(usdcIn, reserveUSDC, reserveMON);
        require(monOut >= minMONOut, "MiniSwap: insufficient MON output");

        require(mUSDC.transferFrom(msg.sender, address(this), usdcIn), "MiniSwap: USDC transfer failed");

        reserveUSDC += usdcIn;
        reserveMON -= monOut;

        payable(msg.sender).transfer(monOut);

        emit Swap("USDC->MON", usdcIn, monOut);
    }

    function getAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    ) public pure returns (uint256) {
        require(amountIn > 0, "MiniSwap: zero input amount");
        require(reserveIn > 0 && reserveOut > 0, "MiniSwap: insufficient liquidity");

        uint256 amountInWithFee = amountIn * 997;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = (reserveIn * 1000) + amountInWithFee;

        return numerator / denominator;
    }
}
