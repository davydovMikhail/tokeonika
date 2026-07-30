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

    /// @notice Pauses all transfers, mints, and redemptions for this asset
    /// @dev Callable only by assetAdmin. Standard Pausable._pause()
    function pause() external onlyAssetAdmin {
        _pause();
    }

    /// @notice Resumes transfers, mints, and redemptions for this asset
    /// @dev Callable only by assetAdmin. Standard Pausable._unpause()
    function unpause() external onlyAssetAdmin {
        _unpause();
    }

    // ---------------------------------------------------------------------
    // Force transfer / force burn (Asset Admin)
    // ---------------------------------------------------------------------

    /// @notice Forcibly moves tokens between two addresses without the sender's signature
    /// @dev Callable only by assetAdmin. Only removes the requirement for `from` to sign/approve — admission checks (whitelist), pause, and isClosed still apply to both sides via the overridden _update
    /// @param from Address tokens are moved from
    /// @param to Address tokens are moved to
    /// @param amount Amount of asset tokens to move
    function forceTransfer(address from, address to, uint256 amount) external onlyAssetAdmin {
        _transfer(from, to, amount);
    }

    /// @notice Forcibly burns tokens from an address, bypassing all transfer restrictions
    /// @dev Callable only by assetAdmin. Routes through _rawBurn, which calls the base ERC20._update directly — bypasses admission checks, pause, and isClosed. Intentional: the admin must be able to seize tokens even in an emergency, while the asset is paused or closed
    /// @param from Address tokens are burned from
    /// @param amount Amount of asset tokens to burn
    function forceBurn(address from, uint256 amount) external onlyAssetAdmin {
        _rawBurn(from, amount);
    }

    /// @notice Grants admission to the given address
    /// @dev Callable only by assetAdmin. Adds to the allow-list (default-deny model) — the address becomes admitted only after this call
    /// @param investor Address to add to the list
    function addToWhitelist(address investor) external onlyAssetAdmin {
        isWhitelisted[investor] = true;
        emit WhitelistAdded(investor);
    }

    /// @notice Revokes admission from the given address
    /// @dev Callable only by assetAdmin. Removes from the allow-list, revoking admission
    /// @param investor Address to remove from the list
    function removeFromWhitelist(address investor) external onlyAssetAdmin {
        isWhitelisted[investor] = false;
        emit WhitelistRemoved(investor);
    }

    /// @notice Checks whether an address is currently admitted to hold/transact this asset
    /// @dev returns isWhitelisted[investor] directly
    /// @param investor Address to check
    /// @return bool True if the address is currently admitted
    function isAllowed(address investor) external view returns (bool) {
        return isWhitelisted[investor];
    }

    /// @notice Enforces admission, pause, and closure rules on every mint, burn, and transfer
    /// @dev Reverts if isClosed or paused(). For from == address(0) (mint), checks admission of `to`. For to == address(0) (burn), checks admission of `from`. For a regular transfer, checks admission of both sides. Admission = whitelisted. Delegates to super._update after checks pass
    /// @param from Sender address (address(0) on mint)
    /// @param to Recipient address (address(0) on burn)
    /// @param value Amount of tokens involved
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

    /// @dev Internal admission check used by _update. Returns isWhitelisted[investor].
    /// @param investor Address to check
    /// @return bool True if the address is currently admitted
    function _isAllowed(address investor) internal view returns (bool) {
        return isWhitelisted[investor];
    }

    /// @dev Internal burn that bypasses the overridden _update entirely by calling the base ERC20._update directly — used by forceBurn to ignore admission, pause, and isClosed
    /// @param from Address tokens are burned from
    /// @param amount Amount of asset tokens to burn
    function _rawBurn(address from, uint256 amount) internal {
        super._update(from, address(0), amount);
    }
}