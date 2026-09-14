// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BazaarToken} from "../src/BazaarToken.sol";

/// @notice The launch token: fixed supply to the deployer, 18 decimals, exact transfers, no admin.
contract BazaarTokenTest is Test {
    address internal deployer = makeAddr("factory");
    BazaarToken internal token;

    function setUp() public {
        vm.prank(deployer);
        token = new BazaarToken();
    }

    function test_mintsExactlyOneBillionToTheDeployer() public view {
        assertEq(token.totalSupply(), 1_000_000_000e18);
        assertEq(token.totalSupply(), 10 ** 27);
        assertEq(token.balanceOf(deployer), token.totalSupply());
        assertEq(token.TOTAL_SUPPLY(), token.totalSupply());
    }

    function test_metadata() public view {
        assertEq(token.name(), "Bazaar");
        assertEq(token.symbol(), "BZR");
        assertEq(token.decimals(), 18);
    }

    function test_transferMovesExactlyTheAmount() public {
        address to = makeAddr("to");
        vm.prank(deployer);
        assertTrue(token.transfer(to, 1e18));
        assertEq(token.balanceOf(to), 1e18);
        assertEq(token.balanceOf(deployer), 10 ** 27 - 1e18);
        assertEq(token.totalSupply(), 10 ** 27);
    }

    function test_hasNoMintOrAdminSurface() public {
        string[6] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            vm.prank(deployer);
            (bool ok,) = address(token).call(abi.encodeWithSignature(signatures[i], deployer, uint256(1)));
            assertFalse(ok, signatures[i]);
            assertEq(token.totalSupply(), 10 ** 27, signatures[i]);
        }
    }

    function test_permitDomainUsesTheConstantName() public view {
        bytes32 expected = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("Bazaar"),
                keccak256("1"),
                block.chainid,
                address(token)
            )
        );
        assertEq(token.DOMAIN_SEPARATOR(), expected);
    }
}
