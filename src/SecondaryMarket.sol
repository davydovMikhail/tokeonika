// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IAssetToken} from "./interfaces/IAssetToken.sol";
import {IAssetFactory} from "./interfaces/IAssetFactory.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

contract SecondaryMarket is ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum OrderStatus {
        Open,            
        PartiallyFilled, 
        Filled,          
        Cancelled        
    }

    struct Order {
        address maker;
        address assetToken;
        uint256 amount;
        uint256 pricePerUnit;
        uint256 filledAmount;
        OrderStatus status;
        uint256 createdAt;
    }

    constructor(address _assetFactory) {
        require(_assetFactory != address(0), "invalid asset factory");
        assetFactory = IAssetFactory(_assetFactory);
    }

    IAssetFactory assetFactory;

    mapping(uint256 => Order) public orders;
    uint256 public nextOrderId;
    uint256 private constant RATE_PRECISION = 1e18;

    event OrderPlaced(uint256 indexed orderId);
    event OrderFilled(uint256 indexed orderId);
    event OrderCancelled(uint256 indexed orderId);

    function placeOrder(address assetToken, uint256 amount, uint256 pricePerUnit)
        external nonReentrant returns (uint256 orderId)
    {
        require(amount > 0, "amount must be > 0");
        require(pricePerUnit > 0, "price must be > 0");
        require(assetFactory.isRegisteredAsset(assetToken), "asset not registered");

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

        emit OrderPlaced(orderId);
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

        emit OrderFilled(orderId);
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
}