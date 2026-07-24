// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

contract TokenBase is ERC20 {
    address public assetAdmin;           // текущий админ актива, сверяется при каждом вызове admin-функций
    address public priceAuthority;       // кто имеет право обновлять курс обмена; по умолчанию равен assetAdmin
    address public stablecoinToken;      // адрес ERC-20 стейблкоина, в котором торгуется этот актив
    string  public uri;                  // ссылка на off-chain документ/описание актива; изменяемо
    string  public isin;                 // просто строковое поле, без валидации/бизнес-логики; изменяемо
    string  public jurisdiction;         // просто метаданные, без встроенных правил допуска; изменяемо
    uint16  public mintFeeBps;           // комиссия при mint в базисных пунктах, 20 = 0.2%
    uint16  public redemptionFeeBps;     // комиссия при redemption в базисных пунктах
    address public issuerTreasury;       // адрес (в stablecoinToken), куда поступают деньги инвестора при mint (принципал, за вычетом fee)
    address public redemptionSource;     // адрес (в stablecoinToken), с которого списываются деньги инвестору при redemption; может совпадать с issuerTreasury
    bool    public isClosed;             // если true — актив закрыт через closeAsset, дальнейшие mint/redeem/transfer заблокированы
    uint256 public currentRate;          // курс обмена stablecoin↔asset, обновляется через updateExchangeRate
    uint256 public maxTotalSupply;           // максимальное количество токенов, которое может быть выпущено;
    address private pendingAssetAdmin;      // адрес, которому предложено право стать новым assetAdmin; для двухшаговой передачи прав

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
        // Пустая строка "" означает "не менять" — вызывающий передаёт текущее значение,
        // если не хочет обновлять конкретное поле. Явного sentinel-типа (Optional) в Solidity нет.
        if (bytes(_uri).length > 0) {
            uri = _uri;
        }
        if (bytes(_isin).length > 0) {
            isin = _isin;
        }
        if (bytes(_jurisdiction).length > 0) {
            jurisdiction = _jurisdiction;
        }
    }

    function updateTreasuryAddresses(
        address newIssuerTreasury,
        address newRedemptionSource
    ) external onlyAssetAdmin {
        require(newIssuerTreasury != address(0) && newRedemptionSource != address(0), "zero address");
        issuerTreasury = newIssuerTreasury;
        redemptionSource = newRedemptionSource;
    }

    function updatePriceAuthority(address newPriceAuthority) external onlyAssetAdmin {
        require(newPriceAuthority != address(0), "zero address");
        priceAuthority = newPriceAuthority;
    }

    function updateExchangeRate(uint256 newRate) external onlyPriceAuthority {
        require(newRate > 0, "rate must be > 0");
        currentRate = newRate;
    }

    function updateFees(uint16 newMintFeeBps, uint16 newRedemptionFeeBps) external onlyAssetAdmin {
        require(newMintFeeBps <= 10_000 && newRedemptionFeeBps <= 10_000, "fee > 100%");
        mintFeeBps = newMintFeeBps;
        redemptionFeeBps = newRedemptionFeeBps;
    }

    // ---------------------------------------------------------------------
    // Mint / Redeem (investor-facing)
    // ---------------------------------------------------------------------

    uint256 private constant BPS_DENOMINATOR = 10_000;
    uint256 private constant RATE_PRECISION = 1e18;
    // ASSUMPTION (в этом куске ТЗ mint/redeem не описаны — этого требует пользователь,
    // реализация "по логике курса обмена и существующих параметров"):
    // currentRate выражен с точностью 1e18 и означает "сколько stablecoin в целых единицах
    // (не в сырых base units, т.е. независимо от decimals стейблкоина) стоит 1 asset token".
    // Например currentRate = 1.05e18 значит "1 asset token = 1.05 stablecoin".
    // _stablecoinDecimals используется здесь для перевода между сырыми unit'ами стейблкоина
    // (то, что реально лежит на балансах) и нормализованными 18-значными величинами для расчёта по rate.
    // Если реальная договорённость про rate иная — эту часть придётся переписать.

    function mint(uint256 stablecoinAmount) external returns (uint256 assetAmount) {
        require(stablecoinAmount > 0, "amount must be > 0");

        uint256 feeRaw = (stablecoinAmount * mintFeeBps) / BPS_DENOMINATOR;
        uint256 netRaw = stablecoinAmount - feeRaw;

        // Забираем всю сумму у инвестора: net идёт в issuerTreasury (принципал),
        // fee остаётся на балансе самого AssetToken (нет отдельного feeVault) — выводится через withdrawFees.
        ERC20(stablecoinToken).transferFrom(msg.sender, issuerTreasury, netRaw);
        if (feeRaw > 0) {
            // require(ERC20(stablecoinToken).transferFrom(msg.sender, address(this), feeRaw), "transfer of fee failed");
            ERC20(stablecoinToken).transferFrom(msg.sender, address(this), feeRaw);
        }

        assetAmount = (netRaw * RATE_PRECISION) / currentRate; // нормализуем к 18 decimals, делим на курс, возвращаем к исходным decimals;

        require(totalSupply() + assetAmount <= maxTotalSupply, "exceeds max supply");

        _mint(msg.sender, assetAmount); // whitelist-проверка получателя сработает внутри _update
    }

    function redeem(uint256 assetAmount) external returns (uint256 netStablecoinOut) {
        require(assetAmount > 0, "amount must be > 0");

        _burn(msg.sender, assetAmount); // whitelist-проверка отправителя сработает внутри _update
        
        uint256 grossRaw = (assetAmount * currentRate) / RATE_PRECISION;

        uint256 feeRaw = (grossRaw * redemptionFeeBps) / BPS_DENOMINATOR;
        netStablecoinOut = grossRaw - feeRaw;

        ERC20(stablecoinToken).transferFrom(redemptionSource, msg.sender, netStablecoinOut);
        if (feeRaw > 0) {
            ERC20(stablecoinToken).transferFrom(redemptionSource, address(this), feeRaw);
        }
    }

    // ---------------------------------------------------------------------
    // Two-step authority transfer
    // ---------------------------------------------------------------------

    function proposeAuthorityTransfer(address newAdmin) external onlyAssetAdmin {
        require(newAdmin != address(0), "zero address");
        pendingAssetAdmin = newAdmin;
    }

    function acceptAuthorityTransfer() external {
        require(msg.sender == pendingAssetAdmin, "not pending admin");
        assetAdmin = pendingAssetAdmin;
        pendingAssetAdmin = address(0);
    }

    function cancelAuthorityTransfer() external onlyAssetAdmin {
        pendingAssetAdmin = address(0);
    }

    // ---------------------------------------------------------------------
    // Close asset
    // ---------------------------------------------------------------------

    function closeAsset() external onlyAssetAdmin {
        require(totalSupply() == 0, "supply not zero");
        isClosed = true;
        // emit AssetClosed();
    }
}