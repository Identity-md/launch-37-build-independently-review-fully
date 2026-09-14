// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "solady/tokens/ERC20.sol";

/// @notice The Bazaar launch token: fixed supply, 18 decimals, no admin.
/// @dev Deployed by ProjectFactory. The constructor takes no arguments and mints the entire
/// supply of 1,000,000,000 tokens (10^27 minor units) to `msg.sender`, which is the factory.
/// There is no mint, burn-by-admin, pause, owner, or upgrade path: the runtime is a plain
/// Solady ERC-20 with EIP-2612 permit.
contract BazaarToken is ERC20 {
    /// @notice Sepolia policy v3: exactly 10^27 minor units.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e18;

    constructor() {
        _mint(msg.sender, TOTAL_SUPPLY);
    }

    function name() public pure override returns (string memory) {
        return "Bazaar";
    }

    function symbol() public pure override returns (string memory) {
        return "BZR";
    }

    /// @dev Lets Solady cache the EIP-712 name hash instead of hashing `name()` on every permit.
    function _constantNameHash() internal pure override returns (bytes32) {
        return keccak256(bytes("Bazaar"));
    }
}
