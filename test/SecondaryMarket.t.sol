// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {TestBase} from "./helpers/TestBase.t.sol";
import {SecondaryMarket} from "../src/SecondaryMarket.sol";
import {AssetV1} from "../src/AssetV1.sol";
import {TokenBase} from "../src/TokenBase.sol";
import {AssetFactory} from "../src/AssetFactory.sol";

contract SecondaryMarketTest is TestBase {
    SecondaryMarket internal market;
    AssetV1 internal wlAsset;

    function setUp() public {
        setUpBase();
        market = new SecondaryMarket(address(factory));
        wlAsset = deployWhitelistAsset();
        approveRedemptionSource(address(wlAsset));

        vm.startPrank(assetAdmin);
        wlAsset.addToWhitelist(investorA);
        wlAsset.addToWhitelist(investorB);
        wlAsset.addToWhitelist(address(market));
        vm.stopPrank();

        approveMint(investorA, address(wlAsset), 1_000 * 1e6);
        vm.prank(investorA);
        wlAsset.mint(1_000 * 1e6);
    }

    function test_constructor_rejectsZeroFactory() public {
        vm.expectRevert("invalid asset factory");
        new SecondaryMarket(address(0));
    }

    // ---------------------------------------------------------------
    // placeOrder
    // ---------------------------------------------------------------
    function test_placeOrder_escrowsTokensAndRegistersOrder() public {
        uint256 amount = wlAsset.balanceOf(investorA);
        uint256 price = 1_100_000; // 1.1 USDC per whole asset token

        vm.prank(investorA);
        wlAsset.approve(address(market), amount);
        vm.prank(investorA);
        uint256 orderId = market.placeOrder(address(wlAsset), amount, price);

        (address maker, address assetToken, uint256 amt, uint256 pricePerUnit, uint256 filled, SecondaryMarket.OrderStatus status,) =
            market.orders(orderId);

        assertEq(maker, investorA);
        assertEq(assetToken, address(wlAsset));
        assertEq(amt, amount);
        assertEq(pricePerUnit, price);
        assertEq(filled, 0);
        assertTrue(status == SecondaryMarket.OrderStatus.Open);
        assertEq(wlAsset.balanceOf(address(market)), amount);
        assertEq(wlAsset.balanceOf(investorA), 0);
    }

    function test_placeOrder_revertsForUnregisteredAsset() public {
        // deploy an asset directly, bypassing the factory, so it's not registered
        TokenBase.AssetTokenParams memory p = defaultParams("Rogue", "RGE");
        AssetV1 rogue = new AssetV1(p);

        vm.prank(investorA);
        vm.expectRevert("asset not registered");
        market.placeOrder(address(rogue), 1, 1);
    }

    function test_placeOrder_revertsOnZeroAmountOrPrice() public {
        vm.prank(investorA);
        vm.expectRevert("amount must be > 0");
        market.placeOrder(address(wlAsset), 0, 1);

        vm.prank(investorA);
        vm.expectRevert("price must be > 0");
        market.placeOrder(address(wlAsset), 1, 0);
    }

    function test_placeOrder_revertsIfMakerNotWhitelisted() public {
        // approve first so the revert we hit is the whitelist check inside
        // _update(), not an unrelated "insufficient allowance" error
        vm.prank(investorA);
        wlAsset.approve(address(market), 1);

        vm.prank(assetAdmin);
        wlAsset.removeFromWhitelist(investorA);

        vm.prank(investorA);
        vm.expectRevert("sender not whitelisted");
        market.placeOrder(address(wlAsset), 1, 1);
    }

    function test_placeOrder_revertsIfMarketNotWhitelisted() public {
        vm.prank(assetAdmin);
        wlAsset.removeFromWhitelist(address(market));

        uint256 amount = wlAsset.balanceOf(investorA);
        vm.prank(investorA);
        wlAsset.approve(address(market), amount);
        vm.prank(investorA);
        vm.expectRevert("recipient not whitelisted");
        market.placeOrder(address(wlAsset), amount, 1_000_000);
    }

    // ---------------------------------------------------------------
    // fillOrder
    // ---------------------------------------------------------------
    function _placeStandardOrder() internal returns (uint256 orderId, uint256 amount, uint256 price) {
        amount = wlAsset.balanceOf(investorA);
        price = 1_000_000; // 1:1
        vm.prank(investorA);
        wlAsset.approve(address(market), amount);
        vm.prank(investorA);
        orderId = market.placeOrder(address(wlAsset), amount, price);
    }

    function test_fillOrder_partialFillUpdatesStatusAndBalances() public {
        (uint256 orderId, uint256 amount, uint256 price) = _placeStandardOrder();
        uint256 fillAmount = amount / 4;
        uint256 expectedStableOut = (fillAmount * price) / RATE_PRECISION;

        vm.prank(investorB);
        stablecoin.approve(address(market), type(uint256).max);

        uint256 makerStableBefore = stablecoin.balanceOf(investorA);

        vm.prank(investorB);
        market.fillOrder(orderId, fillAmount);

        (, , , , uint256 filled, SecondaryMarket.OrderStatus status,) = market.orders(orderId);
        assertEq(filled, fillAmount);
        assertTrue(status == SecondaryMarket.OrderStatus.PartiallyFilled);
        assertEq(wlAsset.balanceOf(investorB), fillAmount);
        assertEq(stablecoin.balanceOf(investorA), makerStableBefore + expectedStableOut);
    }

    function test_fillOrder_fullFillMarksFilled() public {
        (uint256 orderId, uint256 amount,) = _placeStandardOrder();
        vm.prank(investorB);
        stablecoin.approve(address(market), type(uint256).max);

        vm.prank(investorB);
        market.fillOrder(orderId, amount);

        (, , , , , SecondaryMarket.OrderStatus status,) = market.orders(orderId);
        assertTrue(status == SecondaryMarket.OrderStatus.Filled);
        assertEq(wlAsset.balanceOf(investorB), amount);
        assertEq(wlAsset.balanceOf(address(market)), 0);
    }

    function test_fillOrder_revertsAboveRemainingAmount() public {
        (uint256 orderId, uint256 amount,) = _placeStandardOrder();
        vm.prank(investorB);
        stablecoin.approve(address(market), type(uint256).max);

        vm.prank(investorB);
        vm.expectRevert("invalid fill amount");
        market.fillOrder(orderId, amount + 1);
    }

    function test_fillOrder_revertsOnZeroFillAmount() public {
        (uint256 orderId,,) = _placeStandardOrder();
        vm.prank(investorB);
        vm.expectRevert("invalid fill amount");
        market.fillOrder(orderId, 0);
    }

    function test_fillOrder_revertsOnNonexistentOrder() public {
        vm.prank(investorB);
        vm.expectRevert("order does not exist");
        market.fillOrder(999, 1);
    }

    function test_fillOrder_revertsIfAlreadyFilled() public {
        (uint256 orderId, uint256 amount,) = _placeStandardOrder();
        vm.startPrank(investorB);
        stablecoin.approve(address(market), type(uint256).max);
        market.fillOrder(orderId, amount);
        vm.expectRevert("order not fillable");
        market.fillOrder(orderId, 1);
        vm.stopPrank();
    }

    /// @dev maker's admission is NOT re-checked at fill time, only at
    ///      placeOrder. This test locks in that documented behavior: even if the
    ///      maker is blacklisted/removed after placing, fillOrder still succeeds
    ///      because payment goes directly taker -> maker (an ERC20 transfer that
    ///      the *stablecoin* contract, not the asset contract, controls).
    function test_fillOrder_doesNotRecheckMakerAdmission() public {
        (uint256 orderId, uint256 amount,) = _placeStandardOrder();

        vm.prank(assetAdmin);
        wlAsset.removeFromWhitelist(investorA); // maker no longer whitelisted

        vm.prank(investorB);
        stablecoin.approve(address(market), type(uint256).max);
        vm.prank(investorB);
        market.fillOrder(orderId, amount); // succeeds despite maker being delisted
    }

    // ---------------------------------------------------------------
    // cancelOrder
    // ---------------------------------------------------------------
    function test_cancelOrder_returnsUnfilledRemainderToMaker() public {
        (uint256 orderId, uint256 amount,) = _placeStandardOrder();
        uint256 fillAmount = amount / 3;
        vm.prank(investorB);
        stablecoin.approve(address(market), type(uint256).max);
        vm.prank(investorB);
        market.fillOrder(orderId, fillAmount);

        vm.prank(investorA);
        market.cancelOrder(orderId);

        (, , , , , SecondaryMarket.OrderStatus status,) = market.orders(orderId);
        assertTrue(status == SecondaryMarket.OrderStatus.Cancelled);
        assertEq(wlAsset.balanceOf(investorA), amount - fillAmount);
    }

    function test_cancelOrder_onlyMaker() public {
        (uint256 orderId,,) = _placeStandardOrder();
        vm.prank(investorB);
        vm.expectRevert("not the maker");
        market.cancelOrder(orderId);
    }

    function test_cancelOrder_revertsIfAlreadyCancelledOrFilled() public {
        (uint256 orderId, uint256 amount,) = _placeStandardOrder();
        vm.prank(investorA);
        market.cancelOrder(orderId);

        vm.prank(investorA);
        vm.expectRevert("order not cancellable");
        market.cancelOrder(orderId);
    }

    /// @dev known gap — if the maker is blacklisted/removed from the
    ///      whitelist after placing an order, cancelOrder's safeTransfer back to
    ///      them reverts, and the remaining escrowed balance is stuck with no
    ///      recovery path. This test documents the exact failure mode.
    function test_cancelOrder_stuckIfMakerLaterDelisted() public {
        (uint256 orderId,,) = _placeStandardOrder();

        vm.prank(assetAdmin);
        wlAsset.removeFromWhitelist(investorA);

        vm.prank(investorA);
        vm.expectRevert("recipient not whitelisted");
        market.cancelOrder(orderId);
    }
}
