// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IAssetToken} from "./interfaces/IAssetToken.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

contract SecondaryMarket is ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum OrderStatus {
        Open,            // 0 — заявка активна, ничего ещё не исполнено
        PartiallyFilled, // 1 — часть исполнена, остаток ещё в эскроу
        Filled,          // 2 — исполнена полностью
        Cancelled        // 3 — отменена maker'ом либо принудительно перенаправлена через forceRecoverOrder
    }

    struct Order {
        address maker;
        address assetToken;
        uint256 amount;
        uint256 pricePerUnit;   // цена за один ЦЕЛЫЙ токен актива, в сырых единицах стейблкоина
        uint256 filledAmount;
        OrderStatus status;
        uint256 createdAt;
    }

    mapping(uint256 => Order) public orders;
    uint256 public nextOrderId;
    uint256 private constant RATE_PRECISION = 1e18;

    event OrderPlaced(uint256 indexed orderId, address indexed maker, address indexed assetToken, uint256 amount, uint256 pricePerUnit);
    event OrderFilled(uint256 indexed orderId, address indexed taker, uint256 fillAmount, uint256 stablecoinPaid);
    event OrderCancelled(uint256 indexed orderId);
    event OrderForceRecovered(uint256 indexed orderId, address indexed destination, uint256 amount);
    event MarketVaultInitialized(address indexed assetToken);

    function placeOrder(address assetToken, uint256 amount, uint256 pricePerUnit)
        external nonReentrant returns (uint256 orderId)
    {
        require(amount > 0, "amount must be > 0");
        require(pricePerUnit > 0, "price must be > 0");

        IERC20(assetToken).safeTransferFrom(msg.sender, address(this), amount);

        orderId = nextOrderId++;
        orders[orderId] = Order({
            maker: msg.sender,
            assetToken: assetToken,
            amount: amount,
            pricePerUnit: pricePerUnit,
            filledAmount: 0,
            status: OrderStatus.Open,
            createdAt: block.timestamp
        });

        emit OrderPlaced(orderId, msg.sender, assetToken, amount, pricePerUnit);
    }

    function fillOrder(uint256 orderId, uint256 fillAmount) external nonReentrant {
        Order storage order = orders[orderId];
        require(order.maker != address(0), "order does not exist");
        require(order.status == OrderStatus.Open || order.status == OrderStatus.PartiallyFilled, "order not fillable");

        uint256 remaining = order.amount - order.filledAmount;
        require(fillAmount > 0 && fillAmount <= remaining, "invalid fill amount");

        uint256 stablecoinAmount = (fillAmount * order.pricePerUnit) / RATE_PRECISION;

        order.filledAmount += fillAmount;
        order.status = (order.filledAmount == order.amount) ? OrderStatus.Filled : OrderStatus.PartiallyFilled;

        address stablecoinToken = IAssetToken(order.assetToken).stablecoinToken();

        IERC20(stablecoinToken).safeTransferFrom(msg.sender, order.maker, stablecoinAmount);
        IERC20(order.assetToken).safeTransfer(msg.sender, fillAmount);

        emit OrderFilled(orderId, msg.sender, fillAmount, stablecoinAmount);
    }

    function cancelOrder(uint256 orderId) external nonReentrant {
        Order storage order = orders[orderId];
        require(order.maker == msg.sender, "not the maker");
        require(order.status == OrderStatus.Open || order.status == OrderStatus.PartiallyFilled, "order not cancellable");

        uint256 remaining = order.amount - order.filledAmount;
        order.status = OrderStatus.Cancelled;

        if (remaining > 0) {
            IERC20(order.assetToken).safeTransfer(order.maker, remaining);
        }

        emit OrderCancelled(orderId);
    }

    // function forceRecoverOrder(uint256 orderId, address destination) external nonReentrant {
    //     Order storage order = orders[orderId];
    //     require(order.maker != address(0), "order does not exist");
    //     require(msg.sender == IAssetToken(order.assetToken).assetAdmin(), "not asset admin");
    //     require(order.status == OrderStatus.Open || order.status == OrderStatus.PartiallyFilled, "order not recoverable");

    //     uint256 remaining = order.amount - order.filledAmount;
    //     require(remaining > 0, "nothing to recover");

    //     order.status = OrderStatus.Cancelled;

    //     IERC20(order.assetToken).safeTransfer(destination, remaining);

    //     emit OrderForceRecovered(orderId, destination, remaining);
    // }
}