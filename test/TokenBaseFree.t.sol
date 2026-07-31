// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {TestBase} from "./helpers/TestBase.t.sol";
import {TokenBase} from "../src/TokenBase.sol";
import {AssetFactory} from "../src/AssetFactory.sol";

/// @notice Exercises TokenBase logic (mint/redeem formula, metadata, fees,
///         treasury, price authority, authority transfer, closeAsset) through
///         the bare "Free" variant, since it has no admission layer to get in
///         the way of testing the base contract in isolation.
contract TokenBaseFreeTest is TestBase {
    TokenBase internal asset;

    function setUp() public {
        setUpBase();
        asset = deployFreeAsset();
        approveRedemptionSource(address(asset));
    }

    // ---------------------------------------------------------------
    // Mint
    // ---------------------------------------------------------------
    function test_mint_computesFeeAndAssetAmountPerFormula() public {
        uint256 stableIn = 1_000 * 1e6; // 1000 USDC
        approveMint(investorA, address(asset), stableIn);

        uint256 expectedFee = (stableIn * 20) / 10_000; // mintFeeBps = 20
        uint256 expectedNet = stableIn - expectedFee;
        uint256 expectedAssetOut = (expectedNet * RATE_PRECISION) / ONE_TO_ONE_USDC_RATE;

        vm.prank(investorA);
        uint256 out = asset.mint(stableIn);

        assertEq(out, expectedAssetOut);
        assertEq(asset.balanceOf(investorA), expectedAssetOut);
        assertEq(stablecoin.balanceOf(issuerTreasury), expectedNet);
        assertEq(stablecoin.balanceOf(address(asset)), expectedFee);
    }

    function test_mint_zeroFee_sendsNothingToContractBalance() public {
        vm.prank(assetAdmin);
        asset.updateFees(0, 50);

        uint256 stableIn = 500 * 1e6;
        approveMint(investorA, address(asset), stableIn);

        vm.prank(investorA);
        asset.mint(stableIn);

        assertEq(stablecoin.balanceOf(address(asset)), 0);
        assertEq(stablecoin.balanceOf(issuerTreasury), stableIn);
    }

    function test_mint_revertsOnZeroAmount() public {
        vm.prank(investorA);
        vm.expectRevert("amount must be > 0");
        asset.mint(0);
    }

    function test_mint_revertsWhenClosed() public {
        // closeAsset requires totalSupply()==0, which holds before any mint
        vm.prank(assetAdmin);
        asset.closeAsset();

        approveMint(investorA, address(asset), 100 * 1e6);
        vm.prank(investorA);
        vm.expectRevert("asset closed");
        asset.mint(100 * 1e6);
    }

    function test_mint_revertsAboveMaxTotalSupply() public {
        // Force a tiny cap, then try to mint past it
        // maxTotalSupply is set at construction; deploy a fresh asset with a low cap
        TokenBase.AssetTokenParams memory p = defaultParams("Capped", "CAP");
        p.maxSupply = 1 ether; // 1 whole token cap
        address token = factory.createAsset(AssetFactory.TypeAsset.Free, p);
        TokenBase capped = TokenBase(token);

        // at 1:1 rate, minting 2 USDC (net of fee) would produce > 1 asset token
        uint256 stableIn = 2 * 1e6;
        approveMint(investorA, address(capped), stableIn);
        vm.prank(investorA);
        vm.expectRevert("exceeds max supply");
        capped.mint(stableIn);
    }

    // ---------------------------------------------------------------
    // Redeem
    // ---------------------------------------------------------------
    function test_redeem_computesGrossFeeAndNetPerFormula() public {
        uint256 stableIn = 1_000 * 1e6;
        approveMint(investorA, address(asset), stableIn);
        vm.prank(investorA);
        uint256 assetAmount = asset.mint(stableIn);

        uint256 grossRaw = (assetAmount * ONE_TO_ONE_USDC_RATE) / RATE_PRECISION;
        uint256 fee = (grossRaw * 50) / 10_000; // redemptionFeeBps = 50
        uint256 expectedNetOut = grossRaw - fee;

        uint256 redemptionSourceBalBefore = stablecoin.balanceOf(redemptionSource);

        vm.prank(investorA);
        uint256 netOut = asset.redeem(assetAmount);

        assertEq(netOut, expectedNetOut);
        assertEq(asset.balanceOf(investorA), 0);
        assertEq(stablecoin.balanceOf(investorA) - (1_000_000 * 1e6 - stableIn), expectedNetOut);
        assertEq(redemptionSourceBalBefore - stablecoin.balanceOf(redemptionSource), grossRaw);
        // fee portion landed on the asset contract itself, on top of the mint fee already there
        uint256 mintFee = (stableIn * 20) / 10_000;
        assertEq(stablecoin.balanceOf(address(asset)), mintFee + fee);
    }

    function test_redeem_revertsWithoutAllowanceFromRedemptionSource() public {
        // fresh asset, redemptionSource has NOT approved it
        TokenBase.AssetTokenParams memory p = defaultParams("NoApprove", "NOAP");
        address token = factory.createAsset(AssetFactory.TypeAsset.Free, p);
        TokenBase fresh = TokenBase(token);

        uint256 stableIn = 100 * 1e6;
        approveMint(investorA, address(fresh), stableIn);
        vm.prank(investorA);
        uint256 assetAmount = fresh.mint(stableIn);

        vm.prank(investorA);
        vm.expectRevert(); // SafeERC20 revert on insufficient allowance
        fresh.redeem(assetAmount);
    }

    function test_redeem_revertsOnZeroAmount() public {
        vm.prank(investorA);
        vm.expectRevert("amount must be > 0");
        asset.redeem(0);
    }

    /// @dev Documented asymmetry: TokenBase.mint() has an explicit `require(!isClosed, ...)`
    ///      guard at the function level, but redeem() does not — closing relies entirely on
    ///      totalSupply() being zero at close time. This test locks in that asymmetry: mint
    ///      is blocked post-close, confirming the guard that exists; the missing guard on
    ///      redeem is only reachable if a balance can exist after isClosed flips (not possible
    ///      through TokenBase's own functions alone, but AssetV1/AssetV2 close the gap
    ///      defensively via their _update() override regardless — see AssetV1.t.sol).
    function test_closeAsset_mintGuardExists_redeemHasNoEquivalentGuard() public {
        uint256 stableIn = 100 * 1e6;
        approveMint(investorA, address(asset), stableIn);
        vm.prank(investorA);
        uint256 assetAmount = asset.mint(stableIn);

        vm.prank(investorA);
        asset.redeem(assetAmount); // bring totalSupply back to 0 so closeAsset can succeed

        vm.prank(assetAdmin);
        asset.closeAsset();
        assertTrue(asset.isClosed());

        approveMint(investorA, address(asset), 10 * 1e6);
        vm.prank(investorA);
        vm.expectRevert("asset closed");
        asset.mint(10 * 1e6); // mint's own require(!isClosed) fires
    }

    // ---------------------------------------------------------------
    // Metadata
    // ---------------------------------------------------------------
    function test_updateMetadata_emptyStringLeavesFieldUnchanged() public {
        vm.prank(assetAdmin);
        asset.updateMetadata("ipfs://new-uri", "", "");

        assertEq(asset.uri(), "ipfs://new-uri");
        assertEq(asset.isin(), "US0000000000"); // unchanged
        assertEq(asset.jurisdiction(), "US"); // unchanged
    }

    function test_updateMetadata_onlyAssetAdmin() public {
        vm.prank(stranger);
        vm.expectRevert("not asset admin");
        asset.updateMetadata("x", "", "");
    }

    // ---------------------------------------------------------------
    // Treasury / price authority / fees
    // ---------------------------------------------------------------
    function test_updateTreasuryAddresses_rejectsZero() public {
        vm.prank(assetAdmin);
        vm.expectRevert("zero address");
        asset.updateTreasuryAddresses(address(0), redemptionSource);
    }

    function test_updateTreasuryAddresses_succeeds() public {
        address newTreasury = makeAddr("newTreasury");
        address newSource = makeAddr("newSource");
        vm.prank(assetAdmin);
        asset.updateTreasuryAddresses(newTreasury, newSource);
        assertEq(asset.issuerTreasury(), newTreasury);
        assertEq(asset.redemptionSource(), newSource);
    }

    function test_updatePriceAuthority_rejectsZeroAndOnlyAdmin() public {
        vm.prank(assetAdmin);
        vm.expectRevert("zero address");
        asset.updatePriceAuthority(address(0));

        vm.prank(stranger);
        vm.expectRevert("not asset admin");
        asset.updatePriceAuthority(makeAddr("newPA"));
    }

    function test_updateExchangeRate_onlyPriceAuthority_rejectsZero() public {
        vm.prank(stranger);
        vm.expectRevert("not price authority");
        asset.updateExchangeRate(2_000_000);

        vm.prank(priceAuthority);
        vm.expectRevert("rate must be > 0");
        asset.updateExchangeRate(0);

        vm.prank(priceAuthority);
        asset.updateExchangeRate(2_000_000);
        assertEq(asset.currentRate(), 2_000_000);
    }

    function test_updateFees_rejectsAboveCapAndOnlyAdmin() public {
        vm.prank(assetAdmin);
        vm.expectRevert("fee > 100%");
        asset.updateFees(10_001, 0);

        vm.prank(stranger);
        vm.expectRevert("not asset admin");
        asset.updateFees(100, 100);
    }

    function test_withdrawFees_transfersFullBalanceAndRevertsOnEmpty() public {
        uint256 stableIn = 1_000 * 1e6;
        approveMint(investorA, address(asset), stableIn);
        vm.prank(investorA);
        asset.mint(stableIn);

        uint256 expectedFee = (stableIn * 20) / 10_000;
        address dest = makeAddr("feeDest");

        vm.prank(assetAdmin);
        asset.withdrawFees(dest);
        assertEq(stablecoin.balanceOf(dest), expectedFee);
        assertEq(stablecoin.balanceOf(address(asset)), 0);

        vm.prank(assetAdmin);
        vm.expectRevert("nothing to withdraw");
        asset.withdrawFees(dest);
    }

    function test_withdrawFees_onlyAssetAdminAndRejectsZeroDest() public {
        vm.prank(stranger);
        vm.expectRevert("not asset admin");
        asset.withdrawFees(makeAddr("d"));

        vm.prank(assetAdmin);
        vm.expectRevert("zero address");
        asset.withdrawFees(address(0));
    }

    // ---------------------------------------------------------------
    // Two-step authority transfer
    // ---------------------------------------------------------------
    function test_authorityTransfer_twoStepFlow() public {
        address newAdmin = makeAddr("newAssetAdmin");

        vm.prank(assetAdmin);
        asset.proposeAuthorityTransfer(newAdmin);
        assertEq(asset.assetAdmin(), assetAdmin); // unchanged until accepted

        vm.prank(newAdmin);
        asset.acceptAuthorityTransfer();
        assertEq(asset.assetAdmin(), newAdmin);

        // old admin has lost access
        vm.prank(assetAdmin);
        vm.expectRevert("not asset admin");
        asset.updateFees(0, 0);
    }

    function test_authorityTransfer_onlyPendingAdminCanAccept() public {
        address newAdmin = makeAddr("newAssetAdmin");
        vm.prank(assetAdmin);
        asset.proposeAuthorityTransfer(newAdmin);

        vm.prank(stranger);
        vm.expectRevert("not pending admin");
        asset.acceptAuthorityTransfer();
    }

    function test_authorityTransfer_cancelBeforeAcceptance() public {
        address newAdmin = makeAddr("newAssetAdmin");
        vm.prank(assetAdmin);
        asset.proposeAuthorityTransfer(newAdmin);

        vm.prank(assetAdmin);
        asset.cancelAuthorityTransfer();

        vm.prank(newAdmin);
        vm.expectRevert("not pending admin");
        asset.acceptAuthorityTransfer();
    }

    // ---------------------------------------------------------------
    // closeAsset
    // ---------------------------------------------------------------
    function test_closeAsset_requiresZeroTotalSupply() public {
        approveMint(investorA, address(asset), 100 * 1e6);
        vm.prank(investorA);
        asset.mint(100 * 1e6);

        vm.prank(assetAdmin);
        vm.expectRevert("supply not zero");
        asset.closeAsset();
    }

    function test_closeAsset_onlyAssetAdmin() public {
        vm.prank(stranger);
        vm.expectRevert("not asset admin");
        asset.closeAsset();
    }

    function test_closeAsset_succeedsAtZeroSupply() public {
        vm.prank(assetAdmin);
        asset.closeAsset();
        assertTrue(asset.isClosed());
    }
}
