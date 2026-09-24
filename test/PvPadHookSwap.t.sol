// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./utils/Fixture.sol";
import {PvPadHook} from "../src/PvPadHook.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {
    LoggingReceiver,
    StoringReceiver,
    RevertingReceiver,
    ReentrantBeneficiary,
    GasBurner
} from "./mocks/Receivers.sol";

/// @dev The swap fee: how much, from which currency, to whom, and every delivery path.
contract PvPadHookSwapTest is Fixture {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    PoolKey plainKey;

    function setUp() public override {
        super.setUp();
        // A hookless twin with identical liquidity, the reference for "what the pool itself does".
        plainKey = PoolKey(NATIVE, PVP_CURRENCY, POOL_FEE, TICK_SPACING, IHooks(address(0)));
        manager.initialize(plainKey, SQRT_PRICE_1_1);
        lpRouter.modifyLiquidity{value: 2_000 ether}(
            plainKey, ModifyLiquidityParams(FULL_RANGE_LOWER, FULL_RANGE_UPPER, 1_000 ether, bytes32(0)), ""
        );
    }

    function hookRevert(bytes4 callback, bytes4 reason) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            callback,
            abi.encodeWithSelector(reason),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    function crown(address beneficiary_) internal {
        vm.prank(carol);
        hook.claimKing{value: 0.02 ether}(beneficiary_);
    }

    // ------------------------------------------------------------------------------------------
    // The four swap shapes: the trader always moves exactly amountSpecified; the fee is 1% of it.
    // ------------------------------------------------------------------------------------------

    function test_exactInputBuy_feeInEth() public {
        crown(alice);
        uint256 aliceBefore = alice.balance;
        uint256 bobEth = bob.balance;
        uint256 bobPvp = pvp.balanceOf(bob);

        BalanceDelta hooked = buyExactIn(bob, 1 ether);
        assertEq(hooked.amount0(), -1 ether, "trader pays exactly what was specified");
        assertEq(bobEth - bob.balance, 1 ether);
        assertEq(pvp.balanceOf(bob) - bobPvp, uint256(int256(hooked.amount1())));
        assertEq(alice.balance - aliceBefore, 0.01 ether, "beneficiary was pushed the ETH fee");
        assertEq(hook.totalSkimmed(NATIVE), 0.01 ether);
        assertEq(address(hook).balance, 0.02 ether, "only the king claim remains in the hook");

        // The pool itself saw a 0.99 ETH swap: same output as the twin pool for 0.99 ETH.
        vm.prank(bob);
        BalanceDelta plain =
            swapRouter.swap{value: 0.99 ether}(plainKey, params(true, -0.99 ether), settings(), "");
        assertEq(plain.amount1(), hooked.amount1());
        assertEq(sqrtPriceOf(plainKey), sqrtPrice());
        assertEthConserved();
        assertManagerSettled();
    }

    function test_exactOutputBuy_feeInPvp() public {
        crown(alice);
        uint256 alicePvp = pvp.balanceOf(alice);
        uint256 bobPvp = pvp.balanceOf(bob);

        BalanceDelta hooked = buyExactOut(bob, 1 ether, 5 ether);
        assertEq(hooked.amount1(), 1 ether, "trader receives exactly what was specified");
        assertEq(pvp.balanceOf(bob) - bobPvp, 1 ether);
        assertEq(pvp.balanceOf(alice) - alicePvp, 0.01 ether, "beneficiary received the PVP fee");
        assertEq(hook.totalSkimmed(PVP_CURRENCY), 0.01 ether);
        assertEq(pvp.balanceOf(address(hook)), 0);

        // The pool delivered 1.01 PVP: same ETH cost as the twin pool for 1.01 PVP out.
        vm.prank(bob);
        BalanceDelta plain =
            swapRouter.swap{value: 5 ether}(plainKey, params(true, 1.01 ether), settings(), "");
        assertEq(plain.amount0(), hooked.amount0());
        assertPvpConserved();
        assertManagerSettled();
    }

    function test_exactInputSell_feeInPvp() public {
        crown(alice);
        uint256 alicePvp = pvp.balanceOf(alice);
        uint256 bobPvp = pvp.balanceOf(bob);
        uint256 bobEth = bob.balance;

        BalanceDelta hooked = sellExactIn(bob, 1 ether);
        assertEq(hooked.amount1(), -1 ether);
        assertEq(bobPvp - pvp.balanceOf(bob), 1 ether);
        assertEq(bob.balance - bobEth, uint256(int256(hooked.amount0())));
        assertEq(pvp.balanceOf(alice) - alicePvp, 0.01 ether);

        vm.prank(bob);
        BalanceDelta plain = swapRouter.swap(plainKey, params(false, -0.99 ether), settings(), "");
        assertEq(plain.amount0(), hooked.amount0());
        assertPvpConserved();
        assertManagerSettled();
    }

    function test_exactOutputSell_feeInEth() public {
        crown(alice);
        uint256 aliceEth = alice.balance;
        uint256 bobEth = bob.balance;

        BalanceDelta hooked = sellExactOut(bob, 1 ether);
        assertEq(hooked.amount0(), 1 ether);
        assertEq(bob.balance - bobEth, 1 ether);
        assertEq(alice.balance - aliceEth, 0.01 ether);

        vm.prank(bob);
        BalanceDelta plain = swapRouter.swap(plainKey, params(false, 1.01 ether), settings(), "");
        assertEq(plain.amount1(), hooked.amount1());
        assertEthConserved();
        assertManagerSettled();
    }

    function testFuzz_exactInputBuyChargesOnePercent(uint256 amount) public {
        amount = bound(amount, 100, 50 ether);
        crown(alice);
        vm.deal(bob, amount);
        uint256 aliceBefore = alice.balance;
        BalanceDelta d = buyExactIn(bob, amount);
        assertEq(d.amount0(), -int256(amount));
        assertEq(bob.balance, 0);
        assertGt(d.amount1(), 0);
        assertEq(alice.balance - aliceBefore, amount / 100);
        assertEthConserved();
        assertManagerSettled();
    }

    function testFuzz_exactInputSellChargesOnePercent(uint256 amount) public {
        amount = bound(amount, 100, 50 ether);
        crown(alice);
        pvp.transfer(bob, amount);
        uint256 alicePvp = pvp.balanceOf(alice);
        uint256 bobPvp = pvp.balanceOf(bob);
        BalanceDelta d = sellExactIn(bob, amount);
        assertEq(d.amount1(), -int256(amount));
        assertEq(bobPvp - pvp.balanceOf(bob), amount);
        assertEq(pvp.balanceOf(alice) - alicePvp, amount / 100);
        assertPvpConserved();
        assertManagerSettled();
    }

    // ------------------------------------------------------------------------------------------
    // Edge cases of the fee itself
    // ------------------------------------------------------------------------------------------

    function test_dustSwapsPayNoFeeAndStillTrade() public {
        crown(alice);
        BalanceDelta d = buyExactIn(bob, 99);
        assertEq(d.amount0(), -99);
        assertGt(d.amount1(), 0);
        assertEq(hook.totalSkimmed(NATIVE), 0);
        assertManagerSettled();
    }

    function test_partialFillReverts() public {
        crown(alice);
        // A price limit just below the current price stops the swap early.
        SwapParams memory p = SwapParams(true, -100 ether, sqrtPrice() - sqrtPrice() / 1000);
        uint256 bobEth = bob.balance;
        vm.expectRevert(hookRevert(IHooks.afterSwap.selector, PvPadHook.PartialFill.selector));
        vm.prank(bob);
        swapRouter.swap{value: 100 ether}(key, p, settings(), "");
        assertEq(bob.balance, bobEth);
        assertEq(hook.totalSkimmed(NATIVE), 0);
        assertEq(sqrtPrice(), SQRT_PRICE_1_1);
    }

    function test_hooklessPoolPaysNothing() public {
        crown(alice);
        uint256 aliceBefore = alice.balance;
        vm.prank(bob);
        swapRouter.swap{value: 1 ether}(plainKey, params(true, -1 ether), settings(), "");
        assertEq(alice.balance, aliceBefore);
        assertEq(hook.totalSkimmed(NATIVE), 0);
    }

    function test_liquidityIsNeverIntercepted() public {
        crown(alice);
        buyExactIn(bob, 1 ether);
        sellExactIn(bob, 1 ether);
        // The LP can add and fully remove without the hook being involved.
        lpRouter.modifyLiquidity{value: 100 ether}(
            key, ModifyLiquidityParams(FULL_RANGE_LOWER, FULL_RANGE_UPPER, 10 ether, bytes32(0)), ""
        );
        lpRouter.modifyLiquidity(
            key, ModifyLiquidityParams(FULL_RANGE_LOWER, FULL_RANGE_UPPER, -1_010 ether, bytes32(0)), ""
        );
        assertEq(IPoolManager(address(manager)).getLiquidity(key.toId()), 0);
        assertManagerSettled();
    }

    // ------------------------------------------------------------------------------------------
    // Before the first King: unassigned fees belong to the first beneficiary
    // ------------------------------------------------------------------------------------------

    function test_feesBeforeAnyKingWaitForTheFirstBeneficiary() public {
        buyExactIn(bob, 1 ether);
        sellExactIn(bob, 1 ether);
        assertEq(hook.unassigned(NATIVE), 0.01 ether);
        assertEq(hook.unassigned(PVP_CURRENCY), 0.01 ether);
        assertEq(address(hook).balance, 0.01 ether);
        assertEq(pvp.balanceOf(address(hook)), 0.01 ether);

        vm.expectRevert(PvPadHook.NoBeneficiary.selector);
        hook.assignUnassigned(NATIVE);

        crown(alice);
        hook.assignUnassigned(NATIVE);
        hook.assignUnassigned(PVP_CURRENCY);
        assertEq(hook.pending(alice, NATIVE), 0.01 ether);
        assertEq(hook.pending(alice, PVP_CURRENCY), 0.01 ether);
        assertEq(hook.unassigned(NATIVE), 0);
        vm.expectRevert(PvPadHook.NothingToDo.selector);
        hook.assignUnassigned(NATIVE);

        uint256 aliceEth = alice.balance;
        uint256 bobPvp = pvp.balanceOf(bob);
        vm.prank(alice);
        hook.withdraw(NATIVE, alice);
        vm.prank(alice);
        hook.withdraw(PVP_CURRENCY, bob);
        assertEq(alice.balance - aliceEth, 0.01 ether);
        assertEq(pvp.balanceOf(bob) - bobPvp, 0.01 ether);
        assertEq(address(hook).balance, 0.02 ether);
        assertEthConserved();
        assertPvpConserved();
    }

    // ------------------------------------------------------------------------------------------
    // Delivery paths for contract beneficiaries
    // ------------------------------------------------------------------------------------------

    function test_loggingReceiverIsPaidInsideTheSwap() public {
        LoggingReceiver r = new LoggingReceiver();
        crown(address(r));
        buyExactIn(bob, 1 ether);
        assertEq(address(r).balance, 0.01 ether);
        assertEq(hook.pending(address(r), NATIVE), 0);
    }

    function test_expensiveReceiverGetsACreditAndPullsIt() public {
        StoringReceiver r = new StoringReceiver();
        crown(address(r));
        buyExactIn(bob, 1 ether);
        assertEq(address(r).balance, 0, "2300 gas is not enough for an SSTORE");
        assertEq(hook.pending(address(r), NATIVE), 0.01 ether);
        assertEq(hook.totalPending(NATIVE), 0.01 ether);
        assertEthConserved();

        r.pull(hook, NATIVE, address(r));
        assertEq(address(r).balance, 0.01 ether);
        assertEq(r.received(), 0.01 ether);
        assertEq(hook.pending(address(r), NATIVE), 0);
        assertEthConserved();
    }

    function test_refusingReceiverNeverBlocksTradingAndCanPullElsewhere() public {
        RevertingReceiver r = new RevertingReceiver();
        crown(address(r));
        buyExactIn(bob, 1 ether);
        sellExactOut(bob, 1 ether);
        assertEq(hook.pending(address(r), NATIVE), 0.02 ether);

        vm.expectRevert(PvPadHook.PaymentFailed.selector);
        r.pull(hook, NATIVE, address(r));
        assertEq(hook.pending(address(r), NATIVE), 0.02 ether, "a failed pull keeps the credit");

        r.pull(hook, NATIVE, alice);
        assertEq(alice.balance, 1_000 ether + 0.02 ether);
        assertEthConserved();
    }

    function test_gasBurnerBeneficiaryCannotStallTheSwap() public {
        GasBurner r = new GasBurner();
        crown(address(r));
        uint256 gasBefore = gasleft();
        buyExactIn(bob, 1 ether);
        assertLt(gasBefore - gasleft(), 1_000_000, "only the 2300-gas stipend was burnt");
        assertEq(hook.pending(address(r), NATIVE), 0.01 ether);
    }

    function test_reentrantBeneficiaryIsCreditedAndCannotReenterOnPull() public {
        ReentrantBeneficiary r = new ReentrantBeneficiary(hook, NATIVE);
        crown(address(r));
        buyExactIn(bob, 1 ether);
        assertEq(hook.pending(address(r), NATIVE), 0.01 ether);
        assertFalse(r.reentered());

        // Pulling to itself re-enters withdraw from receive(): the guard trips, the payment fails,
        // the whole pull reverts and the credit survives.
        vm.expectRevert(PvPadHook.PaymentFailed.selector);
        r.pull(address(r));
        assertEq(hook.pending(address(r), NATIVE), 0.01 ether);
        assertFalse(r.reentered());

        r.pull(alice);
        assertEq(alice.balance, 1_000 ether + 0.01 ether);
        assertEthConserved();
    }

    function test_withdrawRejectsZeroRecipientAndEmptyCredit() public {
        vm.expectRevert(PvPadHook.ZeroAddress.selector);
        hook.withdraw(NATIVE, address(0));
        vm.expectRevert(PvPadHook.NothingToDo.selector);
        hook.withdraw(NATIVE, alice);
        vm.expectRevert(PvPadHook.NothingToDo.selector);
        hook.redeem(NATIVE);
    }

    function test_beneficiaryChangeRedirectsOnlyFutureFees() public {
        crown(alice);
        buyExactIn(bob, 1 ether);
        vm.prank(carol);
        hook.claimKing{value: 0.1 ether}(carol);
        uint256 aliceEth = alice.balance;
        uint256 carolEth = carol.balance;
        buyExactIn(bob, 1 ether);
        assertEq(alice.balance, aliceEth);
        assertEq(carol.balance - carolEth, 0.01 ether);
    }

    // ------------------------------------------------------------------------------------------
    // Any pool may use the hook; fees in a foreign token are delivered the same way
    // ------------------------------------------------------------------------------------------

    function test_foreignTokenPoolPaysFeesInThatToken() public {
        MockERC20 foo = new MockERC20("Foo", "FOO", 1e24);
        foo.approve(address(lpRouter), type(uint256).max);
        foo.approve(address(swapRouter), type(uint256).max);
        (Currency c0, Currency c1) = address(foo) < address(pvp)
            ? (Currency.wrap(address(foo)), PVP_CURRENCY)
            : (PVP_CURRENCY, Currency.wrap(address(foo)));
        PoolKey memory fooKey = PoolKey(c0, c1, POOL_FEE, TICK_SPACING, IHooks(address(hook)));
        manager.initialize(fooKey, SQRT_PRICE_1_1);
        lpRouter.modifyLiquidity(
            fooKey, ModifyLiquidityParams(FULL_RANGE_LOWER, FULL_RANGE_UPPER, 1_000 ether, bytes32(0)), ""
        );
        crown(alice);
        bool fooIsZero = Currency.unwrap(c0) == address(foo);
        BalanceDelta d = swapRouter.swap(fooKey, params(fooIsZero, -1 ether), settings(), "");
        assertEq(fooIsZero ? d.amount0() : d.amount1(), -1 ether);
        assertEq(foo.balanceOf(alice), 0.01 ether);
        assertEq(hook.totalSkimmed(Currency.wrap(address(foo))), 0.01 ether);
        assertManagerSettled();
    }

    function sqrtPriceOf(PoolKey memory k) internal view returns (uint160 p) {
        (p,,,) = IPoolManager(address(manager)).getSlot0(k.toId());
    }
}
