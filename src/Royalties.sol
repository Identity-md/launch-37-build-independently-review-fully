// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "solady/auth/Ownable.sol";
import {IRoyalties} from "./interfaces/IRoyalties.sol";
import {IRoyaltyImplementation} from "./interfaces/IRoyaltyImplementation.sol";

/// @notice Royalty policy for the Bazaar marketplace.
/// @dev The marketplace holds this contract's address as an immutable and asks it on every sale.
/// The *logic* that decides who is owed what lives in a swappable implementation that only the
/// owner can change; the *bound* does not. Whatever the implementation answers, this contract
/// hardcodes that a royalty is between 0 and 5% of the sale price inclusive and reverts otherwise.
///
/// Until an implementation is set there is no royalty and no recipient: `royaltyInfo` returns
/// `(address(0), 0)` without making any external call.
///
/// The implementation is reached with a regular STATICCALL, never DELEGATECALL, so it cannot touch
/// this contract's storage, cannot reenter the marketplace, and cannot change who the owner is.
contract Royalties is Ownable, IRoyalties {
    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Basis-point denominator.
    uint256 public constant BPS = 10_000;

    /// @notice Hard ceiling on any royalty: 5% of the sale price. Not configurable.
    uint256 public constant MAX_ROYALTY_BPS = 500;

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice The contract royalty logic is delegated to. Zero means royalties are off.
    address public implementation;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted whenever the owner swaps the royalty implementation.
    event RoyaltyImplementationChanged(
        address indexed previousImplementation, address indexed newImplementation, address indexed by
    );

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error ZeroAddress();
    error ImplementationNotAContract(address implementation);
    error RoyaltyOutOfBounds(uint256 royaltyAmount, uint256 maxRoyaltyAmount);
    error RoyaltyReceiverMissing();

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param owner_ The project owner (`$owner` in the launch manifest). Never `msg.sender`:
    /// the factory constructs this contract and must not end up in control of it.
    constructor(address owner_) {
        if (owner_ == address(0)) revert ZeroAddress();
        _initializeOwner(owner_);
    }

    /*//////////////////////////////////////////////////////////////
                                  ADMIN
    //////////////////////////////////////////////////////////////*/

    /// @notice Swap the royalty implementation. Pass `address(0)` to switch royalties off.
    /// @dev Only a deployed contract is accepted; an address without code would make every
    /// sale revert on ABI decoding until it was replaced.
    function setImplementation(address newImplementation) external onlyOwner {
        if (newImplementation != address(0) && newImplementation.code.length == 0) {
            revert ImplementationNotAContract(newImplementation);
        }
        address previous = implementation;
        implementation = newImplementation;
        emit RoyaltyImplementationChanged(previous, newImplementation, msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                                  VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IRoyalties
    /// @dev Reverts if the implementation answers with more than `MAX_ROYALTY_BPS` of `salePrice`
    /// or with a positive amount and no receiver. A zero amount is normalised to `(0, 0)`.
    function royaltyInfo(address collection, uint256 tokenId, uint256 salePrice)
        external
        view
        override
        returns (address receiver, uint256 royaltyAmount)
    {
        address impl = implementation;
        if (impl == address(0)) return (address(0), 0);

        (receiver, royaltyAmount) = IRoyaltyImplementation(impl).royaltyInfo(collection, tokenId, salePrice);

        if (royaltyAmount == 0) return (address(0), 0);
        uint256 maxAmount = maxRoyalty(salePrice);
        if (royaltyAmount > maxAmount) revert RoyaltyOutOfBounds(royaltyAmount, maxAmount);
        if (receiver == address(0)) revert RoyaltyReceiverMissing();
    }

    /// @notice The largest royalty this contract will ever pass through for `salePrice`.
    function maxRoyalty(uint256 salePrice) public pure returns (uint256) {
        return salePrice * MAX_ROYALTY_BPS / BPS;
    }
}
