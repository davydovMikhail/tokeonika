// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IAssetToken} from "./interfaces/IAssetToken.sol";
import {IAssetFactory} from "./interfaces/IAssetFactory.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

contract SecondaryMarket is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Lifecycle states of a resting order
    /// @dev Open -> no fills yet
    /// @dev PartiallyFilled -> some but not all of amount filled
    /// @dev Filled -> fully filled, terminal
    /// @dev Cancelled -> withdrawn by maker, terminal
    enum OrderStatus {
        Open,            
        PartiallyFilled, 
        Filled,          
        Cancelled        
    }

    /// @notice A resting sell order for an asset token, escrowed by this contract
    /// @dev pricePerUnit is the price of one whole asset token (1e18 raw units), denominated in raw units of the asset's stablecoinToken — same scale used by TokenBase.exchangeRate
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

    /// @notice Emitted when a new sell order is escrowed
    /// @param orderId Identifier of the newly created order
    event OrderPlaced(uint256 indexed orderId);
    /// @notice Emitted on each fill of an order, partial or complete
    /// @param orderId Identifier of the order being filled
    /// @param taker Address that filled the order
    /// @param fillAmount Amount of asset token bought in this fill
    event OrderFilled(uint256 indexed orderId, address indexed taker, uint256 fillAmount);
    /// @notice Emitted when a maker cancels their order
    /// @param orderId Identifier of the cancelled order
    event OrderCancelled(uint256 indexed orderId);

    /// @notice Escrows asset tokens and opens a new sell order
    /// @dev Requires assetToken to be registered with assetFactory. Pulls `amount` of assetToken from msg.sender into this contract via safeTransferFrom — reverts if msg.sender is not admitted (whitelist/blacklist) to send to this contract, or if the market itself has not been admitted to receive the asset
    /// @param assetToken Address of the asset token being sold
    /// @param amount Amount of asset token to escrow and offer, must be > 0
    /// @param pricePerUnit Price of one whole asset token, in raw units of the asset's stablecoinToken, must be > 0
    /// @return orderId Identifier assigned to the newly created order
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

    /// @notice Buys some or all of the remaining amount on an open order
    /// @dev Computes stablecoinAmount = fillAmount * order.pricePerUnit / RATE_PRECISION. Stablecoin is paid directly from taker to maker (never held in escrow); the asset token is transferred from this contract's escrow to the taker. Maker's admission is not re-checked at fill time — it was only checked at placeOrder. Taker's admission on the asset side and stablecoin allowance/balance are enforced by the respective token transfers
    /// @param orderId Identifier of the order to fill
    /// @param fillAmount Amount of asset token to buy; must be > 0 and <= order's remaining unfilled amount
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

        emit OrderFilled(orderId, msg.sender, fillAmount);
    }

    /// @notice Cancels an order and returns any unfilled escrowed amount to the maker
    /// @dev Callable only by the order's maker. No admin recovery path exists if the maker is later revoked/blacklisted — the safeTransfer back to maker will revert and the remaining balance stays stuck in escrow
    /// @param orderId Identifier of the order to cancel
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