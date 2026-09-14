// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "solady/auth/Ownable.sol";
import {IRoyaltyImplementation} from "./interfaces/IRoyaltyImplementation.sol";

/// @notice Reference royalty implementation: a per-collection (receiver, basis points) table.
/// @dev Optional. `Royalties` starts with no implementation; the owner may deploy this contract
/// (or any other `IRoyaltyImplementation`) and point `Royalties.setImplementation` at it.
/// The 5% ceiling is enforced again here purely for operator ergonomics; the binding check is
/// the one hardcoded in `Royalties`.
contract RoyaltyRegistry is Ownable, IRoyaltyImplementation {
    struct CollectionRoyalty {
        address receiver;
        uint16 bps;
    }

    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_ROYALTY_BPS = 500;

    mapping(address collection => CollectionRoyalty) public collectionRoyalty;

    event CollectionRoyaltySet(address indexed collection, address indexed receiver, uint16 bps, address indexed by);

    error ZeroAddress();
    error InvalidRoyalty();

    /// @param owner_ The project owner (`$owner`), never `msg.sender`.
    constructor(address owner_) {
        if (owner_ == address(0)) revert ZeroAddress();
        _initializeOwner(owner_);
    }

    /// @notice Set (or clear, with `bps == 0`) the royalty for one collection.
    function setCollectionRoyalty(address collection, address receiver, uint16 bps) external onlyOwner {
        if (bps > MAX_ROYALTY_BPS) revert InvalidRoyalty();
        if (bps != 0 && receiver == address(0)) revert InvalidRoyalty();
        collectionRoyalty[collection] = CollectionRoyalty(receiver, bps);
        emit CollectionRoyaltySet(collection, receiver, bps, msg.sender);
    }

    /// @inheritdoc IRoyaltyImplementation
    function royaltyInfo(address collection, uint256, uint256 salePrice)
        external
        view
        override
        returns (address receiver, uint256 royaltyAmount)
    {
        CollectionRoyalty memory r = collectionRoyalty[collection];
        if (r.bps == 0) return (address(0), 0);
        return (r.receiver, salePrice * r.bps / BPS);
    }
}
