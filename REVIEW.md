# Independent review — Bazaar marketplace launch

Scope: `src/BazaarToken.sol`, `src/Royalties.sol`, `src/RoyaltyRegistry.sol`,
`src/BazaarMarketplace.sol`, the vendored Solady sources they use, and the launch shape
(constructor arguments, privileged beneficiaries, dependency order). Method: line-by-line read
against the threat model below, then targeted tests for every concern that survived the read.
Tests passing is evidence, not proof; this section records what was looked for, what was found,
and what remains.

**Verdict:** no open findings of high or medium severity. Six low/informational items are either
fixed in the delivered code or accepted and documented. A funded mainnet release should still get
a separate adversarial review by a contributor who did not write this code.

---

## Threat model

| Actor | Capability | Goal |
| --- | --- | --- |
| Malicious collection | Arbitrary code in `transferFrom` / `ownerOf`: reenter, revert, lie, burn gas | Steal or freeze tokens custodied for *other* listings; drain escrowed ETH; corrupt another collection's oracle |
| Malicious counterparty | Any EOA or contract as seller, buyer, offerer, royalty receiver | Take ETH or tokens they did not pay for; fill in the creation block; cancel what is not theirs |
| Compromised `$owner` | Fee recipient; controls the royalty implementation | Extract more than 0.5% + 5% per trade; touch custodied assets |
| Factory | `msg.sender` during construction | End up holding a role (it cannot exercise one) |

Assets: custodied ERC-721s, escrowed offer ETH, the launch token supply, oracle integrity.

## Invariants checked

1. `address(marketplace).balance == escrowedOfferEth` after every action (absent forced ETH).
   Enforced by construction (`_settle` disburses exactly `price`; only `msg.value == price` and
   offer escrow ever fund a payout) and asserted in every marketplace and adversarial test.
2. A token in custody has exactly one active listing (`listingIdOf`) and one key in the floor
   index; both are cleared together in `_removeListing`.
3. `fee + royalty + proceeds == price`, `fee == price * 50 / 10_000`, `royalty <= price * 500 / 10_000`.
   Fuzzed over `price ∈ [1, 2^96)` and `bps ∈ [0, 500]`.
4. Nothing is fillable in its creation block; everything is fillable one block later.
5. Constructors never read `msg.sender`; every privilege resolves to a constructor argument.
6. No `DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT` in any runtime; runtimes under 24,576 bytes.

## Findings

### F-1 (Low, fixed) — A silently no-op `transferFrom` could take a buyer's ETH
A collection whose `transferFrom` returns without moving anything would, under plain CEI, let the
marketplace pay the seller while the buyer receives nothing. Fix: after every delivery the
marketplace requires `ownerOf(tokenId) == recipient` and reverts with `DeliveryFailed` otherwise;
after every custody pull it requires `ownerOf == marketplace` (`CustodyNotReceived`).
A collection that also lies in `ownerOf` can still defraud *its own* buyers, which no marketplace
can prevent, but it cannot reach anyone else's assets.
Test: `test_lyingCollection_silentNoOpTransfer_buyerIsProtected`.

### F-2 (Low, fixed) — A custodied token could be presented to `acceptOffer`
For an honest ERC-721 the transfer would fail (the marketplace is the owner), but a lying
collection could claim the caller owns a token that is in custody and the marketplace would then
move "its" token to the offerer. Fix: `acceptOffer` reverts with `TokenInCustody` when
`listingIdOf[collection][tokenId] != 0`, so the marketplace is never the vehicle.
Test: `test_lyingCollection_cannotUseCustodiedTokenToFillAnOffer`.

### F-3 (Low, fixed) — Royalty bound depended entirely on `Royalties`
`Royalties` is immutable in the marketplace and hardcodes the 5% ceiling, but a defensive
re-check costs one multiplication. Fix: `_settle` reverts with `RoyaltyTooHigh` if the returned
amount exceeds `price * 500 / 10_000`, so even a hypothetically wrong `Royalties` deployment
cannot push a royalty above 5%.

### F-4 (Low, fixed) — Setting a codeless royalty implementation would brick every sale
`Royalties.royaltyInfo` ABI-decodes the implementation's return data; an EOA or a typo address
would make every sale revert until replaced. Fix: `setImplementation` rejects any non-zero
address without code (`ImplementationNotAContract`). Zero is allowed and means "off".
Test: `test_setImplementation_rejectsAddressWithoutCode`.

### F-5 (Informational, accepted) — `$owner` can halt sales through the royalty implementation
A reverting or gas-exhausting implementation blocks all sales. This is an owner-only lever with
no extraction potential (the 5% cap holds regardless), so it is documented as an operational
responsibility rather than mitigated with a gas-capped call, which would break legitimate
implementations. `$owner` should be a multisig.

### F-6 (Informational, accepted) — Push settlement lets a recipient block their own trade
A seller, royalty receiver or the fee recipient that rejects ETH makes that trade revert. For a
seller or offerer this only hurts themselves; a rejecting royalty receiver is fixed by `$owner`
via the registry; a rejecting fee recipient would halt everything, so `$owner` must accept ETH.
The alternative (pull payments) is excluded by the requirements and would reintroduce a claims
ledger. Tests: `test_sellerRejectingEth_*`, `test_royaltyReceiverRejectingEth_*`,
`test_offererRejectingEth_*`, `test_feeRecipientRejectingEth_blocksEveryTrade`.

### Not findings (checked and rejected)

- **Reentrancy through transfer hooks or ETH pushes.** Every entry point is `nonReentrant`;
  reads are `STATICCALL`s. Verified against all six entry points with bubbled and swallowed
  nested calls (`test_everyEntryPointIsGuardedAgainstReentrancy` and companions).
- **Cross-collection contamination.** The only state shared across collections is the two id
  counters and `escrowedOfferEth`, none of which a collection can influence except through its
  own bounded trades. Oracle rings and floor trees are keyed per collection.
- **Wash trading the oracle.** Possible at the cost of 0.5% per trade plus gas; the oracle is
  documented as raw market data, not a manipulation-resistant price. A self-buy of one's own
  listing is rejected (`SelfTrade`), which removes only the trivial case.
- **Overflow in oracle sums.** `Bucket.sum` is `uint128`, prices are capped at `2^96 - 1`; checked
  arithmetic would need 2^32 sales in one five-minute bucket to revert.
- **Red-black tree key collisions.** Keys are `(price << 32) | listingId` with unique ids, so two
  listings never share a key and equal prices order by age. Keys stay under 2^128, one slot each.
- **Storage growth.** Removed tree nodes are compacted by Solady; rings are fixed size.
- **Factory as owner.** `Royalties` and `RoyaltyRegistry` initialise ownership from the
  argument; the marketplace has no owner. `test_privilegesGoToOwnerNotToTheFactory`.
- **Token surface.** Solady ERC-20 with `_mint` in the constructor only; no `mint`, owner, proxy
  or `SELFDESTRUCT`. The protected floor suite passes against the actual creation code.

## Residual risks

- Any collection can defraud people who choose to trade *that* collection; the marketplace is
  neutral infrastructure and does not vet collections.
- Stuck listings (collection begins reverting) can pin that collection's floor indefinitely.
- No emergency controls exist by design; a bug means a new deployment and users migrating.
- One-block maturity is not MEV protection.

## Recommendation

Proceed to the manifest node with `Royalties` first and `BazaarMarketplace` second. Before any
deployment holding real value, commission an independent adversarial review with emphasis on
the delivery-check assumptions (F-1, F-2) and the Solady `RedBlackTreeLib` integration.
