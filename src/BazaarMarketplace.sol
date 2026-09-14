// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {RedBlackTreeLib} from "solady/utils/RedBlackTreeLib.sol";
import {IERC721Minimal} from "./interfaces/IERC721Minimal.sol";
import {IRoyalties} from "./interfaces/IRoyalties.sol";

/// @notice Bazaar: a fully on-chain, custodial marketplace for any ERC-721.
///
/// Actions
///   list         The seller transfers the token into custody and names an ETH price.
///   cancelListing The seller takes the token back.
///   buy          A buyer pays exactly the price; the token and the ETH are pushed on the spot.
///   makeOffer    ETH escrowed here as a standing bid for *any* token of one collection.
///   cancelOffer  The offerer takes the ETH back.
///   acceptOffer  A token holder fills a standing bid with a token they hold in their wallet.
///
/// Settlement is push-only: the buyer receives the token, the seller the proceeds, `feeRecipient`
/// the 0.5% protocol fee and the royalty receiver (if any) their share, all inside the same call.
/// Nothing is left to claim later; the only ETH ever held here is the escrow of open offers.
///
/// Every listing and every offer must mature for one block before it can be filled, so a fill
/// can never be bundled into the block that created what it fills.
///
/// Adversarial collections. Any ERC-721 may reenter, revert, or lie. The contract follows
/// checks-effects-interactions, guards every state-changing entry point against reentrancy,
/// touches exactly one listing or offer per call, and never lets one collection's behaviour reach
/// another's state. A misbehaving collection can only make its own trades fail.
///
/// Oracle. Per collection this contract keeps the floor (lowest active ask, exact, maintained in
/// a red-black tree) and rolling average sale prices over roughly 1 hour, 1 day and 1 week
/// (bucketed rings, see `averagePrice*`). Floor and averages are raw market data, not
/// manipulation-resistant prices: anyone can list at any price, and wash trades cost only the fee.
contract BazaarMarketplace is ReentrancyGuard {
    using RedBlackTreeLib for RedBlackTreeLib.Tree;
    using RedBlackTreeLib for bytes32;

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Basis-point denominator.
    uint256 public constant BPS = 10_000;

    /// @notice Protocol fee on every trade: 0.5% of the price, paid to `feeRecipient`.
    uint256 public constant PROTOCOL_FEE_BPS = 50;

    /// @notice Defensive mirror of the bound hardcoded in `Royalties`.
    uint256 public constant MAX_ROYALTY_BPS = 500;

    /// @notice Blocks a listing or offer must age before it can be filled.
    uint256 public constant MATURITY_BLOCKS = 1;

    /// @notice Largest price or offer accepted, in wei (about 7.9e10 ETH).
    uint256 public constant MAX_PRICE = type(uint96).max;

    /// @dev Ids are packed into the floor index next to the price; see `_floorKey`.
    uint256 internal constant _MAX_ID = type(uint32).max;

    /// @notice Oracle ring geometry: bucket length and bucket count per window.
    uint256 public constant HOUR_BUCKET_SECONDS = 5 minutes;
    uint256 public constant HOUR_BUCKET_COUNT = 12;
    uint256 public constant DAY_BUCKET_SECONDS = 1 hours;
    uint256 public constant DAY_BUCKET_COUNT = 24;
    uint256 public constant WEEK_BUCKET_SECONDS = 6 hours;
    uint256 public constant WEEK_BUCKET_COUNT = 28;

    /*//////////////////////////////////////////////////////////////
                                  TYPES
    //////////////////////////////////////////////////////////////*/

    struct Listing {
        address seller;
        uint64 createdBlock;
        address collection;
        uint96 price;
        uint256 tokenId;
    }

    struct Offer {
        address offerer;
        uint64 createdBlock;
        address collection;
        uint96 amount;
    }

    /// @dev One ring slot: which epoch it belongs to, how many sales, and their total price.
    struct Bucket {
        uint64 epoch;
        uint64 count;
        uint128 sum;
    }

    struct SaleSnapshot {
        uint128 price;
        uint64 timestamp;
        uint64 blockNumber;
    }

    /*//////////////////////////////////////////////////////////////
                                IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Receives the protocol fee (`$owner` in the launch manifest).
    address public immutable feeRecipient;

    /// @notice Royalty policy (`$contract:Royalties` in the launch manifest).
    IRoyalties public immutable royalties;

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Next listing id; ids start at 1 so 0 always means "none".
    uint256 public nextListingId = 1;

    /// @notice Next offer id; ids start at 1 so 0 always means "none".
    uint256 public nextOfferId = 1;

    /// @notice Sum of every open offer. Always equals this contract's balance, absent forced ETH.
    uint256 public escrowedOfferEth;

    mapping(uint256 listingId => Listing) internal _listings;
    mapping(uint256 offerId => Offer) internal _offers;

    /// @notice Active listing id for a token in custody, or 0.
    mapping(address collection => mapping(uint256 tokenId => uint256 listingId)) public listingIdOf;

    /// @dev Ordered set of `_floorKey(price, listingId)` per collection; `first()` is the floor.
    mapping(address collection => RedBlackTreeLib.Tree) internal _floorIndex;

    mapping(address collection => mapping(uint256 slot => Bucket)) internal _hourRing;
    mapping(address collection => mapping(uint256 slot => Bucket)) internal _dayRing;
    mapping(address collection => mapping(uint256 slot => Bucket)) internal _weekRing;

    /// @notice Most recent sale per collection.
    mapping(address collection => SaleSnapshot) public lastSale;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event Listed(
        uint256 indexed listingId,
        address indexed collection,
        uint256 indexed tokenId,
        address seller,
        uint256 price,
        uint256 createdBlock
    );
    event ListingCancelled(
        uint256 indexed listingId, address indexed collection, uint256 indexed tokenId, address seller
    );
    event Bought(
        uint256 indexed listingId,
        address indexed collection,
        uint256 indexed tokenId,
        address seller,
        address buyer,
        uint256 price
    );
    event OfferMade(
        uint256 indexed offerId,
        address indexed collection,
        address indexed offerer,
        uint256 amount,
        uint256 createdBlock
    );
    event OfferCancelled(uint256 indexed offerId, address indexed collection, address indexed offerer, uint256 amount);
    event OfferAccepted(
        uint256 indexed offerId,
        address indexed collection,
        uint256 indexed tokenId,
        address seller,
        address offerer,
        uint256 amount
    );
    event ProtocolFeePaid(
        address indexed collection, uint256 indexed tokenId, address indexed recipient, uint256 amount
    );
    event RoyaltyPaid(address indexed collection, uint256 indexed tokenId, address indexed receiver, uint256 amount);
    event OracleSaleRecorded(address indexed collection, uint256 indexed tokenId, uint256 price, uint256 timestamp);
    event OracleFloorUpdated(address indexed collection, uint256 floorPrice, uint256 floorListingId);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error ZeroAddress();
    error NotAContract(address account);
    error InvalidPrice(uint256 price);
    error IdOverflow();
    error AlreadyListed(address collection, uint256 tokenId);
    error ListingNotFound(uint256 listingId);
    error NotSeller();
    error NotMatured(uint256 createdBlock);
    error IncorrectPayment(uint256 expected, uint256 actual);
    error SelfTrade();
    error OfferNotFound(uint256 offerId);
    error NotOfferer();
    error NotTokenOwner();
    error TokenInCustody(address collection, uint256 tokenId);
    error CustodyNotReceived(address collection, uint256 tokenId);
    error DeliveryFailed(address collection, uint256 tokenId);
    error RoyaltyTooHigh(uint256 royaltyAmount, uint256 maxRoyaltyAmount);

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param feeRecipient_ Payout wallet for the protocol fee (`$owner`).
    /// @param royalties_ The deployed `Royalties` contract (`$contract:Royalties`).
    /// @dev Neither argument is ever `msg.sender`: the factory constructs this contract.
    constructor(address feeRecipient_, address royalties_) {
        if (feeRecipient_ == address(0) || royalties_ == address(0)) revert ZeroAddress();
        if (royalties_.code.length == 0) revert NotAContract(royalties_);
        feeRecipient = feeRecipient_;
        royalties = IRoyalties(royalties_);
    }

    /*//////////////////////////////////////////////////////////////
                                LISTINGS
    //////////////////////////////////////////////////////////////*/

    /// @notice List `tokenId` of `collection` for exactly `price` wei. The token moves into custody.
    /// @dev The caller must own the token and have approved this contract. Fillable from the next block.
    function list(address collection, uint256 tokenId, uint256 price)
        external
        nonReentrant
        returns (uint256 listingId)
    {
        if (price == 0 || price > MAX_PRICE) revert InvalidPrice(price);
        if (listingIdOf[collection][tokenId] != 0) revert AlreadyListed(collection, tokenId);

        listingId = nextListingId++;
        if (listingId > _MAX_ID) revert IdOverflow();

        // Effects.
        _listings[listingId] = Listing({
            seller: msg.sender,
            createdBlock: uint64(block.number),
            collection: collection,
            price: uint96(price),
            tokenId: tokenId
        });
        listingIdOf[collection][tokenId] = listingId;
        _floorIndex[collection].insert(_floorKey(price, listingId));

        emit Listed(listingId, collection, tokenId, msg.sender, price, block.number);
        _emitFloor(collection);

        // Interactions: pull the token in, then confirm the collection agrees it is here.
        IERC721Minimal(collection).transferFrom(msg.sender, address(this), tokenId);
        if (IERC721Minimal(collection).ownerOf(tokenId) != address(this)) {
            revert CustodyNotReceived(collection, tokenId);
        }
    }

    /// @notice Cancel a listing and take the token back. Seller only; no maturity required.
    function cancelListing(uint256 listingId) external nonReentrant {
        Listing memory l = _listings[listingId];
        if (l.seller == address(0)) revert ListingNotFound(listingId);
        if (l.seller != msg.sender) revert NotSeller();

        // Effects.
        _removeListing(listingId, l);

        emit ListingCancelled(listingId, l.collection, l.tokenId, l.seller);
        _emitFloor(l.collection);

        // Interactions.
        IERC721Minimal(l.collection).transferFrom(address(this), l.seller, l.tokenId);
    }

    /// @notice Buy a matured listing by sending exactly its price.
    /// @dev Pushes the token to the buyer, then royalty, fee and proceeds, all in this call.
    function buy(uint256 listingId) external payable nonReentrant {
        Listing memory l = _listings[listingId];
        if (l.seller == address(0)) revert ListingNotFound(listingId);
        if (block.number < uint256(l.createdBlock) + MATURITY_BLOCKS) revert NotMatured(l.createdBlock);
        if (msg.value != l.price) revert IncorrectPayment(l.price, msg.value);
        if (msg.sender == l.seller) revert SelfTrade();

        // Effects.
        _removeListing(listingId, l);
        _recordSale(l.collection, l.tokenId, l.price);

        emit Bought(listingId, l.collection, l.tokenId, l.seller, msg.sender, l.price);
        _emitFloor(l.collection);

        // Interactions.
        IERC721Minimal(l.collection).transferFrom(address(this), msg.sender, l.tokenId);
        if (IERC721Minimal(l.collection).ownerOf(l.tokenId) != msg.sender) {
            revert DeliveryFailed(l.collection, l.tokenId);
        }
        _settle(l.collection, l.tokenId, l.price, l.seller);
    }

    /*//////////////////////////////////////////////////////////////
                                 OFFERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Escrow `msg.value` as a standing bid for any token of `collection`.
    /// @dev Fillable from the next block. The offerer can cancel at any time.
    function makeOffer(address collection) external payable nonReentrant returns (uint256 offerId) {
        if (msg.value == 0 || msg.value > MAX_PRICE) revert InvalidPrice(msg.value);
        if (collection.code.length == 0) revert NotAContract(collection);

        offerId = nextOfferId++;
        if (offerId > _MAX_ID) revert IdOverflow();

        // Effects.
        _offers[offerId] = Offer({
            offerer: msg.sender, createdBlock: uint64(block.number), collection: collection, amount: uint96(msg.value)
        });
        escrowedOfferEth += msg.value;

        emit OfferMade(offerId, collection, msg.sender, msg.value, block.number);
    }

    /// @notice Cancel an offer and take the escrowed ETH back. Offerer only.
    function cancelOffer(uint256 offerId) external nonReentrant {
        Offer memory o = _offers[offerId];
        if (o.offerer == address(0)) revert OfferNotFound(offerId);
        if (o.offerer != msg.sender) revert NotOfferer();

        // Effects.
        delete _offers[offerId];
        escrowedOfferEth -= o.amount;

        emit OfferCancelled(offerId, o.collection, o.offerer, o.amount);

        // Interactions.
        SafeTransferLib.safeTransferETH(o.offerer, o.amount);
    }

    /// @notice Fill a matured offer with `tokenId`, which the caller must hold in their own wallet.
    /// @dev The caller must have approved this contract for the token. A token that is in custody
    /// for a listing cannot be used; cancel the listing first.
    function acceptOffer(uint256 offerId, uint256 tokenId) external nonReentrant {
        Offer memory o = _offers[offerId];
        if (o.offerer == address(0)) revert OfferNotFound(offerId);
        if (block.number < uint256(o.createdBlock) + MATURITY_BLOCKS) revert NotMatured(o.createdBlock);
        if (msg.sender == o.offerer) revert SelfTrade();
        if (listingIdOf[o.collection][tokenId] != 0) revert TokenInCustody(o.collection, tokenId);
        if (IERC721Minimal(o.collection).ownerOf(tokenId) != msg.sender) revert NotTokenOwner();

        // Effects.
        delete _offers[offerId];
        escrowedOfferEth -= o.amount;
        _recordSale(o.collection, tokenId, o.amount);

        emit OfferAccepted(offerId, o.collection, tokenId, msg.sender, o.offerer, o.amount);

        // Interactions.
        IERC721Minimal(o.collection).transferFrom(msg.sender, o.offerer, tokenId);
        if (IERC721Minimal(o.collection).ownerOf(tokenId) != o.offerer) {
            revert DeliveryFailed(o.collection, tokenId);
        }
        _settle(o.collection, tokenId, o.amount, msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                                  VIEWS
    //////////////////////////////////////////////////////////////*/

    function getListing(uint256 listingId) external view returns (Listing memory) {
        return _listings[listingId];
    }

    function getOffer(uint256 offerId) external view returns (Offer memory) {
        return _offers[offerId];
    }

    /// @notice True when the listing exists and has matured.
    function isListingFillable(uint256 listingId) external view returns (bool) {
        Listing storage l = _listings[listingId];
        return l.seller != address(0) && block.number >= uint256(l.createdBlock) + MATURITY_BLOCKS;
    }

    /// @notice True when the offer exists and has matured.
    function isOfferFillable(uint256 offerId) external view returns (bool) {
        Offer storage o = _offers[offerId];
        return o.offerer != address(0) && block.number >= uint256(o.createdBlock) + MATURITY_BLOCKS;
    }

    /// @notice Fee and royalty a sale at `price` would pay, and what the seller would receive.
    function quote(address collection, uint256 tokenId, uint256 price)
        external
        view
        returns (uint256 protocolFee, address royaltyReceiver, uint256 royaltyAmount, uint256 sellerProceeds)
    {
        protocolFee = price * PROTOCOL_FEE_BPS / BPS;
        (royaltyReceiver, royaltyAmount) = royalties.royaltyInfo(collection, tokenId, price);
        sellerProceeds = price - protocolFee - royaltyAmount;
    }

    /*//////////////////////////////////////////////////////////////
                              ORACLE VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Lowest active ask for `collection`, or 0 when nothing is listed.
    function floorPrice(address collection) public view returns (uint256) {
        (, uint256 price) = floorListing(collection);
        return price;
    }

    /// @notice The listing currently at the floor, or `(0, 0)`.
    function floorListing(address collection) public view returns (uint256 listingId, uint256 price) {
        bytes32 ptr = _floorIndex[collection].first();
        if (ptr.isEmpty()) return (0, 0);
        uint256 key = ptr.value();
        return (key & _MAX_ID, key >> 32);
    }

    /// @notice Number of active listings for `collection`.
    function activeListingCount(address collection) external view returns (uint256) {
        return _floorIndex[collection].size();
    }

    /// @notice Average sale price over the trailing ~1 hour (12 buckets of 5 minutes).
    function averagePrice1h(address collection) public view returns (uint256 average, uint256 sales) {
        return _average(_hourRing[collection], HOUR_BUCKET_SECONDS, HOUR_BUCKET_COUNT);
    }

    /// @notice Average sale price over the trailing ~1 day (24 buckets of 1 hour).
    function averagePrice1d(address collection) public view returns (uint256 average, uint256 sales) {
        return _average(_dayRing[collection], DAY_BUCKET_SECONDS, DAY_BUCKET_COUNT);
    }

    /// @notice Average sale price over the trailing ~1 week (28 buckets of 6 hours).
    function averagePrice1w(address collection) public view returns (uint256 average, uint256 sales) {
        return _average(_weekRing[collection], WEEK_BUCKET_SECONDS, WEEK_BUCKET_COUNT);
    }

    /// @notice Every oracle reading for `collection` in one call.
    function priceOracle(address collection)
        external
        view
        returns (uint256 floor, uint256 average1h, uint256 average1d, uint256 average1w)
    {
        floor = floorPrice(collection);
        (average1h,) = averagePrice1h(collection);
        (average1d,) = averagePrice1d(collection);
        (average1w,) = averagePrice1w(collection);
    }

    /*//////////////////////////////////////////////////////////////
                                INTERNALS
    //////////////////////////////////////////////////////////////*/

    /// @dev Price in the high bits so the tree orders by price first, id second (ties are stable).
    /// Keys stay below 2^128, so every node fits in one storage slot.
    function _floorKey(uint256 price, uint256 listingId) internal pure returns (uint256) {
        return (price << 32) | listingId;
    }

    function _removeListing(uint256 listingId, Listing memory l) internal {
        delete _listings[listingId];
        delete listingIdOf[l.collection][l.tokenId];
        _floorIndex[l.collection].remove(_floorKey(l.price, listingId));
    }

    function _emitFloor(address collection) internal {
        (uint256 listingId, uint256 price) = floorListing(collection);
        emit OracleFloorUpdated(collection, price, listingId);
    }

    /// @dev Pays royalty, fee and proceeds for one sale. `price` is fully disbursed: what is not
    /// royalty or fee goes to the seller, so the contract's balance never drifts from escrow.
    function _settle(address collection, uint256 tokenId, uint256 price, address seller) internal {
        uint256 fee = price * PROTOCOL_FEE_BPS / BPS;
        (address royaltyReceiver, uint256 royalty) = royalties.royaltyInfo(collection, tokenId, price);
        uint256 maxRoyalty = price * MAX_ROYALTY_BPS / BPS;
        if (royalty > maxRoyalty) revert RoyaltyTooHigh(royalty, maxRoyalty);
        uint256 proceeds = price - fee - royalty;

        if (royalty != 0) {
            SafeTransferLib.safeTransferETH(royaltyReceiver, royalty);
            emit RoyaltyPaid(collection, tokenId, royaltyReceiver, royalty);
        }
        if (fee != 0) {
            SafeTransferLib.safeTransferETH(feeRecipient, fee);
            emit ProtocolFeePaid(collection, tokenId, feeRecipient, fee);
        }
        SafeTransferLib.safeTransferETH(seller, proceeds);
    }

    function _recordSale(address collection, uint256 tokenId, uint256 price) internal {
        _bump(_hourRing[collection], HOUR_BUCKET_SECONDS, HOUR_BUCKET_COUNT, price);
        _bump(_dayRing[collection], DAY_BUCKET_SECONDS, DAY_BUCKET_COUNT, price);
        _bump(_weekRing[collection], WEEK_BUCKET_SECONDS, WEEK_BUCKET_COUNT, price);
        lastSale[collection] = SaleSnapshot({
            price: uint128(price), timestamp: uint64(block.timestamp), blockNumber: uint64(block.number)
        });
        emit OracleSaleRecorded(collection, tokenId, price, block.timestamp);
    }

    /// @dev Adds one sale to the ring slot for the current epoch, recycling the slot if stale.
    function _bump(mapping(uint256 => Bucket) storage ring, uint256 bucketSeconds, uint256 bucketCount, uint256 price)
        internal
    {
        uint256 epoch = block.timestamp / bucketSeconds;
        Bucket storage b = ring[epoch % bucketCount];
        if (b.epoch != epoch) {
            b.epoch = uint64(epoch);
            b.count = 1;
            b.sum = uint128(price);
        } else {
            b.count += 1;
            b.sum += uint128(price);
        }
    }

    /// @dev Averages every live slot. A slot is live when its epoch is one of the last
    /// `bucketCount` epochs including the current one, so the window spans between
    /// `(bucketCount - 1) * bucketSeconds` and `bucketCount * bucketSeconds` seconds.
    function _average(mapping(uint256 => Bucket) storage ring, uint256 bucketSeconds, uint256 bucketCount)
        internal
        view
        returns (uint256 average, uint256 sales)
    {
        uint256 epoch = block.timestamp / bucketSeconds;
        uint256 oldestLive = epoch + 1 > bucketCount ? epoch + 1 - bucketCount : 0;
        uint256 sum;
        for (uint256 i; i < bucketCount; ++i) {
            Bucket storage b = ring[i];
            uint256 count = b.count;
            if (count != 0 && b.epoch >= oldestLive) {
                sum += b.sum;
                sales += count;
            }
        }
        average = sales == 0 ? 0 : sum / sales;
    }
}
