# Deployment handoff (unsigned)

Sepolia only, chain ID `11155111`. Nothing here is a transaction, a key or an RPC endpoint. The
services check the chain ID and the code at the PoolManager address before broadcasting. Bytecode
portability is not authorization to deploy elsewhere.

## Toolchain

Solidity `0.8.26`, EVM `cancun`, optimizer on with 200 runs, `via_ir = false`,
`bytecode_hash = "none"`, `cbor_metadata = false`, exactly as in `foundry.toml`. These settings are
part of the attested creation code and therefore of the hook's CREATE2 address. Use the native solc
in the offline profile; do not swap in a wrapper or enable FFI / filesystem access.

Sizes with these settings: hook creation code 12,435 bytes (12,403 + the 32-byte argument),
hook runtime 11,616 bytes, both well under EIP-170. The runtime contains no `SELFDESTRUCT`,
`DELEGATECALL` or `CALLCODE` and no data section (a 32-byte hashed reentrancy slot was deliberately
avoided because the optimizer would have moved it into code data that opcode scanners read as
instructions).

## Constructor inputs

| Artifact | Constructor inputs | Constraints |
| --- | --- | --- |
| `src/PVP.sol:PVP` | none | Must be deployed **by the factory**: it mints `10^27` to `msg.sender` and the factory must end up holding all of it. |
| `src/PvPadHook.sol:PvPadHook` | `IPoolManager manager` | **The only argument.** Nonzero; the constructor does not call it. Deployed with CREATE2 at an address whose low 14 bits are exactly `0xC8` (decimal `200`); the constructor reverts otherwise. |

Sepolia PoolManager named by the approved workflow: `0xE03A1074c86CFeDd5C142C4F04F1a1536e203543`.
On 2026-09-24 it answered `eth_getCode` with PoolManager runtime code on chain `11155111` through a
public Sepolia RPC (`https://ethereum-sepolia-rpc.publicnode.com`). Re-check before broadcasting.

## Order

1. **PVP** by the factory. Confirm `totalSupply() == balanceOf(factory) == 10^27`, `decimals() == 18`.
2. **PvPadHook** with the PoolManager only, via CREATE2. Mine the salt offline against the exact
   creation code (`test/utils/HookMiner.sol` shows the loop; `cast create2 --ends-with c8` with the
   14-bit mask in mind also works). The salt depends on the deployer address and the creation code,
   nothing else; a new compile means a new salt but never a new constructor argument. Verify on
   chain: `poolManager() == manager`, `updater() == 0x5b95A971B4583A5f011E9DA082acdD679b870D06`,
   `claimPrice() == 10000000000000000`, `getHookPermissions()` = beforeSwap + afterSwap +
   beforeSwapReturnDelta, `uint160(hook) & 0x3fff == 0xc8`, runtime code equals the attested artifact.
3. **`PoolManager.initialize(key, sqrtPriceX96)`** from the factory (or any sender), with
   `key = (currency0 = ETH, currency1 = PVP, fee, tickSpacing, hooks = hook)`. The hook is not
   called. A wrong price reverts in the PoolManager only.
4. **Seed liquidity** with ordinary v4 tooling. Two shapes were rehearsed: full-range two-sided at
   parity, and a PVP-only position below the opening price (`test/FactoryLaunch.t.sol`). With a
   PVP-only seed the first exact-input buys defer their ETH fee as an ERC-6909 claim that anyone can
   `redeem(address(0))` afterwards; nothing is lost and no swap fails because of it.
5. Hand the live addresses of PVP and PvPadHook to the frontend with explorer links.

There is no bind step, no pad, no router allow-list and no post-deployment configuration.

## Parameters the services must choose and review

- Initial `sqrtPriceX96`, liquidity amount, range and who holds the LP position.
- Pool `fee` and `tickSpacing`.
- The CREATE2 deployer contract and the mined salt.
- Custody of the updater key (`0x5b95A971B4583A5f011E9DA082acdD679b870D06`) and the oracle client
  integration behind it; whether and to whom to hand the role over (`proposeUpdater` /
  `acceptUpdater`).
- Who calls `assignUnassigned` and `redeem` when needed (both permissionless; the frontend can
  offer them).

## Frontend and keeper integration

- **King**: read `king`, `beneficiary`, `claimPrice`, `claimCount`; call `claimKing(beneficiary)`
  with strictly more than `claimPrice`. A stale bid reverts with `BidTooLow(currentPrice)`.
- **Fees**: `totalSkimmed(currency)` for the running total per currency (`address(0)` is ETH);
  `pending(account, currency)` and `withdraw(currency, to)` for credits; `unassigned(currency)` and
  `assignUnassigned(currency)` for pre-King fees; `deferred(currency)` and `redeem(currency)` for
  claims still on the PoolManager. Events `FeeDelivered`, `FeeCredited`, `FeeDeferred`, `Withdrawn`,
  `Redeemed`, `UnassignedAssigned`.
- **Trading**: any v4 router. Quote off chain against the pool; the trader pays or receives exactly
  `amountSpecified`; the fee is 1% of it in the specified currency and the pool sees 99% / 101%.
  Use extreme `sqrtPriceLimitX96` values and enforce slippage through the router's minimum-output
  or maximum-input checks: a price limit that stops the swap early makes the whole swap revert
  (`PartialFill`).
- **Workers**: poll `currentEpoch`, `epochs(id)`, `availableForNextEpoch()` and the published
  proofs; call `claimWorker(id, payee, amount, proof)` inside `[windowStart, windowEnd)`.
  Events `EpochSet`, `WorkerPaid`, `WorkersFunded`, `UpdaterProposed`, `UpdaterChanged`.

## Operational responsibilities after deployment

| Responsibility | Who |
| --- | --- |
| Custody of the deploying key, gas, and the CREATE2 salt | services |
| Source verification on the explorer with the settings above | services |
| Cross-checking the PoolManager address against the Uniswap deployments list | manifest assignment and reviewer |
| Running the keeper (`docs/keeper.md`) and guarding the updater key | Identity MD operations |
| Calling `redeem` / `assignUnassigned` when the site shows a nonzero `deferred` / `unassigned` | anyone; suggested: the frontend |
| Independent adversarial review before release | separate contributor (`docs/review-notes.md`) |
