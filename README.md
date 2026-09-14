# Bazaar — a fully on-chain marketplace for any ERC-721

Bazaar is a custodial, push-settled marketplace for arbitrary ERC-721 collections, delivered as a
Sepolia `evm_project` launch: one fixed-supply launch token plus two application contracts deployed
by ProjectFactory with static constructor arguments only.

| Contract | Role | Constructor |
| --- | --- | --- |
| `BazaarToken` | Launch token. 1,000,000,000 BZR (10^27 minor units, 18 decimals) minted to its deployer. No admin, no mint, no proxy. | none |
| `Royalties` | Royalty policy. Delegates *who is owed what* to a swappable implementation; hardcodes that the answer is between 0% and 5% inclusive. | `(address owner)` → `$owner` |
| `BazaarMarketplace` | Listings, offers, settlement, 0.5% protocol fee, per-collection price oracle. No admin at all. | `(address feeRecipient, address royalties)` → `$owner`, `$contract:Royalties` |
| `RoyaltyRegistry` | *Optional.* Reference royalty implementation: a per-collection `(receiver, bps)` table. | `(address owner)` → `$owner` |

Everything is built and tested offline with Foundry. Solady and forge-std are vendored under
`lib/` as ordinary files (no submodules, no `forge install`).

- `forge build` · `forge test` · `forge fmt --check` — all pass with no network.
- 120 tests across six suites; see [Tests](#tests).
- [REVIEW.md](./REVIEW.md) holds the independent review: threat model, findings, residual risks.

---

## Architecture

```
                 list / cancelListing / buy                 makeOffer / cancelOffer / acceptOffer
  seller ──────────────────────────────▶ BazaarMarketplace ◀─────────────────────────── bidder
                                          │   │    │  ▲
              token custody (ERC-721) ◀───┘   │    │  └── STATICCALL royaltyInfo(collection, id, price)
              ETH pushed on settlement  ◀─────┘    │             │
              (seller, fee, royalty)               │             ▼
                                                   │        Royalties  ── STATICCALL ──▶ implementation
                                                   │        (owner-swappable impl, 0–5% hardcoded)
                                                   ▼
                                       per-collection oracle state
                                       floor (red-black tree) + 1h/1d/1w sale rings
```

### Custody and settlement

- **list(collection, tokenId, price)** — the seller must own the token and have approved the
  marketplace. The token is pulled into custody with `transferFrom`, and the marketplace then
  requires `ownerOf(tokenId) == marketplace`. Price must be in `[1, 2^96 - 1]` wei.
- **cancelListing(listingId)** — seller only, allowed at any time. Pushes the token back.
- **buy(listingId)** — `msg.value` must equal the price exactly. The marketplace pushes the token to
  the buyer, requires `ownerOf(tokenId) == buyer`, then pushes royalty, fee and proceeds. A seller
  cannot buy their own listing.
- **makeOffer(collection)** — `msg.value` is escrowed as a standing bid for *any* token of
  `collection`. The collection must have code.
- **cancelOffer(offerId)** — offerer only, allowed at any time. Pushes the ETH back.
- **acceptOffer(offerId, tokenId)** — the caller must hold `tokenId` in their own wallet (a token
  in custody for a listing must be cancelled first) and must have approved the marketplace. The
  token is pushed to the offerer, delivery is verified, then royalty, fee and proceeds are pushed.
  An offerer cannot accept their own offer.

Settlement is **push-only**. There is no claim, withdraw or sweep path. The only ETH the
marketplace ever holds is the escrow of open offers, and the contract exposes that number as
`escrowedOfferEth()`; tests assert `balance == escrowedOfferEth` after every action.

The marketplace has no owner, no pause, no upgrade and no rescue function. Its only privileged
inputs are the two immutables fixed at construction.

### One-block maturity

Every listing and every offer records `createdBlock`. `buy` and `acceptOffer` revert with
`NotMatured` unless `block.number >= createdBlock + 1`. A fill can never land in the block that
created what it fills. Cancellations are not subject to maturity. `isListingFillable` and
`isOfferFillable` expose the rule to front-ends.

### Handling hostile collections

Any ERC-721 may be malicious. The marketplace never trusts a collection beyond its own trade:

- **Checks-effects-interactions.** Listing, offer and oracle state are written before the first
  external call. A revert anywhere in the interaction phase undoes only that call's effects.
- **Reentrancy guard** (Solady `ReentrancyGuard`) on all six state-changing entry points. A
  transfer hook that reenters gets `Reentrancy()`; if the collection swallows that error the outer
  trade still completes and the nested call has had no effect.
- **Reads are STATICCALLs.** `ownerOf` and `royaltyInfo` are declared `view`, so a collection or a
  royalty implementation cannot mutate anything while the marketplace reads it.
- **One trade per call.** Every entry point touches exactly one listing or one offer. There is no
  batching, so a failure cannot take an unrelated trade down with it.
- **Value conservation.** `_settle` splits exactly the trade's price into royalty + fee + proceeds.
  No path sends ETH that was not either this call's `msg.value` or this offer's escrow.
- **Delivery checks.** After every transfer the marketplace asks the collection who owns the token
  and reverts if the answer is not the expected recipient. A collection that silently no-ops its
  transfers cannot take a buyer's ETH.
- **Per-collection oracle state.** A collection can only distort its own floor and averages.

What a hostile collection *can* do is make its own trades fail or lie about its own tokens; the
tests in `test/Adversarial.t.sol` show that in each case every other custodied token, every other
listing and all escrowed ETH stay exactly as they were.

---

## Fee flow

On every sale (a `buy` or an `acceptOffer`) at price `P`:

| Leg | Amount | Recipient | Event |
| --- | --- | --- | --- |
| Protocol fee | `P * 50 / 10_000` (0.5%, rounds down) | `feeRecipient` (`$owner`) | `ProtocolFeePaid` |
| Royalty | `Royalties.royaltyInfo(collection, tokenId, P)`; at most `P * 500 / 10_000` (5%) | receiver named by the royalty implementation | `RoyaltyPaid` (only if non-zero) |
| Proceeds | `P - fee - royalty` | seller | — |

Order inside one call: token delivery → royalty → fee → proceeds. All three ETH legs use Solady
`safeTransferETH` with full gas; if any recipient rejects ETH the trade reverts in full, including
the token delivery. Rounding is always in the seller's favour. A fee of zero (prices below 200
wei) is simply not sent.

Worked example, `P = 1 ETH`, royalty 5%: fee 0.005 ETH → `$owner`; royalty 0.05 ETH → receiver;
proceeds 0.945 ETH → seller. `quote(collection, tokenId, price)` returns the split without trading.

---

## Royalties

`Royalties` is deployed first and its address is baked into the marketplace as an immutable.

- **Default:** `implementation == address(0)`, `royaltyInfo` returns `(address(0), 0)` and makes
  no external call. Royalties are off until `$owner` sets an implementation.
- **Bound:** `MAX_ROYALTY_BPS = 500` is a constant. Whatever the implementation answers,
  `Royalties` reverts with `RoyaltyOutOfBounds(amount, max)` when `amount > salePrice * 500 / 10_000`,
  and with `RoyaltyReceiverMissing()` when a positive amount has no receiver. A zero amount is
  normalised to `(address(0), 0)`. Exactly 5% passes; 5% plus one wei reverts. The marketplace
  re-checks the same bound in `_settle` as a belt-and-braces guard.
- **Delegation:** a regular `STATICCALL` to `IRoyaltyImplementation.royaltyInfo(collection,
  tokenId, salePrice)`. Never `DELEGATECALL` (forbidden by the launch policy and unnecessary).
- **Ownership:** Solady `Ownable`, initialised from the constructor argument (`$owner`), never from
  `msg.sender`, because the factory is `msg.sender`.

### Swapping the royalty implementation

1. Deploy any contract implementing `IRoyaltyImplementation` — `RoyaltyRegistry` is the shipped
   reference (per-collection `(receiver, bps)`, owner-managed, itself capped at 500 bps). It can be
   deployed as an optional third launch contract with `$owner`, or later by hand.
2. From `$owner`, call `Royalties.setImplementation(newImplementation)`. The address must have
   code (or be zero to switch royalties off). `RoyaltyImplementationChanged(previous, next, by)`
   is emitted.
3. Configure the implementation, e.g. `RoyaltyRegistry.setCollectionRoyalty(collection, receiver, bps)`.
4. Verify with `BazaarMarketplace.quote(collection, tokenId, price)`.

Because the marketplace calls `Royalties` on every sale, a reverting or gas-exhausting
implementation blocks *all* sales until `$owner` swaps it out. Only `$owner` can put such a
contract in place, so this is an operational responsibility, not an attacker's lever.

---

## Price oracle

Per collection, updated on every listing, cancellation and sale, and readable at any time:

| View | Meaning |
| --- | --- |
| `floorPrice(collection)` / `floorListing(collection)` | Lowest active ask and the listing holding it. Exact: listings live in a Solady red-black tree keyed by `(price << 32) \| listingId`, so ties resolve to the older listing and removals promote the next ask in `O(log n)`. |
| `averagePrice1h(collection)` | Mean sale price and sale count over the trailing hour. |
| `averagePrice1d(collection)` | Same over the trailing day. |
| `averagePrice1w(collection)` | Same over the trailing week. |
| `priceOracle(collection)` | `(floor, avg1h, avg1d, avg1w)` in one call. |
| `lastSale(collection)` | `(price, timestamp, blockNumber)` of the most recent sale. |
| `activeListingCount(collection)` | Size of the floor index. |

### Window geometry

Averages are simple moving averages over bucketed rings. Each sale adds `(price, 1)` to the
bucket for the current epoch of each ring; a bucket whose stored epoch is stale is recycled on
write. Reading sums every bucket whose epoch is within the last `N` epochs, current one included.

| Window | Bucket length | Buckets | Effective span |
| --- | --- | --- | --- |
| 1 hour | 5 minutes | 12 | 55–60 minutes |
| 1 day | 1 hour | 24 | 23–24 hours |
| 1 week | 6 hours | 28 | 6.75–7 days |

So "1 hour" means *between 55 and 60 minutes* depending on where the current bucket sits; the
tests in `test/Oracle.t.sol` pin the exact roll-off moments. Writes cost three bucket updates
per sale; reads iterate at most 12/24/28 slots and are `view`.

Both buys and accepted offers are sales. Listings and cancellations move the floor but never the
averages.

### What the oracle is not

The floor is the lowest ask, full stop: anyone can list at 1 wei. The averages count real
settled trades, but wash trading costs only the 0.5% fee plus gas. Treat these as raw market data
for indexers and UIs, not as manipulation-resistant prices for lending or liquidation.

---

## Events

| Event | Indexed | Data | Emitted by |
| --- | --- | --- | --- |
| `Listed` | `listingId`, `collection`, `tokenId` | `seller`, `price`, `createdBlock` | `list` |
| `ListingCancelled` | `listingId`, `collection`, `tokenId` | `seller` | `cancelListing` |
| `Bought` | `listingId`, `collection`, `tokenId` | `seller`, `buyer`, `price` | `buy` |
| `OfferMade` | `offerId`, `collection`, `offerer` | `amount`, `createdBlock` | `makeOffer` |
| `OfferCancelled` | `offerId`, `collection`, `offerer` | `amount` | `cancelOffer` |
| `OfferAccepted` | `offerId`, `collection`, `tokenId` | `seller`, `offerer`, `amount` | `acceptOffer` |
| `ProtocolFeePaid` | `collection`, `tokenId`, `recipient` | `amount` | every sale with a non-zero fee |
| `RoyaltyPaid` | `collection`, `tokenId`, `receiver` | `amount` | every sale with a non-zero royalty |
| `OracleSaleRecorded` | `collection`, `tokenId` | `price`, `timestamp` | every sale |
| `OracleFloorUpdated` | `collection` | `floorPrice`, `floorListingId` | every list, cancel and buy (`0, 0` when the book empties) |
| `RoyaltyImplementationChanged` (Royalties) | `previousImplementation`, `newImplementation`, `by` | — | `setImplementation` |
| `CollectionRoyaltySet` (RoyaltyRegistry) | `collection`, `receiver`, `by` | `bps` | `setCollectionRoyalty` |

An indexer can rebuild every listing, offer, trade, fee and royalty from these alone; the
`Oracle*` events let it mirror the on-chain readings without calling views.

---

## Launch: deployment parameters

Follow the evm-project-launch reference. The manifest node writes `launch.json`; the values it
needs are:

| Field | Value |
| --- | --- |
| kind | `evm_project` |
| token | `src/BazaarToken.sol:BazaarToken` — no constructor arguments, 18 decimals, mints 10^27 to `msg.sender` (the factory) |
| contracts (in order) | 1. `Royalties` ← `["$owner"]`  2. `BazaarMarketplace` ← `["$owner", "$contract:Royalties"]`  3. *(optional)* `RoyaltyRegistry` ← `["$owner"]` |
| foundry | `solc 0.8.26`, `evm_version = cancun`, `optimizer_runs = 1000`, `bytecode_hash = "none"`, `via_ir = false` |

Illustrative shape (the manifest node owns the exact schema):

```json
{
  "kind": "evm_project",
  "token": { "contract": "src/BazaarToken.sol:BazaarToken" },
  "contracts": [
    { "name": "Royalties",         "contract": "src/Royalties.sol:Royalties",                 "constructorArgs": ["$owner"] },
    { "name": "BazaarMarketplace", "contract": "src/BazaarMarketplace.sol:BazaarMarketplace", "constructorArgs": ["$owner", "$contract:Royalties"] }
  ]
}
```

Policy compliance, checked by `test/Launch.t.sol` and rehearsed against the protected floor suite:

- Constructors are `nonpayable`, take only `address` arguments, and never read `msg.sender`.
  `$owner` becomes the fee recipient and the `Royalties` owner; the factory holds no role.
- No initialisation call is needed: the marketplace and `Royalties` are usable the moment they
  exist. The registry is optional and wired in later by `$owner`.
- Runtimes are ~11.7 KB (marketplace), ~1.8 KB (Royalties), ~2.2 KB (token); none contains
  `DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT`. Application constructors do not touch the token.
- Pool parameters (native ETH pair, fee 3000, tick spacing 60, initial sqrt price) come from
  policy and are not a valuation claim.

Contributors do not broadcast. Nothing in this repository signs or sends transactions; the
admitted release is executed by the deployer through ProjectFactory.

---

## Operational responsibilities (`$owner`)

- **Be able to receive plain ETH.** The fee is pushed to `$owner` on every sale; if `$owner`
  rejects ETH every trade reverts (`test_feeRecipientRejectingEth_blocksEveryTrade`). Use an EOA
  or a contract with a payable `receive`. A multisig is recommended: `$owner` also controls the
  royalty implementation.
- **Royalty implementation.** Set it only to audited code; a reverting or gas-hungry
  implementation halts all sales until replaced. Royalty receivers must accept ETH, otherwise
  sales of that collection revert until the receiver is changed.
- **No emergency levers.** The marketplace cannot be paused, upgraded or drained by anyone. A
  release is final; fixes mean a new deployment.

## Assumptions and known limits

- **Transfers use `transferFrom`, not `safeTransferFrom`.** Buyers and offerers that are contracts
  must be able to hold ERC-721s; the marketplace does not call `onERC721Received`. This removes an
  entire class of receiver-hook reentrancy and keeps settlement from depending on a hook.
- **Direct transfers are not recoverable.** A token sent straight to the marketplace with
  `transferFrom` (bypassing `list`) is stranded; there is deliberately no admin rescue. A
  `safeTransferFrom` to the marketplace reverts, which protects most wallets.
- **Stuck listings.** If a collection starts reverting on transfer after a token is listed, that
  listing can be neither bought nor cancelled until the collection behaves again, and it keeps
  its place in that collection's floor index.
- **Operators cannot sell for owners.** `acceptOffer` requires `ownerOf(tokenId) == msg.sender`
  so proceeds always go to the owner of record.
- **Maturity is one block** (~12 s on Sepolia). It prevents same-block create-and-fill; it is not
  a front-running defence.
- **Forced ETH** (via `SELFDESTRUCT` from another contract) makes `balance > escrowedOfferEth`; it
  is unreachable and harmless.
- **Ids are capped at 2^32 - 1** to keep floor-index keys in one storage slot; a marketplace with
  four billion listings would stop accepting new ones.
- **Collections outside the ERC-721 letter** (e.g. `transferFrom` returning `bool`) work as long
  as `ownerOf` and `transferFrom` behave; there is no ERC-165 gate.
- Tests are not an audit. See [REVIEW.md](./REVIEW.md) for the review performed here and the
  recommendation for an independent adversarial pass before any funded release.

---

## Tests

```
forge test
```

| Suite | Covers |
| --- | --- |
| `test/BazaarMarketplace.t.sol` (54) | Every action's success and failure paths, the one-block maturity rule for listings and offers, exact payment, self-trade, fee and royalty math (fixed cases plus a fuzz over price and royalty bps proving `fee + royalty + proceeds == price`), event emission and ordering. |
| `test/Oracle.t.sol` (17) | Floor across list/cancel/buy, ties, per-collection isolation, 25-deep books, `OracleFloorUpdated` on every update; averages roll-off at the 1h/1d/1w boundaries, bucket recycling, accumulation within a bucket, accepted offers counted, listings ignored, fuzzed mean. |
| `test/Adversarial.t.sol` (16) | A reentrant ERC-721 attacking each of the six entry points from its transfer hook (bubbled and swallowed variants); an ERC-721 that reverts on transfer or on `ownerOf`; a collection with no-op or unauthenticated transfers and pinned `ownerOf`; sellers, offerers, royalty receivers and a fee recipient that reject ETH; the escrow invariant across mixed activity. In every case the honest listing, honest offer and escrow are shown untouched. |
| `test/Royalties.t.sol` (23) | Defaults, owner-only swap, code check, exactly 5% passes, 5% + 1 wei reverts, receiver required, zero normalised, implementation revert propagates, fuzzed in-bound and out-of-bound bps; the reference registry. |
| `test/BazaarToken.t.sol` (5) | Supply, decimals, metadata, exact transfers, no admin surface, permit domain. |
| `test/Launch.t.sol` (5) | Factory-as-`msg.sender` deployment in manifest order, supply untouched by constructors, privileges to `$owner` not the factory, runtime size and forbidden-opcode scan. |

The protected launch-floor suite (`Token.protected.t.sol`, `Project.protected.t.sol`) was also run
locally against the real creation code with the verifier's environment contract (CREATE2 from a
stand-in factory, chain id 11155111, expected supply 10^27) and passes 8/8.

## Repository layout

```
foundry.toml            solc 0.8.26, cancun, bytecode_hash none, ffi off, no fs permissions
remappings.txt          forge-std/ and solady/ → lib/
src/
  BazaarToken.sol       launch token
  Royalties.sol         bounded, owner-swappable royalty policy
  RoyaltyRegistry.sol   optional reference implementation
  BazaarMarketplace.sol marketplace + oracle
  interfaces/           IERC721Minimal, IRoyalties, IRoyaltyImplementation
test/                   suites above, BaseTest fixture, mocks/ (honest, reentrant, reverting, lying ERC-721s, ETH rejecter, steerable royalty impl)
lib/solady              v0.1.26 — ERC20, ERC721, Ownable, ReentrancyGuard, SafeTransferLib, RedBlackTreeLib (MIT)
lib/forge-std           v1.16.1 — src/ only (Apache-2.0 OR MIT)
REVIEW.md               independent review notes
```
