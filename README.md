# greekfi

Core contracts for the Greek.fi options protocol — a fully collateralized,
oracle-free options primitive. Minting deposits collateral and issues two freely
transferable ERC-20 tokens: a long **Option** and a short **Receipt**, backed 1:1
by collateral at all times. Settlement is purely time-gated; the protocol never
reads price on-chain.

This repository contains **only** the core contracts, their interfaces, and the
build configuration — no tests, scripts, mocks, or frontend.

## Layout

```
contracts/
├── Factory.sol            # Deploys + registers Option/Receipt clone pairs; central allowance hub
├── Option.sol             # Long side (ERC-20) — exercise / mint / pair-burn / expire
├── Receipt.sol            # Short side (ERC-20, immutable-args clone) — holds collateral, redeem
├── OptionUtils.sol        # Shared view/formatting helpers
└── interfaces/
    ├── IFactory.sol
    ├── IOption.sol
    └── IReceipt.sol
```

## Build

```bash
forge install                       # restores OpenZeppelin + greekfi/clone
forge build
```

## Dependencies

| Dependency | Pin |
|------------|-----|
| [OpenZeppelin Contracts](https://github.com/OpenZeppelin/openzeppelin-contracts) | `e4f70216` |
| [greekfi/clone](https://github.com/greekfi/clone) | `v0.2.1` |

Compiler: solc 0.8.35, `via_ir = true`, optimizer 200 runs, `evm_version = "osaka"`.

## License

[Business Source License 1.1](LICENSE) (`BUSL-1.1`). Source-available with
non-production use permitted; production use requires a commercial license from
the Licensor until the **Change Date of 2029-06-23** (3 years), at which point
the code converts to the **BSD 3-Clause License**.
