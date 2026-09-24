# Worker-pot keeper README

The keeper turns King-claim ETH into attested worker epochs. Solidity never calls `api.imd.fun`;
everything below happens off chain, and the only on-chain action is
`setEpoch(root, windowStart, windowEnd)` from the `updater` address
(`0x5b95A971B4583A5f011E9DA082acdD679b870D06` at deployment; `updater()` after any handoff).

## Contract rules the keeper works within

- Only `updater` can call `setEpoch`. `root != 0`, `windowStart < windowEnd`,
  `windowEnd > now`, `windowEnd - windowStart <= 90 days`. `windowStart` may be in the past
  (claims open immediately) or in the future.
- A new epoch can only open once the previous one's `windowEnd` has passed, even if fully claimed.
  Epoch IDs count up from 1.
- The epoch budget is `availableForNextEpoch()` at `setEpoch` time: the pot plus whatever the ended
  epoch left unclaimed. An empty budget reverts (`EmptyPot`). ETH arriving during an epoch waits
  for the next one. Nobody can sweep it.
- A claim must name the current epoch, arrive inside the window, carry a positive amount and a
  nonzero payee, verify against the root, be the payee's first claim in that epoch, and fit in
  `budget - paid`. Anyone may relay a claim; ETH always goes to the leaf's payee. A payee that
  refuses ETH makes that claim revert and leaves it claimable.
- Leaf: `keccak256(bytes.concat(keccak256(abi.encode(block.chainid, address(hook), epochId, payee, amount))))`
  with types `(uint256, address, uint256, address, uint256)`. Pairs hash as `keccak256(min || max)`;
  an unpaired node is promoted unchanged. Chain, contract and epoch binding stops replay in another
  deployment or epoch. `PvPadHook.leaf(epochId, payee, amount)` returns the leaf for the live
  contract.

## Recipe

1. **Sample workers.** `GET https://api.imd.fun/workers`. Fix an explicit UTC window and keep the
   raw response and a block/time snapshot. Eligible workers are those whose `lastHeartbeatAt` lies
   in the window. Decide inclusion, cutoff and weights *before* attestation.
2. **Map worker to payee.** For each eligible `tokenId`, call `ownerOf(tokenId)` on the worker
   collection `0x0000ec93127baa929e58e97dd0095a2bfb38ec1d` and/or use the Identity MD
   `/contributors` wallet mapping. The collection lives on mainnet: **Sepolia cannot read it**, so
   this mapping is an off-chain step for now and stays off chain until a future mainnet deploy.
   Resolve any disagreement between the two sources through the oracle policy; an API field alone is
   not a verified payable wallet. Reject zero or missing payees and duplicate worker IDs; aggregate
   several workers paying the same wallet into one leaf.
3. **Size the epoch.** Snapshot `currentEpoch() + 1`, the hook address, chain ID `11155111`,
   `availableForNextEpoch()` and the intended window. Produce integer-wei allocations whose sum is
   at most the budget. A simple starting policy: floor(budget / eligible count) each, remainder
   rolls forward. Weights are an operator decision the attestation covers.
4. **Build the tree.**
   `python3 scripts/merkle.py allocations.json --hook 0x… --epoch <id> --budget <wei> > epoch.json`
   Input: `[{"payee": "0x…", "amount": "<wei>"}, …]`. The tool refuses duplicates, zero payees,
   non-positive amounts and totals over budget, sorts leaves for a reproducible root, and emits every
   proof. It is standard-library Python and touches no network. Its unit tests
   (`python3 -m unittest discover -s scripts -p '*_test.py'`) pin the root and proofs to a vector that
   `test/MerkleVectors.t.sol` reproduces in Solidity.
5. **Attest.** Submit an Identity MD `oracle.request` with **panelSize 70, quorum 67, bool result**
   binding the snapshot, the mapping evidence, the allocations, chain ID, hook address, epoch ID,
   root, budget and window. Only an affirmative quorum authorises `setEpoch`. Retain the signed
   artifact. This repository ships no oracle client and invents no request schema: use the service's
   authenticated integration.
6. **Publish.** Re-check `currentEpoch`, the previous epoch's `windowEnd`, `availableForNextEpoch()`
   and the updater key immediately before sending; re-attest if anything material changed. Send
   `setEpoch(root, windowStart, windowEnd)`. Serialise updater submissions. Publish `epoch.json` and
   the retained evidence so payees can claim on their own and reviewers can reconstruct the decision.
7. **Failure modes.** A failed API call, unresolved identity, negative quorum or insufficient votes
   means no root is submitted; funds simply wait in the pot. A payee whose transfer reverts, or who
   misses `windowEnd`, is reassessed for the next attested epoch; nothing can be redirected on chain.
   If the budget printed by the tool is larger than the pot at send time (a claim from the previous
   epoch landed in between), the tree is still valid: claims past the budget simply fail with
   `InsufficientBudget` and are reassessed.

The updater is trusted to honour the attestation. The contract verifies the updater and the proof,
never the oracle's signature or the worker data. A compromised updater can publish a dishonest
future root for the pot's balance, so updater key custody and the two-step handoff are
consequential. It cannot touch swap fees, credits or claims.
