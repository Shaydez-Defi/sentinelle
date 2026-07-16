// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract mUSDC is ERC20, Ownable {
    mapping(address => bool) public minters;
    mapping(address => uint256) public lastFaucetClaim;

    uint256 public constant FAUCET_AMOUNT = 1000 * 10 ** 6;
    uint256 public constant FAUCET_COOLDOWN = 1 hours;

    event MinterSet(address indexed account, bool status);
    event FaucetClaimed(address indexed account, uint256 amount);

    constructor() ERC20("Mock USDC", "mUSDC") Ownable(msg.sender) {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function setMinter(address account, bool status) external onlyOwner {
        minters[account] = status;
        emit MinterSet(account, status);
    }

    function mint(address to, uint256 amount) external {
        require(minters[msg.sender], "mUSDC: not a minter");
        _mint(to, amount);
    }

    function burnFrom(address account, uint256 amount) external {
        require(minters[msg.sender], "mUSDC: not a minter");
        _spendAllowance(account, msg.sender, amount);
        _burn(account, amount);
    }

    function faucet() external {
        require(
            block.timestamp >= lastFaucetClaim[msg.sender] + FAUCET_COOLDOWN,
            "mUSDC: wait 1 hour"
        );
        lastFaucetClaim[msg.sender] = block.timestamp;
        _mint(msg.sender, FAUCET_AMOUNT);
        emit FaucetClaimed(msg.sender, FAUCET_AMOUNT);
    }
}
