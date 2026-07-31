// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {PlatformConfig} from "../src/PlatformConfig.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";

contract PlatformConfigTest is Test {
    PlatformConfig internal config;
    address internal initialAdmin = makeAddr("initialAdmin");
    address internal newAdmin = makeAddr("newAdmin");
    address internal anotherAdmin = makeAddr("anotherAdmin");

    function setUp() public {
        config = new PlatformConfig(initialAdmin);
    }

    function test_constructorSetsInitialOwner() public {
        assertEq(config.owner(), initialAdmin);
    }

    function test_constructorRejectsZeroAddress() public {
        // OZ Ownable reverts with OwnableInvalidOwner(address(0))
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new PlatformConfig(address(0));
    }

    function test_transferOwnershipDoesNotTransferImmediately() public {
        vm.prank(initialAdmin);
        config.transferOwnership(newAdmin);

        // owner unchanged until acceptOwnership is called
        assertEq(config.owner(), initialAdmin);
        assertEq(config.pendingOwner(), newAdmin);
    }

    function test_acceptOwnershipCompletesTransfer() public {
        vm.prank(initialAdmin);
        config.transferOwnership(newAdmin);

        vm.prank(newAdmin);
        config.acceptOwnership();

        assertEq(config.owner(), newAdmin);
        assertEq(config.pendingOwner(), address(0));
    }

    function test_onlyPendingOwnerCanAccept() public {
        vm.prank(initialAdmin);
        config.transferOwnership(newAdmin);

        vm.prank(stranger());
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger()));
        config.acceptOwnership();
    }

    function test_reproposingOverwritesPendingOwner() public {
        vm.startPrank(initialAdmin);
        config.transferOwnership(newAdmin);
        assertEq(config.pendingOwner(), newAdmin);

        config.transferOwnership(anotherAdmin);
        assertEq(config.pendingOwner(), anotherAdmin);
        vm.stopPrank();

        // the previously-proposed address can no longer accept
        vm.prank(newAdmin);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, newAdmin));
        config.acceptOwnership();
    }

    function test_onlyOwnerCanProposeTransfer() public {
        vm.prank(stranger());
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger()));
        config.transferOwnership(newAdmin);
    }

    function stranger() internal pure returns (address) {
        return address(0xBEEF);
    }
}
