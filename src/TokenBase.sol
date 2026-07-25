// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

contract TokenBase is ERC20, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 private constant BPS_DENOMINATOR = 10_000;
    uint256 private constant RATE_PRECISION = 1e18;

    address public assetAdmin;           // The current asset admin is verified each time an admin function is called
    address public priceAuthority;       // Who has the authority to update the exchange rate
    address public stablecoinToken;      // The ERC-20 address of the stablecoin on which this asset is traded
    string  public uri;                  // The reference to some off-chain information
    string  public isin;                 // International Securities Identification Number (ISIN) for the asset; just metadata, no built-in rules; mutable
    string  public jurisdiction;         // Jurisdiction of the asset; just metadata, no built-in rules; mutable
    uint16  public mintFeeBps;           // Mint commission in basis points, 20 = 0.2%
    uint16  public redemptionFeeBps;     // Redemption fee in basis points
    address public issuerTreasury;       // Address (in stablecoinToken) where the investor's funds are sent upon minting (minus the fee)
    address public redemptionSource;     // The address (in `stablecoinToken`) from which funds are debited to the investor upon redemption; may be the same as `issuerTreasury`
    bool    public isClosed;             // If true, the asset is closed via `closeAsset`, and further `mint`, `redeem`, and `transfer` operations are blocked
    uint256 public currentRate;          // Stablecoin↔asset exchange rate, updated via `updateExchangeRate`
    uint256 public maxTotalSupply;       // The maximum number of tokens that can be issued;
    address private pendingAssetAdmin;   // The address that has been offered the right to become the new assetAdmin; for a two-step transfer of rights

    event MetadataUpdated(string uri, string isin, string jurisdiction);
    event TreasuryAddressesUpdated(address newIssuerTreasury, address newRedemptionSource);
    event PriceAuthorityUpdated(address newPriceAuthority);
    event ExchangeRateUpdated(uint256 newRate);
    event FeesUpdated(uint16 newMintFeeBps, uint16 newRedemptionFeeBps);
    event FeesWithdrawn(address destination, uint256 amount);
    event Minted(address indexed investor, uint256 stablecoinAmount, uint256 assetAmount);
    event Redeemed(address indexed investor, uint256 assetAmount, uint256 stablecoinAmount);
    event AuthorityTransferProposed(address indexed currentAdmin, address indexed proposedAdmin);
    event AuthorityTransferAccepted(address indexed previousAdmin, address indexed newAdmin);
    event AuthorityTransferCancelled(address indexed currentAdmin, address indexed cancelledAdmin);
    event AssetClosed();

    constructor(
        AssetTokenParams memory _config
    ) ERC20(_config.name, _config.symbol) {
        assetAdmin = _config.assetAdmin;
        priceAuthority = _config.priceAuthority;
        stablecoinToken = _config.stablecoinToken;
        issuerTreasury = _config.issuerTreasury;
        redemptionSource = _config.redemptionSource;
        mintFeeBps = _config.mintFeeBps;
        redemptionFeeBps = _config.redemptionFeeBps;
        uri = _config.uri;
        isin = _config.isin;
        jurisdiction = _config.jurisdiction;
        currentRate = _config.initialRate;
        maxTotalSupply = _config.maxSupply;
    }

    struct AssetTokenParams {
        string  name;
        string  symbol;
        string  uri;
        string  isin;
        string  jurisdiction;
        address assetAdmin;
        address priceAuthority;
        address stablecoinToken;
        address issuerTreasury;
        address redemptionSource;
        uint16  mintFeeBps;
        uint16  redemptionFeeBps;
        uint256 initialRate;
        uint256 maxSupply;
    }

    modifier onlyAssetAdmin() {
        _onlyAssetAdmin();
        _;
    }
    
    function _onlyAssetAdmin() internal view {
        require(msg.sender == assetAdmin, "not asset admin");
    }

    modifier onlyPriceAuthority() {
        _onlyPriceAuthority();
        _;
    }

    function _onlyPriceAuthority() internal view {
        require(msg.sender == priceAuthority, "not price authority");
    }

    // ---------------------------------------------------------------------
    // Metadata / config (Asset Admin)
    // ---------------------------------------------------------------------

    function updateMetadata(
        string calldata _uri,
        string calldata _isin,
        string calldata _jurisdiction
    ) external onlyAssetAdmin {
        // An empty string “” means “do not change”.
        if (bytes(_uri).length > 0) {
            uri = _uri;
        }
        if (bytes(_isin).length > 0) {
            isin = _isin;
        }
        if (bytes(_jurisdiction).length > 0) {
            jurisdiction = _jurisdiction;
        }
        emit MetadataUpdated(uri, isin, jurisdiction);
    }

    function updateTreasuryAddresses(
        address newIssuerTreasury,
        address newRedemptionSource
    ) external onlyAssetAdmin {
        require(newIssuerTreasury != address(0) && newRedemptionSource != address(0), "zero address");
        issuerTreasury = newIssuerTreasury;
        redemptionSource = newRedemptionSource;
        emit TreasuryAddressesUpdated(newIssuerTreasury, newRedemptionSource);
    }

    function updatePriceAuthority(address newPriceAuthority) external onlyAssetAdmin {
        require(newPriceAuthority != address(0), "zero address");
        priceAuthority = newPriceAuthority;
        emit PriceAuthorityUpdated(newPriceAuthority);
    }

    function updateExchangeRate(uint256 newRate) external onlyPriceAuthority {
        require(newRate > 0, "rate must be > 0");
        currentRate = newRate;
        emit ExchangeRateUpdated(newRate);
    }

    function updateFees(uint16 newMintFeeBps, uint16 newRedemptionFeeBps) external onlyAssetAdmin {
        require(newMintFeeBps <= 10_000 && newRedemptionFeeBps <= 10_000, "fee > 100%");
        mintFeeBps = newMintFeeBps;
        redemptionFeeBps = newRedemptionFeeBps;
        emit FeesUpdated(newMintFeeBps, newRedemptionFeeBps);
    }

    function withdrawFees(address destination) external onlyAssetAdmin {
        require(destination != address(0), "zero address");
        uint256 balance = ERC20(stablecoinToken).balanceOf(address(this));
        require(balance > 0, "nothing to withdraw");
        IERC20(stablecoinToken).safeTransfer(destination, balance);
        emit FeesWithdrawn(destination, balance);
    }

    // ---------------------------------------------------------------------
    // Mint / Redeem (investor-facing)
    // ---------------------------------------------------------------------

    function mint(uint256 stablecoinAmount) external nonReentrant returns (uint256 assetAmount) {
        require(!isClosed, "asset closed");
        require(stablecoinAmount > 0, "amount must be > 0");

        uint256 feeRaw = (stablecoinAmount * mintFeeBps) / BPS_DENOMINATOR;
        uint256 netRaw = stablecoinAmount - feeRaw;

        // Забираем всю сумму у инвестора: net идёт в issuerTreasury (принципал),
        // fee остаётся на балансе самого AssetToken (нет отдельного feeVault) — выводится через withdrawFees.
        IERC20(stablecoinToken).safeTransferFrom(msg.sender, issuerTreasury, netRaw);
        if (feeRaw > 0) {
            IERC20(stablecoinToken).safeTransferFrom(msg.sender, address(this), feeRaw);
        }

        assetAmount = (netRaw * RATE_PRECISION) / currentRate; // нормализуем к 18 decimals, делим на курс, возвращаем к исходным decimals;

        require(totalSupply() + assetAmount <= maxTotalSupply, "exceeds max supply");

        _mint(msg.sender, assetAmount); // whitelist-проверка получателя сработает внутри _update
        emit Minted(msg.sender, stablecoinAmount, assetAmount);
    }

    function redeem(uint256 assetAmount) external nonReentrant returns (uint256 netStablecoinOut) {
        require(assetAmount > 0, "amount must be > 0");

        _burn(msg.sender, assetAmount); // whitelist-проверка отправителя сработает внутри _update
        
        uint256 grossRaw = (assetAmount * currentRate) / RATE_PRECISION;

        uint256 feeRaw = (grossRaw * redemptionFeeBps) / BPS_DENOMINATOR;
        netStablecoinOut = grossRaw - feeRaw;

        IERC20(stablecoinToken).safeTransferFrom(redemptionSource, msg.sender, netStablecoinOut);
        if (feeRaw > 0) {
            IERC20(stablecoinToken).safeTransferFrom(redemptionSource, address(this), feeRaw);
        }
        emit Redeemed(msg.sender, assetAmount, netStablecoinOut);
    }

    // ---------------------------------------------------------------------
    // Two-step authority transfer
    // ---------------------------------------------------------------------

    function proposeAuthorityTransfer(address newAdmin) external onlyAssetAdmin {
        require(newAdmin != address(0), "zero address");
        pendingAssetAdmin = newAdmin;
        emit AuthorityTransferProposed(assetAdmin, newAdmin);
    }

    function acceptAuthorityTransfer() external {
        require(msg.sender == pendingAssetAdmin, "not pending admin");
        address previousAdmin = assetAdmin;
        assetAdmin = pendingAssetAdmin;
        pendingAssetAdmin = address(0);
        emit AuthorityTransferAccepted(previousAdmin, assetAdmin);
    }

    function cancelAuthorityTransfer() external onlyAssetAdmin {
        address cancelled = pendingAssetAdmin;
        pendingAssetAdmin = address(0);
        emit AuthorityTransferCancelled(assetAdmin, cancelled);
    }

    // ---------------------------------------------------------------------
    // Close asset
    // ---------------------------------------------------------------------

    function closeAsset() external onlyAssetAdmin {
        require(totalSupply() == 0, "supply not zero");
        isClosed = true;
        emit AssetClosed();
    }
}