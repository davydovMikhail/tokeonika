// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {TokenBase} from "./TokenBase.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";

// токен со встроенным blacklist
contract AssetV2 is TokenBase, Pausable {

    mapping(address => bool) internal isBlacklisted;

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
        // Снимает требование подписи `from`, но НЕ снимает blacklist-проверку —
        // обычный _transfer идёт через _update(), где blacklist всё равно сработает на обе стороны.
        _transfer(from, to, amount);
    }

    function forceBurn(address from, uint256 amount) external onlyAssetAdmin {
        // Минует blacklist-проверку в _update() — работает даже если `from` уже не в blacklist.
        _rawBurn(from, amount);
    }

    function addToBlacklist(address investor) external onlyAssetAdmin {
        isBlacklisted[investor] = true;
    }

    function removeFromBlacklist(address investor) external onlyAssetAdmin {
        isBlacklisted[investor] = false;
    }

    function isAllowed(address investor) external view returns (bool) {
        return !isBlacklisted[investor];
    }

    function _update(address from, address to, uint256 value) internal virtual override {
        require(!isClosed, "asset closed");
        require(!paused(), "asset paused");

        // mint: from == address(0) -> проверяем допуск получателя (investor)
        // burn: to == address(0)   -> проверяем допуск отправителя (investor)
        // transfer: проверяем обе стороны
        if (from == address(0)) {
            require(_isAllowed(to), "recipient blacklisted");
        } else if (to == address(0)) {
            require(_isAllowed(from), "sender blacklisted");
        } else {
            require(_isAllowed(from), "sender blacklisted");
            require(_isAllowed(to), "recipient blacklisted");
        }

        super._update(from, to, value);
    }

    function _isAllowed(address investor) internal view returns (bool) {
        return !isBlacklisted[investor];
    }

    // Внутренний путь, обращающийся к базовой реализации ERC-20 напрямую,
    // минуя переопределённый _update() этого контракта (а вместе с ним — blacklist-проверку,
    // а также isClosed/paused). Доступен только из forceBurn (проверка msg.sender == assetAdmin).
    //
    // РЕШЕНИЕ ПОДТВЕРЖДЕНО: forceBurn обходит и blacklist, и isClosed/paused — админ должен
    // мочь изъять токены даже когда актив на паузе или закрыт (экстренная ситуация,
    // регуляторное изъятие, восстановление при утере ключа).
    function _rawBurn(address from, uint256 amount) internal {
        super._update(from, address(0), amount);
    }
}