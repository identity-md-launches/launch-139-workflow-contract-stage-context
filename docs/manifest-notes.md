# Notes for the launch.json assignment

This repository does not contain `launch.json`; the separate manifest assignment writes it. These
are the facts it needs, taken from the source, so the manifest and the code cannot disagree.

The attestation rule of the approved workflow is the reason the hook looks the way it does:
**`hook.constructorArgs` must be exactly one literal address, the Sepolia PoolManager.** Never
`$pad`, `$token`, `$pvp`, `$king`, `$subsidy` or a sibling contract's name; there are no sibling
contracts.

| Field | Value | Where it comes from |
| --- | --- | --- |
| `kind` | `univ4_hook` | approved workflow |
| `hook.contract` | `PvPadHook` | `src/PvPadHook.sol` |
| `hook.constructorArgs` | exactly one entry: `"0xE03A1074c86CFeDd5C142C4F04F1a1536e203543"` | the constructor's only parameter, `IPoolManager manager`; the Sepolia PoolManager named by the approved workflow |
| `hook.permissions` | `["beforeSwap", "afterSwap", "beforeSwapReturnDelta"]` — flags `0xC8` = `200` | `getHookPermissions()`; the constructor reverts at any other address. **No `beforeInitialize`.** |
| `token.contract` | `PVP` | `src/PVP.sol` |
| `token.name` / `symbol` / `decimals` | `Pepe Values Pepe` / `PVP` / `18` | the ERC-20 metadata constants |
| `pool.pairedCurrency` | `0x0000000000000000000000000000000000000000` (native ETH) | the product: fees are pushed as ETH; the hook itself accepts any pool |
| `pool.fee` / `pool.tickSpacing` | a manifest choice; tests use `3000` / `60` | not restricted by the hook |
| `pool.initialPrice` | a manifest choice (sqrtPriceX96, decimal string) | not fixed by the workflow or the code; `test/FactoryLaunch.t.sol` uses `79228162514264337593543950336000` (1,000,000 PVP per ETH) |

Do not add `totalSupply`, allocation basis points, `feeBps`, `bumpBps`, the initial claim price or
the updater to the manifest: the policy owns the 10/80/10 split, and the economics are compile-time
constants in the source (`FEE_BPS = 100`, `BUMP_BPS = 1000`, `INITIAL_CLAIM_PRICE = 0.01 ether`,
`INITIAL_UPDATER = 0x5b95A971B4583A5f011E9DA082acdD679b870D06`). The `notes` may state them as facts
about the source.

Things the `notes` may usefully say:

- The pool is opened by the factory's own `PoolManager.initialize` call; the hook has no
  initialize permission and does not care who the sender is (fixes launch 138's `WrappedError`
  `0x90bfb865`).
- The fee is 1% of the specified currency of each swap, delivered to the King's beneficiary; swaps
  must fully fill; there is no house cut, owner, pause, upgrade path, SELFDESTRUCT or DELEGATECALL.
- King claims fund the worker pot; the updater publishes attested Merkle epochs.
- Toolchain: solc `0.8.26`, EVM `cancun`, optimizer on with `200` runs, `via_ir = false`,
  `bytecode_hash = "none"`, `cbor_metadata = false` (`foundry.toml`). The hook's creation code is
  the compiled initcode plus one 32-byte ABI word (the PoolManager); `test/Deployment.t.sol`
  checks that shape.
- Dependencies are vendored as ordinary files (`docs/dependencies.json`).

Reference checks the manifest reviewer can reproduce offline:

```
forge inspect src/PvPadHook.sol:PvPadHook abi --json   # one constructor input: manager (address)
forge test --match-contract DeploymentTest             # mined address carries 200, manager word appended
bash scripts/export-abi.sh --check                     # docs/abi/*.json equal the compiled ABIs
```

The protected floor suites pass against the built creation code with `IMD_HOOK_FLAGS=200`, with and
without `IMD_POOL_MANAGER=0xE03A1074c86CFeDd5C142C4F04F1a1536e203543`, and with
`IMD_TOKEN_DECIMALS=18`. With `IMD_HOOK_FLAGS=136` (a different hook's flags) the hook suite fails
in `setUp`, as it should.
