// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PVP} from "../../src/PVP.sol";
import {PvPadHook} from "../../src/PvPadHook.sol";
import {HookFlags} from "../../src/HookFlags.sol";
import {HookMiner} from "./HookMiner.sol";

/// @dev Deploys PVP and PvPadHook against a local PoolManager the way the launch factory does: the
/// factory deploys the token and receives 10^27, the hook is CREATE2-mined for flags 0xC8 with the
/// PoolManager as its only constructor argument, and `PoolManager.initialize` is called by the
/// factory itself (a sender that is not a pad). Liquidity is ordinary v4 liquidity through the
/// stock v4 test router. Suites override `seed()` to change the shape of the initial liquidity.
abstract contract Fixture is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint24 internal constant POOL_FEE = 3000;
    int24 internal constant TICK_SPACING = 60;
    int24 internal constant FULL_RANGE_LOWER = -887_220;
    int24 internal constant FULL_RANGE_UPPER = 887_220;
    Currency internal constant NATIVE = Currency.wrap(address(0));

    address internal factory = makeAddr("factory");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal updater = 0x5b95A971B4583A5f011E9DA082acdD679b870D06;

    PoolManager internal manager;
    PoolSwapTest internal swapRouter;
    PoolModifyLiquidityTest internal lpRouter;
    PVP internal pvp;
    PvPadHook internal hook;
    PoolKey internal key;
    Currency internal PVP_CURRENCY;

    uint256 private nextSalt;

    receive() external payable {}

    function setUp() public virtual {
        // A realistic clock: forge starts at timestamp 1, which makes window arithmetic meaningless.
        vm.warp(1_760_000_000);
        manager = new PoolManager(address(this));
        swapRouter = new PoolSwapTest(manager);
        lpRouter = new PoolModifyLiquidityTest(manager);

        vm.prank(factory);
        pvp = new PVP();
        assertEq(pvp.balanceOf(factory), 1e27, "factory holds the whole supply");

        hook = deployHook(manager);
        PVP_CURRENCY = Currency.wrap(address(pvp));
        key = PoolKey(NATIVE, PVP_CURRENCY, POOL_FEE, TICK_SPACING, IHooks(address(hook)));

        // The factory opens the pool itself. No pad, no bind, no beforeInitialize.
        vm.prank(factory);
        manager.initialize(key, initialSqrtPrice());

        // This contract stands in for the LP the factory seeds with: it gets tokens and ETH.
        vm.prank(factory);
        pvp.transfer(address(this), 8e26);
        vm.deal(address(this), 100_000 ether);
        pvp.approve(address(lpRouter), type(uint256).max);
        pvp.approve(address(swapRouter), type(uint256).max);
        seed();

        address[3] memory users = [alice, bob, carol];
        for (uint256 i = 0; i < users.length; i++) {
            vm.deal(users[i], 1_000 ether);
            vm.prank(factory);
            pvp.transfer(users[i], 1_000 ether);
            vm.prank(users[i]);
            pvp.approve(address(swapRouter), type(uint256).max);
        }
    }

    /// @dev The price the pool opens at. 1 PVP per ETH keeps the numbers readable.
    function initialSqrtPrice() internal pure virtual returns (uint160) {
        return SQRT_PRICE_1_1;
    }

    /// @dev Full-range, two-sided liquidity by default.
    function seed() internal virtual {
        lpRouter.modifyLiquidity{value: 2_000 ether}(
            key, ModifyLiquidityParams(FULL_RANGE_LOWER, FULL_RANGE_UPPER, 1_000 ether, bytes32(0)), ""
        );
    }

    /// @dev Mines a CREATE2 salt from this contract so the hook lands on an address carrying exactly
    /// the three declared bits. Salts are never reused within a test.
    function deployHook(IPoolManager m) internal returns (PvPadHook deployed) {
        bytes memory creationCode = abi.encodePacked(type(PvPadHook).creationCode, abi.encode(address(m)));
        (address predicted, bytes32 salt) =
            HookMiner.find(address(this), HookFlags.PVPAD_HOOK, creationCode, nextSalt);
        nextSalt = uint256(salt) + 1;
        deployed = new PvPadHook{salt: salt}(m);
        assertEq(address(deployed), predicted, "create2 prediction");
    }

    // ------------------------------------------------------------------------------------------
    // Swap helpers. Limits are the extremes so nothing is a partial fill unless a test wants one.
    // ------------------------------------------------------------------------------------------

    function params(bool zeroForOne, int256 amount) internal pure returns (SwapParams memory) {
        return SwapParams(
            zeroForOne, amount, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
    }

    function settings() internal pure returns (PoolSwapTest.TestSettings memory) {
        return PoolSwapTest.TestSettings(false, false);
    }

    /// @dev ETH in, PVP out, exact input. `who` pays `amount` ETH.
    function buyExactIn(address who, uint256 amount) internal returns (BalanceDelta) {
        vm.prank(who);
        return swapRouter.swap{value: amount}(key, params(true, -int256(amount)), settings(), "");
    }

    /// @dev ETH in, PVP out, exact output of `amount` PVP; `maxEth` is sent and the rest refunded.
    function buyExactOut(address who, uint256 amount, uint256 maxEth) internal returns (BalanceDelta) {
        vm.prank(who);
        return swapRouter.swap{value: maxEth}(key, params(true, int256(amount)), settings(), "");
    }

    /// @dev PVP in, ETH out, exact input of `amount` PVP.
    function sellExactIn(address who, uint256 amount) internal returns (BalanceDelta) {
        vm.prank(who);
        return swapRouter.swap(key, params(false, -int256(amount)), settings(), "");
    }

    /// @dev PVP in, ETH out, exact output of `amount` ETH.
    function sellExactOut(address who, uint256 amount) internal returns (BalanceDelta) {
        vm.prank(who);
        return swapRouter.swap(key, params(false, int256(amount)), settings(), "");
    }

    function poolId() internal view returns (PoolId) {
        return key.toId();
    }

    function sqrtPrice() internal view returns (uint160 p) {
        (p,,,) = IPoolManager(address(manager)).getSlot0(key.toId());
    }

    /// @dev Every ETH the hook owns (plus claims it can still redeem) is spoken for by exactly one
    /// ledger: the worker pot, the live epoch's remainder, beneficiary credits, or unassigned fees.
    function assertEthConserved() internal view {
        uint256 epochRemaining;
        uint256 id = hook.currentEpoch();
        if (id != 0) {
            (,,, uint256 budget, uint256 paid) = hook.epochs(id);
            epochRemaining = budget - paid;
        }
        assertEq(
            address(hook).balance + hook.deferred(NATIVE),
            hook.workerPot() + epochRemaining + hook.totalPending(NATIVE) + hook.unassigned(NATIVE),
            "ETH conservation"
        );
    }

    function assertPvpConserved() internal view {
        assertEq(
            pvp.balanceOf(address(hook)) + hook.deferred(PVP_CURRENCY),
            hook.totalPending(PVP_CURRENCY) + hook.unassigned(PVP_CURRENCY),
            "PVP conservation"
        );
    }

    function assertManagerSettled() internal view {
        assertEq(IPoolManager(address(manager)).getNonzeroDeltaCount(), 0, "nonzero deltas");
        assertFalse(IPoolManager(address(manager)).isUnlocked(), "manager still unlocked");
    }
}
