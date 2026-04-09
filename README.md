# Amolis Vault Factory

Foundry project for bootstrapping an Amolis-managed Morpho vault stack around a user-supplied XUSD token.

## Architecture

- `AmolisFactory` bootstraps a Chainlink-backed oracle, a Morpho Blue market, and a fresh controller-owned vault stack.
- `AmolisVaultController` permanently owns the deployed VaultV2 and only exposes the constrained admin surface intended for operators.
- Unit tests cover bootstrap wiring, ownership and whitelist policy, cap updates, and fee-recipient safety.
- Mainnet fork tests exercise the full lender and borrower lifecycle against live Morpho, USDC, and Chainlink contracts.

## Requirements

- Foundry with `forge`, `cast`, and `anvil` on your `PATH`
- Git submodules initialized
- Optional mainnet RPC credentials for fork tests, documented in `.env.example`

## Common Commands

```sh
forge fmt
forge build
forge test -vvv
forge test --profile mainnet-fork -vvv
```

## Configuration

- The project is pinned to `solc 0.8.28`, uses the Cancun EVM target, and compiles through `via_ir`.
- Fork tests read `MAINNET_RPC_URL` and optional `MAINNET_FORK_BLOCK` from the process environment; Foundry can source them from `.env`.
- CI runs formatting, build, and the full unit test suite through GitHub Actions.

## Repository Layout

- `src/AmolisFactory.sol`: deployment entrypoint for new Amolis vault stacks
- `src/AmolisVaultController.sol`: narrow controller and gate implementation for deployed vaults
- `test/`: local unit and bootstrap coverage
- `test/fork/`: mainnet fork integration coverage
