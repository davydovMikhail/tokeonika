// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {TokenBase} from "./TokenBase.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";

// токен со встроенным whitelist
contract AssetV1 is TokenBase, Pausable {


    mapping(address => bool) internal isWhitelisted;

    constructor(
        AssetTokenParams memory _config
    ) TokenBase(
        _config
    ) {
    }



    // ---------------------------------------------------------------------
    // Pause (Asset Admin) — используем Pausable напрямую, без дублирующего isPaused
    // ---------------------------------------------------------------------

    function pause() external onlyAssetAdmin {
        _pause();
    }

    function unpause() external onlyAssetAdmin {
        _unpause();
    }

    // ---------------------------------------------------------------------
    // Force transfer / force burn (Asset Admin)
    // ---------------------------------------------------------------------

    function forceTransfer(address from, address to, uint256 amount) external onlyAssetAdmin {
        // Снимает требование подписи `from`, но НЕ снимает whitelist-проверку —
        // обычный _transfer идёт через _update(), где whitelist всё равно сработает на обе стороны.
        _transfer(from, to, amount);
    }

    function forceBurn(address from, uint256 amount) external onlyAssetAdmin {
        // Минует whitelist-проверку в _update() — работает даже если `from` уже не в whitelist.
        _rawBurn(from, amount);
    }

    function addToWhitelist(address investor) external onlyAssetAdmin {
        isWhitelisted[investor] = true;
    }

    function removeFromWhitelist(address investor) external onlyAssetAdmin {
        isWhitelisted[investor] = false;
    }

    function isAllowed(address investor) external view returns (bool) {
        return isWhitelisted[investor];
    }

    function _update(address from, address to, uint256 value) internal virtual override {
        require(!isClosed, "asset closed");
        require(!paused(), "asset paused");

        // mint: from == address(0) -> проверяем допуск получателя (investor)
        // burn: to == address(0)   -> проверяем допуск отправителя (investor)
        // transfer: проверяем обе стороны
        if (from == address(0)) {
            require(_isAllowed(to), "recipient not whitelisted");
        } else if (to == address(0)) {
            require(_isAllowed(from), "sender not whitelisted");
        } else {
            require(_isAllowed(from), "sender not whitelisted");
            require(_isAllowed(to), "recipient not whitelisted");
        }

        super._update(from, to, value);
    }

    function _isAllowed(address investor) internal view returns (bool) {
        return isWhitelisted[investor];
    }

    // Внутренний путь, обращающийся к базовой реализации ERC-20 напрямую,
    // минуя переопределённый _update() этого контракта (а вместе с ним — whitelist-проверку,
    // а также isClosed/paused). Доступен только из forceBurn (проверка msg.sender == assetAdmin).
    //
    // РЕШЕНИЕ ПОДТВЕРЖДЕНО: forceBurn обходит и whitelist, и isClosed/paused — админ должен
    // мочь изъять токены даже когда актив на паузе или закрыт (экстренная ситуация,
    // регуляторное изъятие, восстановление при утере ключа).
    function _rawBurn(address from, uint256 amount) internal {
        super._update(from, address(0), amount);
    }
}