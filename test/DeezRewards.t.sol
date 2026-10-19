// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeezToken} from "../src/DeezToken.sol";
import {DeezRewards} from "../src/DeezRewards.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice Unit tests of the distributor alone, with stand-in pool manager and hook addresses.
contract DeezRewardsTest is Test {
    uint256 constant EPOCH = 1 days;
    uint256 constant SUPPLY = 1e27;

    DeezToken token;
    MockERC20 imd;
    DeezRewards rewards;

    address poolManager = address(0x9001);
    address hook = address(0x9002);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address carol = address(0xCA201);
    address dead = 0x000000000000000000000000000000000000dEaD;

    function setUp() public {
        vm.warp(100 * EPOCH + 5); // epoch 100
        token = new DeezToken();
        imd = new MockERC20("IMD", "IMD", 0);
        rewards = new DeezRewards(address(token), address(imd), poolManager, hook);
    }

    function fund(uint256 amount) internal {
        imd.mint(address(rewards), amount);
        rewards.accrue();
    }

    function epochs(uint256 e) internal pure returns (uint256[] memory list) {
        list = new uint256[](1);
        list[0] = e;
    }

    function eligible() internal view returns (uint256) {
        return SUPPLY - token.balanceOf(poolManager) - token.balanceOf(dead) - token.balanceOf(hook)
            - token.balanceOf(address(rewards));
    }

    function test_constructorRefusesZeroAddresses() public {
        vm.expectRevert(DeezRewards.ZeroAddress.selector);
        new DeezRewards(address(0), address(imd), poolManager, hook);
        vm.expectRevert(DeezRewards.ZeroAddress.selector);
        new DeezRewards(address(token), address(imd), poolManager, address(0));
    }

    function test_epochArithmetic() public view {
        assertEq(rewards.currentEpoch(), 100);
        assertEq(rewards.snapshotOf(100), 101 * EPOCH - 1);
        assertFalse(rewards.hasEnded(100));
        assertTrue(rewards.hasEnded(99));
        assertEq(rewards.EPOCH_LENGTH(), 1 days);
        assertEq(rewards.CLAIM_WINDOW(), 365);
    }

    function test_excludedAddresses() public view {
        assertTrue(rewards.isExcluded(poolManager));
        assertTrue(rewards.isExcluded(hook));
        assertTrue(rewards.isExcluded(dead));
        assertTrue(rewards.isExcluded(address(rewards)));
        assertTrue(rewards.isExcluded(address(0)));
        assertFalse(rewards.isExcluded(alice));
    }

    function test_accrueCreditsTheCurrentEpochOnce() public {
        imd.mint(address(rewards), 1_000 ether);
        assertEq(rewards.accrue(), 1_000 ether);
        assertEq(rewards.accrue(), 0, "nothing new");
        (uint128 total,,,) = rewards.pots(100);
        assertEq(total, 1_000 ether);
        assertEq(rewards.reserved(), 1_000 ether);
    }

    function test_claimsAreProportionalToBalanceAtTheSnapshot() public {
        token.transfer(alice, 300 ether);
        token.transfer(bob, 100 ether);
        token.transfer(poolManager, 500_000_000 ether); // the pool's share earns nothing
        token.transfer(dead, 1_000 ether);
        token.transfer(hook, 7 ether);
        fund(1_000 ether);
        uint256 supply = eligible();

        vm.warp(101 * EPOCH); // epoch 100 just ended
        assertTrue(rewards.hasEnded(100));
        assertEq(rewards.eligibleSupplyAt(100), supply);

        uint256 expectedAlice = 1_000 ether * 300 ether / supply;
        uint256 expectedBob = 1_000 ether * 100 ether / supply;
        assertEq(rewards.claimable(alice, 100), expectedAlice);
        assertEq(rewards.claimable(bob, 100), expectedBob);
        assertEq(rewards.claimable(poolManager, 100), 0);

        vm.prank(carol); // anyone may trigger a claim; the money goes to the holder
        assertEq(rewards.claim(alice, epochs(100)), expectedAlice);
        assertEq(imd.balanceOf(alice), expectedAlice);
        assertEq(imd.balanceOf(carol), 0);
        assertEq(rewards.claim(bob, epochs(100)), expectedBob);
        assertEq(expectedAlice, 3 * expectedBob, "three times the bag, three times the share");
        (,, uint256 storedSupply,) = rewards.pots(100);
        assertEq(storedSupply, supply, "finalized on first claim");
        assertEq(rewards.reserved(), 1_000 ether - expectedAlice - expectedBob);
    }

    function test_deployerShareIsProportionalToo() public {
        // The deployer (standing in for whoever holds the rest of the supply) earns on its balance like anyone.
        token.transfer(alice, 250_000_000 ether);
        token.transfer(poolManager, 500_000_000 ether);
        fund(100 ether);
        vm.warp(101 * EPOCH);
        assertEq(rewards.claim(alice, epochs(100)), 50 ether);
        assertEq(rewards.claim(address(this), epochs(100)), 50 ether);
    }

    function test_balanceMovedAfterTheSnapshotDoesNotChangeTheEpoch() public {
        token.transfer(alice, 100 ether);
        fund(100 ether);
        vm.warp(101 * EPOCH);
        vm.prank(alice);
        token.transfer(carol, 100 ether); // moved in epoch 101
        uint256 supply = eligible();
        assertEq(rewards.claimable(alice, 100), 100 ether * 100 ether / supply);
        assertEq(rewards.claimable(carol, 100), 0);
        // Epoch 101's rewards go to carol.
        fund(100 ether);
        vm.warp(102 * EPOCH);
        assertEq(rewards.claimable(alice, 101), 0);
        assertEq(rewards.claimable(carol, 101), 100 ether * 100 ether / supply);
    }

    function test_claimBeforeTheEpochEndsReverts() public {
        token.transfer(alice, 100 ether);
        fund(100 ether);
        vm.expectRevert(abi.encodeWithSelector(DeezRewards.EpochNotEnded.selector, 100));
        rewards.claim(alice, epochs(100));
        assertEq(rewards.claimable(alice, 100), 0);
    }

    function test_doubleClaimReverts() public {
        token.transfer(alice, 100 ether);
        fund(100 ether);
        vm.warp(101 * EPOCH);
        rewards.claim(alice, epochs(100));
        vm.expectRevert(abi.encodeWithSelector(DeezRewards.AlreadyClaimed.selector, 100, alice));
        rewards.claim(alice, epochs(100));
        uint256[] memory twice = new uint256[](2);
        twice[0] = 100;
        twice[1] = 100;
        vm.expectRevert(abi.encodeWithSelector(DeezRewards.AlreadyClaimed.selector, 100, bob));
        rewards.claim(bob, twice);
    }

    function test_excludedAddressesCannotClaim() public {
        fund(100 ether);
        vm.warp(101 * EPOCH);
        vm.expectRevert(abi.encodeWithSelector(DeezRewards.Excluded.selector, poolManager));
        rewards.claim(poolManager, epochs(100));
        vm.expectRevert(abi.encodeWithSelector(DeezRewards.Excluded.selector, dead));
        rewards.claim(dead, epochs(100));
        vm.expectRevert(abi.encodeWithSelector(DeezRewards.Excluded.selector, hook));
        rewards.claim(hook, epochs(100));
    }

    function test_emptyClaimReverts() public {
        fund(100 ether);
        vm.warp(101 * EPOCH);
        vm.expectRevert(DeezRewards.NothingToClaim.selector);
        rewards.claim(alice, epochs(100)); // alice holds nothing
        vm.expectRevert(DeezRewards.NothingToClaim.selector);
        rewards.claim(alice, epochs(99)); // no pot
    }

    function test_claimManyEpochsAtOnce() public {
        token.transfer(alice, 500_000_000 ether);
        token.transfer(poolManager, 500_000_000 ether - 1 ether);
        // alice holds 500M of 500M + 1 eligible: close to everything.
        fund(100 ether);
        vm.warp(101 * EPOCH);
        fund(200 ether);
        vm.warp(102 * EPOCH);
        fund(300 ether);
        vm.warp(103 * EPOCH + 10);
        uint256[] memory list = new uint256[](3);
        list[0] = 100;
        list[1] = 101;
        list[2] = 102;
        uint256 expected = rewards.claimableMany(alice, list);
        assertApproxEqRel(expected, 600 ether, 1e12);
        assertEq(rewards.claim(alice, list), expected);
        assertEq(imd.balanceOf(alice), expected);
    }

    function test_recycleFoldsUnclaimedIntoTheCurrentEpoch() public {
        token.transfer(alice, 500_000_000 ether);
        token.transfer(bob, 500_000_000 ether - 1 ether);
        fund(100 ether);
        vm.warp(101 * EPOCH);
        rewards.claim(alice, epochs(100));
        vm.expectRevert(abi.encodeWithSelector(DeezRewards.ClaimWindowOpen.selector, 100));
        rewards.recycle(100);

        vm.warp((100 + 365 + 1) * EPOCH);
        uint256 remainder = rewards.recycle(100);
        assertGt(remainder, 0);
        (uint128 total, uint128 claimedAmount,, bool closed) = rewards.pots(100);
        assertTrue(closed);
        assertEq(remainder, total - claimedAmount);
        (uint128 nowTotal,,,) = rewards.pots(rewards.currentEpoch());
        assertEq(nowTotal, remainder, "credited to the current epoch");
        assertEq(rewards.claimable(bob, 100), 0);
        vm.expectRevert(abi.encodeWithSelector(DeezRewards.EpochClosed.selector, 100));
        rewards.claim(bob, epochs(100));
        vm.expectRevert(abi.encodeWithSelector(DeezRewards.EpochClosed.selector, 100));
        rewards.recycle(100);
        // Bob can still claim the recycled epoch like any other once it ends.
        vm.warp((100 + 365 + 2) * EPOCH);
        assertGt(rewards.claim(bob, epochs(100 + 365 + 1)), 0);
    }

    function test_finalizeRequiresAnEndedEpoch() public {
        vm.expectRevert(abi.encodeWithSelector(DeezRewards.EpochNotEnded.selector, 100));
        rewards.finalize(100);
        vm.warp(101 * EPOCH);
        assertEq(rewards.finalize(100), eligible());
        assertEq(rewards.finalize(100), eligible(), "idempotent");
    }

    function testFuzz_claimsNeverExceedThePotAndSplitByBalance(uint96 a, uint96 b, uint96 pot) public {
        a = uint96(bound(a, 1 ether, 1e26));
        b = uint96(bound(b, 1 ether, 1e26));
        pot = uint96(bound(pot, 1 ether, 1e24));
        token.transfer(alice, a);
        token.transfer(bob, b);
        token.transfer(poolManager, SUPPLY - uint256(a) - b); // only alice and bob are eligible
        fund(pot);
        vm.warp(101 * EPOCH);
        uint256 supply = uint256(a) + b;
        assertEq(rewards.eligibleSupplyAt(100), supply);
        uint256 paidA = rewards.claim(alice, epochs(100));
        uint256 paidB = rewards.claim(bob, epochs(100));
        assertEq(paidA, uint256(pot) * a / supply);
        assertEq(paidB, uint256(pot) * b / supply);
        assertLe(paidA + paidB, pot, "never pays more than the pot");
        assertGe(paidA + paidB + 2, pot, "at most rounding dust stays");
        assertEq(imd.balanceOf(address(rewards)), uint256(pot) - paidA - paidB);
    }
}
