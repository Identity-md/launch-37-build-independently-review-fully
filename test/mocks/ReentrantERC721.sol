// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MockERC721} from "./MockERC721.sol";
import {BazaarMarketplace} from "../../src/BazaarMarketplace.sol";

/// @notice An ERC-721 whose transfer hook reenters the marketplace.
/// @dev Armed once per attack. The hook fires on every transfer (including the marketplace's
/// custody pull and delivery push) and issues one nested marketplace call. With `swallow` set
/// the hook ignores the nested call's failure so the outer trade can still complete; without it
/// the nested revert is bubbled up so the outer trade fails.
contract ReentrantERC721 is MockERC721 {
    enum Attack {
        None,
        Buy,
        CancelListing,
        List,
        MakeOffer,
        CancelOffer,
        AcceptOffer
    }

    BazaarMarketplace public immutable market;

    Attack public attack;
    uint256 public targetId;
    uint256 public targetTokenId;
    uint256 public attackValue;
    bool public swallow;

    bool public attempted;
    bool public nestedCallSucceeded;
    bytes public nestedRevertData;

    constructor(BazaarMarketplace market_) {
        market = market_;
    }

    receive() external payable {}

    function arm(Attack attack_, uint256 targetId_, uint256 targetTokenId_, uint256 value, bool swallow_) external {
        attack = attack_;
        targetId = targetId_;
        targetTokenId = targetTokenId_;
        attackValue = value;
        swallow = swallow_;
        attempted = false;
        nestedCallSucceeded = false;
        delete nestedRevertData;
    }

    /// @dev Lets this contract list its own tokens on the marketplace.
    function approveMarket() external {
        _setApprovalForAll(address(this), address(market), true);
    }

    function _afterTokenTransfer(address, address, uint256) internal override {
        Attack a = attack;
        if (a == Attack.None) return;
        attack = Attack.None;

        bytes memory data;
        uint256 value;
        if (a == Attack.Buy) {
            data = abi.encodeCall(market.buy, (targetId));
            value = attackValue;
        } else if (a == Attack.CancelListing) {
            data = abi.encodeCall(market.cancelListing, (targetId));
        } else if (a == Attack.List) {
            data = abi.encodeCall(market.list, (address(this), targetTokenId, attackValue));
        } else if (a == Attack.MakeOffer) {
            data = abi.encodeCall(market.makeOffer, (address(this)));
            value = attackValue;
        } else if (a == Attack.CancelOffer) {
            data = abi.encodeCall(market.cancelOffer, (targetId));
        } else {
            data = abi.encodeCall(market.acceptOffer, (targetId, targetTokenId));
        }

        attempted = true;
        (bool ok, bytes memory ret) = address(market).call{value: value}(data);
        nestedCallSucceeded = ok;
        nestedRevertData = ret;
        if (!ok && !swallow) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }
}
