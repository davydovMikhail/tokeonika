// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Ownable2Step} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";

/// @title PlatformConfig
/// @notice Holds the single Platform Admin address for the whole white-label deployment
/// @dev Thin wrapper around OpenZeppelin's Ownable2Step. owner() is the Platform Admin.
///      All two-step ownership transfer logic (transferOwnership / acceptOwnership) is
///      inherited as-is — this contract adds no logic of its own beyond wiring up the
///      initial owner in the constructor.
///
///      Ownable2Step protects against a typo'd address during a voluntary handoff: the
///      new owner must explicitly call acceptOwnership() before control actually transfers.
///      It does NOT protect against key loss — if the current Platform Admin loses access
///      to their key, there is no recovery path; this is an accepted risk
///
///      Other contracts (e.g. AssetFactory) reference this contract's owner() through the
///      minimal IPlatformConfig interface rather than importing Ownable2Step directly, to
///      keep their dependency surface to a single view function.
contract PlatformConfig is Ownable2Step {
    /// @notice Sets the initial Platform Admin
    /// @dev Ownable (as of the version used here) requires an explicit initial owner —
    ///      there is no implicit "owner = deployer" fallback.
    /// @param initialOwner Address to be set as the first Platform Admin
    constructor(address initialOwner) Ownable(initialOwner) {}
}