// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {DeezBase} from "./DeezBase.t.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {DeezHook} from "../src/DeezHook.sol";
import {DeezLiquidityLock} from "../src/DeezLiquidityLock.sol";

abstract contract DeezLiquidityLockTests is DeezBase {
    using StateLibrary for IPoolManager;

    DeezLiquidityLock lock;

    function setUp() public override {
        super.setUp();
        lock = hook.liquidityLock();
    }

    function rangeLiquidity(int24 lower, int24 upper) internal view returns (uint128) {
        (uint128 liquidity,,) =
            IPoolManager(address(manager)).getPositionInfo(key.toId(), address(lock), lower, upper, bytes32(0));
        return liquidity;
    }

    function test_wiring() public {
        assertEq(address(lock.poolManager()), address(manager));
        assertEq(address(lock.hook()), address(hook));
        (bool ok,) = address(lock).call(abi.encodeWithSignature("owner()"));
        assertFalse(ok, "the lock has no owner");
    }

    function test_lockRefusesNothing() public {
        vm.expectRevert(DeezLiquidityLock.NothingToLock.selector);
        lock.lock();
    }

    function test_lockRefusesBeforeThePoolExists() public {
        DeezHook fresh = DeezHook(deployHook(manager, address(token), address(imd)));
        DeezLiquidityLock freshLock = fresh.liquidityLock();
        token.transfer(address(freshLock), 1 ether);
        vm.expectRevert(DeezLiquidityLock.PoolNotInitialized.selector);
        freshLock.lock();
    }

    function test_lockDeezOnlyBecomesLiquidityAboveThePrice() public {
        seedBalanced(1_000_000 ether);
        token.transfer(address(lock), 10_000_000 ether);
        uint128 liquidity = lock.lock();
        assertGt(liquidity, 0);
        assertLt(token.balanceOf(address(lock)), 10_000_000 ether / 100_000, "all but dust locked");
        (int24 lower, int24 upper) = tokenIsCurrency0
            ? (int24(TICK_SPACING), TickMath.maxUsableTick(TICK_SPACING))
            : (TickMath.minUsableTick(TICK_SPACING), int24(0));
        assertEq(rangeLiquidity(lower, upper), liquidity);
        assertEq(
            tokenIsCurrency0 ? lock.totalLocked0() : lock.totalLocked1(),
            10_000_000 ether - token.balanceOf(address(lock))
        );
        assertEq(imd.balanceOf(address(lock)), 0);
        // Trading against it works: a buy now draws on the locked depth too.
        uint256 before = token.balanceOf(address(swapper));
        buy(-1_000 ether);
        assertGt(token.balanceOf(address(swapper)), before);
    }

    function test_lockImdOnlyBecomesABuyWallBelowThePrice() public {
        seedBalanced(1_000_000 ether);
        imd.mint(address(lock), 5_000 ether);
        uint128 liquidity = lock.lock();
        assertGt(liquidity, 0);
        (int24 lower, int24 upper) = tokenIsCurrency0
            ? (TickMath.minUsableTick(TICK_SPACING), int24(0))
            : (int24(TICK_SPACING), TickMath.maxUsableTick(TICK_SPACING));
        assertEq(rangeLiquidity(lower, upper), liquidity);
        assertLt(imd.balanceOf(address(lock)), 5_000 ether / 100_000);
    }

    function test_lockBothBecomesFullRange() public {
        seedBalanced(1_000_000 ether);
        token.transfer(address(lock), 10_000 ether);
        imd.mint(address(lock), 10_000 ether);
        uint128 liquidity = lock.lock();
        assertEq(rangeLiquidity(TickMath.minUsableTick(TICK_SPACING), TickMath.maxUsableTick(TICK_SPACING)), liquidity);
        assertLt(token.balanceOf(address(lock)), 1 ether);
        assertLt(imd.balanceOf(address(lock)), 1 ether);
        // A second lock adds to the same position.
        token.transfer(address(lock), 1_000 ether);
        imd.mint(address(lock), 1_000 ether);
        uint128 more = lock.lock();
        assertEq(
            rangeLiquidity(TickMath.minUsableTick(TICK_SPACING), TickMath.maxUsableTick(TICK_SPACING)), liquidity + more
        );
    }

    function test_lockedLiquidityCannotBeRemoved() public {
        seedBalanced(1_000_000 ether);
        token.transfer(address(lock), 10_000 ether);
        imd.mint(address(lock), 10_000 ether);
        lock.lock();
        string[4] memory signatures = ["unlock()", "withdraw()", "removeLiquidity(uint128)", "collect()"];
        for (uint256 i = 0; i < signatures.length; i++) {
            (bool ok,) = address(lock).call(abi.encodeWithSignature(signatures[i], uint128(1)));
            assertFalse(ok, signatures[i]);
        }
        vm.expectRevert(DeezLiquidityLock.NotPoolManager.selector);
        lock.unlockCallback("");
    }
}

contract DeezLiquidityLockToken0Test is DeezLiquidityLockTests {
    function wantTokenIsCurrency0() internal pure override returns (bool) {
        return true;
    }
}

contract DeezLiquidityLockToken1Test is DeezLiquidityLockTests {
    function wantTokenIsCurrency0() internal pure override returns (bool) {
        return false;
    }
}
