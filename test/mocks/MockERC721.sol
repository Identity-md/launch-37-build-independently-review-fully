// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC721} from "solady/tokens/ERC721.sol";

/// @notice A well-behaved ERC-721 with a public mint, for tests.
contract MockERC721 is ERC721 {
    function name() public pure virtual override returns (string memory) {
        return "Mock NFT";
    }

    function symbol() public pure virtual override returns (string memory) {
        return "MOCK";
    }

    function tokenURI(uint256) public pure virtual override returns (string memory) {
        return "";
    }

    function mint(address to, uint256 id) external {
        _mint(to, id);
    }
}
