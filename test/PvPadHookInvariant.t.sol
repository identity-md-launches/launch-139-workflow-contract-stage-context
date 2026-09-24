// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Fixture} from "./utils/Fixture.sol";
import {PvPadHook} from "../src/PvPadHook.sol";
import {PVP} from "../src/PVP.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {LoggingReceiver, StoringReceiver, RevertingReceiver} from "./mocks/Receivers.sol";

/// @dev Drives the hook through random sequences of swaps in all four shapes, King claims to EOAs
/// and to contracts that accept, delay or refuse payment, pulls, redemptions, epochs and worker
/// claims. Every call must succeed (fail_on_revert), so inputs are bounded to legal ones.
contract Handler is Test {
    PvPadHook public hook;
    PVP public pvp;
    PoolSwapTest public swapRouter;
    PoolKey public key;
    Currency constant NATIVE = Currency.wrap(address(0));
    Currency public PVP_CURRENCY;
    address public updater;

    address[] public beneficiaries;
    address public worker = makeAddr("worker");
    uint256 public epochLeafAmount;
    uint256 public epochLeafId;

    uint256 public swaps;
    uint256 public deferrals;
    uint256 public claims;
    uint256 public workerPayouts;

    receive() external payable {}

    constructor(PvPadHook hook_, PVP pvp_, PoolSwapTest router_, PoolKey memory key_, address updater_) {
        hook = hook_;
        pvp = pvp_;
        swapRouter = router_;
        key = key_;
        updater = updater_;
        PVP_CURRENCY = Currency.wrap(address(pvp_));
        pvp.approve(address(swapRouter), type(uint256).max);
        beneficiaries.push(makeAddr("eoa-beneficiary"));
        beneficiaries.push(address(new LoggingReceiver()));
        beneficiaries.push(address(new StoringReceiver()));
        beneficiaries.push(address(new RevertingReceiver()));
    }

    function _params(bool zeroForOne, int256 amount) internal pure returns (SwapParams memory) {
        return SwapParams(
            zeroForOne, amount, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
    }

    function _settings() internal pure returns (PoolSwapTest.TestSettings memory) {
        return PoolSwapTest.TestSettings(false, false);
    }

    function buyExactIn(uint256 amount) external {
        amount = bound(amount, 1e12, 5 ether);
        vm.deal(address(this), amount);
        uint256 before = hook.deferred(NATIVE);
        swapRouter.swap{value: amount}(key, _params(true, -int256(amount)), _settings(), "");
        if (hook.deferred(NATIVE) > before) deferrals++;
        swaps++;
    }

    function sellExactIn(uint256 amount) external virtual {
        amount = bound(amount, 1e12, 5 ether);
        swapRouter.swap(key, _params(false, -int256(amount)), _settings(), "");
        swaps++;
    }

    function buyExactOut(uint256 amount) external {
        amount = bound(amount, 1e12, 1 ether);
        vm.deal(address(this), 20 ether);
        swapRouter.swap{value: 20 ether}(key, _params(true, int256(amount)), _settings(), "");
        swaps++;
    }

    function sellExactOut(uint256 amount) external virtual {
        amount = bound(amount, 1e12, 1 ether);
        swapRouter.swap(key, _params(false, int256(amount)), _settings(), "");
        swaps++;
    }

    function claimKing(uint256 who, uint256 extra) external {
        address b = beneficiaries[who % beneficiaries.length];
        uint256 value = hook.claimPrice() + 1 + bound(extra, 0, 0.1 ether);
        vm.deal(address(this), value);
        hook.claimKing{value: value}(b);
        claims++;
    }

    function withdraw(uint256 who, bool native) external {
        address b = beneficiaries[who % beneficiaries.length];
        Currency c = native ? NATIVE : PVP_CURRENCY;
        if (hook.pending(b, c) == 0) return;
        address to = b == beneficiaries[3] ? beneficiaries[0] : b;
        if (b == beneficiaries[3]) {
            RevertingReceiver(payable(b)).pull(hook, c, to);
        } else if (b == beneficiaries[2]) {
            StoringReceiver(payable(b)).pull(hook, c, to);
        } else {
            vm.prank(b);
            hook.withdraw(c, to);
        }
    }

    function redeem(bool native) external {
        Currency c = native ? NATIVE : PVP_CURRENCY;
        if (hook.deferred(c) == 0) return;
        hook.redeem(c);
    }

    function assignUnassigned(bool native) external {
        Currency c = native ? NATIVE : PVP_CURRENCY;
        if (hook.beneficiary() == address(0) || hook.unassigned(c) == 0) return;
        hook.assignUnassigned(c);
    }

    function fundWorkers(uint256 amount) external {
        amount = bound(amount, 1, 1 ether);
        vm.deal(address(this), amount);
        hook.fundWorkers{value: amount}();
    }

    function setEpoch(uint256 window) external {
        uint256 id = hook.currentEpoch();
        if (id != 0) {
            (,, uint64 windowEnd,,) = hook.epochs(id);
            if (block.timestamp < windowEnd) return;
        }
        uint256 budget = hook.availableForNextEpoch();
        if (budget < 2) return;
        window = bound(window, 1 hours, 30 days);
        epochLeafId = id + 1;
        epochLeafAmount = budget / 2;
        bytes32 root = hook.leaf(epochLeafId, worker, epochLeafAmount);
        vm.prank(updater);
        hook.setEpoch(root, uint64(block.timestamp), uint64(block.timestamp + window));
    }

    function claimWorker() external {
        uint256 id = hook.currentEpoch();
        if (id == 0 || id != epochLeafId || hook.claimed(id, worker)) return;
        (, uint64 start, uint64 end,,) = hook.epochs(id);
        if (block.timestamp < start || block.timestamp >= end) return;
        hook.claimWorker(id, payable(worker), epochLeafAmount, new bytes32[](0));
        workerPayouts++;
    }

    function warp(uint256 by) external {
        vm.warp(block.timestamp + bound(by, 0, 2 days));
    }
}

contract PvPadHookInvariantTest is Fixture {
    Handler handler;

    function setUp() public override {
        super.setUp();
        handler = new Handler(hook, pvp, swapRouter, key, updater);
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
        assertGe(pvp.balanceOf(address(manager)), hook.deferred(PVP_CURRENCY));
        assertEq(manager.balanceOf(address(hook), 0), hook.deferred(NATIVE));
        assertEq(
            manager.balanceOf(address(hook), uint256(uint160(address(pvp)))), hook.deferred(PVP_CURRENCY)
        );
    }

    function invariant_supplyNeverGrows() public view {
        assertEq(pvp.totalSupply(), 1e27);
    }

    function invariant_claimPriceOnlyRises() public view {
        assertGe(hook.claimPrice(), 0.01 ether);
        if (hook.claimCount() > 0) assertTrue(hook.beneficiary() != address(0));
    }
}
