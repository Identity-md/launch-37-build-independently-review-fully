// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BazaarToken} from "../src/BazaarToken.sol";
import {Royalties} from "../src/Royalties.sol";
import {RoyaltyRegistry} from "../src/RoyaltyRegistry.sol";
import {BazaarMarketplace} from "../src/BazaarMarketplace.sol";

/// @notice Mirrors what ProjectFactory does: the factory is `msg.sender` for every constructor,
/// the token is deployed first, then the application contracts in manifest order with static
/// arguments only. Nothing here broadcasts; it is a local rehearsal of the launch floor.
contract LaunchTest is Test {
    address internal factory = makeAddr("factory");
    address internal owner = makeAddr("owner");

    BazaarToken internal token;
    Royalties internal royalties;
    BazaarMarketplace internal market;
    RoyaltyRegistry internal registry;

    function setUp() public {
        vm.startPrank(factory);
        token = new BazaarToken();
        // Manifest order: Royalties($owner) then Marketplace($owner, $contract:Royalties).
        royalties = new Royalties(owner);
        market = new BazaarMarketplace(owner, address(royalties));
        // Optional third application contract.
        registry = new RoyaltyRegistry(owner);
        vm.stopPrank();
    }

    function test_tokenMintsTheWholeSupplyToTheFactory() public view {
        assertEq(token.totalSupply(), 10 ** 27);
        assertEq(token.balanceOf(factory), 10 ** 27);
        assertEq(token.decimals(), 18);
    }

    function test_applicationConstructorsLeaveTheSupplyUntouched() public view {
        assertEq(token.balanceOf(factory), 10 ** 27, "a constructor moved the launch supply");
        assertEq(token.totalSupply(), 10 ** 27);
    }

    function test_privilegesGoToOwnerNotToTheFactory() public view {
        assertEq(royalties.owner(), owner);
        assertEq(registry.owner(), owner);
        assertEq(market.feeRecipient(), owner);
        assertEq(address(market.royalties()), address(royalties));
        assertTrue(royalties.owner() != factory, "the factory must never hold a role");
        assertTrue(market.feeRecipient() != factory, "the factory must never receive fees");
    }

    function test_marketplaceIsUsableRightAfterDeployment() public view {
        // No initialisation call is needed: the factory makes none.
        assertEq(market.nextListingId(), 1);
        assertEq(market.nextOfferId(), 1);
        (address r, uint256 amount) = market.royalties().royaltyInfo(address(0xBEEF), 1, 1 ether);
        assertEq(r, address(0));
        assertEq(amount, 0);
    }

    function test_runtimeIsBoundedAndFreeOfForbiddenOpcodes() public view {
        address[4] memory deployed = [address(token), address(royalties), address(market), address(registry)];
        for (uint256 i; i < deployed.length; ++i) {
            bytes memory code = deployed[i].code;
            assertGt(code.length, 0, "missing runtime");
            assertLe(code.length, 24_576, "runtime exceeds EIP-170");
            _assertNoForbiddenOpcodes(code);
        }
    }

    /// @dev Same scan as the launch floor: skips PUSH immediates so constants cannot false-positive.
    function _assertNoForbiddenOpcodes(bytes memory code) internal pure {
        for (uint256 j; j < code.length; ++j) {
            uint8 op = uint8(code[j]);
            if (op >= 0x60 && op <= 0x7f) {
                j += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4, "DELEGATECALL in runtime");
            assertTrue(op != 0xf2, "CALLCODE in runtime");
            assertTrue(op != 0xff, "SELFDESTRUCT in runtime");
        }
    }
}
