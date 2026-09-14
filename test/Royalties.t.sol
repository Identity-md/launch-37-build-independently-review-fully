// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {Royalties} from "../src/Royalties.sol";
import {RoyaltyRegistry} from "../src/RoyaltyRegistry.sol";
import {MockRoyaltyImplementation} from "./mocks/MockRoyaltyImplementation.sol";

/// @notice The Royalties bound (0-5% inclusive), its defaults, and the swappable implementation.
contract RoyaltiesTest is Test {
    address internal owner = makeAddr("owner");
    address internal stranger = makeAddr("stranger");
    address internal receiver = makeAddr("receiver");
    address internal collection = makeAddr("collection");

    Royalties internal royalties;
    MockRoyaltyImplementation internal impl;

    function setUp() public {
        royalties = new Royalties(owner);
        impl = new MockRoyaltyImplementation();
    }

    function _useImpl() internal {
        vm.prank(owner);
        royalties.setImplementation(address(impl));
    }

    /*//////////////////////////////////////////////////////////////
                           CONSTRUCTOR / ADMIN
    //////////////////////////////////////////////////////////////*/

    function test_constructor_setsOwnerFromArgumentNotSender() public view {
        assertEq(royalties.owner(), owner);
        assertTrue(royalties.owner() != address(this), "deployer must not become owner");
    }

    function test_constructor_revertsOnZeroOwner() public {
        vm.expectRevert(Royalties.ZeroAddress.selector);
        new Royalties(address(0));
    }

    function test_defaultIsZeroWithNoRecipient() public view {
        assertEq(royalties.implementation(), address(0));
        (address r, uint256 amount) = royalties.royaltyInfo(collection, 1, 1 ether);
        assertEq(r, address(0));
        assertEq(amount, 0);
    }

    function test_setImplementation_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(Ownable.Unauthorized.selector);
        royalties.setImplementation(address(impl));
    }

    function test_setImplementation_rejectsAddressWithoutCode() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Royalties.ImplementationNotAContract.selector, stranger));
        royalties.setImplementation(stranger);
    }

    function test_setImplementation_storesAndEmits() public {
        vm.prank(owner);
        vm.expectEmit(true, true, true, true, address(royalties));
        emit Royalties.RoyaltyImplementationChanged(address(0), address(impl), owner);
        royalties.setImplementation(address(impl));
        assertEq(royalties.implementation(), address(impl));
    }

    function test_setImplementation_canBeSwappedAndCleared() public {
        _useImpl();
        MockRoyaltyImplementation other = new MockRoyaltyImplementation();
        other.setBps(receiver, 100);

        vm.prank(owner);
        vm.expectEmit(true, true, true, true, address(royalties));
        emit Royalties.RoyaltyImplementationChanged(address(impl), address(other), owner);
        royalties.setImplementation(address(other));
        (address r, uint256 amount) = royalties.royaltyInfo(collection, 1, 1 ether);
        assertEq(r, receiver);
        assertEq(amount, 0.01 ether);

        vm.prank(owner);
        royalties.setImplementation(address(0));
        (r, amount) = royalties.royaltyInfo(collection, 1, 1 ether);
        assertEq(r, address(0));
        assertEq(amount, 0);
    }

    function test_ownershipCanBeTransferred() public {
        vm.prank(owner);
        royalties.transferOwnership(stranger);
        assertEq(royalties.owner(), stranger);
        vm.prank(stranger);
        royalties.setImplementation(address(impl));
        assertEq(royalties.implementation(), address(impl));
    }

    /*//////////////////////////////////////////////////////////////
                                 BOUNDS
    //////////////////////////////////////////////////////////////*/

    function test_maxRoyalty_isFivePercent() public view {
        assertEq(royalties.MAX_ROYALTY_BPS(), 500);
        assertEq(royalties.maxRoyalty(1 ether), 0.05 ether);
        assertEq(royalties.maxRoyalty(199), 9);
        assertEq(royalties.maxRoyalty(19), 0);
    }

    function test_royalty_atExactlyFivePercentPasses() public {
        _useImpl();
        impl.setBps(receiver, 500);
        (address r, uint256 amount) = royalties.royaltyInfo(collection, 1, 1 ether);
        assertEq(r, receiver);
        assertEq(amount, 0.05 ether);
    }

    function test_royalty_oneWeiAboveFivePercentReverts() public {
        _useImpl();
        uint256 max = royalties.maxRoyalty(1 ether);
        impl.setFixedAmount(receiver, max + 1);
        vm.expectRevert(abi.encodeWithSelector(Royalties.RoyaltyOutOfBounds.selector, max + 1, max));
        royalties.royaltyInfo(collection, 1, 1 ether);
    }

    function test_royalty_zeroAmountNormalisesReceiver() public {
        _useImpl();
        impl.setBps(receiver, 0);
        (address r, uint256 amount) = royalties.royaltyInfo(collection, 1, 1 ether);
        assertEq(r, address(0));
        assertEq(amount, 0);
    }

    function test_royalty_positiveAmountWithoutReceiverReverts() public {
        _useImpl();
        impl.setFixedAmount(address(0), 1);
        vm.expectRevert(Royalties.RoyaltyReceiverMissing.selector);
        royalties.royaltyInfo(collection, 1, 1 ether);
    }

    function test_royalty_implementationRevertPropagates() public {
        _useImpl();
        impl.setShouldRevert(true);
        vm.expectRevert(MockRoyaltyImplementation.ImplementationReverted.selector);
        royalties.royaltyInfo(collection, 1, 1 ether);
    }

    function test_royalty_tinyPricesRoundDownToZeroAtTheBound() public {
        _useImpl();
        // 5% of 19 wei rounds to 0, so any positive royalty is out of bounds.
        impl.setFixedAmount(receiver, 1);
        vm.expectRevert(abi.encodeWithSelector(Royalties.RoyaltyOutOfBounds.selector, 1, 0));
        royalties.royaltyInfo(collection, 1, 19);
    }

    function testFuzz_royaltyWithinBoundPasses(uint16 bps, uint96 price) public {
        bps = uint16(bound(bps, 0, 500));
        _useImpl();
        impl.setBps(receiver, bps);
        (address r, uint256 amount) = royalties.royaltyInfo(collection, 1, price);
        uint256 expected = uint256(price) * bps / 10_000;
        assertEq(amount, expected);
        assertEq(r, expected == 0 ? address(0) : receiver);
        assertLe(amount, royalties.maxRoyalty(price));
    }

    function testFuzz_royaltyAboveBoundReverts(uint16 bps, uint96 price) public {
        bps = uint16(bound(bps, 501, 10_000));
        price = uint96(bound(price, 10_000, type(uint96).max));
        _useImpl();
        impl.setBps(receiver, bps);
        vm.expectRevert();
        royalties.royaltyInfo(collection, 1, price);
    }

    /*//////////////////////////////////////////////////////////////
                          REFERENCE REGISTRY
    //////////////////////////////////////////////////////////////*/

    function test_registry_defaultsToZero() public {
        RoyaltyRegistry registry = new RoyaltyRegistry(owner);
        (address r, uint256 amount) = registry.royaltyInfo(collection, 1, 1 ether);
        assertEq(r, address(0));
        assertEq(amount, 0);
    }

    function test_registry_constructorRevertsOnZeroOwner() public {
        vm.expectRevert(RoyaltyRegistry.ZeroAddress.selector);
        new RoyaltyRegistry(address(0));
    }

    function test_registry_setAndClear() public {
        RoyaltyRegistry registry = new RoyaltyRegistry(owner);
        vm.prank(owner);
        vm.expectEmit(true, true, true, true, address(registry));
        emit RoyaltyRegistry.CollectionRoyaltySet(collection, receiver, 250, owner);
        registry.setCollectionRoyalty(collection, receiver, 250);
        (address r, uint256 amount) = registry.royaltyInfo(collection, 1, 2 ether);
        assertEq(r, receiver);
        assertEq(amount, 0.05 ether);

        vm.prank(owner);
        registry.setCollectionRoyalty(collection, address(0), 0);
        (r, amount) = registry.royaltyInfo(collection, 1, 2 ether);
        assertEq(r, address(0));
        assertEq(amount, 0);
    }

    function test_registry_onlyOwner() public {
        RoyaltyRegistry registry = new RoyaltyRegistry(owner);
        vm.prank(stranger);
        vm.expectRevert(Ownable.Unauthorized.selector);
        registry.setCollectionRoyalty(collection, receiver, 100);
    }

    function test_registry_rejectsAboveFivePercentAndMissingReceiver() public {
        RoyaltyRegistry registry = new RoyaltyRegistry(owner);
        vm.startPrank(owner);
        vm.expectRevert(RoyaltyRegistry.InvalidRoyalty.selector);
        registry.setCollectionRoyalty(collection, receiver, 501);
        vm.expectRevert(RoyaltyRegistry.InvalidRoyalty.selector);
        registry.setCollectionRoyalty(collection, address(0), 100);
        registry.setCollectionRoyalty(collection, receiver, 500);
        vm.stopPrank();
    }

    function test_registry_worksThroughRoyalties() public {
        RoyaltyRegistry registry = new RoyaltyRegistry(owner);
        vm.startPrank(owner);
        registry.setCollectionRoyalty(collection, receiver, 500);
        royalties.setImplementation(address(registry));
        vm.stopPrank();
        (address r, uint256 amount) = royalties.royaltyInfo(collection, 1, 1 ether);
        assertEq(r, receiver);
        assertEq(amount, 0.05 ether);
    }
}
