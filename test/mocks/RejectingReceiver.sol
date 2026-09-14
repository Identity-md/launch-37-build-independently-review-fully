// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice An address that refuses every ETH transfer.
contract RejectingReceiver {
    error NoEther();

    receive() external payable {
        revert NoEther();
    }
}
