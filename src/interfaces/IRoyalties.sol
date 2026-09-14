// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice What the marketplace asks the Royalties contract on every sale.
/// @dev `view` on purpose: the marketplace reaches royalty logic through a STATICCALL, so neither
/// the Royalties contract nor whatever implementation it delegates to can reenter a trade.
interface IRoyalties {
    /// @notice Royalty owed on a sale, already bounded to [0, MAX_ROYALTY_BPS] of `salePrice`.
    /// @return receiver Where the royalty goes; `address(0)` when `royaltyAmount` is zero.
    /// @return royaltyAmount Wei owed, never more than 5% of `salePrice`.
    function royaltyInfo(address collection, uint256 tokenId, uint256 salePrice)
        external
        view
        returns (address receiver, uint256 royaltyAmount);
}
