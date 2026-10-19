// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

/// @notice The slice of the hook the lock reads.
interface IDeezHookForLock {
    function poolKey() external view returns (PoolKey memory);
    function initialized() external view returns (bool);
}

/// @title Permanent liquidity lock for the $DEEZ/$IMD pool
/// @notice Anyone may send $DEEZ and/or $IMD here and call `lock()`: the balances become a liquidity position in
/// the launch pool that this contract owns and that nothing can ever withdraw. There is no owner, no remove
/// function and no way to collect the position's LP fees: they compound into the pool for every trader.
///
/// This is how the requester's 1% of supply (10,000,000 $DEEZ) is made permanent liquidity: transfer it here and
/// call `lock()`. Both tokens present: a full-range position. $DEEZ only: a position in the range just above the
/// current price (a permanent sell-side depth). $IMD only: a position just below the price (a permanent buy wall).
contract DeezLiquidityLock is IUnlockCallback {
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;

    IPoolManager public immutable poolManager;
    IDeezHookForLock public immutable hook;

    /// @notice Liquidity this contract has locked, by position range.
    mapping(bytes32 rangeId => uint128 liquidity) public lockedLiquidity;
    /// @notice Total $DEEZ and $IMD ever locked, for display.
    uint256 public totalLocked0;
    uint256 public totalLocked1;

    event Locked(int24 tickLower, int24 tickUpper, uint128 liquidity, uint256 amount0, uint256 amount1);

    error NotPoolManager();
    error PoolNotInitialized();
    error NothingToLock();
    error ZeroAddress();

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    constructor(IPoolManager poolManager_, address hook_) {
        if (address(poolManager_) == address(0) || hook_ == address(0)) revert ZeroAddress();
        poolManager = poolManager_;
        hook = IDeezHookForLock(hook_);
    }

    /// @notice Turn every token this contract holds into locked liquidity in the launch pool.
    /// @return liquidity The liquidity added.
    function lock() external returns (uint128 liquidity) {
        if (!hook.initialized()) revert PoolNotInitialized();
        PoolKey memory key = hook.poolKey();
        uint256 balance0 = IERC20(Currency.unwrap(key.currency0)).balanceOf(address(this));
        uint256 balance1 = IERC20(Currency.unwrap(key.currency1)).balanceOf(address(this));
        if (balance0 == 0 && balance1 == 0) revert NothingToLock();

        (uint160 sqrtPriceX96, int24 tick,,) = poolManager.getSlot0(key.toId());
        int24 spacing = key.tickSpacing;
        int24 tickLower = TickMath.minUsableTick(spacing);
        int24 tickUpper = TickMath.maxUsableTick(spacing);
        if (balance1 == 0) {
            // Token0 only: the whole position must sit above the current price.
            tickLower = _ceilToSpacing(tick + 1, spacing);
            if (tickLower >= tickUpper) tickLower = tickUpper - spacing;
        } else if (balance0 == 0) {
            // Token1 only: the whole position must sit at or below the current price.
            tickUpper = _floorToSpacing(tick, spacing);
            if (tickUpper <= tickLower) tickUpper = tickLower + spacing;
        }
        liquidity = _liquidityFor(sqrtPriceX96, tickLower, tickUpper, balance0, balance1);
        if (liquidity == 0) revert NothingToLock();

        bytes memory out = poolManager.unlock(abi.encode(key, tickLower, tickUpper, liquidity));
        (uint256 amount0, uint256 amount1) = abi.decode(out, (uint256, uint256));
        lockedLiquidity[keccak256(abi.encode(tickLower, tickUpper))] += liquidity;
        totalLocked0 += amount0;
        totalLocked1 += amount1;
        emit Locked(tickLower, tickUpper, liquidity, amount0, amount1);
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        (PoolKey memory key, int24 tickLower, int24 tickUpper, uint128 liquidity) =
            abi.decode(data, (PoolKey, int24, int24, uint128));
        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: int256(uint256(liquidity)), salt: bytes32(0)
            }),
            ""
        );
        uint256 amount0 = _settle(key.currency0, delta.amount0());
        uint256 amount1 = _settle(key.currency1, delta.amount1());
        return abi.encode(amount0, amount1);
    }

    function _settle(Currency currency, int128 amount) private returns (uint256 paid) {
        if (amount >= 0) return 0;
        paid = uint256(uint128(-amount));
        poolManager.sync(currency);
        IERC20(Currency.unwrap(currency)).safeTransfer(address(poolManager), paid);
        poolManager.settle();
    }

    /// @dev The largest liquidity both balances can fund in the range, shaved by one part in a million so the
    /// PoolManager's round-up on the amounts owed never exceeds what is held.
    function _liquidityFor(uint160 sqrtPriceX96, int24 tickLower, int24 tickUpper, uint256 amount0, uint256 amount1)
        internal
        pure
        returns (uint128)
    {
        uint160 sqrtA = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtB = TickMath.getSqrtPriceAtTick(tickUpper);
        uint256 liquidity;
        if (sqrtPriceX96 <= sqrtA) {
            liquidity = _liquidityForAmount0(sqrtA, sqrtB, amount0);
        } else if (sqrtPriceX96 < sqrtB) {
            uint256 l0 = _liquidityForAmount0(sqrtPriceX96, sqrtB, amount0);
            uint256 l1 = _liquidityForAmount1(sqrtA, sqrtPriceX96, amount1);
            liquidity = l0 < l1 ? l0 : l1;
        } else {
            liquidity = _liquidityForAmount1(sqrtA, sqrtB, amount1);
        }
        liquidity -= liquidity / 1_000_000;
        if (liquidity > type(uint128).max) liquidity = type(uint128).max;
        return uint128(liquidity);
    }

    function _liquidityForAmount0(uint160 sqrtA, uint160 sqrtB, uint256 amount0) internal pure returns (uint256) {
        uint256 intermediate = FullMath.mulDiv(sqrtA, sqrtB, FixedPoint96.Q96);
        return FullMath.mulDiv(amount0, intermediate, sqrtB - sqrtA);
    }

    function _liquidityForAmount1(uint160 sqrtA, uint160 sqrtB, uint256 amount1) internal pure returns (uint256) {
        return FullMath.mulDiv(amount1, FixedPoint96.Q96, sqrtB - sqrtA);
    }

    function _floorToSpacing(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 q = tick / spacing;
        if (tick < 0 && tick % spacing != 0) q--;
        return q * spacing;
    }

    function _ceilToSpacing(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 floored = _floorToSpacing(tick, spacing);
        return floored == tick ? tick : floored + spacing;
    }
}
