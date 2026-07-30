// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {TokenBase} from "./TokenBase.sol";
import {AssetV1} from "./AssetV1.sol";
import {AssetV2} from "./AssetV2.sol";

// TODO(platform-admin-gate): uncomment to require createAsset to be called only by the
// Platform Admin. See the three commented blocks below marked with the same tag.
// import {IPlatformConfig} from "./interfaces/IPlatformConfig.sol";

contract AssetFactory {

    mapping(address => bool) public isRegisteredAsset;
    address[] public allAssets;

    // TODO(platform-admin-gate): uncomment
    // IPlatformConfig public immutable platformConfig;

    /// @notice Emitted when a new asset token is deployed and registered
    /// @param assetToken Address of the newly deployed asset token contract
    /// @param assetType Admission model the asset was deployed with (Whitelist / Blacklist / Free)
    event AssetCreated(address indexed assetToken, TypeAsset assetType);

    /// @notice Selects which asset token implementation createAsset deploys
    /// @dev Whitelist -> AssetV1 (default-deny, admission via whitelist); Blacklist -> AssetV2 (default-allow, admission via blacklist); Free -> bare TokenBase (no admission checks, no pause, no forced actions)
    enum TypeAsset {
        Whitelist, // 0 - deploy AssetV1 with whitelist 
        Blacklist, // 1 - deploy AssetV2 with blacklist 
        Free       // 2 — deploy TokenBase without whitelist/blacklist
    }

    constructor() {
    }

    // TODO(platform-admin-gate): delete the constructor above and uncomment this one instead.
    // Requires passing the address of an already-deployed PlatformConfig at deploy time.
    //
    // constructor(address _platformConfig) {
    //     require(_platformConfig != address(0), "zero address");
    //     platformConfig = IPlatformConfig(_platformConfig);
    // }

    // TODO(platform-admin-gate): uncomment. Once uncommented, also remove the /* */
    // around `onlyPlatformAdmin` in createAsset's signature below.
    //
    // modifier onlyPlatformAdmin() {
    //     require(msg.sender == platformConfig.owner(), "not platform admin");
    //     _;
    // }

    /// @notice Deploys a new asset token and registers it with the factory
    /// @dev Intentionally callable by anyone — this is a deliberate testnet/demo choice, not
    ///      the intended production behavior. To restrict this to the Platform Admin before
    ///      going to production, apply the three commented TODO(platform-admin-gate) blocks
    ///      above and remove the /* */ around `onlyPlatformAdmin` just below. Validates
    ///      required config fields and fee/rate bounds before deployment, then dispatches to
    ///      the corresponding implementation based on assetType.
    /// @param assetType Admission model to deploy (Whitelist / Blacklist / Free)
    /// @param config Full set of asset parameters passed through to the token's constructor (see TokenBase.AssetTokenParams)
    /// @return assetToken Address of the newly deployed asset token
    function createAsset(
        TypeAsset assetType,
        TokenBase.AssetTokenParams memory config
    ) external /* onlyPlatformAdmin */ returns (address assetToken) {
        require(config.assetAdmin != address(0), "assetAdmin required");
        require(config.stablecoinToken != address(0), "stablecoinToken required");
        require(config.issuerTreasury != address(0), "issuerTreasury required");
        require(config.redemptionSource != address(0), "redemptionSource required");
        require(config.priceAuthority != address(0), "priceAuthority required");
        require(config.mintFeeBps <= 10_000 && config.redemptionFeeBps <= 10_000, "fee > 100%");
        require(config.initialRate > 0, "rate must be > 0");


        if (assetType == TypeAsset.Whitelist) {
            assetToken = address(
            new AssetV1(
                config
                )
            );
        } 
        else if (assetType == TypeAsset.Blacklist) {
            assetToken = address(
            new AssetV2(
                config
                )
            );
        } else if (assetType == TypeAsset.Free) {
            assetToken = address(
            new TokenBase(
                config
                )
            );
        }

        isRegisteredAsset[assetToken] = true;
        allAssets.push(assetToken);

        emit AssetCreated(assetToken, assetType);
    }

    /// @notice Returns the total number of assets deployed through this factory
    /// @dev Reads allAssets.length; useful for indexers/off-chain paginating over allAssets
    /// @return uint256 Count of registered assets
    function totalAssets() external view returns (uint256) {
        return allAssets.length;
    }
}