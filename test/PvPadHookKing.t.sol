// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./utils/Fixture.sol";
import {PvPadHook} from "../src/PvPadHook.sol";

/// @dev King claims: pricing, funding of the worker pot, and what a claim never does.
contract PvPadHookKingTest is Fixture {
    event KingClaimed(
        address indexed king,
        address indexed beneficiary,
        uint256 paid,
        uint256 nextPrice,
        uint256 indexed claimId
    );

    function test_firstClaimMustExceedTheInitialPrice() public {
        vm.expectRevert(abi.encodeWithSelector(PvPadHook.BidTooLow.selector, 0.01 ether));
        vm.prank(alice);
        hook.claimKing{value: 0.01 ether}(alice);

        vm.expectRevert(abi.encodeWithSelector(PvPadHook.BidTooLow.selector, 0.01 ether));
        vm.prank(alice);
        hook.claimKing{value: 0}(alice);

        assertEq(hook.king(), address(0));
        assertEq(hook.workerPot(), 0);
    }

    function test_claimRejectsZeroBeneficiary() public {
        vm.expectRevert(PvPadHook.ZeroAddress.selector);
        vm.prank(alice);
        hook.claimKing{value: 1 ether}(address(0));
    }

    function test_claimCrownsCallerNamesBeneficiaryAndFundsWorkers() public {
        vm.expectEmit(true, true, true, true);
        emit KingClaimed(alice, bob, 0.02 ether, 0.022 ether, 1);
        vm.prank(alice);
        hook.claimKing{value: 0.02 ether}(bob);

        assertEq(hook.king(), alice);
        assertEq(hook.beneficiary(), bob);
        assertEq(hook.claimCount(), 1);
        assertEq(hook.claimPrice(), 0.022 ether);
        assertEq(hook.workerPot(), 0.02 ether);
        assertEq(address(hook).balance, 0.02 ether);
        assertEthConserved();
    }

    function test_previousKingIsNeverPaidFromTheBid() public {
        vm.prank(alice);
        hook.claimKing{value: 0.02 ether}(alice);
        uint256 aliceBefore = alice.balance;

        vm.expectRevert(abi.encodeWithSelector(PvPadHook.BidTooLow.selector, 0.022 ether));
        vm.prank(bob);
        hook.claimKing{value: 0.022 ether}(bob);

        vm.prank(bob);
        hook.claimKing{value: 0.03 ether}(carol);
        assertEq(hook.king(), bob);
        assertEq(hook.beneficiary(), carol);
        assertEq(hook.claimPrice(), 0.033 ether);
        assertEq(hook.workerPot(), 0.05 ether);
        assertEq(alice.balance, aliceBefore, "the dethroned king got nothing");
        assertEq(address(hook).balance, 0.05 ether);
        assertEthConserved();
    }

    function test_bumpRoundsUp() public {
        vm.prank(alice);
        hook.claimKing{value: 0.01 ether + 1}(alice);
        // (1e16 + 1) * 1000 / 10000 = 1e15 + 0.1, rounded up to 1e15 + 1
        assertEq(hook.claimPrice(), 0.01 ether + 1 + 0.001 ether + 1);
    }

    function testFuzz_nextPriceIsAtLeastTenPercentHigher(uint256 bid) public {
        bid = bound(bid, 0.01 ether + 1, 1_000 ether);
        vm.deal(alice, bid);
        vm.prank(alice);
        hook.claimKing{value: bid}(alice);
        uint256 next = hook.claimPrice();
        assertGe(next, bid + bid / 10);
        assertLe(next, bid + bid / 10 + 1);
        assertEq(hook.workerPot(), bid);
        assertEthConserved();
    }

    function test_claimCanBeMadeByAContractBeneficiaryForItself() public {
        vm.prank(alice);
        hook.claimKing{value: 1 ether}(address(swapRouter));
        assertEq(hook.beneficiary(), address(swapRouter));
    }

    function test_fundWorkersAddsToThePot() public {
        vm.prank(alice);
        hook.fundWorkers{value: 0.5 ether}();
        assertEq(hook.workerPot(), 0.5 ether);
        vm.expectRevert(PvPadHook.NothingToDo.selector);
        hook.fundWorkers{value: 0}();
        assertEthConserved();
    }
}
