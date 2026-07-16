# Sentinelle - Agent Instructions

## Workflow
- After every successful change (new file, edit, or fix), always run git add -A, commit with a clear message describing the change, and push to the main branch on GitHub.
- Do not push if forge build fails. Fix the build first, then commit and push.
- Never commit .env, private keys, or any secrets. Confirm .gitignore covers these before the first push in a session.
- Keep commit messages short and specific (e.g. "Add MiniSwap.sol with fee-adjusted constant product swaps"), not generic ("update files").

## Style
- No em-dashes in comments or commit messages.
- No over-engineered patterns. Keep contracts minimal and readable.
- Solidity ^0.8.19, OpenZeppelin contracts from lib/ for standard primitives (ERC20, Ownable, ReentrancyGuard).
