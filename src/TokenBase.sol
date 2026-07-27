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
    event Minted(address indexed investor, uint256 stablecoinAmount, uint256 assetAmount, uint16 mintFeeBps);
    event Redeemed(address indexed investor, uint256 assetAmount, uint256 stablecoinAmount, uint16 redemptionFeeBps);
    event AuthorityTransferProposed(address indexed currentAdmin, address indexed proposedAdmin);
    event AuthorityTransferAccepted(address indexed previousAdmin, address indexed newAdmin);
    event AuthorityTransferCancelled(address indexed currentAdmin, address indexed cancelledAdmin);
    event AssetClosed();

    /// @notice Initializes the core parameters of the asset at deployment
    /// @dev Called by AssetFactory via new AssetV1/AssetV2/TokenBase; ERC20(name, symbol) fixes decimals at 18
    /// @param _config Full set of asset parameters (see struct AssetTokenParams)
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

    /// @dev Restricts the call to the address currently set as assetAdmin
    modifier onlyAssetAdmin() {
        _onlyAssetAdmin();
        _;
    }
    
    /// @dev Restricts the call to the address currently set as assetAdmin
    function _onlyAssetAdmin() internal view {
        require(msg.sender == assetAdmin, "not asset admin");
    }

    /// @dev Restricts the call to the address currently set as priceAuthority
    modifier onlyPriceAuthority() {
        _onlyPriceAuthority();
        _;
    }

    /// @dev Restricts the call to the address currently set as priceAuthority
    function _onlyPriceAuthority() internal view {
        require(msg.sender == priceAuthority, "not price authority");
    }

    // ---------------------------------------------------------------------
    // Metadata / config (Asset Admin)
    // ---------------------------------------------------------------------

    /// @notice Updates the asset's off-chain metadata
    /// @dev Callable only by assetAdmin. An empty string "" means "leave this field unchanged" — there is no separate nullable flag, so a field cannot be explicitly cleared to "" through this function
    /// @param _uri New off-chain description URI; "" = unchanged
    /// @param _isin New ISIN; "" = unchanged
    /// @param _jurisdiction New jurisdiction; "" = unchanged
    function updateMetadata(
        string calldata _uri,
        string calldata _isin,
        string calldata _jurisdiction
    ) external onlyAssetAdmin {
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

    /// @notice Updates the treasury addresses used during mint and redemption
    /// @dev Callable only by assetAdmin. Both parameters are checked against address(0)
    /// @param newIssuerTreasury New recipient of investor funds on mint (principal net of fee)
    /// @param newRedemptionSource New source address debited to pay the investor on redemption
    function updateTreasuryAddresses(
        address newIssuerTreasury,
        address newRedemptionSource
    ) external onlyAssetAdmin {
        require(newIssuerTreasury != address(0) && newRedemptionSource != address(0), "zero address");
        issuerTreasury = newIssuerTreasury;
        redemptionSource = newRedemptionSource;
        emit TreasuryAddressesUpdated(newIssuerTreasury, newRedemptionSource);
    }

    /// @notice Assigns a new priceAuthority for the asset
    /// @dev Callable only by assetAdmin. Checked against address(0)
    /// @param newPriceAuthority New address authorized to call updateExchangeRate
    function updatePriceAuthority(address newPriceAuthority) external onlyAssetAdmin {
        require(newPriceAuthority != address(0), "zero address");
        priceAuthority = newPriceAuthority;
        emit PriceAuthorityUpdated(newPriceAuthority);
    }

    /// @notice Updates the current stablecoin↔asset exchange rate
    /// @dev Callable only by priceAuthority. newRate must be > 0
    /// @param newRate Price of one whole asset token, expressed in raw units of stablecoinToken
    function updateExchangeRate(uint256 newRate) external onlyPriceAuthority {
        require(newRate > 0, "rate must be > 0");
        currentRate = newRate;
        emit ExchangeRateUpdated(newRate);
    }

    /// @notice Updates the mint and redemption fees
    /// @dev Callable only by assetAdmin. Both values are capped at 10_000 bps (100%)
    /// @param newMintFeeBps New mint fee, in basis points
    /// @param newRedemptionFeeBps New redemption fee, in basis points
    function updateFees(uint16 newMintFeeBps, uint16 newRedemptionFeeBps) external onlyAssetAdmin {
        require(newMintFeeBps <= 10_000 && newRedemptionFeeBps <= 10_000, "fee > 100%");
        mintFeeBps = newMintFeeBps;
        redemptionFeeBps = newRedemptionFeeBps;
        emit FeesUpdated(newMintFeeBps, newRedemptionFeeBps);
    }

    /// @notice Withdraws accumulated fees held on the contract, in stablecoinToken
    /// @dev Callable only by assetAdmin. Transfers the contract's entire current stablecoinToken balance; reverts on a zero balance
    /// @param destination Recipient address; checked against address(0)
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

    /// @notice Exchanges stablecoin for the asset token at the current rate
    /// @dev The fee (feeRaw) stays on the contract balance and is withdrawn separately via withdrawFees; the principal (netRaw) is sent to issuerTreasury. Reverts if isClosed == true or if maxTotalSupply would be exceeded. Recipient admission (whitelist/blacklist) is enforced inside _update on the _mint call — for AssetV1/AssetV2; the Free variant has no admission check
    /// @param stablecoinAmount Amount of stablecoin deposited by the investor (raw units), must be > 0
    /// @return assetAmount Amount of asset tokens credited to the investor
    function mint(uint256 stablecoinAmount) external nonReentrant returns (uint256 assetAmount) {
        require(!isClosed, "asset closed");
        require(stablecoinAmount > 0, "amount must be > 0");

        uint256 feeRaw = (stablecoinAmount * mintFeeBps) / BPS_DENOMINATOR;
        uint256 netRaw = stablecoinAmount - feeRaw;

        IERC20(stablecoinToken).safeTransferFrom(msg.sender, issuerTreasury, netRaw);
        if (feeRaw > 0) {
            IERC20(stablecoinToken).safeTransferFrom(msg.sender, address(this), feeRaw);
        }

        assetAmount = (netRaw * RATE_PRECISION) / currentRate;

        require(totalSupply() + assetAmount <= maxTotalSupply, "exceeds max supply");

        _mint(msg.sender, assetAmount);
        emit Minted(msg.sender, stablecoinAmount, assetAmount, mintFeeBps);
    }

    /// @notice Exchanges the asset token back for stablecoin at the current rate
    /// @dev Sender admission is enforced inside _update on the _burn call — for AssetV1/AssetV2; the Free variant has neither an admission check nor an explicit isClosed check at this function's level. redemptionSource must have pre-granted the contract an allowance for the required amount — this is an intentional design choice, not a side effect
    /// @param assetAmount Amount of asset tokens burned by the investor, must be > 0
    /// @return netStablecoinOut Amount of stablecoin paid to the investor, net of the redemption fee
    function redeem(uint256 assetAmount) external nonReentrant returns (uint256 netStablecoinOut) {
        require(assetAmount > 0, "amount must be > 0");

        _burn(msg.sender, assetAmount);
        
        uint256 grossRaw = (assetAmount * currentRate) / RATE_PRECISION;

        uint256 feeRaw = (grossRaw * redemptionFeeBps) / BPS_DENOMINATOR;
        netStablecoinOut = grossRaw - feeRaw;

        IERC20(stablecoinToken).safeTransferFrom(redemptionSource, msg.sender, netStablecoinOut);
        if (feeRaw > 0) {
            IERC20(stablecoinToken).safeTransferFrom(redemptionSource, address(this), feeRaw);
        }
        emit Redeemed(msg.sender, assetAmount, netStablecoinOut, redemptionFeeBps);
    }

    // ---------------------------------------------------------------------
    // Two-step authority transfer
    // ---------------------------------------------------------------------

    /// @notice Proposes transferring assetAdmin rights to a new address (first step of the two-step transfer)
    /// @dev Callable only by the current assetAdmin. Rights transfer only after acceptAuthorityTransfer
    /// @param newAdmin Candidate address for the new assetAdmin; checked against address(0)
    function proposeAuthorityTransfer(address newAdmin) external onlyAssetAdmin {
        require(newAdmin != address(0), "zero address");
        pendingAssetAdmin = newAdmin;
        emit AuthorityTransferProposed(assetAdmin, newAdmin);
    }

    /// @notice Confirms acceptance of assetAdmin rights (second step of the transfer)
    /// @dev Callable only by the address previously set as pendingAssetAdmin via proposeAuthorityTransfer
    function acceptAuthorityTransfer() external {
        require(msg.sender == pendingAssetAdmin, "not pending admin");
        address previousAdmin = assetAdmin;
        assetAdmin = pendingAssetAdmin;
        pendingAssetAdmin = address(0);
        emit AuthorityTransferAccepted(previousAdmin, assetAdmin);
    }

    /// @notice Cancels a pending assetAdmin transfer proposal
    /// @dev Callable only by the current assetAdmin; consent of pendingAssetAdmin is not required
    function cancelAuthorityTransfer() external onlyAssetAdmin {
        address cancelled = pendingAssetAdmin;
        pendingAssetAdmin = address(0);
        emit AuthorityTransferCancelled(assetAdmin, cancelled);
    }

    // ---------------------------------------------------------------------
    // Close asset
    // ---------------------------------------------------------------------

    /// @notice Irreversibly closes the asset
    /// @dev Callable only by assetAdmin. Requires totalSupply() == 0. For AssetV1/AssetV2, closing blocks further mint/redeem/transfer via the overridden _update; for the bare TokenBase (Free variant), operations continue unrestricted — a known limitation not addressed at this contract's level
    function closeAsset() external onlyAssetAdmin {
        require(totalSupply() == 0, "supply not zero");
        isClosed = true;
        emit AssetClosed();
    }
}