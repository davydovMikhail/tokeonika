// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {TokenBase} from "../../src/TokenBase.sol";
import {AssetV1} from "../../src/AssetV1.sol";
import {AssetV2} from "../../src/AssetV2.sol";
import {AssetFactory} from "../../src/AssetFactory.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @notice Shared fixtures for the whole suite: actors, a mock stablecoin, the
///         factory, and a helper to build AssetTokenParams so individual test
///         files don't repeat 14-field struct literals.
abstract contract TestBase is Test {
    // Actors
    address internal platformAdmin = makeAddr("platformAdmin");
    address internal assetAdmin = makeAddr("assetAdmin");
    address internal priceAuthority = makeAddr("priceAuthority");
    address internal issuerTreasury = makeAddr("issuerTreasury");
    address internal redemptionSource = makeAddr("redemptionSource");
    address internal investorA = makeAddr("investorA");
    address internal investorB = makeAddr("investorB");
    address internal stranger = makeAddr("stranger");

    MockERC20 internal stablecoin;
    AssetFactory internal factory;

    uint256 internal constant RATE_PRECISION = 1e18;
    uint256 internal constant ONE_TO_ONE_USDC_RATE = 1_000_000; // 1 whole asset token == 1 USDC (6 decimals)

    function setUpBase() internal {
        stablecoin = new MockERC20("Mock USDC", "mUSDC", 6);
        factory = new AssetFactory();

        // redemptionSource needs to pre-approve the asset contract per-asset;
        // individual test files grant allowance after the asset is deployed,
        // since the spender address (the asset token) isn't known beforehand.
        stablecoin.mint(investorA, 1_000_000 * 1e6);
        stablecoin.mint(investorB, 1_000_000 * 1e6);
        stablecoin.mint(redemptionSource, 1_000_000 * 1e6);
    }

    function defaultParams(string memory name_, string memory symbol_)
        internal
        view
        returns (TokenBase.AssetTokenParams memory)
    {
        return TokenBase.AssetTokenParams({
            name: name_,
            symbol: symbol_,
            uri: "ipfs://asset-doc",
            isin: "US0000000000",
            jurisdiction: "US",
            assetAdmin: assetAdmin,
            priceAuthority: priceAuthority,
            stablecoinToken: address(stablecoin),
            issuerTreasury: issuerTreasury,
            redemptionSource: redemptionSource,
            mintFeeBps: 20, // 0.2%
            redemptionFeeBps: 50, // 0.5%
            initialRate: ONE_TO_ONE_USDC_RATE,
            maxSupply: 1_000_000 ether
        });
    }

    function deployWhitelistAsset() internal returns (AssetV1) {
        TokenBase.AssetTokenParams memory p = defaultParams("Whitelist Asset", "WLA");
        address token = factory.createAsset(AssetFactory.TypeAsset.Whitelist, p);
        return AssetV1(token);
    }

    function deployBlacklistAsset() internal returns (AssetV2) {
        TokenBase.AssetTokenParams memory p = defaultParams("Blacklist Asset", "BLA");
        address token = factory.createAsset(AssetFactory.TypeAsset.Blacklist, p);
        return AssetV2(token);
    }

    function deployFreeAsset() internal returns (TokenBase) {
        TokenBase.AssetTokenParams memory p = defaultParams("Free Asset", "FRA");
        address token = factory.createAsset(AssetFactory.TypeAsset.Free, p);
        return TokenBase(token);
    }

    /// @dev redemptionSource must pre-approve the asset contract before redeem() works
    function approveRedemptionSource(address asset) internal {
        vm.prank(redemptionSource);
        stablecoin.approve(asset, type(uint256).max);
    }

    function approveMint(address investor, address asset, uint256 amount) internal {
        vm.prank(investor);
        stablecoin.approve(asset, amount);
    }
}
