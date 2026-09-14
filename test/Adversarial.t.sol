// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./BaseTest.sol";
import {BazaarMarketplace} from "../src/BazaarMarketplace.sol";
import {ReentrantERC721} from "./mocks/ReentrantERC721.sol";
import {RevertingERC721} from "./mocks/RevertingERC721.sol";
import {LyingERC721} from "./mocks/LyingERC721.sol";
import {RejectingReceiver} from "./mocks/RejectingReceiver.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @notice Malicious collections and hostile counterparties: a failure only ever affects its own trade.
contract AdversarialTest is BaseTest {
    ReentrantERC721 internal evil;
    RevertingERC721 internal flaky;
    LyingERC721 internal liar;

    uint256 internal honestListing;
    uint256 internal honestOffer;

    function setUp() public override {
        super.setUp();
        evil = new ReentrantERC721(market);
        flaky = new RevertingERC721();
        liar = new LyingERC721();

        // Assets custodied for other people, which no attacker may touch.
        honestListing = _mintAndList(alice, 1, 1 ether);
        honestOffer = _offer(bob, address(nft), 0.5 ether);
        _mature();
        _assertEscrowInvariant();
    }

    function _assertHonestStateUntouched() internal view {
        assertEq(nft.ownerOf(1), address(market), "honest token left custody");
        assertEq(market.getListing(honestListing).seller, alice, "honest listing changed");
        assertEq(market.getListing(honestListing).price, 1 ether);
        assertEq(market.getOffer(honestOffer).offerer, bob, "honest offer changed");
        assertEq(market.getOffer(honestOffer).amount, 0.5 ether);
        assertEq(market.escrowedOfferEth(), 0.5 ether, "escrow changed");
        assertEq(market.floorPrice(address(nft)), 1 ether, "honest floor changed");
        _assertEscrowInvariant();
    }

    function _reentrancyRevert() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(ReentrancyGuard.Reentrancy.selector);
    }

    /*//////////////////////////////////////////////////////////////
                         REENTRANT COLLECTION
    //////////////////////////////////////////////////////////////*/

    function test_reentrantBuyDuringDelivery_bubblesAndRevertsOnlyThatTrade() public {
        evil.mint(carol, 1);
        uint256 evilListing = _list(carol, address(evil), 1, 1 ether);
        _mature();
        vm.deal(address(evil), 1 ether);
        evil.arm(ReentrantERC721.Attack.Buy, honestListing, 0, 1 ether, false);

        vm.prank(bob);
        vm.expectRevert(ReentrancyGuard.Reentrancy.selector);
        market.buy{value: 1 ether}(evilListing);

        // The guard's revert bubbled through the hook and undid the whole trade, including the
        // hook's own bookkeeping: the attack is still armed and nothing was attempted on record.
        assertTrue(evil.attack() == ReentrantERC721.Attack.Buy, "hook state must roll back with the trade");
        assertFalse(evil.attempted());
        assertEq(market.getListing(evilListing).seller, carol, "evil listing must survive its own failure");
        assertEq(evil.ownerOf(1), address(market));
        _assertHonestStateUntouched();
    }

    function test_reentrantBuySwallowed_outerTradeCompletesNestedHasNoEffect() public {
        evil.mint(carol, 1);
        uint256 evilListing = _list(carol, address(evil), 1, 1 ether);
        _mature();
        vm.deal(address(evil), 1 ether);
        evil.arm(ReentrantERC721.Attack.Buy, honestListing, 0, 1 ether, true);

        uint256 carolBefore = carol.balance;
        vm.prank(bob);
        market.buy{value: 1 ether}(evilListing);

        assertTrue(evil.attempted());
        assertFalse(evil.nestedCallSucceeded(), "nested buy must fail");
        assertEq(evil.nestedRevertData(), _reentrancyRevert());
        assertEq(evil.ownerOf(1), bob, "outer trade delivers");
        assertEq(carol.balance - carolBefore, 0.995 ether, "outer trade pays");
        assertEq(address(evil).balance, 1 ether, "nested buy must not have spent anything");
        _assertHonestStateUntouched();
    }

    function test_reentrantCancelDuringCustodyPull_isBlocked() public {
        evil.mint(carol, 2);
        evil.arm(ReentrantERC721.Attack.CancelListing, honestListing, 0, 0, false);

        vm.startPrank(carol);
        evil.setApprovalForAll(address(market), true);
        vm.expectRevert(ReentrancyGuard.Reentrancy.selector);
        market.list(address(evil), 2, 1 ether);
        vm.stopPrank();

        assertEq(evil.ownerOf(2), carol, "failed listing must not keep the token");
        assertEq(market.listingIdOf(address(evil), 2), 0);
        assertEq(market.activeListingCount(address(evil)), 0);
        _assertHonestStateUntouched();
    }

    function test_everyEntryPointIsGuardedAgainstReentrancy() public {
        // The evil collection owns a token of its own so the nested `list` has something to list.
        evil.mint(address(evil), 50);
        evil.approveMarket();
        vm.deal(address(evil), 1 ether);

        ReentrantERC721.Attack[6] memory attacks = [
            ReentrantERC721.Attack.Buy,
            ReentrantERC721.Attack.CancelListing,
            ReentrantERC721.Attack.List,
            ReentrantERC721.Attack.MakeOffer,
            ReentrantERC721.Attack.CancelOffer,
            ReentrantERC721.Attack.AcceptOffer
        ];

        for (uint256 i; i < attacks.length; ++i) {
            uint256 tokenId = 10 + i;
            evil.mint(carol, tokenId);
            evil.arm(attacks[i], i == 0 ? honestListing : honestOffer, 50, i == 0 ? 1 ether : 0.1 ether, true);

            // Each listing pulls the token into custody, which fires the hook once.
            _list(carol, address(evil), tokenId, 1 ether);

            assertTrue(evil.attempted(), "hook did not fire");
            assertFalse(evil.nestedCallSucceeded(), "nested call must fail");
            assertEq(evil.nestedRevertData(), _reentrancyRevert(), "must fail on the guard, not later");
            _assertHonestStateUntouched();
        }
        assertEq(address(evil).balance, 1 ether, "no nested call may have moved ETH");
        assertEq(market.listingIdOf(address(evil), 50), 0, "nested list must not have created a listing");
    }

    /*//////////////////////////////////////////////////////////////
                         REVERTING COLLECTION
    //////////////////////////////////////////////////////////////*/

    function test_revertingTransfer_listFailsCleanly() public {
        flaky.mint(carol, 1);
        flaky.setRevertOnTransfer(true);

        vm.startPrank(carol);
        flaky.setApprovalForAll(address(market), true);
        vm.expectRevert(RevertingERC721.TransferRejected.selector);
        market.list(address(flaky), 1, 1 ether);
        vm.stopPrank();

        assertEq(market.listingIdOf(address(flaky), 1), 0);
        assertEq(market.activeListingCount(address(flaky)), 0);
        _assertHonestStateUntouched();
    }

    function test_revertingTransfer_afterListing_onlyThatListingIsStuck() public {
        flaky.mint(carol, 1);
        uint256 flakyListing = _list(carol, address(flaky), 1, 1 ether);
        _mature();
        flaky.setRevertOnTransfer(true);

        vm.prank(bob);
        vm.expectRevert(RevertingERC721.TransferRejected.selector);
        market.buy{value: 1 ether}(flakyListing);

        vm.prank(carol);
        vm.expectRevert(RevertingERC721.TransferRejected.selector);
        market.cancelListing(flakyListing);

        assertEq(market.getListing(flakyListing).seller, carol, "stuck listing stays recorded");
        _assertHonestStateUntouched();

        // The honest listing is still perfectly tradable.
        vm.prank(bob);
        market.buy{value: 1 ether}(honestListing);
        assertEq(nft.ownerOf(1), bob);
        _assertEscrowInvariant();

        // Once the collection behaves again the seller recovers the token.
        flaky.setRevertOnTransfer(false);
        vm.prank(carol);
        market.cancelListing(flakyListing);
        assertEq(flaky.ownerOf(1), carol);
    }

    function test_revertingOwnerOf_onlyThatTradeFails() public {
        flaky.mint(carol, 1);
        uint256 flakyListing = _list(carol, address(flaky), 1, 1 ether);
        _mature();
        flaky.setRevertOnOwnerOf(true);

        vm.prank(bob);
        vm.expectRevert(RevertingERC721.OwnerOfRejected.selector);
        market.buy{value: 1 ether}(flakyListing);

        assertEq(market.getListing(flakyListing).seller, carol);
        _assertHonestStateUntouched();
    }

    /*//////////////////////////////////////////////////////////////
                           LYING COLLECTION
    //////////////////////////////////////////////////////////////*/

    function test_lyingCollection_silentNoOpTransfer_buyerIsProtected() public {
        liar.mint(carol, 1);
        liar.setNoopTransfers(true);
        liar.setFixedOwner(address(market)); // claims custody it never gave
        uint256 liarListing = _list(carol, address(liar), 1, 1 ether);
        _mature();

        uint256 bobBefore = bob.balance;
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(BazaarMarketplace.DeliveryFailed.selector, address(liar), 1));
        market.buy{value: 1 ether}(liarListing);

        assertEq(bob.balance, bobBefore, "buyer must not pay for a token that never arrives");
        _assertHonestStateUntouched();
    }

    function test_lyingCollection_unauthenticatedTransfers_cannotReachOtherCollections() public {
        // Carol "lists" a token the liar says belongs to Alice: the liar moves it without any check.
        liar.mint(alice, 5);
        uint256 liarListing = _list(carol, address(liar), 5, 1 ether);
        _mature();

        uint256 carolBefore = carol.balance;
        vm.prank(bob);
        market.buy{value: 1 ether}(liarListing);

        assertEq(liar.ownerOf(5), bob);
        assertEq(carol.balance - carolBefore, 0.995 ether, "only the buyer's own ETH reaches the seller");
        _assertHonestStateUntouched();
    }

    function test_lyingCollection_acceptOffer_onlyThatOffererIsExposed() public {
        uint256 liarOffer = _offer(bob, address(liar), 1 ether);
        _mature();
        liar.mint(carol, 99); // anyone can mint anything on a lying collection

        vm.prank(carol);
        market.acceptOffer(liarOffer, 99);

        assertEq(liar.ownerOf(99), bob, "bob received what he bid on");
        assertEq(market.escrowedOfferEth(), 0.5 ether, "only bob's liar escrow was spent");
        _assertHonestStateUntouched();
    }

    function test_lyingCollection_cannotUseCustodiedTokenToFillAnOffer() public {
        // The honest token is in custody. Even if a collection lies about who owns it, the
        // marketplace refuses to move a custodied token for an offer.
        liar.mint(carol, 1);
        uint256 liarListing = _list(carol, address(liar), 1, 1 ether);
        uint256 liarOffer = _offer(bob, address(liar), 0.7 ether);
        _mature();

        liar.setFixedOwner(alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BazaarMarketplace.TokenInCustody.selector, address(liar), 1));
        market.acceptOffer(liarOffer, 1);

        assertEq(market.getListing(liarListing).seller, carol);
        _assertEscrowInvariant();
    }

    /*//////////////////////////////////////////////////////////////
                      COUNTERPARTIES THAT REJECT ETH
    //////////////////////////////////////////////////////////////*/

    function test_sellerRejectingEth_onlyTheirListingCannotBeBought() public {
        RejectingReceiver seller = new RejectingReceiver();
        nft.mint(address(seller), 9);
        uint256 stuck = _list(address(seller), address(nft), 9, 1 ether);
        _mature();

        vm.prank(bob);
        vm.expectRevert(SafeTransferLib.ETHTransferFailed.selector);
        market.buy{value: 1 ether}(stuck);

        assertEq(market.getListing(stuck).seller, address(seller));
        assertEq(nft.ownerOf(9), address(market));

        vm.prank(bob);
        market.buy{value: 1 ether}(honestListing);
        assertEq(nft.ownerOf(1), bob);
        _assertEscrowInvariant();

        // The seller can still take the token back: cancel pushes an NFT, not ETH.
        vm.prank(address(seller));
        market.cancelListing(stuck);
        assertEq(nft.ownerOf(9), address(seller));
    }

    function test_royaltyReceiverRejectingEth_tradeFailsUntilTheOwnerFixesIt() public {
        RejectingReceiver receiver = new RejectingReceiver();
        _enableRoyalty(address(nft), address(receiver), 500);

        vm.prank(bob);
        vm.expectRevert(SafeTransferLib.ETHTransferFailed.selector);
        market.buy{value: 1 ether}(honestListing);
        _assertHonestStateUntouched();

        vm.prank(owner);
        registry.setCollectionRoyalty(address(nft), royaltyReceiver, 500);
        vm.prank(bob);
        market.buy{value: 1 ether}(honestListing);
        assertEq(royaltyReceiver.balance, 0.05 ether);
    }

    function test_offererRejectingEth_cannotCancelButCanStillBeFilled() public {
        RejectingReceiver offerer = new RejectingReceiver();
        vm.deal(address(offerer), 2 ether);
        vm.prank(address(offerer));
        uint256 offerId = market.makeOffer{value: 2 ether}(address(nft));
        _mature();

        vm.prank(address(offerer));
        vm.expectRevert(SafeTransferLib.ETHTransferFailed.selector);
        market.cancelOffer(offerId);

        nft.mint(carol, 3);
        vm.startPrank(carol);
        nft.setApprovalForAll(address(market), true);
        market.acceptOffer(offerId, 3);
        vm.stopPrank();
        assertEq(nft.ownerOf(3), address(offerer));
        _assertEscrowInvariant();
    }

    function test_feeRecipientRejectingEth_blocksEveryTrade() public {
        // Operational responsibility: $owner must be able to receive plain ETH.
        RejectingReceiver badOwner = new RejectingReceiver();
        BazaarMarketplace badMarket = new BazaarMarketplace(address(badOwner), address(royalties));
        nft.mint(carol, 4);
        vm.startPrank(carol);
        nft.setApprovalForAll(address(badMarket), true);
        uint256 id = badMarket.list(address(nft), 4, 1 ether);
        vm.stopPrank();
        _mature();

        vm.prank(bob);
        vm.expectRevert(SafeTransferLib.ETHTransferFailed.selector);
        badMarket.buy{value: 1 ether}(id);
    }

    /*//////////////////////////////////////////////////////////////
                           ESCROW INVARIANT
    //////////////////////////////////////////////////////////////*/

    function test_escrowInvariantHoldsAcrossMixedActivity() public {
        uint256 o1 = _offer(carol, address(nft), 1 ether);
        _assertEscrowInvariant();
        uint256 o2 = _offer(carol, address(nft), 2 ether);
        _assertEscrowInvariant();
        uint256 l2 = _mintAndList(alice, 2, 0.3 ether);
        _assertEscrowInvariant();
        _mature();

        vm.prank(bob);
        market.buy{value: 0.3 ether}(l2);
        _assertEscrowInvariant();

        nft.mint(alice, 3);
        vm.startPrank(alice);
        nft.setApprovalForAll(address(market), true);
        market.acceptOffer(o2, 3);
        vm.stopPrank();
        _assertEscrowInvariant();
        assertEq(market.escrowedOfferEth(), 1.5 ether);

        vm.prank(carol);
        market.cancelOffer(o1);
        _assertEscrowInvariant();

        // A failing buy leaves escrow alone.
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(BazaarMarketplace.IncorrectPayment.selector, 1 ether, 0.9 ether));
        market.buy{value: 0.9 ether}(honestListing);
        _assertEscrowInvariant();

        vm.prank(bob);
        market.cancelOffer(honestOffer);
        assertEq(market.escrowedOfferEth(), 0);
        assertEq(address(market).balance, 0, "nothing is ever held except open offers");
    }
}
