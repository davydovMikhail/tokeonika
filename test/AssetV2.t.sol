// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {TestBase} from "./helpers/TestBase.t.sol";
import {AssetV2} from "../src/AssetV2.sol";

contract AssetV2Test is TestBase {
    AssetV2 internal asset;

    function setUp() public {
        setUpBase();
        asset = deployBlacklistAsset();
        approveRedemptionSource(address(asset));
    }

    // ---------------------------------------------------------------
    // Default-allow model — the inverse of AssetV1
    // ---------------------------------------------------------------
    function test_defaultAllow_everyoneAllowedInitially() public view {
        assertTrue(asset.isAllowed(investorA));
        assertTrue(asset.isAllowed(stranger));
    }

    function test_mint_succeedsWithoutAnyListing() public {
        approveMint(investorA, address(asset), 100 * 1e6);
        vm.prank(investorA);
        uint256 out = asset.mint(100 * 1e6);
        assertGt(out, 0);
    }

    function test_addToBlacklist_blocksMint() public {
        vm.prank(assetAdmin);
        asset.addToBlacklist(investorA);

        approveMint(investorA, address(asset), 100 * 1e6);
        vm.prank(investorA);
        vm.expectRevert("recipient blacklisted");
        asset.mint(100 * 1e6);
    }

    function test_removeFromBlacklist_restoresAdmission() public {
        vm.prank(assetAdmin);
        asset.addToBlacklist(investorA);
        vm.prank(assetAdmin);
        asset.removeFromBlacklist(investorA);

        approveMint(investorA, address(asset), 100 * 1e6);
        vm.prank(investorA);
        asset.mint(100 * 1e6); // should not revert
    }

    function test_transfer_blockedIfEitherSideBlacklisted() public {
        approveMint(investorA, address(asset), 100 * 1e6);
        vm.prank(investorA);
        uint256 minted = asset.mint(100 * 1e6);

        vm.prank(assetAdmin);
        asset.addToBlacklist(investorB);

        vm.prank(investorA);
        vm.expectRevert("recipient blacklisted");
        asset.transfer(investorB, minted);

        vm.prank(assetAdmin);
        asset.removeFromBlacklist(investorB);
        vm.prank(investorA);
        asset.transfer(investorB, minted); // now succeeds
        assertEq(asset.balanceOf(investorB), minted);
    }

    function test_redeem_blockedForBlacklistedSender() public {
        approveMint(investorA, address(asset), 100 * 1e6);
        vm.prank(investorA);
        uint256 minted = asset.mint(100 * 1e6);

        vm.prank(assetAdmin);
        asset.addToBlacklist(investorA);

        vm.prank(investorA);
        vm.expectRevert("sender blacklisted");
        asset.redeem(minted);
    }

    function test_onlyAssetAdminCanManageBlacklist() public {
        vm.prank(stranger);
        vm.expectRevert("not asset admin");
        asset.addToBlacklist(investorA);

        vm.prank(stranger);
        vm.expectRevert("not asset admin");
        asset.removeFromBlacklist(investorA);
    }

    // ---------------------------------------------------------------
    // Pause / force transfer / force burn — same mechanics as V1
    // ---------------------------------------------------------------
    function test_pause_blocksMint() public {
        vm.prank(assetAdmin);
        asset.pause();

        approveMint(investorA, address(asset), 100 * 1e6);
        vm.prank(investorA);
        vm.expectRevert("asset paused");
        asset.mint(100 * 1e6);
    }

    function test_forceTransfer_stillRespectsBlacklistOnBothSides() public {
        approveMint(investorA, address(asset), 100 * 1e6);
        vm.prank(investorA);
        uint256 minted = asset.mint(100 * 1e6);

        vm.prank(assetAdmin);
        asset.addToBlacklist(investorB);

        vm.prank(assetAdmin);
        vm.expectRevert("recipient blacklisted");
        asset.forceTransfer(investorA, investorB, minted);
    }

    function test_forceBurn_bypassesBlacklistPauseAndClosed() public {
        approveMint(investorA, address(asset), 100 * 1e6);
        vm.prank(investorA);
        uint256 minted = asset.mint(100 * 1e6);

        vm.prank(assetAdmin);
        asset.addToBlacklist(investorA);
        vm.prank(assetAdmin);
        asset.pause();

        vm.prank(assetAdmin);
        asset.forceBurn(investorA, minted);
        assertEq(asset.balanceOf(investorA), 0);
    }
}
