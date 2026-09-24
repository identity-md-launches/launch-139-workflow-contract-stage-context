// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./utils/Fixture.sol";
import {Handler} from "./PvPadHookInvariant.t.sol";
import {PvPadHook} from "../src/PvPadHook.sol";
import {PVP} from "../src/PVP.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";

/// @dev Same handler on the launch-shaped pool (PVP only, 1e6 PVP per ETH): sells are sized to the
/// ETH that buyers have brought in so far, so every call still succeeds, and the first buys go
/// through the deferred-claim path.
contract LaunchHandler is Handler {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager immutable manager;

    constructor(PvPadHook hook_, PVP pvp_, PoolSwapTest router_, PoolKey memory key_, address updater_)
        Handler(hook_, pvp_, router_, key_, updater_)
    {
        manager = hook_.poolManager();
    }

    /// @dev PVP per ETH, rounded down; zero below parity.
    function pvpPerEth() internal view returns (uint256) {
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(key.toId());
        uint256 s = uint256(sqrtPriceX96) >> 96;
        return s * s;
    }

    function sellExactIn(uint256 amount) external override {
        uint256 price = pvpPerEth();
        uint256 ethInPool = address(manager).balance;
        uint256 maxPvp = ethInPool / 4 * price;
        if (price == 0 || maxPvp < 1e12) return;
        amount = bound(amount, 1e12, maxPvp);
        swapRouter.swap(key, _params(false, -int256(amount)), _settings(), "");
        swaps++;
    }

    function sellExactOut(uint256 amount) external override {
        uint256 ethInPool = address(manager).balance;
        if (ethInPool / 4 < 1e9) return;
        amount = bound(amount, 1e9, ethInPool / 4);
        swapRouter.swap(key, _params(false, int256(amount)), _settings(), "");
        swaps++;
    }
}

contract FactoryLaunchInvariantTest is Fixture {
    uint160 constant LAUNCH_SQRT_PRICE = 79228162514264337593543950336000;
    int24 constant POSITION_UPPER = 138_120;
    int24 constant POSITION_LOWER = 132_120;

    LaunchHandler handler;

    function initialSqrtPrice() internal pure override returns (uint160) {
        return LAUNCH_SQRT_PRICE;
    }

    function seed() internal override {
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtPriceAtTick(POSITION_LOWER), TickMath.getSqrtPriceAtTick(POSITION_UPPER), 8e26
        );
        lpRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams(POSITION_LOWER, POSITION_UPPER, int256(uint256(liquidity)), bytes32(0)),
            ""
        );
    }

    function setUp() public override {
        super.setUp();
        handler = new LaunchHandler(hook, pvp, swapRouter, key, updater);
        vm.prank(factory);
        pvp.transfer(address(handler), 1e26);
        targetContract(address(handler));
    }

    function invariant_ethIsConserved() public view {
        assertEthConserved();
    }

    function invariant_pvpIsConserved() public view {
        assertPvpConserved();
    }

    function invariant_managerIsSettledAndBacksTheClaims() public view {
        assertManagerSettled();
        assertGe(address(manager).balance, hook.deferred(NATIVE));
        assertEq(manager.balanceOf(address(hook), 0), hook.deferred(NATIVE));
    }

    function invariant_supplyNeverGrows() public view {
        assertEq(pvp.totalSupply(), 1e27);
    }
}
