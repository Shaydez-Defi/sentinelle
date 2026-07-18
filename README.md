# Sentinelle

Same-block liquidation protection for lending on Monad.

## Problem

DeFi lending positions get liquidated when nobody is watching. A market moves while you sleep, work, or lose signal, and the protocol seizes your collateral at a discount as a penalty on top of the debt you already owed. Aave deployed on Monad on July 2 and pulled in $100M in deposits within 48 hours. That capital needs monitoring the moment real borrow demand catches up to it.

Existing automation tools on other chains react in minutes, because checking a position on every block is too expensive there. That gap is where liquidations happen.

## Solution

Sentinelle is a self-deleveraging vault. Deposit MON, borrow mUSDC against it, and a permissionless keeper function watches your health factor every block. If it drops below a safe threshold, the vault sells a slice of your own collateral to repay debt automatically. No idle reserve required. No black box: every action is logged on-chain with the health factor before, the trigger, and the health factor after.

Monad's sub-second blocks and low fees make block-level checking economically viable, which is what makes same-block reaction possible here.

## How it works

1. Deposit MON as collateral, borrow mUSDC against it up to 150% collateralization.
2. A keeper (or anyone, since selfRepay is permissionless) calls selfRepay when health factor drops below 130%.
3. The vault sells a fixed slice of collateral through an internal AMM, repays a portion of the debt, and emits an event recording the exact before and after health factor.
4. The position stays open. Only the risk gets reduced.

## Architecture

Three contracts, Solidity ^0.8.19, built with Foundry.

- src/mUSDC.sol - mock USDC-style ERC20, 6 decimals, owner-gated minting for the vault, public faucet with a 1-hour cooldown for testing.
- src/MiniSwap.sol - a minimal constant-product AMM pairing MON and mUSDC, seeded with owner liquidity, used internally by the vault to convert collateral into repayment funds. Not a public liquidity venue.
- src/VaultManager.sol - the core contract. Tracks collateral and debt per user, computes health factor, and exposes deposit, borrow, repay, withdraw, and selfRepay.

## Deployed contracts

Monad Testnet, chain ID 10143. All verified on Sourcify with an exact match.

- VaultManager: 0x1EFE7CfC378480164E21155dc76E9c9325f7C825
- mUSDC: 0xBa2328AA31007Ef5D963Ba0659F48eCF204a7B23
- MiniSwap: 0xf634A2983741Efa1cea74d155284264b6389716b

## Key parameters

- Minimum collateral ratio to borrow: 150%
- Self repay trigger threshold: below 130% health factor
- Amount repaid per trigger: 30% of outstanding debt
- Slippage tolerance on internal swaps: 5%

## Local setup

git clone https://github.com/Shaydez-Defi/sentinelle.git
cd sentinelle
forge install
forge build
forge test -vv

Deploy with your own funded testnet wallet:

forge script script/Deploy.s.sol --rpc-url https://testnet-rpc.monad.xyz --account your-keystore --broadcast


## Frontend

Single page app, plain HTML, CSS, and JavaScript, wired to the live contracts above through ethers.js. Hosted on GitHub Pages at the repo's live URL. Includes a demo mode with a simulated risk event for judging without needing a funded wallet, separate from the real on-chain flow used when a wallet is connected.

## Test coverage

Five tests in test/VaultManager.t.sol, covering deposit and borrow, reverts on undercollateralized borrow, selfRepay recovering health factor, selfRepay reverting when the position is already safe, and withdraw reverting when it would leave a position unsafe.

## What is not built yet

- No real price oracle. monPriceUSD is owner-set, used here for demo purposes and to allow triggering selfRepay predictably during judging. A production version would use a real feed.- No WalletConnect. Desktop wallet connection works through an injected provider. Mobile users need to open the app inside their wallet's built-in browser for now.
- MiniSwap is a self-contained internal AMM, not routed through Monad's real DEX liquidity. This was a deliberate scope cut to avoid depending on external testnet liquidity during a five-day build.
