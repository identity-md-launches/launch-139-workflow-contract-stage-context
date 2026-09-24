// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./utils/Fixture.sol";
import {Opcodes} from "./utils/Opcodes.sol";
import {PvPadHook} from "../src/PvPadHook.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";

/// @dev Deployment, permissions, constants and access control of the hook.
contract PvPadHookTest is Fixture {
    using BeforeSwapDeltaLibrary for BeforeSwapDelta;

    function test_permissionsAreSwapPathOnly() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeSwap);
        assertTrue(p.afterSwap);
        assertTrue(p.beforeSwapReturnDelta);
        assertFalse(p.beforeInitialize, "beforeInitialize must be off: the factory opens the pool");
        assertFalse(
            p.afterInitialize || p.beforeAddLiquidity || p.afterAddLiquidity || p.beforeRemoveLiquidity
                || p.afterRemoveLiquidity || p.beforeDonate || p.afterDonate || p.afterSwapReturnDelta
                || p.afterAddLiquidityReturnDelta || p.afterRemoveLiquidityReturnDelta
        );
    }

    function test_addressCarriesExactlyTheDeclaredFlags() public view {
        assertEq(HookFlags.PVPAD_HOOK, 0xC8);
        assertEq(HookFlags.PVPAD_HOOK, 200);
        assertEq(HookFlags.flagsOf(address(hook)), HookFlags.PVPAD_HOOK);
        assertTrue(HookFlags.matches(address(hook), HookFlags.PVPAD_HOOK));
        assertEq(uint160(address(hook)) & HookFlags.BEFORE_INITIALIZE, 0);
    }

    function test_constants() public view {
        assertEq(address(hook.poolManager()), address(manager));
        assertEq(hook.INITIAL_UPDATER(), 0x5b95A971B4583A5f011E9DA082acdD679b870D06);
        assertEq(hook.updater(), 0x5b95A971B4583A5f011E9DA082acdD679b870D06);
        assertEq(hook.pendingUpdater(), address(0));
        assertEq(hook.FEE_BPS(), 100);
        assertEq(hook.BUMP_BPS(), 1000);
        assertEq(hook.INITIAL_CLAIM_PRICE(), 0.01 ether);
        assertEq(hook.claimPrice(), 0.01 ether);
        assertEq(hook.king(), address(0));
        assertEq(hook.beneficiary(), address(0));
        assertEq(hook.PUSH_GAS(), 2300);
    }

    function test_constructorRejectsZeroManager() public {
        vm.expectRevert(PvPadHook.ZeroAddress.selector);
        new PvPadHook(IPoolManager(address(0)));
    }

    function test_constructorRejectsAddressWithoutTheFlags() public {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        assertFalse(HookFlags.matches(predicted, HookFlags.PVPAD_HOOK), "precondition");
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, predicted));
        new PvPadHook(manager);
    }

    function test_constructorDoesNotCallTheManager() public {
        // A manager address without code is accepted: the admission floor deploys the attested
        // creation code with the Sepolia manager baked in, and no manager may exist there.
        IPoolManager ghost = IPoolManager(makeAddr("ghost-manager"));
        bytes memory creationCode = abi.encodePacked(type(PvPadHook).creationCode, abi.encode(address(ghost)));
        bytes32 salt;
        address predicted;
        bytes32 initCodeHash = keccak256(creationCode);
        for (uint256 i = 0; i < 300_000; i++) {
            predicted = address(
                uint160(
                    uint256(
                        keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(i), initCodeHash))
                    )
                )
            );
            if (HookFlags.matches(predicted, HookFlags.PVPAD_HOOK)) {
                salt = bytes32(i);
                break;
            }
        }
        PvPadHook ghostHook = new PvPadHook{salt: salt}(ghost);
        assertEq(address(ghostHook), predicted);
        assertEq(address(ghostHook.poolManager()), address(ghost));
    }

    function test_runtimeCodeHasNoEscapeHatch() public view {
        bytes memory code = address(hook).code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        assertFalse(Opcodes.hasEscapeHatch(code));
    }

    function test_callbacksRefuseCallersOtherThanThePoolManager() public {
        vm.expectRevert(PvPadHook.NotPoolManager.selector);
        hook.beforeSwap(address(this), key, params(true, -1 ether), "");
        vm.expectRevert(PvPadHook.NotPoolManager.selector);
        hook.afterSwap(address(this), key, params(true, -1 ether), BalanceDelta.wrap(0), "");
        vm.expectRevert(PvPadHook.NotPoolManager.selector);
        hook.unlockCallback(abi.encode(NATIVE));

        vm.prank(address(0xBAD));
        vm.expectRevert(PvPadHook.NotPoolManager.selector);
        hook.beforeSwap(address(0xBAD), key, params(true, -1 ether), "");
    }

    function test_disabledCallbacksRevertEvenForTheManager() public {
        ModifyLiquidityParams memory lp = ModifyLiquidityParams(-60, 60, 1, bytes32(0));
        BalanceDelta zero = BalanceDelta.wrap(0);
        vm.startPrank(address(manager));
        vm.expectRevert(PvPadHook.HookNotImplemented.selector);
        hook.beforeInitialize(address(this), key, SQRT_PRICE_1_1);
        vm.expectRevert(PvPadHook.HookNotImplemented.selector);
        hook.afterInitialize(address(this), key, SQRT_PRICE_1_1, 0);
        vm.expectRevert(PvPadHook.HookNotImplemented.selector);
        hook.beforeAddLiquidity(address(this), key, lp, "");
        vm.expectRevert(PvPadHook.HookNotImplemented.selector);
        hook.afterAddLiquidity(address(this), key, lp, zero, zero, "");
        vm.expectRevert(PvPadHook.HookNotImplemented.selector);
        hook.beforeRemoveLiquidity(address(this), key, lp, "");
        vm.expectRevert(PvPadHook.HookNotImplemented.selector);
        hook.afterRemoveLiquidity(address(this), key, lp, zero, zero, "");
        vm.expectRevert(PvPadHook.HookNotImplemented.selector);
        hook.beforeDonate(address(this), key, 1, 1, "");
        vm.expectRevert(PvPadHook.HookNotImplemented.selector);
        hook.afterDonate(address(this), key, 1, 1, "");
        vm.stopPrank();
    }

    function test_callbacksRefuseAForeignKey() public {
        PoolKey memory foreign =
            PoolKey(key.currency0, key.currency1, key.fee, key.tickSpacing, IHooks(address(1)));
        vm.startPrank(address(manager));
        vm.expectRevert(PvPadHook.WrongHook.selector);
        hook.beforeSwap(address(this), foreign, params(true, -1 ether), "");
        vm.expectRevert(PvPadHook.WrongHook.selector);
        hook.afterSwap(address(this), foreign, params(true, -1 ether), BalanceDelta.wrap(0), "");
        vm.stopPrank();
    }

    function test_directEthIsRejected() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(hook).call{value: 1 ether}("");
        assertFalse(ok);
        assertEq(address(hook).balance, 0);
    }

    function test_feeForIsOnePercentRoundedDown() public view {
        assertEq(hook.feeFor(-1 ether), 0.01 ether);
        assertEq(hook.feeFor(1 ether), 0.01 ether);
        assertEq(hook.feeFor(-99), 0);
        assertEq(hook.feeFor(-100), 1);
        assertEq(hook.feeFor(-199), 1);
        assertEq(hook.feeFor(0), 0);
    }

    function testFuzz_feeFor(int256 amount) public view {
        amount = bound(amount, -int256(type(int128).max), int256(type(int128).max) / 2);
        uint256 magnitude = uint256(amount < 0 ? -amount : amount);
        assertEq(hook.feeFor(amount), magnitude / 100);
    }

    function test_feeForRejectsAmountsThePoolManagerCannotAccount() public {
        vm.expectRevert(PvPadHook.InvalidSwapAmount.selector);
        hook.feeFor(int256(type(int128).max) + 1);
        vm.expectRevert(PvPadHook.InvalidSwapAmount.selector);
        hook.feeFor(-int256(type(int128).max) - 1);
        vm.expectRevert(PvPadHook.InvalidSwapAmount.selector);
        hook.feeFor(type(int256).min);
        // exact output whose enlarged swap would not fit int128
        vm.expectRevert(PvPadHook.InvalidSwapAmount.selector);
        hook.feeFor(int256(type(int128).max));
    }

    function test_specifiedCurrency() public view {
        assertEq(Currency.unwrap(hook.specifiedCurrency(key, params(true, -1))), address(0));
        assertEq(Currency.unwrap(hook.specifiedCurrency(key, params(true, 1))), address(pvp));
        assertEq(Currency.unwrap(hook.specifiedCurrency(key, params(false, -1))), address(pvp));
        assertEq(Currency.unwrap(hook.specifiedCurrency(key, params(false, 1))), address(0));
    }

    function test_beforeSwapReservesTheFeeAndNothingElse() public {
        vm.prank(address(manager));
        (bytes4 selector, BeforeSwapDelta delta, uint24 lpFee) =
            hook.beforeSwap(address(this), key, params(true, -1 ether), "");
        assertEq(selector, IHooks.beforeSwap.selector);
        assertEq(delta.getSpecifiedDelta(), 0.01 ether);
        assertEq(delta.getUnspecifiedDelta(), 0);
        assertEq(lpFee, 0);

        vm.prank(address(manager));
        (, delta,) = hook.beforeSwap(address(this), key, params(false, 50), "");
        assertEq(BeforeSwapDelta.unwrap(delta), 0, "dust reserves nothing");
    }
}
