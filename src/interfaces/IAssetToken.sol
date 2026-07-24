// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

interface IAssetToken {
    function assetAdmin() external view returns (address);
    function stablecoinToken() external view returns (address);
}
    
