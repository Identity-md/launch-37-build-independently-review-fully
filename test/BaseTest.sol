// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BazaarMarketplace} from "../src/BazaarMarketplace.sol";
import {Royalties} from "../src/Royalties.sol";
import {RoyaltyRegistry} from "../src/RoyaltyRegistry.sol";
import {MockERC721} from "./mocks/MockERC721.sol";

interface IApprovalForAll {
    function setApprovalForAll(address operator, bool approved) external;
}

/// @notice Shared fixture: a marketplace wired to a Royalties contract, a registry, and an honest collection.
abstract contract BaseTest is Test {
    /// @dev Aligned to a 6 hour boundary so every oracle ring starts a fresh bucket at T0.
    uint256 internal constant T0 = 1_700_006_400;
    uint256 internal constant B0 = 1_000;

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal royaltyReceiver = makeAddr("royaltyReceiver");

    Royalties internal royalties;
    RoyaltyRegistry internal registry;
    BazaarMarketplace internal market;
    MockERC721 internal nft;

    function setUp() public virtual {
        vm.warp(T0);
        vm.roll(B0);

        royalties = new Royalties(owner);
        market = new BazaarMarketplace(owner, address(royalties));
        registry = new RoyaltyRegistry(owner);
        nft = new MockERC721();

        vm.deal(alice, 1_000 ether);
        vm.deal(bob, 1_000 ether);
        vm.deal(carol, 1_000 ether);
    }

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/

    function _enableRoyalty(address collection, address receiver, uint16 bps) internal {
        vm.startPrank(owner);
        registry.setCollectionRoyalty(collection, receiver, bps);
        royalties.setImplementation(address(registry));
        vm.stopPrank();
    }

    function _list(address seller, address collection, uint256 tokenId, uint256 price)
        internal
        returns (uint256 listingId)
    {
        vm.startPrank(seller);
        IApprovalForAll(collection).setApprovalForAll(address(market), true);
        listingId = market.list(collection, tokenId, price);
        vm.stopPrank();
    }

    function _mintAndList(address seller, uint256 tokenId, uint256 price) internal returns (uint256 listingId) {
        nft.mint(seller, tokenId);
        return _list(seller, address(nft), tokenId, price);
    }

    function _offer(address offerer, address collection, uint256 amount) internal returns (uint256 offerId) {
        vm.prank(offerer);
        offerId = market.makeOffer{value: amount}(collection);
    }

    function _mature() internal {
        vm.roll(block.number + 1);
    }

    function _assertEscrowInvariant() internal view {
        assertEq(address(market).balance, market.escrowedOfferEth(), "escrow invariant broken");
    }
}
