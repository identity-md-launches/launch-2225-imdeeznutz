// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice The slice of the launch token the distributor reads.
interface IDeezToken is IERC20 {
    function getPastBalanceOf(address account, uint256 timepoint) external view returns (uint256);
}

/// @title DEEZ holder rewards
/// @notice Pays every $DEEZ holder its share of the trading fees the hook collects, in $IMD, weighted strictly
/// by the balance it held at the end of each daily epoch. No owner, no admin, no top-N cutoff.
///
/// How the math works, per epoch `e` (a UTC day, `[e * EPOCH_LENGTH, (e + 1) * EPOCH_LENGTH)`):
///   - Every $IMD that reaches this contract while epoch `e` is current, through the hook's `harvest()` or a
///     plain transfer, is credited to `pots[e].total` the next time anyone calls `accrue()`.
///   - `snapshotOf(e)` is the last second of the epoch. Balances at that second are final once the next epoch
///     has begun, and come from the token's own checkpoint history.
///   - `eligibleSupply(e)` = total supply minus the balances of the four excluded addresses at the snapshot:
///     the PoolManager (the pool's liquidity), the burn address, the hook and this contract.
///   - `claimable(account, e)` = `pots[e].total * balanceAt(account, snapshot) / eligibleSupply(e)`.
///   - Anyone may call `claim` for any account; the payout always goes to that account.
///   - A share not claimed within `CLAIM_WINDOW` epochs is recycled into the current epoch's pot, so nothing is
///     stranded by holders who never claim (the burn-adjacent dust, abandoned wallets, the swarm's Merkle
///     distributor while its allocation sits unclaimed).
contract DeezRewards is ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Pot {
        /// @dev $IMD credited to the epoch.
        uint128 total;
        /// @dev $IMD already paid out of it.
        uint128 claimed;
        /// @dev Total supply minus excluded balances at the snapshot; 0 until finalized.
        uint256 eligibleSupply;
        /// @dev Whether the unclaimed remainder was recycled; no claims after that.
        bool closed;
    }

    /// @notice Length of one reward epoch.
    uint256 public constant EPOCH_LENGTH = 1 days;
    /// @notice Epochs a share stays claimable before `recycle` may fold it into the current pot.
    uint256 public constant CLAIM_WINDOW = 365;
    /// @notice The conventional burn address, excluded from rewards.
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    /// @notice The launch token whose holders are paid.
    IDeezToken public immutable token;
    /// @notice The token rewards are paid in ($IMD, the pool's pair currency).
    IERC20 public immutable rewardToken;
    /// @notice The Uniswap v4 PoolManager: it holds the pool's $DEEZ, so it is excluded.
    address public immutable poolManager;
    /// @notice The fee hook that feeds this contract; excluded as well.
    address public immutable hook;

    /// @notice Reward token already assigned to pots (claimed or not); anything above it is new.
    uint256 public reserved;
    /// @notice Per-epoch accounting.
    mapping(uint256 epoch => Pot) public pots;
    /// @notice Whether `account` has claimed epoch `epoch`.
    mapping(uint256 epoch => mapping(address account => bool)) public claimed;

    event Accrued(uint256 indexed epoch, uint256 amount);
    event Finalized(uint256 indexed epoch, uint256 eligibleSupply);
    event Claimed(uint256 indexed epoch, address indexed account, uint256 amount);
    event Recycled(uint256 indexed epoch, uint256 indexed intoEpoch, uint256 amount);

    error ZeroAddress();
    error EpochNotEnded(uint256 epoch);
    error EpochClosed(uint256 epoch);
    error AlreadyClaimed(uint256 epoch, address account);
    error Excluded(address account);
    error NothingToClaim();
    error ClaimWindowOpen(uint256 epoch);

    constructor(address token_, address rewardToken_, address poolManager_, address hook_) {
        if (token_ == address(0) || rewardToken_ == address(0) || poolManager_ == address(0) || hook_ == address(0)) {
            revert ZeroAddress();
        }
        token = IDeezToken(token_);
        rewardToken = IERC20(rewardToken_);
        poolManager = poolManager_;
        hook = hook_;
    }

    // ---------------------------------------------------------------- views

    /// @notice The epoch `block.timestamp` falls in.
    function currentEpoch() public view returns (uint256) {
        return block.timestamp / EPOCH_LENGTH;
    }

    /// @notice The last second of epoch `epoch`: balances at this timepoint decide its shares.
    function snapshotOf(uint256 epoch) public pure returns (uint256) {
        return (epoch + 1) * EPOCH_LENGTH - 1;
    }

    /// @notice Whether epoch `epoch` has ended, i.e. its snapshot balances are final.
    function hasEnded(uint256 epoch) public view returns (bool) {
        return block.timestamp > snapshotOf(epoch);
    }

    /// @notice Addresses that hold $DEEZ but never earn: the pool, the burn address, the hook and this contract.
    function isExcluded(address account) public view returns (bool) {
        return account == poolManager || account == BURN_ADDRESS || account == hook || account == address(this)
            || account == address(0);
    }

    /// @notice Total supply minus the excluded balances at the end of `epoch` (reverts until the epoch ended).
    function eligibleSupplyAt(uint256 epoch) public view returns (uint256) {
        uint256 snapshot = snapshotOf(epoch);
        uint256 excluded = token.getPastBalanceOf(poolManager, snapshot)
            + token.getPastBalanceOf(BURN_ADDRESS, snapshot) + token.getPastBalanceOf(hook, snapshot)
            + token.getPastBalanceOf(address(this), snapshot);
        return token.totalSupply() - excluded;
    }

    /// @notice What `account` can still claim for `epoch`; zero if not ended, already claimed, closed or excluded.
    function claimable(address account, uint256 epoch) public view returns (uint256) {
        if (!hasEnded(epoch) || claimed[epoch][account] || isExcluded(account)) return 0;
        Pot storage pot = pots[epoch];
        if (pot.closed || pot.total == 0) return 0;
        uint256 supply = pot.eligibleSupply == 0 ? eligibleSupplyAt(epoch) : pot.eligibleSupply;
        if (supply == 0) return 0;
        return uint256(pot.total) * token.getPastBalanceOf(account, snapshotOf(epoch)) / supply;
    }

    /// @notice Sum of `claimable` over `epochs`.
    function claimableMany(address account, uint256[] calldata epochs) external view returns (uint256 total) {
        for (uint256 i = 0; i < epochs.length; i++) {
            total += claimable(account, epochs[i]);
        }
    }

    // ------------------------------------------------------------- mutations

    /// @notice Credit every reward token received since the last call to the current epoch's pot.
    /// @dev Permissionless. The hook calls it after each `harvest()`; anyone may donate $IMD and call it.
    function accrue() public returns (uint256 amount) {
        uint256 balance = rewardToken.balanceOf(address(this));
        uint256 reserved_ = reserved;
        if (balance <= reserved_) return 0;
        amount = balance - reserved_;
        uint256 epoch = currentEpoch();
        pots[epoch].total += uint128(amount);
        reserved = balance;
        emit Accrued(epoch, amount);
    }

    /// @notice Record the eligible supply of an ended epoch so later claims do not recompute it.
    function finalize(uint256 epoch) public returns (uint256 supply) {
        Pot storage pot = pots[epoch];
        if (pot.eligibleSupply != 0) return pot.eligibleSupply;
        if (!hasEnded(epoch)) revert EpochNotEnded(epoch);
        supply = eligibleSupplyAt(epoch);
        pot.eligibleSupply = supply;
        emit Finalized(epoch, supply);
    }

    /// @notice Pay `account` its share of each epoch in `epochs`. Anyone may call this for anyone.
    /// @dev Accrues first so a harvest and a claim in the same block never miss each other. Reverts when the
    /// whole batch pays nothing, so a stale or duplicate claim is visible instead of silently succeeding.
    function claim(address account, uint256[] calldata epochs) external nonReentrant returns (uint256 total) {
        if (isExcluded(account)) revert Excluded(account);
        accrue();
        for (uint256 i = 0; i < epochs.length; i++) {
            uint256 epoch = epochs[i];
            Pot storage pot = pots[epoch];
            if (pot.closed) revert EpochClosed(epoch);
            if (claimed[epoch][account]) revert AlreadyClaimed(epoch, account);
            uint256 supply = finalize(epoch);
            claimed[epoch][account] = true;
            if (pot.total == 0 || supply == 0) continue;
            uint256 amount = uint256(pot.total) * token.getPastBalanceOf(account, snapshotOf(epoch)) / supply;
            if (amount == 0) continue;
            pot.claimed += uint128(amount);
            total += amount;
            emit Claimed(epoch, account, amount);
        }
        if (total == 0) revert NothingToClaim();
        reserved -= total;
        rewardToken.safeTransfer(account, total);
    }

    /// @notice Fold what was never claimed for `epoch` into the current epoch, once `CLAIM_WINDOW` epochs passed.
    function recycle(uint256 epoch) external returns (uint256 amount) {
        Pot storage pot = pots[epoch];
        if (pot.closed) revert EpochClosed(epoch);
        if (currentEpoch() < epoch + CLAIM_WINDOW + 1) revert ClaimWindowOpen(epoch);
        pot.closed = true;
        amount = pot.total - pot.claimed;
        if (amount == 0) return 0;
        uint256 into = currentEpoch();
        pots[into].total += uint128(amount);
        emit Recycled(epoch, into, amount);
    }
}
