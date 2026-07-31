// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {TestBase} from "./helpers/TestBase.t.sol";
import {AssetFactory} from "../src/AssetFactory.sol";
import {AssetV1} from "../src/AssetV1.sol";
import {AssetV2} from "../src/AssetV2.sol";
import {TokenBase} from "../src/TokenBase.sol";

contract AssetFactoryTest is TestBase {
    function setUp() public {
        setUpBase();
    }

    // ---------------------------------------------------------------
    // createAsset is currently permissionless — any address may
    // deploy any asset type. This is documented as intentional testnet
    // behavior, so we assert the *current* unrestricted behavior rather
    // than an onlyPlatformAdmin gate.
    // ---------------------------------------------------------------
    function test_anyAddressCanCreateAsset() public {
        TokenBase.AssetTokenParams memory p = defaultParams("Anyone's Asset", "ANY");

        vm.prank(stranger);
        address token = factory.createAsset(AssetFactory.TypeAsset.Whitelist, p);

        assertTrue(factory.isRegisteredAsset(token));
        assertEq(AssetV1(token).assetAdmin(), assetAdmin);
    }

    function test_createAsset_deploysWhitelistVariant() public {
        TokenBase.AssetTokenParams memory p = defaultParams("WL", "WL");
        address token = factory.createAsset(AssetFactory.TypeAsset.Whitelist, p);

        // AssetV1-specific function must exist and be callable
        vm.prank(assetAdmin);
        AssetV1(token).addToWhitelist(investorA);
        assertTrue(AssetV1(token).isAllowed(investorA));
    }

    function test_createAsset_deploysBlacklistVariant() public {
        TokenBase.AssetTokenParams memory p = defaultParams("BL", "BL");
        address token = factory.createAsset(AssetFactory.TypeAsset.Blacklist, p);

        // default-allow: nobody blacklisted yet
        assertTrue(AssetV2(token).isAllowed(investorA));
        vm.prank(assetAdmin);
        AssetV2(token).addToBlacklist(investorA);
        assertFalse(AssetV2(token).isAllowed(investorA));
    }

    function test_createAsset_deploysFreeVariant() public {
        TokenBase.AssetTokenParams memory p = defaultParams("Free", "FREE");
        address token = factory.createAsset(AssetFactory.TypeAsset.Free, p);

        // Free variant is a bare TokenBase — no whitelist/blacklist functions exist,
        // so we only assert it behaves as plain ERC20 (name/symbol wired correctly).
        assertEq(TokenBase(token).name(), "Free");
        assertEq(TokenBase(token).symbol(), "FREE");
    }

    function test_createAsset_registersAndTracksAllAssets() public {
        assertEq(factory.totalAssets(), 0);

        address t1 = factory.createAsset(AssetFactory.TypeAsset.Whitelist, defaultParams("A1", "A1"));
        address t2 = factory.createAsset(AssetFactory.TypeAsset.Blacklist, defaultParams("A2", "A2"));

        assertEq(factory.totalAssets(), 2);
        assertEq(factory.allAssets(0), t1);
        assertEq(factory.allAssets(1), t2);
        assertTrue(factory.isRegisteredAsset(t1));
        assertTrue(factory.isRegisteredAsset(t2));
    }

    function test_createAsset_emitsAssetCreatedWithType() public {
        TokenBase.AssetTokenParams memory p = defaultParams("Ev", "EV");
        // predict the CREATE address so we can assert on the indexed topic
        address predicted = vm.computeCreateAddress(address(factory), vm.getNonce(address(factory)));

        vm.expectEmit(true, false, false, true, address(factory));
        emit AssetFactory.AssetCreated(predicted, AssetFactory.TypeAsset.Blacklist);

        address token = factory.createAsset(AssetFactory.TypeAsset.Blacklist, p);
        assertEq(token, predicted);
    }

    function test_isRegisteredAsset_falseForUnknownAddress() public view {
        assertFalse(factory.isRegisteredAsset(address(0xDEAD)));
    }

    // ---------------------------------------------------------------
    // Validation reverts
    // ---------------------------------------------------------------
    function test_revertsOnZeroAssetAdmin() public {
        TokenBase.AssetTokenParams memory p = defaultParams("X", "X");
        p.assetAdmin = address(0);
        vm.expectRevert("assetAdmin required");
        factory.createAsset(AssetFactory.TypeAsset.Whitelist, p);
    }

    function test_revertsOnZeroStablecoinToken() public {
        TokenBase.AssetTokenParams memory p = defaultParams("X", "X");
        p.stablecoinToken = address(0);
        vm.expectRevert("stablecoinToken required");
        factory.createAsset(AssetFactory.TypeAsset.Whitelist, p);
    }

    function test_revertsOnZeroIssuerTreasury() public {
        TokenBase.AssetTokenParams memory p = defaultParams("X", "X");
        p.issuerTreasury = address(0);
        vm.expectRevert("issuerTreasury required");
        factory.createAsset(AssetFactory.TypeAsset.Whitelist, p);
    }

    function test_revertsOnZeroRedemptionSource() public {
        TokenBase.AssetTokenParams memory p = defaultParams("X", "X");
        p.redemptionSource = address(0);
        vm.expectRevert("redemptionSource required");
        factory.createAsset(AssetFactory.TypeAsset.Whitelist, p);
    }

    function test_revertsOnZeroPriceAuthority() public {
        // priceAuthority is a required explicit param, no fallback to assetAdmin
        TokenBase.AssetTokenParams memory p = defaultParams("X", "X");
        p.priceAuthority = address(0);
        vm.expectRevert("priceAuthority required");
        factory.createAsset(AssetFactory.TypeAsset.Whitelist, p);
    }

    function test_revertsOnMintFeeAboveMax() public {
        TokenBase.AssetTokenParams memory p = defaultParams("X", "X");
        p.mintFeeBps = 10_001;
        vm.expectRevert("fee > 100%");
        factory.createAsset(AssetFactory.TypeAsset.Whitelist, p);
    }

    function test_revertsOnRedemptionFeeAboveMax() public {
        TokenBase.AssetTokenParams memory p = defaultParams("X", "X");
        p.redemptionFeeBps = 10_001;
        vm.expectRevert("fee > 100%");
        factory.createAsset(AssetFactory.TypeAsset.Whitelist, p);
    }

    function test_revertsOnZeroInitialRate() public {
        TokenBase.AssetTokenParams memory p = defaultParams("X", "X");
        p.initialRate = 0;
        vm.expectRevert("rate must be > 0");
        factory.createAsset(AssetFactory.TypeAsset.Whitelist, p);
    }

    function test_feeExactlyAtCapIsAllowed() public {
        TokenBase.AssetTokenParams memory p = defaultParams("X", "X");
        p.mintFeeBps = 10_000;
        p.redemptionFeeBps = 10_000;
        address token = factory.createAsset(AssetFactory.TypeAsset.Whitelist, p);
        assertEq(TokenBase(token).mintFeeBps(), 10_000);
    }
}
