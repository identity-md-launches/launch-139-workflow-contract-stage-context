// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./utils/Fixture.sol";
import {Merkle} from "./utils/Merkle.sol";
import {PvPadHook} from "../src/PvPadHook.sol";
import {RevertingReceiver} from "./mocks/Receivers.sol";

/// @dev The worker pot: Merkle epochs opened by the updater, claims, rollover and the updater handoff.
contract PvPadHookWorkersTest is Fixture {
    address w1 = makeAddr("worker1");
    address w2 = makeAddr("worker2");
    address w3 = makeAddr("worker3");
    address relayer = makeAddr("relayer");

    bytes32[] leaves;
    address[] payees;
    uint256[] amounts;

    function setUp() public override {
        super.setUp();
        // Fund the pot with two King claims: 0.02 + 0.03 ETH.
        vm.prank(alice);
        hook.claimKing{value: 0.02 ether}(alice);
        vm.prank(bob);
        hook.claimKing{value: 0.03 ether}(bob);
        assertEq(hook.workerPot(), 0.05 ether);
    }

    function buildTree(uint256 epochId, address[] memory ps, uint256[] memory as_)
        internal
        returns (bytes32)
    {
        delete leaves;
        delete payees;
        delete amounts;
        for (uint256 i = 0; i < ps.length; i++) {
            leaves.push(hook.leaf(epochId, ps[i], as_[i]));
            payees.push(ps[i]);
            amounts.push(as_[i]);
        }
        return Merkle.root(leaves);
    }

    function threeWorkers(uint256 a1, uint256 a2, uint256 a3) internal returns (bytes32 root) {
        address[] memory ps = new address[](3);
        uint256[] memory as_ = new uint256[](3);
        (ps[0], ps[1], ps[2]) = (w1, w2, w3);
        (as_[0], as_[1], as_[2]) = (a1, a2, a3);
        root = buildTree(hook.currentEpoch() + 1, ps, as_);
    }

    function openEpoch(bytes32 root, uint64 start, uint64 end) internal {
        vm.prank(updater);
        hook.setEpoch(root, start, end);
    }

    function now64() internal view returns (uint64) {
        return uint64(block.timestamp);
    }

    // ------------------------------------------------------------------------------------------
    // setEpoch
    // ------------------------------------------------------------------------------------------

    function test_onlyUpdaterOpensEpochs() public {
        bytes32 root = threeWorkers(0.01 ether, 0.01 ether, 0.01 ether);
        vm.expectRevert(PvPadHook.NotUpdater.selector);
        vm.prank(alice);
        hook.setEpoch(root, now64(), now64() + 1 days);
        vm.expectRevert(PvPadHook.NotUpdater.selector);
        hook.setEpoch(root, now64(), now64() + 1 days);
    }

    function test_setEpochRejectsBadWindows() public {
        bytes32 root = threeWorkers(0.01 ether, 0.01 ether, 0.01 ether);
        vm.startPrank(updater);
        vm.expectRevert(PvPadHook.InvalidWindow.selector);
        hook.setEpoch(bytes32(0), now64(), now64() + 1 days);
        vm.expectRevert(PvPadHook.InvalidWindow.selector);
        hook.setEpoch(root, now64() + 1 days, now64() + 1 days);
        vm.expectRevert(PvPadHook.InvalidWindow.selector);
        hook.setEpoch(root, now64() - 2 days, now64() - 1 days);
        vm.expectRevert(PvPadHook.InvalidWindow.selector);
        hook.setEpoch(root, now64(), now64());
        vm.expectRevert(PvPadHook.InvalidWindow.selector);
        hook.setEpoch(root, now64(), now64() + 90 days + 1);
        vm.stopPrank();
    }

    function test_setEpochSnapshotsTheWholePot() public {
        bytes32 root = threeWorkers(0.02 ether, 0.02 ether, 0.01 ether);
        openEpoch(root, now64(), now64() + 7 days);
        assertEq(hook.currentEpoch(), 1);
        (bytes32 r, uint64 s, uint64 e, uint256 budget, uint256 paid) = hook.epochs(1);
        assertEq(r, root);
        assertEq(s, now64());
        assertEq(e, now64() + 7 days);
        assertEq(budget, 0.05 ether);
        assertEq(paid, 0);
        assertEq(hook.workerPot(), 0);
        assertEq(hook.availableForNextEpoch(), 0);
        assertEthConserved();
    }

    function test_setEpochWithEmptyPotReverts() public {
        // A fresh hook: no claims, no pot.
        PvPadHook fresh = deployHook(manager);
        vm.expectRevert(PvPadHook.EmptyPot.selector);
        vm.prank(updater);
        fresh.setEpoch(bytes32(uint256(1)), now64(), now64() + 1 days);
    }

    function test_newEpochWaitsForThePreviousWindowToEnd() public {
        bytes32 root = threeWorkers(0.02 ether, 0.02 ether, 0.01 ether);
        openEpoch(root, now64(), now64() + 7 days);
        vm.warp(block.timestamp + 6 days);
        vm.prank(carol);
        hook.fundWorkers{value: 0.1 ether}();
        vm.expectRevert(PvPadHook.EpochStillOpen.selector);
        openEpoch(root, now64(), now64() + 1 days);
        assertEq(hook.availableForNextEpoch(), 0.1 ether, "pot only, the epoch is still open");
    }

    // ------------------------------------------------------------------------------------------
    // claimWorker
    // ------------------------------------------------------------------------------------------

    function test_claimPaysThePayeeOncePerEpoch() public {
        bytes32 root = threeWorkers(0.02 ether, 0.02 ether, 0.01 ether);
        openEpoch(root, now64(), now64() + 7 days);

        uint256 before = w1.balance;
        vm.prank(relayer);
        hook.claimWorker(1, payable(w1), 0.02 ether, Merkle.proof(leaves, 0));
        assertEq(w1.balance - before, 0.02 ether, "ETH goes to the payee, not the relayer");
        assertTrue(hook.claimed(1, w1));
        (,,,, uint256 paid) = hook.epochs(1);
        assertEq(paid, 0.02 ether);
        assertEthConserved();

        vm.expectRevert(PvPadHook.InvalidClaim.selector);
        hook.claimWorker(1, payable(w1), 0.02 ether, Merkle.proof(leaves, 0));

        hook.claimWorker(1, payable(w2), 0.02 ether, Merkle.proof(leaves, 1));
        hook.claimWorker(1, payable(w3), 0.01 ether, Merkle.proof(leaves, 2));
        (,,,, paid) = hook.epochs(1);
        assertEq(paid, 0.05 ether);
        assertEq(address(hook).balance, 0);
        assertEthConserved();
    }

    function test_claimRejectsWrongAmountPayeeEpochAndProof() public {
        bytes32 root = threeWorkers(0.02 ether, 0.02 ether, 0.01 ether);
        openEpoch(root, now64(), now64() + 7 days);
        bytes32[] memory proof = Merkle.proof(leaves, 0);

        vm.expectRevert(PvPadHook.InvalidProof.selector);
        hook.claimWorker(1, payable(w1), 0.03 ether, proof);
        vm.expectRevert(PvPadHook.InvalidProof.selector);
        hook.claimWorker(1, payable(alice), 0.02 ether, proof);
        vm.expectRevert(PvPadHook.InvalidProof.selector);
        hook.claimWorker(1, payable(w1), 0.02 ether, Merkle.proof(leaves, 1));
        vm.expectRevert(PvPadHook.InvalidEpoch.selector);
        hook.claimWorker(2, payable(w1), 0.02 ether, proof);
        vm.expectRevert(PvPadHook.InvalidEpoch.selector);
        hook.claimWorker(0, payable(w1), 0.02 ether, proof);
        vm.expectRevert(PvPadHook.InvalidClaim.selector);
        hook.claimWorker(1, payable(address(0)), 0.02 ether, proof);
        vm.expectRevert(PvPadHook.InvalidClaim.selector);
        hook.claimWorker(1, payable(w1), 0, proof);
        assertFalse(hook.claimed(1, w1));
    }

    function test_claimRespectsTheWindow() public {
        bytes32 root = threeWorkers(0.02 ether, 0.02 ether, 0.01 ether);
        openEpoch(root, now64() + 1 days, now64() + 7 days);
        bytes32[] memory proof = Merkle.proof(leaves, 0);

        vm.expectRevert(PvPadHook.OutsideWindow.selector);
        hook.claimWorker(1, payable(w1), 0.02 ether, proof);

        vm.warp(block.timestamp + 1 days);
        hook.claimWorker(1, payable(w1), 0.02 ether, proof);

        vm.warp(block.timestamp + 6 days);
        vm.expectRevert(PvPadHook.OutsideWindow.selector);
        hook.claimWorker(1, payable(w2), 0.02 ether, Merkle.proof(leaves, 1));
    }

    function test_treeLargerThanBudgetFailsOnlyWhereItOverflows() public {
        // A dishonest or mistaken root promising more than the pot cannot pay more than the pot.
        bytes32 root = threeWorkers(0.03 ether, 0.03 ether, 0.03 ether);
        openEpoch(root, now64(), now64() + 7 days);
        hook.claimWorker(1, payable(w1), 0.03 ether, Merkle.proof(leaves, 0));
        vm.expectRevert(PvPadHook.InsufficientBudget.selector);
        hook.claimWorker(1, payable(w2), 0.03 ether, Merkle.proof(leaves, 1));
        assertEq(address(hook).balance, 0.02 ether);
        assertEthConserved();
    }

    function test_claimToARefusingPayeeRevertsAndKeepsTheLeafClaimable() public {
        RevertingReceiver bad = new RevertingReceiver();
        address[] memory ps = new address[](2);
        uint256[] memory as_ = new uint256[](2);
        (ps[0], ps[1]) = (address(bad), w1);
        (as_[0], as_[1]) = (0.02 ether, 0.03 ether);
        bytes32 root = buildTree(1, ps, as_);
        openEpoch(root, now64(), now64() + 7 days);

        vm.expectRevert(PvPadHook.PaymentFailed.selector);
        hook.claimWorker(1, payable(address(bad)), 0.02 ether, Merkle.proof(leaves, 0));
        assertFalse(hook.claimed(1, address(bad)));
        (,,,, uint256 paid) = hook.epochs(1);
        assertEq(paid, 0);
        hook.claimWorker(1, payable(w1), 0.03 ether, Merkle.proof(leaves, 1));
        assertEthConserved();
    }

    function test_unclaimedRemainderRollsIntoTheNextEpoch() public {
        bytes32 root = threeWorkers(0.02 ether, 0.02 ether, 0.01 ether);
        openEpoch(root, now64(), now64() + 7 days);
        hook.claimWorker(1, payable(w1), 0.02 ether, Merkle.proof(leaves, 0));
        vm.warp(block.timestamp + 7 days);
        vm.prank(carol);
        hook.claimKing{value: 0.1 ether}(carol);
        assertEq(hook.availableForNextEpoch(), 0.03 ether + 0.1 ether);

        bytes32 root2 = threeWorkers(0.1 ether, 0.02 ether, 0.01 ether);
        openEpoch(root2, now64(), now64() + 7 days);
        (,,, uint256 budget,) = hook.epochs(2);
        assertEq(budget, 0.13 ether);
        assertEq(hook.workerPot(), 0);
        assertEthConserved();

        // Old-epoch proofs are dead.
        vm.expectRevert(PvPadHook.InvalidEpoch.selector);
        hook.claimWorker(1, payable(w2), 0.02 ether, Merkle.proof(leaves, 1));
        hook.claimWorker(2, payable(w1), 0.1 ether, Merkle.proof(leaves, 0));
        assertEthConserved();
    }

    function test_leafIsBoundToChainContractAndEpoch() public {
        bytes32 a = hook.leaf(1, w1, 1 ether);
        assertEq(
            a,
            keccak256(
                bytes.concat(keccak256(abi.encode(block.chainid, address(hook), uint256(1), w1, 1 ether)))
            )
        );
        assertTrue(a != hook.leaf(2, w1, 1 ether));
        vm.chainId(11155111);
        assertTrue(a != hook.leaf(1, w1, 1 ether));
    }

    function test_singleLeafTreeNeedsNoProof() public {
        address[] memory ps = new address[](1);
        uint256[] memory as_ = new uint256[](1);
        ps[0] = w1;
        as_[0] = 0.05 ether;
        bytes32 root = buildTree(1, ps, as_);
        assertEq(root, leaves[0]);
        openEpoch(root, now64(), now64() + 1 days);
        hook.claimWorker(1, payable(w1), 0.05 ether, new bytes32[](0));
        assertEq(w1.balance, 0.05 ether);
    }

    // ------------------------------------------------------------------------------------------
    // Updater handoff
    // ------------------------------------------------------------------------------------------

    function test_updaterHandoffIsTwoStep() public {
        vm.expectRevert(PvPadHook.NotUpdater.selector);
        vm.prank(alice);
        hook.proposeUpdater(alice);

        vm.prank(updater);
        hook.proposeUpdater(alice);
        assertEq(hook.pendingUpdater(), alice);
        assertEq(hook.updater(), updater, "nothing changes until accepted");

        vm.expectRevert(PvPadHook.NotPendingUpdater.selector);
        vm.prank(bob);
        hook.acceptUpdater();
        vm.expectRevert(PvPadHook.NotPendingUpdater.selector);
        vm.prank(updater);
        hook.acceptUpdater();

        vm.prank(alice);
        hook.acceptUpdater();
        assertEq(hook.updater(), alice);
        assertEq(hook.pendingUpdater(), address(0));

        // The old updater is powerless now; the new one works.
        bytes32 root = threeWorkers(0.02 ether, 0.02 ether, 0.01 ether);
        vm.expectRevert(PvPadHook.NotUpdater.selector);
        vm.prank(updater);
        hook.setEpoch(root, now64(), now64() + 1 days);
        vm.prank(alice);
        hook.setEpoch(root, now64(), now64() + 1 days);
        assertEq(hook.currentEpoch(), 1);
    }

    function test_handoffCanBeCancelledAndNobodyCanAcceptZero() public {
        vm.prank(updater);
        hook.proposeUpdater(alice);
        vm.prank(updater);
        hook.proposeUpdater(address(0));
        assertEq(hook.pendingUpdater(), address(0));
        vm.expectRevert(PvPadHook.NotPendingUpdater.selector);
        vm.prank(alice);
        hook.acceptUpdater();
        vm.expectRevert(PvPadHook.NotPendingUpdater.selector);
        vm.prank(address(0));
        hook.acceptUpdater();
        assertEq(hook.updater(), updater);
    }

    function test_updaterHasNoPowerOverFeesOrThePot() public {
        // The only functions the updater can call are setEpoch and proposeUpdater. There is no
        // withdrawal, sweep, pause, fee setter or beneficiary override for it to reach.
        vm.startPrank(updater);
        vm.expectRevert(PvPadHook.NothingToDo.selector);
        hook.withdraw(NATIVE, updater);
        vm.expectRevert(PvPadHook.NothingToDo.selector);
        hook.redeem(NATIVE);
        vm.stopPrank();
        assertEq(address(hook).balance, 0.05 ether);
        assertEthConserved();
    }
}
