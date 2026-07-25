// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {TokenBase} from "./TokenBase.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";

// blacklist + Pausable + Force transfer/burn
contract AssetV2 is TokenBase, Pausable {

    mapping(address => bool) internal isBlacklisted;

    constructor(
        AssetTokenParams memory _config
    ) TokenBase(
        _config
    ) {
    }

    event BlacklistAdded(address indexed investor);
    event BlacklistRemoved(address indexed investor);

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

    function addToBlacklist(address investor) external onlyAssetAdmin {
        isBlacklisted[investor] = true;
        emit BlacklistAdded(investor);
    }

    function removeFromBlacklist(address investor) external onlyAssetAdmin {
        isBlacklisted[investor] = false;
        emit BlacklistRemoved(investor);
    }

    function isAllowed(address investor) external view returns (bool) {
        return !isBlacklisted[investor];
    }

    function _update(address from, address to, uint256 value) internal virtual override {
        require(!isClosed, "asset closed");
        require(!paused(), "asset paused");

        if (from == address(0)) {
            require(_isAllowed(to), "recipient blacklisted");
        } else if (to == address(0)) {
            require(_isAllowed(from), "sender blacklisted");
        } else {
            require(_isAllowed(from), "sender blacklisted");
            require(_isAllowed(to), "recipient blacklisted");
        }

        super._update(from, to, value);
    }

    function _isAllowed(address investor) internal view returns (bool) {
        return !isBlacklisted[investor];
    }

    function _rawBurn(address from, uint256 amount) internal {
        super._update(from, address(0), amount);
    }
}