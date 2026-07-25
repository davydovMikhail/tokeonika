// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {TokenBase} from "./TokenBase.sol";
import {AssetV1} from "./AssetV1.sol";
import {AssetV2} from "./AssetV2.sol";

contract AssetFactory {

    mapping(address => bool) public isRegisteredAsset;
    address[] public allAssets;

    event AssetCreated(address indexed assetToken, TypeAsset assetType);

    enum TypeAsset {
        Whitelist, // 0 - deploy AssetV1 with whitelist 
        Blacklist, // 1 - deploy AssetV2 with blacklist 
        Free       // 2 — deploy TokenBase without whitelist/blacklist
    }

    constructor() {
    }

    function createAsset(
        TypeAsset assetType,
        TokenBase.AssetTokenParams memory config
    ) external returns (address assetToken) {
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

    function totalAssets() external view returns (uint256) {
        return allAssets.length;
    }
}