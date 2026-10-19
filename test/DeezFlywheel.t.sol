// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {DeezBase} from "./DeezBase.t.sol";

/// @notice End to end: trades pay the fee, anyone harvests, the epoch ends, holders claim $IMD by balance.
contract DeezFlywheelTest is DeezBase {
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address keeper = address(0x4EE9);

    function wantTokenIsCurrency0() internal pure override returns (bool) {
        return true;
    }

    function test_tradesBecomeHolderRewards() public {
        vm.warp(1_000 * 1 days);
        seedBalanced(1_000_000 ether);
        // Everything the test still holds goes to the pool stand-in so only alice and bob are eligible.
        token.transfer(alice, 600 ether);
        token.transfer(bob, 200 ether);
        token.transfer(address(manager), token.balanceOf(address(this)));

        buy(-10_000 ether);
        sell(-3_000 ether);
        buy(2_000 ether);
        uint256 fees = hook.pendingFees();
        assertGt(fees, 0);

        vm.prank(keeper);
        hook.harvest();
        assertEq(imd.balanceOf(address(rewards)), fees);

        uint256 epoch = rewards.currentEpoch();
        vm.warp((epoch + 1) * 1 days);

        uint256 supply = rewards.eligibleSupplyAt(epoch);
        assertEq(supply, 800 ether + token.balanceOf(address(swapper)), "pool, hook and distributor excluded");

        uint256[] memory list = new uint256[](1);
        list[0] = epoch;
        vm.prank(keeper);
        uint256 paidAlice = rewards.claim(alice, list);
        vm.prank(keeper);
        uint256 paidBob = rewards.claim(bob, list);
        assertEq(paidAlice, fees * 600 ether / supply);
        assertEq(paidBob, fees * 200 ether / supply);
        assertApproxEqAbs(paidAlice, 3 * paidBob, 3, "three times the bag, three times the share");
        assertEq(imd.balanceOf(alice), paidAlice);
        assertEq(imd.balanceOf(bob), paidBob);
    }

    function test_harvestAndClaimInTheSameEpochSeeTheSamePot() public {
        vm.warp(1_000 * 1 days);
        seedBalanced(1_000_000 ether);
        token.transfer(alice, 1_000 ether);
        buy(-1_000 ether);
        uint256 fees = hook.pendingFees();
        uint256 epoch = rewards.currentEpoch();
        vm.warp((epoch + 1) * 1 days);
        // Harvest lands in epoch + 1, not the ended epoch: fees belong to the epoch they are harvested in.
        hook.harvest();
        assertEq(rewards.claimable(alice, epoch), 0);
        vm.warp((epoch + 2) * 1 days);
        uint256 supply = rewards.eligibleSupplyAt(epoch + 1);
        assertEq(rewards.claimable(alice, epoch + 1), fees * 1_000 ether / supply);
    }
}
