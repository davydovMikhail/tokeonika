// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {TokenBase} from "./TokenBase.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";

// Whitelist + Pausable + Force transfer/burn
contract AssetV1 is TokenBase, Pausable {

    mapping(address => bool) internal isWhitelisted;

    constructor(
        AssetTokenParams memory _config
    ) TokenBase(
        _config
    ) {
    }

    event WhitelistAdded(address indexed investor);
    event WhitelistRemoved(address indexed investor);

    // ---------------------------------------------------------------------
    // Pause (Asset Admin)
    // ---------------------------------------------------------------------

    function pause() external onlyAssetAdmin {
        _pause();
    }

    function unpause() external onlyAssetAdmin {
        _unpause();
    }

    // ---------------------------------------------------------------------
    // Force transfer / force burn (Asset Admin)
    // ---------------------------------------------------------------------

    function forceTransfer(address from, address to, uint256 amount) external onlyAssetAdmin {
        _transfer(from, to, amount);
    }

    function forceBurn(address from, uint256 amount) external onlyAssetAdmin {
        _rawBurn(from, amount);
    }

    function addToWhitelist(address investor) external onlyAssetAdmin {
        isWhitelisted[investor] = true;
        emit WhitelistAdded(investor);
    }

    function removeFromWhitelist(address investor) external onlyAssetAdmin {
        isWhitelisted[investor] = false;
        emit WhitelistRemoved(investor);
    }

    function isAllowed(address investor) external view returns (bool) {
        return isWhitelisted[investor];
    }

    function _update(address from, address to, uint256 value) internal virtual override {
        require(!isClosed, "asset closed");
        require(!paused(), "asset paused");

        if (from == address(0)) {
            require(_isAllowed(to), "recipient not whitelisted");
        } else if (to == address(0)) {
            require(_isAllowed(from), "sender not whitelisted");
        } else {
            require(_isAllowed(from), "sender not whitelisted");
            require(_isAllowed(to), "recipient not whitelisted");
        }

        super._update(from, to, value);
    }

    function _isAllowed(address investor) internal view returns (bool) {
        return isWhitelisted[investor];
    }

    function _rawBurn(address from, uint256 amount) internal {
        super._update(from, address(0), amount);
    }
}