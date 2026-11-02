# greekfi

Interfaces for the Greek.fi options protocol, a fully collateralized, oracle-free options
primitive. Minting deposits collateral and issues two freely transferable ERC-20 tokens: a long
**Option** and a short **Receipt**, backed 1:1 by collateral at all times. Settlement is purely
time-gated; the protocol never reads price on-chain.

This repository holds the interfaces of the deployed v1.3 contracts, so integrators can build
against the live protocol, plus periphery contracts built on them. Behavioural documentation lives
in the NatSpec.

## Deployment

| | |
|---|---|
| Release | v1.3 |
| Source commit | `c7200d4d3b9053bf820f0b495dbeec9eb630c6b0` |
| Factory | `0x9999999999906A9a5B3CFB1151Ac6812B3042191` |

Addresses per chain, ABIs and RPCs ship in [`greekfi/sdk`](https://github.com/greekfi/sdk).

## Layout

```
contracts/
├── interfaces/
│   ├── IFactory.sol          # Creates and registers Option/Receipt pairs; allowance hub; permission registry
│   ├── IOption.sol           # Long side (ERC-20): mint / exercise / pair-burn / expire
│   ├── IReceipt.sol          # Short side (ERC-20): holds collateral, redeem
│   ├── IBebopSettlement.sol  # Slice of Bebop's settlement contract used by the router
│   ├── IPositionRouter.sol   # Errors and events of the router demo
│   └── ISafe.sol             # Slice of Safe 1.3.0 used by the fork tests
└── periphery/
    └── PositionRouter.sol    # DEMO: fixed-target transfer / redeem and Bebop limit orders for a Safe
test/                         # Mainnet-fork tests against the deployed v1.3 factory, Bebop and the ENS Endowment Safe
```

## Build

```bash
forge install                       # restores OpenZeppelin + forge-std
forge build
ETH_RPC_URL=<mainnet rpc> forge test   # fork tests; defaults to a public RPC
```

## Dependencies

| Dependency | Pin |
|------------|-----|
| [OpenZeppelin Contracts](https://github.com/OpenZeppelin/openzeppelin-contracts) | `e4f70216` |
| [forge-std](https://github.com/foundry-rs/forge-std) | `v1.16.1` |

Compiler: solc 0.8.35, `evm_version = "osaka"`.

## Audits

See [`audit/`](audit/).

## License

[Business Source License 1.1](LICENSE) (`BUSL-1.1`). Source-available with
non-production use permitted; production use requires a commercial license from
the Licensor until the **Change Date of 2029-06-23** (3 years), at which point
the code converts to the **BSD 3-Clause License**.
