# Техническое задание: Tokeonika — White-Label платформа токенизации RWA на Robinhood Chain

## 1. Назначение продукта

Open-source платформа для эмиссии, обращения и погашения токенизированных реальных активов (RWA) на EVM-совместимых сетях (целевые сети: Robinhood Chain, Ethereum, другие EVM).

**Границы ответственности платформы:** KYC, юрисдикционный комплаенс, инвестор-скоринг, AML-процедуры — полностью на стороне компании-клиента, вне периметра разработки. Платформа предоставляет только on-chain и off-chain инфраструктуру допуска (whitelist/blacklist) как generic-механизм.

**Стейблкоин:** обычный ERC-20, per-asset (каждый актив сам решает, в каком стейблкоине торгуется).

**Decimals актива:** не настраиваются — каждый `AssetToken`-контракт использует дефолтную точность OpenZeppelin ERC-20 (18 знаков). Параметра `decimals` нет ни в конструкторе, ни в `createAsset`.

---

## 2. Роли системы

| Роль                             | Описание                                                                                                                                                                                                                               |
| -------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Investor**                     | Конечный пользователь, взаимодействующий с кошельком, минтит/редимит/торгует на вторичном рынке                                                                                                                                        |
| **Asset Admin**                  | Управляет конкретным активом: whitelist/blacklist этого актива, параметры mint/redemption, metadata                                                                                                                                    |
| **Price Authority**              | Обновляет курс обмена stablecoin↔asset для конкретного актива. Обязательный параметр при создании актива                                                                                                                               |
| **Platform Admin** (super-admin) | Создаёт новые активы и назначает Asset Admin, управляет общими настройками white-label деплоя. **На данном этапе создание активов ничем не ограничено** — см. 4.2<br>В testnet этой роли не будет, чтобы каждый мог создать свой asset |

---

## 3. Архитектура верхнего уровня

```
┌─────────────────┐     ┌──────────────────┐     ┌─────────────────────┐
│   Frontend       │────▶│  Backend API      │────▶│  EVM RPC / indexer   │
│ (Investor + Admin│     │ (indexer, off-chain│     │  (The Graph / events)│
│  panels)         │◀────│  state, webhooks) │◀────│                      │
└─────────────────┘     └──────────────────┘     └─────────┬───────────┘
                                                              │
                                                   ┌──────────▼───────────┐
                                                   │   Smart Contracts     │
                                                   │                       │
                                                   │ 1. TokenBase          │
                                                   │ 2. AssetV1 (whitelist)│
                                                   │ 3. AssetV2 (blacklist)│
                                                   │ 4. AssetFactory       │
                                                   │ 5. SecondaryMarket    │
                                                   │ 6. PlatformConfig     │
                                                   └───────────────────────┘
```

**Принцип разделения:** вся логика допуска и владения активом — on-chain (source of truth). Backend — это только индексация, кэш для UI и удобные API-обёртки поверх смарт-контрактов. Backend никогда не является единственным местом хранения whitelist/blacklist-статуса.

---

## 4. On-chain модуль: контракты и структуры данных

### 4.0 `PlatformConfig.sol`

Наследует `Ownable2Step` (OpenZeppelin) — готовая библиотека для двухшаговой передачи прав.

```solidity
contract PlatformConfig is Ownable2Step {
    // owner() — это и есть Platform Admin
}
```

**Функции модуля:**

|Функция|Роль|Параметры|Что делает|
|---|---|---|---|
|`transferOwnership`|Platform Admin (текущий)|`newOwner`|Предлагает передачу прав новому адресу. Права ещё не переходят|
|`acceptOwnership`|Новый Platform Admin|—|Новый владелец подтверждает своим адресом принятие прав|

**Отмена предложения:** `Ownable2Step` не имеет отдельной функции `cancel`. Повторный вызов `transferOwnership` с другим адресом перезаписывает `pendingOwner`.

**Важная оговорка:** механизм защищает от опечатки в адресе при добровольной передаче прав, но не решает проблему утери ключа (см. раздел 8).

**Текущее состояние:** `PlatformConfig` пока не подключён к `AssetFactory` — см. 4.2, это сделано для того чтобы на testnet кто угодно мог создавать свой asset для целей демонстрации возможностей платформы.

---

### 4.1 `TokenBase.sol` и варианты допуска (`AssetV1` / `AssetV2`)

Общая логика актива (metadata, treasury, fees, курс, mint/redeem, передача прав, закрытие) вынесена в `TokenBase.sol`. Механизм допуска — **отдельный, подключаемый слой**, реализованный как два самостоятельных наследника, плюс возможность деплоить `TokenBase` вообще без какого-либо допуска:

|Вариант|Контракт|Модель допуска|
|---|---|---|
|`Whitelist`|`AssetV1.sol`|Allow-list: по умолчанию никто не допущен, кроме явно добавленных адресов|
|`Blacklist`|`AssetV2.sol`|Deny-list: по умолчанию допущены все, кроме явно заблокированных адресов|
|`Free`|`TokenBase.sol` напрямую|Без какого-либо контроля допуска — обычный ERC-20|

Выбор варианта — на усмотрение бизнеса при создании конкретного актива (см. `AssetFactory.TypeAsset`, 4.2). Whitelist/blacklist — это два разных режима допуска с разной семантикой "кто допущен по умолчанию", предоставляемые платформой как опция, а не единственно возможная модель.

**`TokenBase.sol` — структура и поля:**

```solidity
contract TokenBase is ERC20, ReentrancyGuard {
    address public assetAdmin;           // текущий админ актива, сверяется при каждом вызове admin-функций
    address public priceAuthority;       // кто имеет право обновлять курс обмена
    address public stablecoinToken;      // адрес ERC-20 стейблкоина, в котором торгуется этот актив
    string  public uri;                  // ссылка на off-chain документ/описание актива; изменяемо
    string  public isin;                 // просто строковое поле, без валидации/бизнес-логики; изменяемо
    string  public jurisdiction;         // просто метаданные, без встроенных правил допуска; изменяемо
    uint16  public mintFeeBps;           // комиссия при mint в базисных пунктах, 20 = 0.2%
    uint16  public redemptionFeeBps;     // комиссия при redemption в базисных пунктах
    address public issuerTreasury;       // адрес (в stablecoinToken), куда поступают деньги инвестора при mint (принципал, за вычетом fee)
    address public redemptionSource;     // адрес (в stablecoinToken), с которого списываются деньги инвестору при redemption; может совпадать с issuerTreasury
    bool    public isClosed;             // если true — актив закрыт через closeAsset
    uint256 public currentRate;          // курс обмена stablecoin↔asset, обновляется через updateExchangeRate
    uint256 public maxTotalSupply;       // жёсткий потолок эмиссии; mint выше этого предела реверт'ится
    address private pendingAssetAdmin;   // адрес, которому предложено право стать новым assetAdmin (двухшаговая передача)
}
```

Комиссия при mint остаётся на балансе самого контракта (`address(this)`) и выводится через `withdrawFees`.

**Функции `TokenBase` (общие для всех вариантов):**

|Функция|Роль|Параметры|Что делает|
|---|---|---|---|
|`updateMetadata`|Asset Admin|`uri?, isin?, jurisdiction?`|Обновляет поля. Пустая строка `""` означает "не менять это поле" — явного nullable-типа в Solidity нет, поэтому очистить поле до пустой строки через эту функцию невозможно. `name`/`symbol` не принимает — неизменяемы (стандартное поведение ERC-20, нет функции их поменять)|
|`updateTreasuryAddresses`|Asset Admin|`newIssuerTreasury, newRedemptionSource`|Меняет treasury-адреса. Проверяет оба на `!= address(0)`|
|`updatePriceAuthority`|Asset Admin|`newPriceAuthority`|Меняет адрес, обновляющий курс. Проверяет `!= address(0)`|
|`updateExchangeRate`|Price Authority|`newRate`|Обновляет `currentRate`. Проверяет `> 0`|
|`updateFees`|Asset Admin|`newMintFeeBps, newRedemptionFeeBps`|Проверяет `<= 10_000` (100%) для обоих|
|`withdrawFees`|Asset Admin|`destination`|Выводит весь баланс `stablecoinToken`, накопленный на самом контракте, на `destination`|
|`mint`|Investor|`stablecoinAmount`|См. формулу ниже. Проверяет `maxTotalSupply`. Whitelist/blacklist-проверка получателя — через `_update()` (для `AssetV1`/`AssetV2`); для `Free`-варианта проверки допуска нет вообще|
|`redeem`|Investor|`assetAmount`|Обратная операция. Whitelist/blacklist-проверка отправителя — аналогично, через `_update()`|
|`proposeAuthorityTransfer`|Asset Admin (текущий)|`newAdmin`|Предлагает передачу прав над активом. Проверяет `!= address(0)`|
|`acceptAuthorityTransfer`|Новый Asset Admin|—|Подтверждает принятие прав своим адресом|
|`cancelAuthorityTransfer`|Asset Admin (текущий)|—|Отменяет предложение до принятия|
|`closeAsset`|Asset Admin|—|Требует `totalSupply() == 0`, ставит `isClosed = true`|

**Формула mint (`RATE_PRECISION = 1e18`, соответствует фиксированным 18 decimals актива):**

```solidity
feeRaw = stablecoinAmount * mintFeeBps / 10_000;
netRaw = stablecoinAmount - feeRaw;
// netRaw -> issuerTreasury, feeRaw -> остаётся на балансе контракта
assetAmount = netRaw * RATE_PRECISION / currentRate;
require(totalSupply() + assetAmount <= maxTotalSupply);
```

`currentRate` — цена одного **целого** токена актива, выраженная в сырых единицах стейблкоина (например, `1_000000` для 1 USDC при курсе 1:1). Формула — одно умножение, одно деление, без промежуточного двойного масштабирования.

**Формула redeem (обратная):**

```solidity
grossRaw = assetAmount * currentRate / RATE_PRECISION;
feeRaw = grossRaw * redemptionFeeBps / 10_000;
netStablecoinOut = grossRaw - feeRaw;
// redemptionSource -> инвестор (net), redemptionSource -> контракт (fee)
```

`redemptionSource` заранее выдаёт `TokenBase`-контракту `allowance` на нужную сумму — эта схема принята осознанно, а не побочный эффект.

---

**`AssetV1.sol` / `AssetV2.sol` — специфичные для варианта поля и функции:**

Оба наследуют `TokenBase` и `Pausable`. Отличаются только моделью допуска.

```solidity
// AssetV1: mapping(address => bool) internal isWhitelisted;
// AssetV2: mapping(address => bool) internal isBlacklisted;
```

|Функция|Роль|Параметры|Что делает|
|---|---|---|---|
|`pause` / `unpause`|Asset Admin|—|Стандартный `Pausable._pause()`/`_unpause()`|
|`forceTransfer`|Asset Admin|`from, to, amount`|Принудительный перевод без подписи владельца. Проверка допуска в `_update()` всё равно срабатывает на обе стороны — снимается только требование подписи `from`, не требование допуска|
|`forceBurn`|Asset Admin|`from, amount`|Принудительное сжигание через внутренний `_rawBurn`, минующий `_update()` — единственная функция, которая работает независимо от допуска и обходит `isClosed`/`paused()` тоже (осознанное решение: admin должен иметь возможность изъять токены даже в экстренной ситуации, когда актив на паузе или закрыт)|
|`addToWhitelist` (V1) / `addToBlacklist` (V2)|Asset Admin|`investor`|Добавляет адрес в соответствующий список|
|`removeFromWhitelist` (V1) / `removeFromBlacklist` (V2)|Asset Admin|`investor`|Убирает адрес из списка|
|`isAllowed` (view)|Кто угодно|`investor`|V1: возвращает `isWhitelisted[investor]`. V2: возвращает `!isBlacklisted[investor]`|

**`_update()` override (одинаковая структура в обоих вариантах, разный источник проверки):**

```solidity
require(!isClosed, "asset closed");
require(!paused(), "asset paused");
// mint (from == 0): проверяем допуск получателя
// burn (to == 0):   проверяем допуск отправителя
// transfer:         проверяем обе стороны
```

---

### 4.2 `AssetFactory.sol`

```solidity
enum TypeAsset {
    Whitelist, // 0 — деплой AssetV1
    Blacklist, // 1 — деплой AssetV2
    Free       // 2 — деплой голого TokenBase, без допуска
}
```

Создание актива — **полноценный `new` деплой** (`new AssetV1(...)` / `new AssetV2(...)` / `new TokenBase(...)`), не клон через `Clones.sol`. Конструкторы принимают единый `struct AssetTokenParams` (объявлен в `TokenBase`), что и решает проблему stack-too-deep при большом числе параметров.

**Функции модуля:**

|Функция|Роль|Параметры|Что делает|
|---|---|---|---|
|`createAsset`|**Не ограничена** (см. ниже)|`assetType: TypeAsset`, `config: AssetTokenParams`|Деплоит `AssetV1`/`AssetV2`/`TokenBase` в зависимости от `assetType`. Валидирует ненулевые `assetAdmin`, `stablecoinToken`, `issuerTreasury`, `redemptionSource`, `priceAuthority`; `mintFeeBps`/`redemptionFeeBps <= 10_000`; `initialRate > 0`|

**Текущее состояние доступа — важно.** `createAsset` не имеет модификатора авторизации: **любой адрес может вызвать эту функцию** и задеплоить новый актив с произвольными параметрами, включая назначение себя `assetAdmin`. `PlatformConfig`/`Ownable2Step` (см. 4.0) в этой функции никак не используется. Это осознанное текущее состояние ради целей тестирования и демонстрации продукта — **не баг и не пропуск**, но и не финальное поведение: в проде эта функция должна быть ограничена `onlyPlatformAdmin` (проверка `msg.sender == platformConfig.owner()`), прежде чем открывать доступ внешним пользователям.

**`priceAuthority` — обязательный параметр, без fallback.** В отличие от более ранних версий этого документа, автоматической подстановки `assetAdmin` по умолчанию, если `priceAuthority` не указан, **не происходит** — фабрика требует явный ненулевой адрес.

---

### 4.3 `SecondaryMarket.sol`

Держателем эскроированных токенов для всех активов выступает сам контракт `SecondaryMarket` — отдельный per-asset vault-контракт не заводится.

```solidity
contract SecondaryMarket is ReentrancyGuard {
    enum OrderStatus { Open, PartiallyFilled, Filled, Cancelled }

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
}
```

**Функции модуля:**

|Функция|Роль|Параметры|Что делает|
|---|---|---|---|
|`placeOrder`|Investor (maker)|`assetToken, amount, pricePerUnit`|Переводит `amount` токенов актива в эскроу на `SecondaryMarket` через `safeTransferFrom`. Whitelist/blacklist-проверка (maker как source, `SecondaryMarket` как destination) срабатывает автоматически внутри `_update()` актива — если `SecondaryMarket` не допущен (для `AssetV1`) или заблокирован (для `AssetV2`), транзакция ревертится|
|`fillOrder`|Investor (taker)|`orderId, fillAmount`|`stablecoinAmount = fillAmount * pricePerUnit / 1e18`. Taker платит maker'у напрямую (стейблкоин не проходит через эскроу), получает актив из эскроу. Поддерживает частичное исполнение|
|`cancelOrder`|Investor (maker)|`orderId`|Возвращает неисполненный остаток maker'у, статус — `Cancelled`|

**Текущее состояние — известные пробелы, оставлены как есть намеренно:**

- **Нет `initializeMarketVault`.** Чтобы `SecondaryMarket` вообще мог держать токены конкретного актива на `AssetV1`, asset admin должен вручную вызвать `addToWhitelist(secondaryMarketAddress)` на самом токене — отдельной удобной функции для этого в `SecondaryMarket` нет.

---

## 5. Backend — детальная структура

Backend — не источник истины, а сервисный слой между on-chain состоянием и frontend.

### 5.1 Индексер

Наполнение БД происходит через отслеживание эвентов с контрактов.

### 5.2 Схема БД (основные таблицы)

| Таблица               | Назначение                                                                    | Ключевые поля                                                                                                                                                                                                                                       |
| --------------------- | ----------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `assets`              | Кэш конфигурации токена для быстрого листинга                                 | assetToken, assetType (Whitelist/Blacklist/Free), name, symbol, uri, isin, jurisdiction, stablecoinToken, assetAdmin, isPaused, isClosed, mintFeeBps, redemptionFeeBps, issuerTreasury, redemptionSource, priceAuthority, maxTotalSupply, createdAt |
| `price_feeds`         | Кэш `currentRate` по каждому активу                                           | assetToken, currentRate, updatedAt                                                                                                                                                                                                                  |
| `whitelist_status`    | Кэш допуска (whitelist для AssetV1 или инвертированный blacklist для AssetV2) | wallet, assetToken, isAllowed                                                                                                                                                                                                                       |
| `mint_events`         | История mint-транзакций                                                       | investor, assetToken, stablecoinAmount, assetAmount, fee, txHash, timestamp                                                                                                                                                                         |
| `redemption_events`   | История redemption-транзакций                                                 | investor, assetToken, assetAmount, stablecoinAmount, fee, txHash, timestamp                                                                                                                                                                         |
| `orders`              | Кэш ордеров вторичного рынка                                                  | orderId, maker, assetToken, amount, pricePerUnit, filledAmount, status, createdAt                                                                                                                                                                   |
| `order_fills`         | История исполнений ордеров                                                    | orderId, taker, fillAmount, txHash, timestamp                                                                                                                                                                                                       |
| `authority_transfers` | История/статус передачи прав над активами                                     | assetToken, currentAdmin, proposedAdmin, status                                                                                                                                                                                                     |

`PlatformConfig` не кэшируется. `feeVault` как отдельная сущность не существует — комиссии живут на балансе самого `assetToken`, доступном через `withdrawFees`.

### 5.3 API-эндпоинты

**Публичные:**

- `GET /assets` — список активов
- `GET /assets/:assetToken` — детали актива
- `GET /assets/:assetToken/whitelist-status?wallet=...` — допущен ли кошелёк
- `GET /assets/:assetToken/orders` — orderbook
- `GET /assets/:assetToken/exchange-rate` — текущий курс
- `GET /investor/:wallet/history` — история операций инвестора

**Для admin-панелей:**

- `GET /admin/assets` — активы, где вызывающий — assetAdmin
- `GET /admin/assets/:assetToken/whitelist` — список допущенных адресов

**Построение транзакций:**

_Investor:_

- `POST /tx/mint` `{wallet, assetToken, stablecoinAmount}` → unsigned `mint`
- `POST /tx/redeem` `{wallet, assetToken, assetAmount}` → unsigned `redeem`
- `POST /tx/place-order` `{wallet, assetToken, amount, pricePerUnit}` → unsigned `placeOrder`
- `POST /tx/fill-order` `{wallet, orderId, fillAmount}` → unsigned `fillOrder`
- `POST /tx/cancel-order` `{wallet, orderId}` → unsigned `cancelOrder`

_Admin:_

- `POST /tx/create-asset` `{assetType, name, symbol, uri, isin, jurisdiction, stablecoinToken, mintFeeBps, redemptionFeeBps, issuerTreasury, redemptionSource, assetAdmin, priceAuthority, initialRate, maxSupply}` → unsigned `createAsset` (**не ограничено ролью на данном этапе**, см. 4.2)
- `POST /tx/whitelist/add`, `/tx/whitelist/remove` `{wallet, assetToken}` → unsigned `addToWhitelist`/`removeFromWhitelist` (AssetV1) или `addToBlacklist`/`removeFromBlacklist` (AssetV2)
- `POST /tx/update-metadata` `{assetToken, uri?, isin?, jurisdiction?}` → unsigned `updateMetadata`
- `POST /tx/update-treasury-addresses` `{assetToken, newIssuerTreasury, newRedemptionSource}` → unsigned `updateTreasuryAddresses`
- `POST /tx/update-fees` `{assetToken, newMintFeeBps, newRedemptionFeeBps}` → unsigned `updateFees`
- `POST /tx/update-price-authority` `{assetToken, newPriceAuthority}` → unsigned `updatePriceAuthority`
- `POST /tx/update-exchange-rate` `{assetToken, newRate}` → unsigned `updateExchangeRate`
- `POST /tx/pause`, `/tx/unpause` `{assetToken}` → unsigned `pause`/`unpause`
- `POST /tx/withdraw-fees` `{assetToken, destination}` → unsigned `withdrawFees`
- `POST /tx/force-transfer-asset` `{assetToken, from, to, amount}` → unsigned `forceTransfer`
- `POST /tx/force-burn-asset` `{assetToken, from, amount}` → unsigned `forceBurn`
- `POST /tx/propose-authority-transfer` `{assetToken, newAdmin}` → unsigned `proposeAuthorityTransfer`
- `POST /tx/accept-authority-transfer` `{assetToken}` → unsigned `acceptAuthorityTransfer`
- `POST /tx/cancel-authority-transfer` `{assetToken}` → unsigned `cancelAuthorityTransfer`
- `POST /tx/close-asset` `{assetToken}` → unsigned `closeAsset`
- `POST /tx/propose-platform-admin-transfer` `{newAdmin}` → unsigned `transferOwnership`
- `POST /tx/accept-platform-admin-transfer` → unsigned `acceptOwnership`

**Отсутствуют на данный момент** (нет соответствующих функций в контрактах, см. 4.3): `/tx/initialize-market-vault`, `/tx/force-recover-order`.

---

## 6. Frontend — экраны

### Investor

1. Connect wallet
2. Список доступных активов (с фильтром "доступно мне")
3. Mint — swap stablecoin → asset
4. Redemption — обратный swap
5. Вторичный рынок: orderbook, создание/исполнение/отмена заявки
6. История операций

### Asset Admin

1. Редактирование uri/isin/jurisdiction (`updateMetadata`)
2. Управление допуском актива — добавить/убрать адрес (whitelist для AssetV1, blacklist для AssetV2; для Free-варианта экран отсутствует, допуск не применим)
3. Управление комиссиями, treasury-адресами, pause/unpause (для Free-варианта pause недоступен — `Pausable` не наследуется)
4. Вывод накопленных комиссий (`withdrawFees`)
5. Назначение price authority (`updatePriceAuthority`)
6. Передача админ-прав (propose/accept/cancel)
7. Force-transfer / force-burn (только для AssetV1/AssetV2 — недоступно для Free-варианта, где нет `onlyAssetAdmin`-функций допуска вообще, кроме унаследованных из TokenBase)
8. Закрытие актива (`closeAsset`)

### Price Authority

1. Обновление курса обмена (`updateExchangeRate`)

### Platform Admin (если managed-режим)

1. Создание новых активов (**на данном этапе доступно любому адресу, не только Platform Admin** — см. 4.2)
2. Обзор всех активов на деплое
3. Общие настройки white-label инстанса — полностью off-chain
4. Передача прав Platform Admin

---

## 7. Backlog

---

## 8. Осознанно принятые ограничения и открытые задачи

---

## 9. Сквозные сценарии

Формат: каждая строка — один шаг с явным актором.

### 9.0 Общий паттерн для однотипных admin-функций

Применимо к: `updateMetadata`, `updateTreasuryAddresses`, `updateFees`, `updatePriceAuthority`, `pause`/`unpause`, `withdrawFees`.

| №   | Актор                            | Действие                                                  |
| --- | -------------------------------- | --------------------------------------------------------- |
| 1   | Asset Admin (Frontend)           | вводит новые значения                                     |
| 2   | Asset Admin (Frontend → Backend) | `POST /tx/...` `{assetToken, ...}`                        |
| 3   | Backend                          | строит unsigned-транзакцию                                |
| 4   | Asset Admin                      | подписывает                                               |
| 5   | Blockchain                       | `require(msg.sender == assetAdmin)` → применяет изменение |
| 6   | Индексер                         | обновляет `assets`                                        |

### 9.1 Platform Admin

**Создание актива**

| №   | Актор                                                                         | Действие                                                                                                                                                                                                                           |
| --- | ----------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | Любой адрес (Frontend) _(на данном этапе не ограничено ролью Platform Admin)_ | заполняет форму создания актива, выбирает `assetType`                                                                                                                                                                              |
| 2   | Тот же адрес (Frontend → Backend)                                             | `POST /tx/create-asset {...}`                                                                                                                                                                                                      |
| 3   | Backend                                                                       | строит unsigned `createAsset`                                                                                                                                                                                                      |
| 4   | Вызывающий                                                                    | подписывает                                                                                                                                                                                                                        |
| 5   | Blockchain (AssetFactory)                                                     | без проверки роли деплоит `AssetV1`/`AssetV2`/`TokenBase` в зависимости от `assetType`                                                                                                                                             |
| 6   | Индексер                                                                      | Событие AssetCreated(assetToken, assetType) сообщает индексеру адрес актива и его тип, индексер добирает необходимую информацию, зная assetToken, а именно: name, symbol, uri, isin, jurisdiction, stablecoinToken ... и так далее |

**Передача прав Platform Admin** (в текущей реализации этого нет, так как актив может создать кто угодно в целях демонстрации и т д)

|№|Актор|Действие|
|---|---|---|
|1|Текущий Platform Admin|вызывает `transferOwnership(newAdmin)`|
|2|Blockchain|сохраняет `pendingOwner`|
|—|_(разрыв во времени)_||
|3|Новый Platform Admin|вызывает `acceptOwnership()`|
|4|Blockchain|обновляет `owner`|

### 9.2 Asset Admin

**Добавление / удаление из допуска**

| №   | Актор                            | Действие                                                                  |
| --- | -------------------------------- | ------------------------------------------------------------------------- |
| 1   | Asset Admin (Frontend)           | вводит адрес инвестора                                                    |
| 2   | Asset Admin (Frontend → Backend) | `POST /tx/whitelist/add` или `/remove`                                    |
| 3   | Backend                          | строит unsigned-транзакцию                                                |
| 4   | Asset Admin                      | подписывает                                                               |
| 5   | Blockchain                       | `onlyAssetAdmin`; обновляет `isWhitelisted` (V1) или `isBlacklisted` (V2) |
| 6   | Индексер                         | обновляет `whitelist_status`                                              |

**Force-transfer / Force-burn**

| №   | Актор                            | Действие                                                                                                                                     |
| --- | -------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | Asset Admin (Frontend)           | вводит адреса/сумму, подтверждает чувствительную операцию                                                                                    |
| 2   | Asset Admin (Frontend → Backend) | `POST /tx/force-transfer-asset` или `/tx/force-burn-asset`                                                                                   |
| 3   | Backend                          | строит unsigned-транзакцию                                                                                                                   |
| 4   | Asset Admin                      | подписывает                                                                                                                                  |
| 5   | Blockchain                       | `forceTransfer` — допуск проверяется на обе стороны через `_update()`. `forceBurn` — обходит допуск, `isClosed`, `paused()` через `_rawBurn` |
| 6   | Индексер                         | -                                                                                                                                            |

**Передача прав над активом**

|№|Актор|Действие|
|---|---|---|
|1|Текущий Asset Admin|`proposeAuthorityTransfer(newAdmin)`|
|2|Blockchain|сохраняет предложение|
|—|_(разрыв во времени)_||
|3|Новый Asset Admin|`acceptAuthorityTransfer()`|
|4|Blockchain|обновляет `assetAdmin`|

**`closeAsset`**

| №   | Актор       | Действие                                                                                                                                                      |
| --- | ----------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | Asset Admin | инициирует закрытие (только при `totalSupply() == 0`)                                                                                                         |
| 2   | Backend     | строит unsigned `closeAsset`                                                                                                                                  |
| 3   | Asset Admin | подписывает                                                                                                                                                   |
| 4   | Blockchain  | `isClosed = true`. Для AssetV1/V2 блокирует дальнейшие mint/redeem/transfer через `_update()`; для Free — до исправления из backlog (п.2) не блокирует ничего |
| 5   | Индексер    | обновляет поле isClosed в таблице assets                                                                                                                      |

### 9.3 Price Authority

| №   | Актор                                | Действие                                                         |
| --- | ------------------------------------ | ---------------------------------------------------------------- |
| 1   | Price Authority (Frontend)           | вводит `newRate`                                                 |
| 2   | Price Authority (Frontend → Backend) | `POST /tx/update-exchange-rate {assetToken, newRate}`            |
| 3   | Backend                              | строит unsigned-транзакцию                                       |
| 4   | Price Authority                      | подписывает                                                      |
| 5   | Blockchain                           | `require(msg.sender == priceAuthority)`; обновляет `currentRate` |
| 6   | Индексер                             | обновляет `price_feeds`                                          |

### 9.4 Investor

**Mint**

| №   | Актор                         | Действие                                                                                                                                                                           |
| --- | ----------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | Investor (Frontend)           | connect wallet, вводит сумму                                                                                                                                                       |
| 2   | Investor (Frontend → Backend) | `GET /assets/:assetToken/whitelist-status?wallet=...`                                                                                                                              |
| 3   | Investor (Frontend → Backend) | `POST /tx/mint {wallet, assetToken, stablecoinAmount}`                                                                                                                             |
| 4   | Backend                       | строит unsigned `mint`                                                                                                                                                             |
| 5   | Investor                      | подписывает                                                                                                                                                                        |
| 6   | Blockchain                    | считает по курсу, комиссия остаётся на контракте, остаток → `issuerTreasury`; проверяет `maxTotalSupply`; `_mint()` — допуск получателя проверяется через `_update()` (кроме Free) |
| 7   | Индексер                      | Обновляет таблицу mint_events                                                                                                                                                      |

**Redeem** — тот же поток в обратную сторону: `POST /tx/redeem` → `redeem()` → `_burn()` → комиссия и остаток через `redemptionSource`. Обновляет таблицу redemption_events.

**Place order**

| №   | Актор                         | Действие                                                                                 |
| --- | ----------------------------- | ---------------------------------------------------------------------------------------- |
| 1   | Investor (Frontend)           | `GET /assets/:assetToken/orders`                                                         |
| 2   | Investor (Frontend → Backend) | `POST /tx/place-order {wallet, assetToken, amount, pricePerUnit}`                        |
| 3   | Backend                       | строит unsigned `placeOrder`                                                             |
| 4   | Investor (maker)              | подписывает                                                                              |
| 5   | Blockchain                    | допуск maker'а и `SecondaryMarket` проверяется через `_update()` актива; создаёт `Order` |
| 6   | Индексер                      | пишет в `orders`                                                                         |

**Fill order**

|№|Актор|Действие|
|---|---|---|
|1|Investor (taker, Frontend)|выбирает ордер, вводит `fillAmount`|
|2|Investor (Frontend → Backend)|`POST /tx/fill-order {wallet, orderId, fillAmount}`|
|3|Backend|строит unsigned `fillOrder`|
|4|Investor (taker)|подписывает|
|5|Blockchain|допуск `SecondaryMarket` и taker'а проверяется; допуск maker'а на этом шаге не перепроверяется|
|6|Индексер|обновляет `orders`/`order_fills` (события `OrderFilled` эмитятся)|

**Cancel order**

|№|Актор|Действие|
|---|---|---|
|1|Investor (maker)|`POST /tx/cancel-order {wallet, orderId}`|
|2|Backend|строит unsigned `cancelOrder`|
|3|Investor (maker)|подписывает|
|4|Blockchain|допуск maker'а как destination проверяется — если maker исключён/заблокирован, транзакция ревертится, штатного пути восстановления сейчас нет (см. раздел 8)|
|5|Индексер|обновляет `orders` (событие `OrderCancelled` эмитится)|

### 9.5 Корпоративный клиент — прямой вызов

| №   | Актор                             | Действие                                                                                   |
| --- | --------------------------------- | ------------------------------------------------------------------------------------------ |
| 1   | Корпоративный клиент              | сам строит calldata для `mint`/`redeem`                                                    |
| 2   | Корпоративный клиент              | подписывает своим keypair/HSM/multisig                                                     |
| 3   | Корпоративный клиент → Blockchain | отправляет напрямую в EVM RPC                                                              |
| 4   | Blockchain                        | те же проверки, что и в обычном потоке                                                     |
| 5   | Индексер                          | индексер работает так же, независимо от того откуда обращается юзер(Frontend или напрямую) |
