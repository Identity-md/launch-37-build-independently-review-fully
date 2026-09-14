// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IRoyaltyImplementation} from "../../src/interfaces/IRoyaltyImplementation.sol";

/// @notice A royalty implementation the tests can steer to any answer, including bad ones.
contract MockRoyaltyImplementation is IRoyaltyImplementation {
    address public receiver;
    uint256 public bps;
    uint256 public fixedAmount;
    bool public useFixedAmount;
    bool public shouldRevert;

    error ImplementationReverted();

    function setBps(address receiver_, uint256 bps_) external {
        receiver = receiver_;
        bps = bps_;
        useFixedAmount = false;
    }

    function setFixedAmount(address receiver_, uint256 amount) external {
        receiver = receiver_;
        fixedAmount = amount;
        useFixedAmount = true;
    }

    function setShouldRevert(bool value) external {
        shouldRevert = value;
    }

    function royaltyInfo(address, uint256, uint256 salePrice) external view override returns (address, uint256) {
        if (shouldRevert) revert ImplementationReverted();
        if (useFixedAmount) return (receiver, fixedAmount);
        return (receiver, salePrice * bps / 10_000);
    }
}
