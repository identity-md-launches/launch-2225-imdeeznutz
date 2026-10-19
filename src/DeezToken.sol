// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Checkpoints} from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";

/// @title IMDeezNutz ($DEEZ)
/// @notice Fixed-supply ERC-20 for the IMDeezNutz launch: 1,000,000,000 tokens at 18 decimals, minted once to
/// the deployer (the IMD launch factory). No owner, no mint, no burn function, no pause, no blocklist, no
/// transfer tax and no upgrade path: every transfer moves exactly what it was asked to move.
/// @dev The only addition to a plain ERC-20 is a per-account balance history keyed by block timestamp. The
/// rewards distributor reads `getPastBalanceOf` to pay each holder exactly in proportion to the balance it held
/// at the end of an epoch, so no registration, staking or admin snapshot is ever needed. A checkpoint is one
/// extra storage write per side of a transfer; nothing else changes.
contract DeezToken is ERC20 {
    using Checkpoints for Checkpoints.Trace208;

    /// @notice The whole supply, minted once in the constructor.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 ether;

    /// @notice A balance was requested for a timepoint that is not final yet.
    error FutureLookup(uint48 timepoint, uint48 clock);

    mapping(address account => Checkpoints.Trace208) private _history;

    constructor() ERC20("IMDeezNutz", "DEEZ") {
        _mint(msg.sender, TOTAL_SUPPLY);
    }

    /// @notice The clock the balance history is keyed by (EIP-6372): block timestamps.
    function clock() public view returns (uint48) {
        return uint48(block.timestamp);
    }

    /// @notice EIP-6372 clock description.
    // solhint-disable-next-line func-name-mixedcase
    function CLOCK_MODE() external pure returns (string memory) {
        return "mode=timestamp";
    }

    /// @notice The balance `account` held at the end of second `timepoint`.
    /// @dev Reverts while `timepoint` is the current second or later, because that balance can still change.
    function getPastBalanceOf(address account, uint256 timepoint) external view returns (uint256) {
        uint48 now_ = clock();
        if (timepoint >= now_) revert FutureLookup(uint48(timepoint), now_);
        return _history[account].upperLookupRecent(uint48(timepoint));
    }

    /// @notice Number of checkpoints recorded for `account`.
    function numCheckpoints(address account) external view returns (uint256) {
        return _history[account].length();
    }

    /// @notice The `pos`-th checkpoint of `account`: the timestamp it was written at and the balance since.
    function checkpointAt(address account, uint32 pos) external view returns (uint48 timepoint, uint256 balance) {
        Checkpoints.Checkpoint208 memory c = _history[account].at(pos);
        return (c._key, c._value);
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        uint48 now_ = clock();
        if (from != address(0)) _history[from].push(now_, uint208(balanceOf(from)));
        if (to != address(0)) _history[to].push(now_, uint208(balanceOf(to)));
    }
}
