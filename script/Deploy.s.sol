// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

// Deployer wallet must be funded with at least 260 testnet MON before running
// this script (250 for liquidity + gas). Testnet MON can be claimed from the
// Monad faucet: https://faucet.monad.xyz

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../src/mUSDC.sol";
import "../src/MiniSwap.sol";
import "../src/VaultManager.sol";

contract DeploySentinelle is Script {
    function run() external {
        vm.startBroadcast();

        // 1. Deploy mUSDC
        mUSDC musdc = new mUSDC();

        // 2. Deploy MiniSwap with mUSDC address
        MiniSwap miniSwap = new MiniSwap(address(musdc));

        // 3. Deploy VaultManager with mUSDC and MiniSwap addresses
        VaultManager vaultManager = new VaultManager(address(musdc), address(miniSwap));

        // 4. Authorize VaultManager to mint/burn mUSDC
        musdc.setMinter(address(vaultManager), true);

        // 5. Temporarily authorize deployer to mint mUSDC for liquidity seeding
        musdc.setMinter(msg.sender, true);

        // 6. Mint 500,000 mUSDC to deployer for liquidity seeding
        musdc.mint(msg.sender, 500_000 * 10 ** 6);

        // 7. Approve MiniSwap to spend deployer's mUSDC
        musdc.approve(address(miniSwap), type(uint256).max);

        // 8. Seed liquidity: 500,000 mUSDC + 250 MON ($2000 per MON)
        miniSwap.addLiquidity{value: 250 ether}(500_000 * 10 ** 6);

        // 9. Set initial MON price at $2000.00 (6 decimal precision)
        vaultManager.setMonPrice(2000 * 10 ** 6);

        // 10. Revoke deployer's temporary minter status
        musdc.setMinter(msg.sender, false);

        vm.stopBroadcast();

        // Print deployed addresses for frontend/README
        console.log("mUSDC deployed at:", address(musdc));
        console.log("MiniSwap deployed at:", address(miniSwap));
        console.log("VaultManager deployed at:", address(vaultManager));
    }
}
