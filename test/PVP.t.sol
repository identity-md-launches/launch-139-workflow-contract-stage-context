// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PVP} from "../src/PVP.sol";
import {Opcodes} from "./utils/Opcodes.sol";

contract PVPTest is Test {
    address factory = makeAddr("factory");
    address alice = makeAddr("alice");
    PVP token;

    function setUp() public {
        vm.prank(factory);
        token = new PVP();
    }

    function test_metadata() public view {
        assertEq(token.name(), "Pepe Values Pepe");
        assertEq(token.symbol(), "PVP");
        assertEq(token.decimals(), 18);
    }

    function test_mintsExactlyTenToTheTwentySevenToTheDeployer() public view {
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.totalSupply(), 1_000_000_000 * 1e18);
        assertEq(token.INITIAL_SUPPLY(), 1e27);
        assertEq(token.balanceOf(factory), 1e27);
        assertEq(token.balanceOf(address(this)), 0);
    }

    function test_noMintPath() public {
        string[6] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "transferOwnership(address)",
            "setMinter(address)"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            bytes memory data = abi.encodeWithSignature(signatures[i], alice, uint256(1));
            vm.prank(factory);
            (bool ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
            assertEq(token.totalSupply(), 1e27);
        }
    }

    function test_transferMovesExactlyWhatItWasAsked() public {
        vm.prank(factory);
        assertTrue(token.transfer(alice, 5e18));
        assertEq(token.balanceOf(alice), 5e18);
        assertEq(token.balanceOf(factory), 1e27 - 5e18);
        assertEq(token.totalSupply(), 1e27);
    }

    function test_transferRevertsOnInsufficientBalanceAndZeroReceiver() public {
        vm.expectRevert(abi.encodeWithSelector(PVP.InsufficientBalance.selector, alice, 0, 1));
        vm.prank(alice);
        token.transfer(factory, 1);

        vm.expectRevert(PVP.InvalidReceiver.selector);
        vm.prank(factory);
        token.transfer(address(0), 1);
    }

    function test_approveAndTransferFrom() public {
        vm.prank(factory);
        token.approve(alice, 10);
        vm.prank(alice);
        assertTrue(token.transferFrom(factory, alice, 4));
        assertEq(token.allowance(factory, alice), 6);
        vm.expectRevert(abi.encodeWithSelector(PVP.InsufficientAllowance.selector, alice, 6, 7));
        vm.prank(alice);
        token.transferFrom(factory, alice, 7);
    }

    function test_infiniteAllowanceIsNotSpent() public {
        vm.prank(factory);
        token.approve(alice, type(uint256).max);
        vm.prank(alice);
        token.transferFrom(factory, alice, 4);
        assertEq(token.allowance(factory, alice), type(uint256).max);
    }

    function test_burnOnlyLowersSupply() public {
        vm.prank(factory);
        token.burn(1e18);
        assertEq(token.totalSupply(), 1e27 - 1e18);
        assertEq(token.balanceOf(factory), 1e27 - 1e18);

        vm.prank(factory);
        token.approve(alice, 2e18);
        vm.prank(alice);
        token.burnFrom(factory, 2e18);
        assertEq(token.totalSupply(), 1e27 - 3e18);

        vm.expectRevert(abi.encodeWithSelector(PVP.InsufficientBalance.selector, alice, 0, 1));
        vm.prank(alice);
        token.burn(1);
    }

    function test_runtimeCodeHasNoDelegatecallOrSelfdestruct() public view {
        bytes memory code = address(token).code;
        assertGt(code.length, 0);
        assertFalse(Opcodes.hasEscapeHatch(code));
    }

    function testFuzz_transferConservesSupply(address to, uint256 amount) public {
        vm.assume(to != address(0));
        amount = bound(amount, 0, 1e27);
        vm.prank(factory);
        token.transfer(to, amount);
        assertEq(token.balanceOf(to) + token.balanceOf(factory), to == factory ? 2e27 : 1e27);
        assertEq(token.totalSupply(), 1e27);
    }
}
