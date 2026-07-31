// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {TestBase} from "./helpers/TestBase.t.sol";
import {AssetV1} from "../src/AssetV1.sol";

contract AssetV1Test is TestBase {
    AssetV1 internal asset;

    function setUp() public {
        setUpBase();
        asset = deployWhitelistAsset();
        approveRedemptionSource(address(asset));
    }

    // ---------------------------------------------------------------
    // Default-deny model
    // ---------------------------------------------------------------
    function test_defaultDeny_nobodyWhitelistedInitially() public view {
        assertFalse(asset.isAllowed(investorA));
        assertFalse(asset.isAllowed(assetAdmin));
    }

    function test_mint_revertsForNonWhitelistedRecipient() public {
        approveMint(investorA, address(asset), 100 * 1e6);
        vm.prank(investorA);
        vm.expectRevert("recipient not whitelisted");
        asset.mint(100 * 1e6);
    }

    function test_mint_succeedsOnceWhitelisted() public {
        vm.prank(assetAdmin);
        asset.addToWhitelist(investorA);

        approveMint(investorA, address(asset), 100 * 1e6);
        vm.prank(investorA);
        uint256 out = asset.mint(100 * 1e6);
        assertGt(out, 0);
    }

    function test_removeFromWhitelist_blocksFurtherMint() public {
        vm.prank(assetAdmin);
        asset.addToWhitelist(investorA);
        vm.prank(assetAdmin);
        asset.removeFromWhitelist(investorA);

        approveMint(investorA, address(asset), 100 * 1e6);
        vm.prank(investorA);
        vm.expectRevert("recipient not whitelisted");
        asset.mint(100 * 1e6);
    }

    function test_transfer_requiresBothSidesWhitelisted() public {
        vm.prank(assetAdmin);
        asset.addToWhitelist(investorA);
        approveMint(investorA, address(asset), 100 * 1e6);
        vm.prank(investorA);
        uint256 minted = asset.mint(100 * 1e6);

        // investorB not whitelisted yet
        vm.prank(investorA);
        vm.expectRevert("recipient not whitelisted");
        asset.transfer(investorB, minted);

        vm.prank(assetAdmin);
        asset.addToWhitelist(investorB);
        vm.prank(investorA);
        asset.transfer(investorB, minted);
        assertEq(asset.balanceOf(investorB), minted);
    }

    function test_redeem_revertsForNonWhitelistedSender() public {
        vm.prank(assetAdmin);
        asset.addToWhitelist(investorA);
        approveMint(investorA, address(asset), 100 * 1e6);
        vm.prank(investorA);
        uint256 minted = asset.mint(100 * 1e6);

        vm.prank(assetAdmin);
        asset.removeFromWhitelist(investorA);

        vm.prank(investorA);
        vm.expectRevert("sender not whitelisted");
        asset.redeem(minted);
    }

    function test_onlyAssetAdminCanManageWhitelist() public {
        vm.prank(stranger);
        vm.expectRevert("not asset admin");
        asset.addToWhitelist(investorA);

        vm.prank(stranger);
        vm.expectRevert("not asset admin");
        asset.removeFromWhitelist(investorA);
    }

    // ---------------------------------------------------------------
    // Pause
    // ---------------------------------------------------------------
    function test_pause_blocksMintRedeemTransfer() public {
        vm.prank(assetAdmin);
        asset.addToWhitelist(investorA);
        approveMint(investorA, address(asset), 100 * 1e6);
        vm.prank(investorA);
        uint256 minted = asset.mint(100 * 1e6);

        vm.prank(assetAdmin);
        asset.pause();

        approveMint(investorA, address(asset), 100 * 1e6);
        vm.prank(investorA);
        vm.expectRevert("asset paused");
        asset.mint(100 * 1e6);

        vm.prank(investorA);
        vm.expectRevert("asset paused");
        asset.redeem(minted);

        vm.prank(assetAdmin);
        asset.addToWhitelist(investorB);
        vm.prank(investorA);
        vm.expectRevert("asset paused");
        asset.transfer(investorB, minted);
    }

    function test_unpause_restoresOperation() public {
        vm.prank(assetAdmin);
        asset.pause();
        vm.prank(assetAdmin);
        asset.unpause();

        vm.prank(assetAdmin);
        asset.addToWhitelist(investorA);
        approveMint(investorA, address(asset), 100 * 1e6);
        vm.prank(investorA);
        asset.mint(100 * 1e6); // should not revert
    }

    function test_pauseUnpause_onlyAssetAdmin() public {
        vm.prank(stranger);
        vm.expectRevert("not asset admin");
        asset.pause();
    }

    // ---------------------------------------------------------------
    // Force transfer / force burn
    // ---------------------------------------------------------------
    function test_forceTransfer_stillEnforcesAdmissionOnBothSides() public {
        vm.prank(assetAdmin);
        asset.addToWhitelist(investorA);
        approveMint(investorA, address(asset), 100 * 1e6);
        vm.prank(investorA);
        uint256 minted = asset.mint(100 * 1e6);

        // investorB not whitelisted -> forceTransfer to them must still revert
        vm.prank(assetAdmin);
        vm.expectRevert("recipient not whitelisted");
        asset.forceTransfer(investorA, investorB, minted);

        // once whitelisted, forceTransfer works without investorA's signature
        vm.prank(assetAdmin);
        asset.addToWhitelist(investorB);
        vm.prank(assetAdmin);
        asset.forceTransfer(investorA, investorB, minted);
        assertEq(asset.balanceOf(investorB), minted);
    }

    function test_forceTransfer_onlyAssetAdmin() public {
        vm.prank(stranger);
        vm.expectRevert("not asset admin");
        asset.forceTransfer(investorA, investorB, 1);
    }

    function test_forceBurn_bypassesAdmissionPauseAndClosed() public {
        vm.prank(assetAdmin);
        asset.addToWhitelist(investorA);
        approveMint(investorA, address(asset), 100 * 1e6);
        vm.prank(investorA);
        uint256 minted = asset.mint(100 * 1e6);

        vm.prank(assetAdmin);
        asset.removeFromWhitelist(investorA);
        vm.prank(assetAdmin);
        asset.pause();

        vm.prank(assetAdmin);
        asset.forceBurn(investorA, minted);
        assertEq(asset.balanceOf(investorA), 0);
    }

    function test_forceBurn_onlyAssetAdmin() public {
        vm.prank(stranger);
        vm.expectRevert("not asset admin");
        asset.forceBurn(investorA, 1);
    }

    // ---------------------------------------------------------------
    // closeAsset gap closed for V1 (unlike the Free variant)
    // ---------------------------------------------------------------
    function test_closeAsset_blocksTransfersViaUpdateOverride() public {
        vm.prank(assetAdmin);
        asset.addToWhitelist(investorA);
        vm.prank(assetAdmin);
        asset.addToWhitelist(investorB);
        approveMint(investorA, address(asset), 100 * 1e6);
        vm.prank(investorA);
        uint256 minted = asset.mint(100 * 1e6);

        // burn everything to reach totalSupply == 0 so closeAsset can succeed
        vm.prank(investorA);
        asset.redeem(minted);

        vm.prank(assetAdmin);
        asset.closeAsset();

        // any further mint attempt hits the TokenBase-level isClosed check first
        approveMint(investorA, address(asset), 10 * 1e6);
        vm.prank(investorA);
        vm.expectRevert("asset closed");
        asset.mint(10 * 1e6);
    }
}
