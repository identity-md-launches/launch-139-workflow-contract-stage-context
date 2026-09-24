# Review notes

Author's notes for the independent adversarial reviewer. They are neither an audit nor a deployment
approval. Tests passing describe the tested behaviour; they do not establish that untested
behaviour is safe.

## What changed versus launch 138

Everything collapsed into one hook. There is no pad, no bind, no fee router, no separate king or
subsidy contract and no burner. The hook has no `beforeInitialize`; its permissions are
`beforeSwap`, `afterSwap`, `beforeSwapReturnDelta` (flags 200). The fee is skimmed through hook
deltas (BurnHook-shaped) instead of a pad router, so any v4 router can trade. The updater address is
a source constant, not a constructor argument. The token no longer inherits OpenZeppelin; it is a
self-contained ERC-20 with `burn`/`burnFrom`.

## Trust boundaries

- **PoolManager.** Every enabled callback and `unlockCallback` check `msg.sender == poolManager`.
  The disabled callbacks revert for everyone. `sender` and `hookData` are ignored; `tx.origin` is
  never read. The constructor trusts its argument without calling it.
- **Return-delta surface.** `beforeSwapReturnDelta` is enabled, which is the NoOp attack class.
  What limits it: the returned delta is always exactly `feeFor(amountSpecified)` (1%, constant),
  only on the specified side, never on the unspecified side, never an LP fee override; `afterSwap`
  verifies the pool filled `amountSpecified + fee` and (for exact input) produced output before
  moving anything. The hook can only ever take what the delta credited it; taking more would leave
  it with a negative delta and the swap would revert at unlock. There is no `afterSwapReturnDelta`.
- **Beneficiary.** Chosen by the King, fully untrusted. Inside a swap it is only ever sent ETH with
  2300 gas (cannot re-enter the PoolManager or the hook), or handed an ERC-20 by the PoolManager's
  `transfer`. Failure of either becomes a credit. `withdraw` is `nonReentrant`; a beneficiary that
  re-enters from its `receive` makes its own withdrawal revert and keeps the credit
  (`test_reentrantBeneficiaryIsCreditedAndCannotReenterOnPull`).
- **Foreign pools and tokens.** Anyone can open a pool with this hook and any token. Fees in such a
  pool are skimmed in that token and delivered to the same beneficiary. A token whose `transfer`
  reverts or consumes all gas can make swaps in *its own* pool revert or defer; it cannot reach the
  PVP pool's accounting, which is per currency. A token with transfer callbacks (ERC-777 style)
  could call back into a beneficiary during `take`; the beneficiary is then inside `afterSwap`'s
  reentrancy lock and cannot change hook state.
- **King.** No refunds, no expiry, no payout to the dethroned King, no admin. A King can name a
  beneficiary that cannot receive ETH; the fees then accrue as credits nobody can pull until the
  beneficiary changes or that contract pulls (`withdraw` takes a `to`). That is the King's problem
  and the trader never notices.
- **Updater.** Can publish roots for the pot's balance and hand its role over. Cannot touch swap
  fees, credits, deferred claims or the current epoch's already-paid amounts. A dishonest root
  drains at most one epoch's budget (the pot at that moment) to the addresses in the root; the
  chain-, contract- and epoch-bound leaf stops replay.
- **Nobody** can pause, upgrade, change the fee, redirect fees, sweep the pot or mint PVP.

## Assumptions

- The PoolManager at the constructor argument is the intended Uniswap v4 deployment on Sepolia.
- PVP is a plain ERC-20 (it is). ETH is native, not WETH. The launch pool is ETH/PVP; the fee
  pushed as ETH is the product's promise, not a hook restriction.
- The launch factory is the token's immediate deployer and receives the whole supply.
- ETH forced into the hook (`SELFDESTRUCT` from elsewhere) is not counted anywhere and is not
  recoverable; the conservation invariant tested is `balance + deferred == pot + epochRemaining +
  totalPending + unassigned`, which forced ETH would break in the safe direction (surplus).

## Known limitations, on purpose

- **Partial fills revert.** A swap whose price limit stops it early pays the whole fee for volume
  that did not trade, so the hook refuses it. Routers should use extreme limits and enforce slippage
  on amounts.
- **The fee currency follows the swap shape.** Exact-input buys and exact-output sells pay ETH;
  exact-output buys and exact-input sells pay PVP. A beneficiary therefore receives both. A design
  that always charged ETH would need `afterSwapReturnDelta` on top; that permission is not in the
  approved set and was not added.
- **Dust.** Swaps under 100 wei of the specified currency pay no fee. Rounding is down.
- **Deferred claims** exist only while the PoolManager cannot release the currency during the
  swap (a pool with no ETH yet). They are ERC-6909 claims held by the hook and can only ever be
  redeemed to the hook. `withdraw` and `claimWorker` redeem first, which calls `unlock`, so those two
  cannot be called from inside another unlock while a claim is outstanding; `redeem` from a plain
  transaction clears it.
- **Pre-King fees** wait in `unassigned` for the first beneficiary; if there is never a King they
  wait forever.
- **`claimWorker` forwards all gas** to the payee (an attested worker wallet) and reverts on
  failure; a hostile payee can only fail its own claim.
- **Epoch windows** are capped at 90 days; the pot is otherwise unbounded in time.

## Rounding

Fee rounds down. King bump rounds up. Merkle amounts are exact.

## Local verification performed

- `forge build`, `forge test` (88 tests: unit, fuzz, and two stateful invariant suites with
  `fail_on_revert` against the real `PoolManager`), `forge fmt --check`, ABI export check, Python
  unit tests (`bash scripts/check.sh`).
- The two admission floor suites supplied with the task (`Hook.protected.t.sol`,
  `Token.protected.t.sol`) were run from `test/scratch` against the built creation code with
  `IMD_HOOK_FLAGS=200`, `IMD_TOKEN_DECIMALS=18`, once with
  `IMD_POOL_MANAGER=0xE03A1074c86CFeDd5C142C4F04F1a1536e203543` (code etched) and once without:
  9/9 pass both times. With `IMD_HOOK_FLAGS=136` the hook suite fails in `setUp`, as it should.
- The Sepolia PoolManager address was confirmed to carry code through a public RPC on 2026-09-24.
- Not deployed, not fork-rehearsed on Sepolia, not audited.

## Not done here, and needed before release

- Independent adversarial review of the delta accounting in `afterSwap` and `_skim`, especially
  the `try`/`catch` fallbacks, against a malicious ERC-20 in a foreign pool and against routers that
  settle before swapping.
- A Sepolia fork rehearsal with the real PoolManager and a real router (Universal Router / v4
  PositionManager) on both liquidity shapes.
- Gas profiling of `afterSwap` on the deferred path.
- Custody and rotation plan for the updater key.
