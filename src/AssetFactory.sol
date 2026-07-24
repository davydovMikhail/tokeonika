// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {TokenBase} from "./TokenBase.sol";
import {AssetV1} from "./AssetV1.sol";
import {AssetV2} from "./AssetV2.sol";

contract AssetFactory {

    mapping(address => bool) public isRegisteredAsset;
    address[] public allAssets;

    event AssetCreated(
        address indexed assetToken,
        address indexed assetAdmin,
        address indexed stablecoinToken,
        string name,
        string symbol
    );

    enum TypeAsset {
        Whitelist, // 0 - деплой актива с whitelist AssetV1
        Blacklist, // 1 - деплой актива с blacklist AssetV2
        Free       // 2 — деплой TokenBase без whitelist/blacklist
    }

    constructor() {
    }

    function createAsset(
        TypeAsset assetType,
        TokenBase.AssetTokenParams memory config
        // string calldata name,
        // string calldata symbol,
        // string calldata uri,
        // string calldata isin,
        // string calldata jurisdiction,
        // address assetAdmin,
        // address priceAuthority,       // если address(0) — AssetToken сам использует assetAdmin по умолчанию
        // address stablecoinToken,
        // address issuerTreasury,
        // address redemptionSource,
        // uint16 mintFeeBps,
        // uint16 redemptionFeeBps,
        // uint256 initialRate,
        // uint256 maxSupply

    ) external returns (address assetToken) {
        require(config.assetAdmin != address(0), "assetAdmin required");
        require(config.stablecoinToken != address(0), "stablecoinToken required");
        require(config.issuerTreasury != address(0), "issuerTreasury required");
        require(config.redemptionSource != address(0), "redemptionSource required");
        require(config.mintFeeBps <= 10_000 && config.redemptionFeeBps <= 10_000, "fee > 100%");
        require(config.initialRate > 0, "rate must be > 0");

        address resolvedPriceAuthority = config.priceAuthority == address(0) ? config.assetAdmin : config.priceAuthority;

        // TokenBase.AssetTokenParams memory config = TokenBase.AssetTokenParams({
        //     name: name,
        //     symbol: symbol,
        //     uri: uri,
        //     isin: isin,
        //     jurisdiction: jurisdiction,
        //     assetAdmin: assetAdmin,
        //     priceAuthority: resolvedPriceAuthority,
        //     stablecoinToken: stablecoinToken,
        //     issuerTreasury: issuerTreasury,
        //     redemptionSource: redemptionSource,
        //     mintFeeBps: mintFeeBps,
        //     redemptionFeeBps: redemptionFeeBps,
        //     initialRate: initialRate,
        //     maxSupply: maxSupply
        // });

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

        emit AssetCreated(assetToken, config.assetAdmin, config.stablecoinToken, config.name, config.symbol);
    }

    function totalAssets() external view returns (uint256) {
        return allAssets.length;
    }
}