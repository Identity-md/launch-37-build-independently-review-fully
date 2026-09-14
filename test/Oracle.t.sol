// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./BaseTest.sol";
import {BazaarMarketplace} from "../src/BazaarMarketplace.sol";
import {MockERC721} from "./mocks/MockERC721.sol";

/// @notice Floor tracking and the 1h / 1d / 1w rolling averages.
contract OracleTest is BaseTest {
    uint256 internal nextToken = 100;

    /// @dev Lists and sells one token at `price` in the next block, keeping `block.timestamp` where it is.
    function _sell(uint256 price) internal {
        uint256 tokenId = nextToken++;
        uint256 id = _mintAndList(alice, tokenId, price);
        _mature();
        vm.prank(bob);
        market.buy{value: price}(id);
    }

    function _avg1h() internal view returns (uint256 avg, uint256 n) {
        return market.averagePrice1h(address(nft));
    }

    function _avg1d() internal view returns (uint256 avg, uint256 n) {
        return market.averagePrice1d(address(nft));
    }

    function _avg1w() internal view returns (uint256 avg, uint256 n) {
        return market.averagePrice1w(address(nft));
    }

    /*//////////////////////////////////////////////////////////////
                                  FLOOR
    //////////////////////////////////////////////////////////////*/

    function test_floor_isZeroWithoutListings() public view {
        assertEq(market.floorPrice(address(nft)), 0);
        (uint256 id, uint256 price) = market.floorListing(address(nft));
        assertEq(id, 0);
        assertEq(price, 0);
    }

    function test_floor_tracksMinimumAcrossListCancelAndBuy() public {
        uint256 a = _mintAndList(alice, 1, 2 ether);
        assertEq(market.floorPrice(address(nft)), 2 ether);

        uint256 b = _mintAndList(alice, 2, 1 ether);
        assertEq(market.floorPrice(address(nft)), 1 ether);
        (uint256 floorId,) = market.floorListing(address(nft));
        assertEq(floorId, b);

        uint256 c = _mintAndList(alice, 3, 3 ether);
        assertEq(market.floorPrice(address(nft)), 1 ether, "higher listing must not move the floor");
        assertEq(market.activeListingCount(address(nft)), 3);

        vm.prank(alice);
        market.cancelListing(b);
        assertEq(market.floorPrice(address(nft)), 2 ether, "cancelling the floor promotes the next ask");

        _mature();
        vm.prank(bob);
        market.buy{value: 2 ether}(a);
        assertEq(market.floorPrice(address(nft)), 3 ether, "buying the floor promotes the next ask");

        vm.prank(alice);
        market.cancelListing(c);
        assertEq(market.floorPrice(address(nft)), 0, "empty book has no floor");
        assertEq(market.activeListingCount(address(nft)), 0);
    }

    function test_floor_handlesEqualPrices() public {
        uint256 a = _mintAndList(alice, 1, 3 ether);
        uint256 b = _mintAndList(alice, 2, 3 ether);
        (uint256 floorId, uint256 floorPrice) = market.floorListing(address(nft));
        assertEq(floorPrice, 3 ether);
        assertEq(floorId, a, "ties resolve to the older listing");

        vm.prank(alice);
        market.cancelListing(a);
        (floorId, floorPrice) = market.floorListing(address(nft));
        assertEq(floorPrice, 3 ether);
        assertEq(floorId, b);
    }

    function test_floor_isPerCollection() public {
        MockERC721 other = new MockERC721();
        other.mint(alice, 1);
        _mintAndList(alice, 1, 5 ether);
        _list(alice, address(other), 1, 1 ether);

        assertEq(market.floorPrice(address(nft)), 5 ether);
        assertEq(market.floorPrice(address(other)), 1 ether);
    }

    function test_floor_emitsOnEveryUpdate() public {
        uint256 a = _mintAndList(alice, 1, 2 ether);

        // A higher listing does not change the floor but still reports it.
        nft.mint(alice, 2);
        vm.startPrank(alice);
        vm.expectEmit(true, true, true, true, address(market));
        emit BazaarMarketplace.OracleFloorUpdated(address(nft), 2 ether, a);
        uint256 b = market.list(address(nft), 2, 4 ether);

        vm.expectEmit(true, true, true, true, address(market));
        emit BazaarMarketplace.OracleFloorUpdated(address(nft), 4 ether, b);
        market.cancelListing(a);
        vm.stopPrank();

        _mature();
        vm.prank(bob);
        vm.expectEmit(true, true, true, true, address(market));
        emit BazaarMarketplace.OracleFloorUpdated(address(nft), 0, 0);
        market.buy{value: 4 ether}(b);
    }

    function test_floor_survivesManyListings() public {
        // Insert descending so every listing becomes the new floor, then peel them off.
        for (uint256 i = 1; i <= 25; ++i) {
            _mintAndList(alice, i, (26 - i) * 1 ether);
            assertEq(market.floorPrice(address(nft)), (26 - i) * 1 ether);
        }
        assertEq(market.activeListingCount(address(nft)), 25);
        for (uint256 i = 25; i >= 1; --i) {
            vm.prank(alice);
            market.cancelListing(i);
            uint256 expected = i == 1 ? 0 : (26 - (i - 1)) * 1 ether;
            assertEq(market.floorPrice(address(nft)), expected);
        }
    }

    /*//////////////////////////////////////////////////////////////
                             ROLLING AVERAGES
    //////////////////////////////////////////////////////////////*/

    function test_averages_areZeroWithoutSales() public view {
        (uint256 avg, uint256 n) = _avg1h();
        assertEq(avg, 0);
        assertEq(n, 0);
        (avg, n) = _avg1d();
        assertEq(avg, 0);
        (avg, n) = _avg1w();
        assertEq(avg, 0);
        (uint256 floor, uint256 a1h, uint256 a1d, uint256 a1w) = market.priceOracle(address(nft));
        assertEq(floor + a1h + a1d + a1w, 0);
    }

    function test_averages_singleSaleShowsInEveryWindow() public {
        _sell(1 ether);
        (uint256 avg, uint256 n) = _avg1h();
        assertEq(avg, 1 ether);
        assertEq(n, 1);
        (avg, n) = _avg1d();
        assertEq(avg, 1 ether);
        assertEq(n, 1);
        (avg, n) = _avg1w();
        assertEq(avg, 1 ether);
        assertEq(n, 1);
    }

    function test_averages_rollOffAsWindowsExpire() public {
        _sell(1 ether); // at T0
        vm.warp(T0 + 10 minutes);
        _sell(3 ether); // at T0 + 10 min

        (uint256 avg, uint256 n) = _avg1h();
        assertEq(avg, 2 ether);
        assertEq(n, 2);
        (avg, n) = _avg1d();
        assertEq(avg, 2 ether);
        (avg, n) = _avg1w();
        assertEq(avg, 2 ether);

        // Just before the hour the first sale is still inside the 1h window.
        vm.warp(T0 + 60 minutes - 1);
        (avg, n) = _avg1h();
        assertEq(avg, 2 ether);
        assertEq(n, 2);

        // At the hour the first sale's bucket ages out of the 1h ring; the day and week rings keep it.
        vm.warp(T0 + 60 minutes);
        (avg, n) = _avg1h();
        assertEq(avg, 3 ether);
        assertEq(n, 1);
        (avg, n) = _avg1d();
        assertEq(avg, 2 ether);
        assertEq(n, 2);

        // Both sales leave the 1h window once the second bucket ages out.
        vm.warp(T0 + 70 minutes);
        (avg, n) = _avg1h();
        assertEq(avg, 0);
        assertEq(n, 0);

        // The day window: both sales share the first hour bucket.
        vm.warp(T0 + 24 hours - 1);
        (avg, n) = _avg1d();
        assertEq(avg, 2 ether);
        assertEq(n, 2);
        vm.warp(T0 + 24 hours);
        (avg, n) = _avg1d();
        assertEq(avg, 0);
        assertEq(n, 0);
        (avg, n) = _avg1w();
        assertEq(avg, 2 ether);
        assertEq(n, 2);

        // The week window: both sales share the first 6 hour bucket.
        vm.warp(T0 + 7 days - 1);
        (avg, n) = _avg1w();
        assertEq(avg, 2 ether);
        assertEq(n, 2);
        vm.warp(T0 + 7 days);
        (avg, n) = _avg1w();
        assertEq(avg, 0);
        assertEq(n, 0);
    }

    function test_averages_recycleStaleBuckets() public {
        _sell(1 ether); // hour ring slot 0 at epoch E
        vm.warp(T0 + 1 hours); // epoch E + 12 maps to slot 0 again
        _sell(5 ether);
        (uint256 avg, uint256 n) = _avg1h();
        assertEq(n, 1, "stale bucket must be replaced, not accumulated");
        assertEq(avg, 5 ether);
        (avg, n) = _avg1d();
        assertEq(n, 2);
        assertEq(avg, 3 ether);
    }

    function test_averages_accumulateWithinABucket() public {
        _sell(1 ether);
        vm.warp(T0 + 1 minutes);
        _sell(2 ether);
        vm.warp(T0 + 2 minutes);
        _sell(6 ether);
        (uint256 avg, uint256 n) = _avg1h();
        assertEq(n, 3);
        assertEq(avg, 3 ether);
    }

    function test_averages_includeAcceptedOffers() public {
        _sell(1 ether);
        uint256 offerId = _offer(bob, address(nft), 3 ether);
        nft.mint(alice, 7);
        vm.prank(alice);
        nft.setApprovalForAll(address(market), true);
        _mature();
        vm.prank(alice);
        market.acceptOffer(offerId, 7);

        (uint256 avg, uint256 n) = _avg1h();
        assertEq(n, 2);
        assertEq(avg, 2 ether);
    }

    function test_averages_ignoreListingsAndCancellations() public {
        _mintAndList(alice, 1, 10 ether);
        uint256 id = _mintAndList(alice, 2, 20 ether);
        vm.prank(alice);
        market.cancelListing(id);
        (uint256 avg, uint256 n) = _avg1h();
        assertEq(avg, 0);
        assertEq(n, 0);
    }

    function test_averages_arePerCollection() public {
        MockERC721 other = new MockERC721();
        other.mint(alice, 1);
        uint256 id = _list(alice, address(other), 1, 4 ether);
        _mature();
        vm.prank(bob);
        market.buy{value: 4 ether}(id);
        _sell(1 ether);

        (uint256 avg,) = market.averagePrice1h(address(other));
        assertEq(avg, 4 ether);
        (avg,) = _avg1h();
        assertEq(avg, 1 ether);
    }

    function test_lastSale_isUpdatedOnEverySale() public {
        _sell(1 ether);
        (uint128 price, uint64 ts, uint64 bn) = market.lastSale(address(nft));
        assertEq(price, 1 ether);
        assertEq(ts, T0);
        assertEq(bn, block.number);
        vm.warp(T0 + 5);
        _sell(2 ether);
        (price, ts, bn) = market.lastSale(address(nft));
        assertEq(price, 2 ether);
        assertEq(ts, T0 + 5);
        assertEq(bn, block.number);
    }

    function test_priceOracle_aggregatesEveryReading() public {
        _sell(2 ether);
        _mintAndList(alice, 1, 9 ether);
        (uint256 floor, uint256 a1h, uint256 a1d, uint256 a1w) = market.priceOracle(address(nft));
        assertEq(floor, 9 ether);
        assertEq(a1h, 2 ether);
        assertEq(a1d, 2 ether);
        assertEq(a1w, 2 ether);
    }

    function testFuzz_averageIsTheMeanOfSalesInsideTheWindow(uint96[4] memory prices) public {
        uint256 sum;
        for (uint256 i; i < prices.length; ++i) {
            prices[i] = uint96(bound(prices[i], 1, 100 ether));
            vm.deal(bob, prices[i]);
            _sell(prices[i]);
            sum += prices[i];
        }
        (uint256 avg, uint256 n) = _avg1h();
        assertEq(n, prices.length);
        assertEq(avg, sum / prices.length);
    }
}
