// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./BaseTest.sol";
import {BazaarMarketplace} from "../src/BazaarMarketplace.sol";
import {ERC721} from "solady/tokens/ERC721.sol";

/// @notice Every action, its failure modes, the one-block maturity rule, and fee/royalty math.
contract BazaarMarketplaceTest is BaseTest {
    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    function test_constructor_storesImmutables() public view {
        assertEq(market.feeRecipient(), owner);
        assertEq(address(market.royalties()), address(royalties));
        assertEq(market.nextListingId(), 1);
        assertEq(market.nextOfferId(), 1);
        assertEq(market.PROTOCOL_FEE_BPS(), 50);
        assertEq(market.MATURITY_BLOCKS(), 1);
    }

    function test_constructor_revertsOnZeroFeeRecipient() public {
        vm.expectRevert(BazaarMarketplace.ZeroAddress.selector);
        new BazaarMarketplace(address(0), address(royalties));
    }

    function test_constructor_revertsOnZeroRoyalties() public {
        vm.expectRevert(BazaarMarketplace.ZeroAddress.selector);
        new BazaarMarketplace(owner, address(0));
    }

    function test_constructor_revertsWhenRoyaltiesIsNotAContract() public {
        address eoa = makeAddr("eoa");
        vm.expectRevert(abi.encodeWithSelector(BazaarMarketplace.NotAContract.selector, eoa));
        new BazaarMarketplace(owner, eoa);
    }

    function test_marketplaceRejectsPlainEth() public {
        (bool ok,) = address(market).call{value: 1 ether}("");
        assertFalse(ok, "marketplace must not accept stray ETH");
    }

    /*//////////////////////////////////////////////////////////////
                                  LIST
    //////////////////////////////////////////////////////////////*/

    function test_list_takesCustodyAndRecordsListing() public {
        uint256 id = _mintAndList(alice, 1, 1 ether);

        assertEq(id, 1);
        assertEq(nft.ownerOf(1), address(market), "token not in custody");
        BazaarMarketplace.Listing memory l = market.getListing(id);
        assertEq(l.seller, alice);
        assertEq(l.collection, address(nft));
        assertEq(l.tokenId, 1);
        assertEq(l.price, 1 ether);
        assertEq(l.createdBlock, B0);
        assertEq(market.listingIdOf(address(nft), 1), id);
        assertEq(market.nextListingId(), 2);
        assertEq(market.floorPrice(address(nft)), 1 ether);
        assertEq(market.activeListingCount(address(nft)), 1);
        assertFalse(market.isListingFillable(id), "must not be fillable in its own block");
        _assertEscrowInvariant();
    }

    function test_list_emitsEvents() public {
        nft.mint(alice, 1);
        vm.startPrank(alice);
        nft.setApprovalForAll(address(market), true);
        vm.expectEmit(true, true, true, true, address(market));
        emit BazaarMarketplace.Listed(1, address(nft), 1, alice, 1 ether, B0);
        vm.expectEmit(true, true, true, true, address(market));
        emit BazaarMarketplace.OracleFloorUpdated(address(nft), 1 ether, 1);
        market.list(address(nft), 1, 1 ether);
        vm.stopPrank();
    }

    function test_list_acceptsMaxPrice() public {
        uint256 id = _mintAndList(alice, 1, market.MAX_PRICE());
        assertEq(market.getListing(id).price, market.MAX_PRICE());
        assertEq(market.floorPrice(address(nft)), market.MAX_PRICE());
    }

    function test_list_revertsOnZeroPrice() public {
        nft.mint(alice, 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BazaarMarketplace.InvalidPrice.selector, 0));
        market.list(address(nft), 1, 0);
    }

    function test_list_revertsAboveMaxPrice() public {
        uint256 tooHigh = market.MAX_PRICE() + 1;
        nft.mint(alice, 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BazaarMarketplace.InvalidPrice.selector, tooHigh));
        market.list(address(nft), 1, tooHigh);
    }

    function test_list_revertsWithoutApproval() public {
        nft.mint(alice, 1);
        vm.prank(alice);
        vm.expectRevert(ERC721.NotOwnerNorApproved.selector);
        market.list(address(nft), 1, 1 ether);
    }

    function test_list_revertsWhenCallerIsNotTheOwner() public {
        nft.mint(alice, 1);
        vm.startPrank(bob);
        nft.setApprovalForAll(address(market), true);
        vm.expectRevert(ERC721.TransferFromIncorrectOwner.selector);
        market.list(address(nft), 1, 1 ether);
        vm.stopPrank();
    }

    function test_list_revertsWhenAlreadyListed() public {
        _mintAndList(alice, 1, 1 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BazaarMarketplace.AlreadyListed.selector, address(nft), 1));
        market.list(address(nft), 1, 2 ether);
    }

    function test_list_revertsForCollectionWithoutCode() public {
        vm.prank(alice);
        vm.expectRevert();
        market.list(makeAddr("not-a-collection"), 1, 1 ether);
    }

    /*//////////////////////////////////////////////////////////////
                              CANCEL LISTING
    //////////////////////////////////////////////////////////////*/

    function test_cancelListing_returnsTokenAndClearsState() public {
        uint256 id = _mintAndList(alice, 1, 1 ether);

        vm.prank(alice);
        vm.expectEmit(true, true, true, true, address(market));
        emit BazaarMarketplace.ListingCancelled(id, address(nft), 1, alice);
        vm.expectEmit(true, true, true, true, address(market));
        emit BazaarMarketplace.OracleFloorUpdated(address(nft), 0, 0);
        market.cancelListing(id);

        assertEq(nft.ownerOf(1), alice, "token not returned");
        assertEq(market.getListing(id).seller, address(0));
        assertEq(market.listingIdOf(address(nft), 1), 0);
        assertEq(market.floorPrice(address(nft)), 0);
        assertEq(market.activeListingCount(address(nft)), 0);
        _assertEscrowInvariant();
    }

    function test_cancelListing_allowedBeforeMaturity() public {
        uint256 id = _mintAndList(alice, 1, 1 ether);
        vm.prank(alice);
        market.cancelListing(id);
        assertEq(nft.ownerOf(1), alice);
    }

    function test_cancelListing_revertsForNonSeller() public {
        uint256 id = _mintAndList(alice, 1, 1 ether);
        vm.prank(bob);
        vm.expectRevert(BazaarMarketplace.NotSeller.selector);
        market.cancelListing(id);
    }

    function test_cancelListing_revertsForUnknownListing() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BazaarMarketplace.ListingNotFound.selector, 42));
        market.cancelListing(42);
    }

    function test_cancelListing_thenBuyReverts() public {
        uint256 id = _mintAndList(alice, 1, 1 ether);
        vm.prank(alice);
        market.cancelListing(id);
        _mature();
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(BazaarMarketplace.ListingNotFound.selector, id));
        market.buy{value: 1 ether}(id);
    }

    function test_cancelledTokenCanBeRelisted() public {
        uint256 id = _mintAndList(alice, 1, 1 ether);
        vm.prank(alice);
        market.cancelListing(id);
        uint256 id2 = _list(alice, address(nft), 1, 2 ether);
        assertEq(id2, 2);
        assertEq(market.listingIdOf(address(nft), 1), 2);
        assertEq(market.floorPrice(address(nft)), 2 ether);
    }

    /*//////////////////////////////////////////////////////////////
                                   BUY
    //////////////////////////////////////////////////////////////*/

    function test_buy_revertsInTheListingBlock() public {
        uint256 id = _mintAndList(alice, 1, 1 ether);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(BazaarMarketplace.NotMatured.selector, B0));
        market.buy{value: 1 ether}(id);
    }

    function test_buy_succeedsOneBlockLater() public {
        uint256 id = _mintAndList(alice, 1, 1 ether);
        assertFalse(market.isListingFillable(id));
        _mature();
        assertTrue(market.isListingFillable(id));
        vm.prank(bob);
        market.buy{value: 1 ether}(id);
        assertEq(nft.ownerOf(1), bob);
    }

    function test_buy_deliversTokenAndPushesEth() public {
        uint256 id = _mintAndList(alice, 1, 1 ether);
        _mature();

        uint256 aliceBefore = alice.balance;
        uint256 ownerBefore = owner.balance;
        uint256 bobBefore = bob.balance;

        vm.prank(bob);
        market.buy{value: 1 ether}(id);

        assertEq(nft.ownerOf(1), bob, "token not delivered");
        assertEq(owner.balance - ownerBefore, 0.005 ether, "fee");
        assertEq(alice.balance - aliceBefore, 0.995 ether, "proceeds");
        assertEq(bobBefore - bob.balance, 1 ether, "buyer paid");
        assertEq(market.getListing(id).seller, address(0), "listing not cleared");
        assertEq(market.listingIdOf(address(nft), 1), 0);
        assertEq(market.floorPrice(address(nft)), 0);
        (uint128 price, uint64 ts, uint64 bn) = market.lastSale(address(nft));
        assertEq(price, 1 ether);
        assertEq(ts, T0);
        assertEq(bn, B0 + 1);
        _assertEscrowInvariant();
    }

    function test_buy_paysRoyaltyAtFivePercent() public {
        _enableRoyalty(address(nft), royaltyReceiver, 500);
        uint256 id = _mintAndList(alice, 1, 1 ether);
        _mature();

        uint256 aliceBefore = alice.balance;
        uint256 ownerBefore = owner.balance;

        vm.prank(bob);
        market.buy{value: 1 ether}(id);

        assertEq(royaltyReceiver.balance, 0.05 ether, "royalty");
        assertEq(owner.balance - ownerBefore, 0.005 ether, "fee");
        assertEq(alice.balance - aliceBefore, 0.945 ether, "proceeds");
    }

    function test_buy_emitsEventsInOrder() public {
        _enableRoyalty(address(nft), royaltyReceiver, 250);
        uint256 id = _mintAndList(alice, 1, 1 ether);
        _mature();

        vm.prank(bob);
        vm.expectEmit(true, true, true, true, address(market));
        emit BazaarMarketplace.OracleSaleRecorded(address(nft), 1, 1 ether, T0);
        vm.expectEmit(true, true, true, true, address(market));
        emit BazaarMarketplace.Bought(id, address(nft), 1, alice, bob, 1 ether);
        vm.expectEmit(true, true, true, true, address(market));
        emit BazaarMarketplace.OracleFloorUpdated(address(nft), 0, 0);
        vm.expectEmit(true, true, true, true, address(market));
        emit BazaarMarketplace.RoyaltyPaid(address(nft), 1, royaltyReceiver, 0.025 ether);
        vm.expectEmit(true, true, true, true, address(market));
        emit BazaarMarketplace.ProtocolFeePaid(address(nft), 1, owner, 0.005 ether);
        market.buy{value: 1 ether}(id);
    }

    function test_buy_revertsOnUnderpayment() public {
        uint256 id = _mintAndList(alice, 1, 1 ether);
        _mature();
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(BazaarMarketplace.IncorrectPayment.selector, 1 ether, 1 ether - 1));
        market.buy{value: 1 ether - 1}(id);
    }

    function test_buy_revertsOnOverpayment() public {
        uint256 id = _mintAndList(alice, 1, 1 ether);
        _mature();
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(BazaarMarketplace.IncorrectPayment.selector, 1 ether, 1 ether + 1));
        market.buy{value: 1 ether + 1}(id);
    }

    function test_buy_revertsOnSelfTrade() public {
        uint256 id = _mintAndList(alice, 1, 1 ether);
        _mature();
        vm.prank(alice);
        vm.expectRevert(BazaarMarketplace.SelfTrade.selector);
        market.buy{value: 1 ether}(id);
    }

    function test_buy_revertsForUnknownListing() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(BazaarMarketplace.ListingNotFound.selector, 7));
        market.buy{value: 1 ether}(7);
    }

    function test_buy_revertsWhenBoughtTwice() public {
        uint256 id = _mintAndList(alice, 1, 1 ether);
        _mature();
        vm.prank(bob);
        market.buy{value: 1 ether}(id);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(BazaarMarketplace.ListingNotFound.selector, id));
        market.buy{value: 1 ether}(id);
    }

    function test_buy_boughtTokenCanBeRelistedByBuyer() public {
        uint256 id = _mintAndList(alice, 1, 1 ether);
        _mature();
        vm.prank(bob);
        market.buy{value: 1 ether}(id);
        uint256 id2 = _list(bob, address(nft), 1, 3 ether);
        assertEq(market.getListing(id2).seller, bob);
    }

    function testFuzz_settlementConservesValue(uint96 price, uint16 bps) public {
        price = uint96(bound(price, 1, market.MAX_PRICE()));
        bps = uint16(bound(bps, 0, 500));
        _enableRoyalty(address(nft), royaltyReceiver, bps);
        vm.deal(bob, price);

        uint256 id = _mintAndList(alice, 1, price);
        _mature();
        uint256 aliceBefore = alice.balance;
        uint256 ownerBefore = owner.balance;

        vm.prank(bob);
        market.buy{value: price}(id);

        uint256 fee = uint256(price) * 50 / 10_000;
        uint256 royalty = uint256(price) * bps / 10_000;
        assertEq(owner.balance - ownerBefore, fee, "fee");
        assertEq(royaltyReceiver.balance, royalty, "royalty");
        assertEq(alice.balance - aliceBefore, uint256(price) - fee - royalty, "proceeds");
        assertEq(bob.balance, 0, "buyer overpaid or was refunded");
        assertLe(royalty, uint256(price) * 500 / 10_000, "royalty above 5%");
        _assertEscrowInvariant();
    }

    function test_quote_matchesSettlement() public {
        _enableRoyalty(address(nft), royaltyReceiver, 300);
        (uint256 fee, address receiver, uint256 royalty, uint256 proceeds) = market.quote(address(nft), 1, 2 ether);
        assertEq(fee, 0.01 ether);
        assertEq(receiver, royaltyReceiver);
        assertEq(royalty, 0.06 ether);
        assertEq(proceeds, 1.93 ether);
        assertEq(fee + royalty + proceeds, 2 ether);
    }

    /*//////////////////////////////////////////////////////////////
                                MAKE OFFER
    //////////////////////////////////////////////////////////////*/

    function test_makeOffer_escrowsEth() public {
        vm.prank(bob);
        vm.expectEmit(true, true, true, true, address(market));
        emit BazaarMarketplace.OfferMade(1, address(nft), bob, 2 ether, B0);
        uint256 id = market.makeOffer{value: 2 ether}(address(nft));

        assertEq(id, 1);
        BazaarMarketplace.Offer memory o = market.getOffer(id);
        assertEq(o.offerer, bob);
        assertEq(o.collection, address(nft));
        assertEq(o.amount, 2 ether);
        assertEq(o.createdBlock, B0);
        assertEq(market.escrowedOfferEth(), 2 ether);
        assertEq(market.nextOfferId(), 2);
        assertFalse(market.isOfferFillable(id));
        _assertEscrowInvariant();
    }

    function test_makeOffer_revertsOnZeroValue() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(BazaarMarketplace.InvalidPrice.selector, 0));
        market.makeOffer{value: 0}(address(nft));
    }

    function test_makeOffer_revertsAboveMaxPrice() public {
        uint256 tooHigh = market.MAX_PRICE() + 1;
        vm.deal(bob, tooHigh);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(BazaarMarketplace.InvalidPrice.selector, tooHigh));
        market.makeOffer{value: tooHigh}(address(nft));
    }

    function test_makeOffer_revertsForCollectionWithoutCode() public {
        address eoa = makeAddr("not-a-collection");
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(BazaarMarketplace.NotAContract.selector, eoa));
        market.makeOffer{value: 1 ether}(eoa);
    }

    /*//////////////////////////////////////////////////////////////
                               CANCEL OFFER
    //////////////////////////////////////////////////////////////*/

    function test_cancelOffer_refundsEscrow() public {
        uint256 id = _offer(bob, address(nft), 2 ether);
        uint256 before = bob.balance;

        vm.prank(bob);
        vm.expectEmit(true, true, true, true, address(market));
        emit BazaarMarketplace.OfferCancelled(id, address(nft), bob, 2 ether);
        market.cancelOffer(id);

        assertEq(bob.balance - before, 2 ether);
        assertEq(market.getOffer(id).offerer, address(0));
        assertEq(market.escrowedOfferEth(), 0);
        _assertEscrowInvariant();
    }

    function test_cancelOffer_allowedBeforeMaturity() public {
        uint256 id = _offer(bob, address(nft), 2 ether);
        vm.prank(bob);
        market.cancelOffer(id);
        assertEq(market.escrowedOfferEth(), 0);
    }

    function test_cancelOffer_revertsForNonOfferer() public {
        uint256 id = _offer(bob, address(nft), 2 ether);
        vm.prank(alice);
        vm.expectRevert(BazaarMarketplace.NotOfferer.selector);
        market.cancelOffer(id);
    }

    function test_cancelOffer_revertsForUnknownOffer() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(BazaarMarketplace.OfferNotFound.selector, 9));
        market.cancelOffer(9);
    }

    function test_cancelOffer_thenAcceptReverts() public {
        uint256 id = _offer(bob, address(nft), 2 ether);
        vm.prank(bob);
        market.cancelOffer(id);
        _mature();
        nft.mint(alice, 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BazaarMarketplace.OfferNotFound.selector, id));
        market.acceptOffer(id, 1);
    }

    /*//////////////////////////////////////////////////////////////
                               ACCEPT OFFER
    //////////////////////////////////////////////////////////////*/

    function _prepareAcceptance(uint256 amount) internal returns (uint256 offerId) {
        offerId = _offer(bob, address(nft), amount);
        nft.mint(alice, 7);
        vm.prank(alice);
        nft.setApprovalForAll(address(market), true);
    }

    function test_acceptOffer_revertsInTheOfferBlock() public {
        uint256 id = _prepareAcceptance(2 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BazaarMarketplace.NotMatured.selector, B0));
        market.acceptOffer(id, 7);
    }

    function test_acceptOffer_settlesOneBlockLater() public {
        uint256 id = _prepareAcceptance(2 ether);
        _mature();
        assertTrue(market.isOfferFillable(id));

        uint256 aliceBefore = alice.balance;
        uint256 ownerBefore = owner.balance;

        vm.prank(alice);
        market.acceptOffer(id, 7);

        assertEq(nft.ownerOf(7), bob, "token not delivered to offerer");
        assertEq(alice.balance - aliceBefore, 1.99 ether, "proceeds");
        assertEq(owner.balance - ownerBefore, 0.01 ether, "fee");
        assertEq(market.escrowedOfferEth(), 0);
        assertEq(market.getOffer(id).offerer, address(0));
        (uint128 price,,) = market.lastSale(address(nft));
        assertEq(price, 2 ether);
        _assertEscrowInvariant();
    }

    function test_acceptOffer_paysRoyalty() public {
        _enableRoyalty(address(nft), royaltyReceiver, 500);
        uint256 id = _prepareAcceptance(2 ether);
        _mature();
        uint256 aliceBefore = alice.balance;

        vm.prank(alice);
        market.acceptOffer(id, 7);

        assertEq(royaltyReceiver.balance, 0.1 ether);
        assertEq(alice.balance - aliceBefore, 1.89 ether);
    }

    function test_acceptOffer_emitsEventsInOrder() public {
        uint256 id = _prepareAcceptance(2 ether);
        _mature();

        vm.prank(alice);
        vm.expectEmit(true, true, true, true, address(market));
        emit BazaarMarketplace.OracleSaleRecorded(address(nft), 7, 2 ether, T0);
        vm.expectEmit(true, true, true, true, address(market));
        emit BazaarMarketplace.OfferAccepted(id, address(nft), 7, alice, bob, 2 ether);
        vm.expectEmit(true, true, true, true, address(market));
        emit BazaarMarketplace.ProtocolFeePaid(address(nft), 7, owner, 0.01 ether);
        market.acceptOffer(id, 7);
    }

    function test_acceptOffer_revertsWhenCallerDoesNotOwnTheToken() public {
        uint256 id = _prepareAcceptance(2 ether);
        _mature();
        vm.prank(carol);
        vm.expectRevert(BazaarMarketplace.NotTokenOwner.selector);
        market.acceptOffer(id, 7);
    }

    function test_acceptOffer_revertsWhenTokenIsInCustody() public {
        uint256 offerId = _offer(bob, address(nft), 2 ether);
        _mintAndList(alice, 7, 5 ether);
        _mature();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BazaarMarketplace.TokenInCustody.selector, address(nft), 7));
        market.acceptOffer(offerId, 7);
    }

    function test_acceptOffer_revertsOnSelfTrade() public {
        uint256 id = _offer(bob, address(nft), 2 ether);
        nft.mint(bob, 7);
        _mature();
        vm.prank(bob);
        vm.expectRevert(BazaarMarketplace.SelfTrade.selector);
        market.acceptOffer(id, 7);
    }

    function test_acceptOffer_revertsWithoutApproval() public {
        uint256 id = _offer(bob, address(nft), 2 ether);
        nft.mint(alice, 7);
        _mature();
        vm.prank(alice);
        vm.expectRevert(ERC721.NotOwnerNorApproved.selector);
        market.acceptOffer(id, 7);
    }

    function test_acceptOffer_revertsWhenAcceptedTwice() public {
        uint256 id = _prepareAcceptance(2 ether);
        _mature();
        vm.prank(alice);
        market.acceptOffer(id, 7);
        nft.mint(alice, 8);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BazaarMarketplace.OfferNotFound.selector, id));
        market.acceptOffer(id, 8);
    }

    function test_acceptOffer_revertsForUnknownOffer() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BazaarMarketplace.OfferNotFound.selector, 3));
        market.acceptOffer(3, 7);
    }

    function test_acceptOffer_offerIsBoundToItsCollection() public {
        // Bob bids on `nft`; Alice holds token 7 of a different collection and cannot fill it.
        uint256 id = _offer(bob, address(nft), 2 ether);
        _mature();
        vm.prank(alice);
        vm.expectRevert();
        market.acceptOffer(id, 7); // token 7 of `nft` does not exist: ownerOf reverts
    }

    function test_offersAreIndependent() public {
        uint256 a = _offer(bob, address(nft), 1 ether);
        uint256 b = _offer(carol, address(nft), 3 ether);
        assertEq(market.escrowedOfferEth(), 4 ether);
        nft.mint(alice, 7);
        vm.prank(alice);
        nft.setApprovalForAll(address(market), true);
        _mature();

        vm.prank(alice);
        market.acceptOffer(b, 7);
        assertEq(nft.ownerOf(7), carol);
        assertEq(market.escrowedOfferEth(), 1 ether);
        assertEq(market.getOffer(a).offerer, bob, "other offer must survive");
        _assertEscrowInvariant();
    }
}
