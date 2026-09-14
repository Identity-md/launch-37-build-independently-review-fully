// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MockERC721} from "./MockERC721.sol";

/// @notice An ERC-721 that can be switched to revert on transfers or on `ownerOf`.
contract RevertingERC721 is MockERC721 {
    bool public revertOnTransfer;
    bool public revertOnOwnerOf;

    error TransferRejected();
    error OwnerOfRejected();

    function setRevertOnTransfer(bool value) external {
        revertOnTransfer = value;
    }

    function setRevertOnOwnerOf(bool value) external {
        revertOnOwnerOf = value;
    }

    function ownerOf(uint256 id) public view virtual override returns (address result) {
        if (revertOnOwnerOf) revert OwnerOfRejected();
        return super.ownerOf(id);
    }

    function _beforeTokenTransfer(address from, address, uint256) internal virtual override {
        // Mints still work so tests can set the scene; only real transfers are rejected.
        if (revertOnTransfer && from != address(0)) revert TransferRejected();
    }
}
