// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice A contract that speaks just enough ERC-721 to be traded and lies about ownership.
/// @dev `transferFrom` never checks authorisation (anyone can "move" anyone's token), and can be
/// switched to a silent no-op. `ownerOf` can be pinned to a fixed answer regardless of state.
contract LyingERC721 {
    mapping(uint256 => address) internal _owner;

    /// @notice When non-zero, `ownerOf` always returns this address.
    address public fixedOwner;

    /// @notice When set, `transferFrom` does nothing and reports success.
    bool public noopTransfers;

    event Transfer(address indexed from, address indexed to, uint256 indexed id);

    function mint(address to, uint256 id) external {
        _owner[id] = to;
        emit Transfer(address(0), to, id);
    }

    function setFixedOwner(address value) external {
        fixedOwner = value;
    }

    function setNoopTransfers(bool value) external {
        noopTransfers = value;
    }

    function ownerOf(uint256 id) external view returns (address) {
        return fixedOwner != address(0) ? fixedOwner : _owner[id];
    }

    function transferFrom(address from, address to, uint256 id) external {
        if (noopTransfers) return;
        _owner[id] = to;
        emit Transfer(from, to, id);
    }

    function approve(address, uint256) external {}

    function setApprovalForAll(address, bool) external {}
}
