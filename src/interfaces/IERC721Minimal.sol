// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice The two ERC-721 entry points the marketplace relies on.
/// @dev Declared minimally so that any collection can be traded, including ones that predate
/// ERC-165 or that return non-standard data. `ownerOf` is `view` so that the compiler emits a
/// STATICCALL: a collection cannot mutate state (or reenter) while the marketplace reads ownership.
interface IERC721Minimal {
    function ownerOf(uint256 tokenId) external view returns (address);
    function transferFrom(address from, address to, uint256 tokenId) external;
}
