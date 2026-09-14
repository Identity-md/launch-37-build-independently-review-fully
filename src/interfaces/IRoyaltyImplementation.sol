// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice The interface a swappable royalty implementation must expose to `Royalties`.
/// @dev Mirrors ERC-2981's `royaltyInfo` with the collection address prepended, so one
/// implementation can serve every collection. `Royalties` calls it through a STATICCALL and
/// enforces the 0-5% bound itself; an implementation cannot widen that bound.
interface IRoyaltyImplementation {
    function royaltyInfo(address collection, uint256 tokenId, uint256 salePrice)
        external
        view
        returns (address receiver, uint256 royaltyAmount);
}
