// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./utils/Fixture.sol";
import {PvPadHook} from "../src/PvPadHook.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";

/// @dev The launch as the IMD factory performs it: token minted to the factory, hook CREATE2'd with
/// the PoolManager only, `PoolManager.initialize` called by the factory (not a pad), then 80% of
/// the supply seeded as a one-sided PVP position. This is the shape that broke launch 138, and the
/// first buys into a pool holding no ETH are where the deferred-fee path is exercised.
contract FactoryLaunchTest is Fixture {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// @dev 1,000,000 PVP per ETH: sqrt(1e6) * 2^96, the price used in the earlier manifests.
    uint160 constant LAUNCH_SQRT_PRICE = 79228162514264337593543950336000;
    int24 constant POSITION_UPPER = 138_120;
    int24 constant POSITION_LOWER = 132_120;

    function initialSqrtPrice() internal pure override returns (uint160) {
        return LAUNCH_SQRT_PRICE;
    }

    /// @dev PVP only, entirely below the opening price: the pool holds no ETH until someone buys.
    function seed() internal override {
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtPriceAtTick(POSITION_LOWER), TickMath.getSqrtPriceAtTick(POSITION_UPPER), 8e26
        );
        lpRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams(POSITION_LOWER, POSITION_UPPER, int256(uint256(liquidity)), bytes32(0)),
            ""
        );
        assertEq(address(manager).balance, 0, "no ETH in the pool at launch");
        assertGt(pvp.balanceOf(address(manager)), 7.9e26);
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

    function test_factoryOpenedThePoolWithoutTheHookBeingConsulted() public view {
        (uint160 price, int24 tick,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        assertEq(price, LAUNCH_SQRT_PRICE);
        assertEq(tick, 138_162);
        assertEq(HookFlags.flagsOf(address(hook)) & HookFlags.BEFORE_INITIALIZE, 0);
        assertEq(HookFlags.flagsOf(address(hook)) & HookFlags.AFTER_INITIALIZE, 0);
        assertEq(pvp.balanceOf(factory), 2e26 - 3_000 ether, "factory keeps what it did not hand out");
    }

    function test_anySenderCanInitializeAnotherPoolWithThisHook() public {
        // Nothing in the hook cares who opens a pool or what its parameters are.
        PoolKey memory other = PoolKey(NATIVE, PVP_CURRENCY, 500, 10, IHooks(address(hook)));
        vm.prank(makeAddr("random-sender"));
        int24 tick = manager.initialize(other, SQRT_PRICE_1_1);
        assertEq(tick, 0);
    }

    function test_firstBuyDefersTheEthFeeAsAClaimAndAnyoneRedeemsIt() public {
        vm.prank(carol);
        hook.claimKing{value: 0.02 ether}(carol);
        uint256 carolEth = carol.balance;

        BalanceDelta d = buyExactIn(alice, 1 ether);
        assertEq(d.amount0(), -1 ether);
        assertGt(d.amount1(), 0);
        // The PoolManager had no ETH when afterSwap ran, so the fee is a claim, not a transfer.
        assertEq(hook.deferred(NATIVE), 0.01 ether);
        assertEq(manager.balanceOf(address(hook), 0), 0.01 ether);
        assertEq(hook.pending(carol, NATIVE), 0.01 ether);
        assertEq(carol.balance, carolEth, "nothing was pushed");
        assertEq(address(manager).balance, 1 ether, "the trader settled the whole 1 ETH");
        assertEthConserved();
        assertManagerSettled();

        // Anyone turns the claim into balance.
        vm.prank(bob);
        hook.redeem(NATIVE);
        assertEq(hook.deferred(NATIVE), 0);
        assertEq(manager.balanceOf(address(hook), 0), 0);
        assertEq(address(hook).balance, 0.02 ether + 0.01 ether);
        assertEthConserved();

        vm.prank(carol);
        hook.withdraw(NATIVE, carol);
        assertEq(carol.balance - carolEth, 0.01 ether);
        assertEthConserved();
        assertManagerSettled();
    }

    function test_withdrawRedeemsDeferredClaimsOnItsOwn() public {
        vm.prank(carol);
        hook.claimKing{value: 0.02 ether}(carol);
        buyExactIn(alice, 1 ether);
        assertEq(hook.deferred(NATIVE), 0.01 ether);
        uint256 carolEth = carol.balance;
        vm.prank(carol);
        hook.withdraw(NATIVE, carol);
        assertEq(carol.balance - carolEth, 0.01 ether);
        assertEq(hook.deferred(NATIVE), 0);
        assertEthConserved();
    }

    function test_onceThePoolHoldsEthTheFeeIsPushedDirectly() public {
        vm.prank(carol);
        hook.claimKing{value: 0.02 ether}(carol);
        buyExactIn(alice, 1 ether);
        uint256 carolEth = carol.balance;
        buyExactIn(bob, 0.5 ether);
        assertEq(carol.balance - carolEth, 0.005 ether, "pushed inside the swap this time");
        assertEq(hook.deferred(NATIVE), 0.01 ether, "the first fee is still a claim");
        assertEthConserved();
    }

    function test_feesBeforeAnyKingAreDeferredAndUnassigned() public {
        buyExactIn(alice, 1 ether);
        assertEq(hook.deferred(NATIVE), 0.01 ether);
        assertEq(hook.unassigned(NATIVE), 0.01 ether);
        hook.redeem(NATIVE);
        assertEq(address(hook).balance, 0.01 ether);
        vm.prank(carol);
        hook.claimKing{value: 0.02 ether}(carol);
        hook.assignUnassigned(NATIVE);
        assertEq(hook.pending(carol, NATIVE), 0.01 ether);
        assertEthConserved();
    }

    function test_exactOutputBuyPaysThePvpFeeImmediately() public {
        vm.prank(carol);
        hook.claimKing{value: 0.02 ether}(carol);
        uint256 carolPvp = pvp.balanceOf(carol);
        BalanceDelta d = buyExactOut(alice, 1_000 ether, 1 ether);
        assertEq(d.amount1(), 1_000 ether);
        assertEq(pvp.balanceOf(carol) - carolPvp, 10 ether, "1% of the specified PVP");
        assertEq(hook.deferred(PVP_CURRENCY), 0);
        assertManagerSettled();
    }

    function test_sellsAreImpossibleUntilSomeoneHasBought() public {
        // With only PVP in the pool there is no ETH to give: the pool fills nothing.
        vm.expectRevert(hookRevert(IHooks.afterSwap.selector, PvPadHook.PartialFill.selector));
        sellExactIn(alice, 1 ether);
    }

    function test_sellThatWouldYieldNothingReverts() public {
        buyExactIn(alice, 1 ether);
        // 100 wei of PVP at 1e6 PVP per ETH is 0 wei of ETH.
        vm.expectRevert(hookRevert(IHooks.afterSwap.selector, PvPadHook.NoSwapOutput.selector));
        sellExactIn(alice, 100);
    }

    function test_buyThenSellRoundTripPaysBothFees() public {
        vm.prank(carol);
        hook.claimKing{value: 0.02 ether}(carol);
        buyExactIn(alice, 1 ether);
        uint256 alicePvp = pvp.balanceOf(alice);
        uint256 carolPvp = pvp.balanceOf(carol);
        BalanceDelta d = sellExactIn(alice, alicePvp);
        assertEq(d.amount1(), -int256(alicePvp));
        assertGt(d.amount0(), 0);
        assertEq(pvp.balanceOf(carol) - carolPvp, alicePvp / 100);
        assertEq(pvp.balanceOf(alice), 0);
        assertEthConserved();
        assertPvpConserved();
        assertManagerSettled();
    }

    function test_lpCanExitAtAnyTime() public {
        buyExactIn(alice, 1 ether);
        (uint128 liquidity,,) = IPoolManager(address(manager))
            .getPositionInfo(key.toId(), address(lpRouter), POSITION_LOWER, POSITION_UPPER, bytes32(0));
        lpRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams(POSITION_LOWER, POSITION_UPPER, -int256(uint256(liquidity)), bytes32(0)),
            ""
        );
        assertEq(IPoolManager(address(manager)).getLiquidity(key.toId()), 0);
        assertGt(address(this).balance, 0);
        assertManagerSettled();
    }
}
