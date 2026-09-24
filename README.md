# PvPad v3 — PVP launch contracts for Sepolia

Contract contribution for the PvPad ONE-SHOT v3 workflow: Sepolia only (`11155111`), site label
`pvpad`. Two contracts, nothing else to deploy:

| Contract | What it is | Authority |
| --- | --- | --- |
| `PVP` (`src/PVP.sol`) | ERC-20 "Pepe Values Pepe", symbol `PVP`, 18 decimals. The zero-argument constructor mints exactly `10^27` minor units (1,000,000,000 PVP) to `msg.sender`, the launch factory, and nothing else, ever. Holders may `burn`. | None. No owner, mint, pause, proxy or hooks on transfer. |
| `PvPadHook` (`src/PvPadHook.sol`) | Uniswap v4 hook with the whole PvPad economy inside: the 1% swap fee paid to the King's beneficiary, the King seat that funds Identity MD workers, and the Merkle-epoch drip that pays them. Constructor takes **only the PoolManager**. | The epoch `updater` (baked in source, two-step handoff) may publish attested roots. Nothing else is privileged. |

This repository replaces launch 138, which failed because its hook used `beforeInitialize` and
demanded a bound pad while the IMD factory opens the pool itself. This hook has **no initialize,
liquidity or donate permission**: the factory deploys PVP, CREATE2s the hook, calls
`PoolManager.initialize` with itself as sender, seeds ordinary v4 liquidity, and trading starts.
`test/FactoryLaunch.t.sol` rehearses exactly that against the real `PoolManager` code, including a
one-sided PVP-only seed.

It does **not** contain `launch.json` (the separate manifest assignment writes it from
[docs/manifest-notes.md](docs/manifest-notes.md)), does not broadcast transactions and holds no
keys. Publishing, attestation, admission, deployment and the website are later services.

## Running the checks

```
bash scripts/check.sh
```

Runs `forge build`, `forge test`, `forge fmt --check`, the ABI export check and the Python unit
tests of the keeper tool. Requirements: Foundry with solc `0.8.26` and Python 3, both already
installed; nothing is downloaded. Every Solidity import is an ordinary file under `lib/` (pinned in
[docs/dependencies.json](docs/dependencies.json)); no submodules, no npm, no FFI, no filesystem
permissions. EVM target is Cancun (v4 needs transient storage).

## The hook, in one screen

**Permissions.** `beforeSwap`, `afterSwap`, `beforeSwapReturnDelta`, exactly the BurnHook-style
swap-path set: address bits `0xC8` = `200` (`HookFlags.PVPAD_HOOK`). The constructor calls
`Hooks.validateHookPermissions`, so a deployment at any other address reverts.

**Swap fee (1%, `FEE_BPS = 100`, constant).** On every swap the hook takes 1% of the *specified*
currency: the input for exact-input swaps, the output for exact-output swaps. `beforeSwap` returns a
positive specified delta of that amount, so v4 swaps 99% (exact input) or 101% (exact output) and the
trader always moves exactly `amountSpecified`; `afterSwap` checks the pool filled the whole amount
(a partial fill reverts with `PartialFill`), takes the fee out of the PoolManager and delivers it:

- **Native ETH fee** → pushed to the beneficiary with a 2300-gas send inside the swap. An EOA or a
  receiver that only logs (a Safe) gets it immediately. Anything else becomes a credit.
- **ERC-20 fee (PVP)** → transferred by the PoolManager straight to the beneficiary.
- **Delivery failed** → credited to `pending[beneficiary][currency]`; the beneficiary calls
  `withdraw(currency, to)`. A refusing, expensive or re-entering beneficiary can never block a swap.
- **PoolManager cannot release the currency yet** (the first exact-input buys of a pool that holds
  no ETH, before the trader has settled) → the fee is minted to the hook as an ERC-6909 claim,
  recorded in `deferred[currency]`, and anyone calls `redeem(currency)` later; `withdraw` and
  `claimWorker` do it on their own. Tested in `test/FactoryLaunch.t.sol`.
- **No King yet** → fees go to `unassigned[currency]` and belong to the first beneficiary
  (`assignUnassigned(currency)`, permissionless once a King exists).

Zero house cut: there is no treasury address, no cut variable, no owner. The pool's own LP fee
(the manifest's `fee`, e.g. 0.30%) stays with LPs. Anyone may swap through any v4 router; nothing is
gated on a pad. Swaps below 100 wei pay nothing (rounding down).

**King (`claimKing(beneficiary)`, payable).** `msg.value` must be strictly more than `claimPrice`;
the caller becomes `king` and names `beneficiary`, which receives the swap fees from then on. Every
wei of the bid goes to the worker pot; the previous King is never paid. Next
`claimPrice = paid + ceil(paid × 10%)` (`BUMP_BPS = 1000`). **The initial `claimPrice` is
`0.01 ether`** (`INITIAL_CLAIM_PRICE`, a compile-time constant). No refunds, no expiry, no admin.

**Worker pot.** King bids (and `fundWorkers()` donations) accumulate in `workerPot`. Only the
`updater` — `0x5b95A971B4583A5f011E9DA082acdD679b870D06`, `INITIAL_UPDATER`, baked in source and not a
constructor argument — may call `setEpoch(root, windowStart, windowEnd)`, and should do so only after
the off-chain Identity MD `oracle.request` (panelSize 70, quorum 67, bool) attested the root. The
whole pot (plus whatever the previous epoch left unclaimed) becomes the epoch's budget. Workers, or
anyone relaying for them, call `claimWorker(epochId, payee, amount, proof)`; ETH always goes to the
leaf's payee, once per epoch, inside the window. The updater can hand its role over in two steps
(`proposeUpdater` / `acceptUpdater`) and can do nothing else: no withdrawal, sweep, pause or fee
redirect exists. Keeper recipe: [docs/keeper.md](docs/keeper.md). Solidity never calls
`api.imd.fun`.

Naming: the workflow's shorthand `claim(beneficiary)` is `claimKing`, and
`claim(epochId, payee, amount, proof)` is `claimWorker`, so the ABI has no overloads.

## Deployment shape

1. Factory deploys `PVP`, holds `10^27`. The 10/80/10 split is the launch policy's and is not
   encoded here.
2. Factory CREATE2-deploys `PvPadHook(poolManager)` at a salt whose address carries exactly `0xC8`.
   Creation code = `type(PvPadHook).creationCode ++ abi.encode(poolManager)`; the Sepolia
   PoolManager is `0xE03A1074c86CFeDd5C142C4F04F1a1536e203543`.
3. Factory calls `PoolManager.initialize(key, sqrtPriceX96)` with `key = (ETH, PVP, fee, tickSpacing, hook)`.
   The hook is not consulted.
4. Factory seeds liquidity with ordinary v4 tooling. The hook never intercepts liquidity.
5. Trading, King claims and worker epochs run with no further setup.

Details, parameters and the choices left to the services: [docs/deployment.md](docs/deployment.md).

## Documentation

- [docs/manifest-notes.md](docs/manifest-notes.md): what `launch.json` must and must not say.
- [docs/deployment.md](docs/deployment.md): toolchain, constructor inputs, order, operator duties.
- [docs/keeper.md](docs/keeper.md): the worker-epoch keeper (`api.imd.fun/workers`, the worker
  collection, oracle attestation, `scripts/merkle.py`, `setEpoch`).
- [docs/review-notes.md](docs/review-notes.md): assumptions, trust boundaries, known limitations,
  and what the independent adversarial review still has to do.
- ABIs: `docs/abi/PVP.json`, `docs/abi/PvPadHook.json` (`scripts/export-abi.sh`).

## What the site should say

No pump.fun-style house. 1% of every swap on the PVP pool goes to whoever the current King named
as beneficiary. Becoming King costs an ETH bid (starting above 0.01 ETH, +10% per claim) that goes
entirely to Identity MD workers, paid out in attested Merkle epochs. King, fee and worker logic all
live in `PvPadHook`; the live addresses to show are PVP and PvPadHook, with explorer links. The pool
is opened by the launch factory and its liquidity is ordinary Uniswap v4 liquidity.

## Tests

`forge test` runs 88 tests in 10 suites against the real `PoolManager`: token supply, immutability
and transfer exactness; hook permissions, address bits, opcode scan, caller refusal and constructor
rules; the four swap shapes with exact accounting against a hookless twin pool; partial fills,
dust, foreign-token pools; every beneficiary delivery path (EOA, logging, expensive, refusing,
gas-burning and re-entering contracts); deferred claims on a one-sided launch pool; King pricing
and funding; epochs, proofs, windows, rollover, refusing payees and the updater handoff; the
manifest creation code at a mined address; and two stateful invariant suites (2048 calls each,
`fail_on_revert`) that check conservation of ETH and PVP, PoolManager settlement and claim backing.
The two admission floor suites supplied with the task were run against the built creation code
(`IMD_HOOK_FLAGS=200`, with and without the Sepolia PoolManager etched, `IMD_TOKEN_DECIMALS=18`):
9/9 pass. Tests passing are not an audit; see the review notes.
