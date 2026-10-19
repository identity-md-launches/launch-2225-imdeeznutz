# IMDeezNutz ($DEEZ) — Uniswap v4 hook launch on Ethereum

A custom-token / `univ4_hook` launch: a fixed-supply ERC-20, a Uniswap v4 hook that takes exactly 2% of
every buy and sell on the $DEEZ/$IMD pool, and a permissionless distributor that pays that 2% to every
holder in $IMD, weighted strictly by balance. No contract has an owner, an admin function, a pause or an
upgrade path.

| Contract            | Solidity name       | Deployed by                   | Purpose                                                                 |
| ------------------- | ------------------- | ----------------------------- | ----------------------------------------------------------------------- |
| `src/DeezToken.sol` | `DeezToken`         | the launch factory            | $DEEZ: 1,000,000,000 × 10^18 minted once to `msg.sender` (the factory)  |
| `src/DeezHook.sol`  | `DeezHook`          | the launch factory            | the 2% fee on the $IMD side of every swap, held as ERC-6909 claims      |
| `src/DeezRewards.sol` | `DeezRewards`     | `DeezHook`'s constructor      | daily-epoch $IMD rewards weighted by average balance; `hook.rewards()`  |
| `src/DeezLiquidityLock.sol` | `DeezLiquidityLock` | `DeezHook`'s constructor | permanent, un-withdrawable liquidity for the pool; `hook.liquidityLock()` |

The launch deploys exactly two contracts (token and hook); the distributor and the lock are created by the
hook's constructor and exposed through getters, as the launch rules require.

## Launch parameters (for the manifest step)

- Chain: Ethereum mainnet (chain id 1).
- Pair: $IMD, `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7` (18 decimals). Verified on mainnet on
  2026-10-19: `symbol()` returns `IMD`, `decimals()` returns 18, and its verified source is an OpenZeppelin
  ERC-20 / LayerZero OFT (`BridgedFP`) with standard transfers, so moving it out of the PoolManager works.
- Pool: fee 12500 (1.25%), tick spacing 60; the deployer sets the opening price. The hook accepts any fee
  and spacing on its one pool, so the listed tier is never refused.
- `DeezToken` constructor: no arguments.
- `DeezHook` constructor (3 arguments, all whole values):
  1. `poolManager_` → `"$poolManager"`
  2. `token_` → `"$token"`
  3. `pairedCurrency_` → `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7` ($IMD)
- Hook flags (mined into the address): `beforeInitialize | beforeSwap | afterSwap | beforeSwapReturnDelta |
  afterSwapReturnDelta` = `0x20CC` (8396). `getHookPermissions()` returns exactly these.
- No owner argument anywhere: nothing in this launch has an owner, so `$owner`
  (`0xb04548fac7e1505c7c0179d2af59f76c3018d003`) is only the wallet that receives the requester's 2%.
- `foundry.toml`: `solc = "0.8.26"`, `evm_version = "cancun"`, `via_ir = true`, `optimizer_runs = 44444444`,
  `bytecode_hash = "none"`, `ffi = false`, no `fs_permissions`.

## How it works

### The token (`DeezToken`)

Plain OpenZeppelin ERC-20, name `IMDeezNutz`, symbol `DEEZ`, 18 decimals, `1e27` minor units minted to the
deployer in the constructor. No mint, burn, owner, pause, blocklist, fee or proxy. The single addition is a
balance history: every transfer writes one timestamp-keyed checkpoint (one storage slot) for the sender and
the receiver, holding the balance from that second on and the balance integrated over all earlier seconds in
wei-days (`CUMULATIVE_UNIT = 1 days`). `getPastBalanceOf(account, t)` returns the balance held at the end
of second `t`; `getCumulativeBalanceOf(account, t)` the wei-days accumulated before `t`, so the difference
over a one-day epoch is the account's *average balance* that day; `getCumulativeTotalSupply(t)` the same for
the whole supply (`TOTAL_SUPPLY × (t − mintedAt) / 1 days`). This is what lets rewards be weighted by the
balance actually held, for the time it was held, with no staking, no registration and no admin snapshot.
The brief's "no transfer taxes outside the trading fee" holds: the fee lives entirely in the hook.

### The hook (`DeezHook`)

Takes `FEE_BPS = 200` (2.00%) of the $IMD side of every swap on its pool, and nothing from $DEEZ:

| Swap                          | Where the fee is computed | Formula                                              | Effect on the trader                                     |
| ----------------------------- | ------------------------- | ---------------------------------------------------- | -------------------------------------------------------- |
| Buy, exact input ($IMD in)    | `beforeSwap` (specified)  | `fee = in × 2%`                                      | pays `in`; the pool receives `in − fee`                  |
| Buy, exact output ($DEEZ out) | `afterSwap` (unspecified) | `fee = poolCharge × 2 / 98`                          | receives exactly `out`; pays `poolCharge + fee`          |
| Sell, exact input ($DEEZ in)  | `afterSwap` (unspecified) | `fee = poolPayout × 2%`                              | pays `in`; receives `poolPayout − fee`                   |
| Sell, exact output ($IMD out) | `beforeSwap` (specified)  | `fee = out × 2 / 98`                                 | receives exactly `out`; the pool pays `out + fee`        |

In every case the fee is 2.00% of the gross $IMD that changes hands (to one wei of rounding). The fee is
returned as a hook delta (`beforeSwapReturnDelta` / `afterSwapReturnDelta`) and, in `afterSwap`, minted to
the hook as an ERC-6909 claim on the PoolManager (`poolManager.mint`). A claim needs no token balance in
the PoolManager, so the first buy on the launch pool, which holds only $DEEZ, works, and no recipient can
ever make a fee-bearing swap revert.

**Partial fills.** In the two $IMD-specified cases the fee is taken in `beforeSwap` from the *requested*
amount, before the pool has traded. If the pool then fills less than the request (the trader's
`sqrtPriceLimitX96` is reached, or an exact-output sell asks for more $IMD than the pool holds, the normal
case on a launch pool seeded with $DEEZ only), that fee would be more than 2% of what actually traded, and
on a sell the trader could end up paying $IMD and receiving nothing. `afterSwap` therefore compares the
realised $IMD delta with what `beforeSwap` assumed (`in − fee` on an exact-input buy, `out + fee` on an
exact-output sell) and reverts the whole swap with `PartialFill(expected, actual)` on any mismatch. Nothing
is charged. The two $DEEZ-specified cases read the realised delta and are charged correctly on partial
fills. Routers built on v4-periphery's `V4Router` pass the extreme price limit and enforce slippage with
`amountOutMinimum` / `amountInMaximum`, so they only hit `PartialFill` when the pool genuinely cannot fill
the order, which is when the trade should not go through anyway.

**Epoch attribution.** Each fee is recorded against the reward epoch the trade happens in
(`pendingFeesOf(epoch)`; `FeeTaken(buy, epoch, amount)`). `harvest()` (anyone) harvests the current and the
previous epoch: it unlocks the manager, burns the claims, takes the $IMD into `DeezRewards` and calls
`credit(epoch, amount)` for each, so a fee always lands in the pot of the day it was traded, whoever
harvests and whenever. `harvestEpochs(uint256[])` does the same for any older epochs still pending.

`beforeInitialize` accepts exactly one pool, the first one initialized, and only if its currencies are
`{ $DEEZ, $IMD }`; any fee tier and tick spacing the factory chooses is accepted. Every callback checks
`msg.sender == poolManager`. The hook declares no liquidity callbacks, so the launch factory's fee collect
(a zero liquidity change) is never touched and can never be blocked.

### The distributor (`DeezRewards`)

- `EPOCH_LENGTH = 1 days`; epoch `e` is `[e·86400, (e+1)·86400)`; `snapshotOf(e) = (e+1)·86400 − 1` is its
  last second, after which its weights are final (`hasEnded(e)`).
- `credit(e, amount)` (hook only) credits $IMD the hook has just delivered to the pot of epoch `e`, the
  epoch the fees were traded in. `accrue()` (anyone) credits any other $IMD received, such as a donation,
  to the current epoch. A credit to an epoch already recycled goes to the current epoch instead.
- `weightOf(account, e)` = the account's average $DEEZ balance over epoch `e`, in wei:
  `getCumulativeBalanceOf(account, end) − getCumulativeBalanceOf(account, start)`. A wallet that held 100
  $DEEZ all day weighs 100; one that held 100 for the last second weighs 100 / 86,400.
- `eligibleSupplyAt(e) = averageTotalSupply − weightOf(PoolManager) − weightOf(0x…dEaD) − weightOf(hook) −
  weightOf(rewards)` over the epoch. The PoolManager is where the pool's $DEEZ lives (Uniswap v4 is a
  singleton), so "the pool / LP position" is excluded as the brief asks.
- `claimable(account, e) = pots[e].total × weightOf(account, e) / eligibleSupplyAt(e)`. Bigger bags get
  proportionally more; there is no cutoff and no minimum. A share is capped at what is left in the pot, so
  the per-checkpoint rounding of the token's cumulative balances (one wei-day per segment) can never make
  the pot pay out more than it holds.
- `claim(account, epochs[])` pays `account` for each listed ended epoch and may only be called by `account`
  itself (`NotAccount` otherwise), so no third party can push a share into a contract that cannot move it.
  Double claims, excluded addresses, un-ended epochs and empty claims revert.
- `recycle(e)`, after `CLAIM_WINDOW = 90` epochs, folds whatever was never claimed for `e` into the current
  pot and closes `e`. This keeps $IMD from being stranded by holders that never claim (abandoned wallets,
  contracts that hold $DEEZ but have no way to call `claim`, such as the swarm's Merkle distributor while its
  allocation sits there, rounding dust). With weights by average balance, nobody can snipe the recycled
  pot either: it is shared by whoever holds through the day it is recycled into.

### The liquidity lock (`DeezLiquidityLock`)

Anyone can send $DEEZ and/or $IMD to it and call `lockAs(mode, minTick, maxTick)`: `Token0Only` /
`Token1Only` lock only that token's balance (the other side is ignored, so 1 wei of it sent by a stranger
changes nothing) in the range just above / at or below the current price (permanent sell-side depth / a
permanent buy wall); `FullRange` locks both in a full-range position, as much as the scarcer side funds,
and the rest can be locked single-sided with a second call in the same transaction; `Auto` picks a mode
from the balances. The call reverts with `TickOutOfBounds` unless the pool's current tick is within
`[minTick, maxTick]`, so a price move in the same block cannot change where the position lands. `lock()` is
`lockAs(Auto, MIN_TICK, MAX_TICK)`. The position is owned by the lock, which has no remove function, no
owner and no fee collection, so the liquidity and its LP fees stay in the pool forever.

## After launch (operational responsibilities)

1. **Requester's 2% (20,000,000 $DEEZ) → at least 1% locked.** From the wallet that received the 2%
   (`$owner`), transfer ≥ 10,000,000 $DEEZ to `hook.liquidityLock()` and call
   `lockAs(Token0Only or Token1Only, minTick, maxTick)` (the side $DEEZ sorts on: `hook.tokenIsCurrency0()`)
   with a tick bound around the current price, ideally both in one transaction or private bundle, so that
   nobody can change the position by sending dust or moving the price between the two steps. To lock a
   balanced position instead, send $IMD alongside and use `FullRange`; to add a buy wall, send $IMD alone
   and use the $IMD side's mode. The lock is permanent: do not send anything you want back. The rest of
   the 2% is the requester's to keep or lock. No contract enforces this step: the factory sends the whole 2%
   to the paying wallet and nothing here may be allocated supply at launch, so it is the requester's
   commitment, verifiable afterwards through `lockedLiquidity` / `totalLocked0` / `totalLocked1`.
2. **Harvest and claim.** `DeezHook.harvest()` / `harvestEpochs(epochs)`, `DeezRewards.accrue()` and
   `DeezRewards.recycle(epoch)` are permissionless; `DeezRewards.claim(holder, epochs)` is called by the
   holder. Nothing runs by itself: somebody (any holder, a keeper, the site's buttons) has to send those
   transactions. A claim for an epoch needs the epoch to have ended (UTC day boundary). Fees not harvested
   within a day of trading are still credited to their own epoch; `harvestEpochs` picks them up.
3. **Website.** `site/` is a static single page (`index.html`, `deez.config.js`, `logo.svg`). Fill
   `deez.config.js` with the launched addresses, the pool id, the launch tx and the Uniswap / DexScreener
   URLs, then publish the folder to sites.imd.fun (or pin to IPFS and point an ENS name at it). The page
   shows "announced at launch" for any field left empty, and its claim widget talks to the wallet's own
   provider (no third-party RPC, no library).
4. **Explorer verification** of the two launched contracts and the two hook-created ones is the deployer's
   step (`forge verify-contract` with this repository's settings).

## What the brief asked that the launch does not do, and why

- *Mint the supply split / allocate to swarm, pool, requester.* The factory does all of it: 10% to the
  swarm's Merkle distributor, 88% into the pool, 2% to the paying wallet. No contract here receives supply
  at launch.
- *Settle the hook fee in ETH.* The default for IMD hook launches is to sell the fee for ETH inside the
  swap. The brief says otherwise ("rewards should preferably be paid in $IMD"), so the fee stays in $IMD,
  the pair currency, and is paid out in $IMD. No ETH market, no price bound, no owner-set parameter.
- *Deploy, return addresses, transaction hashes, website URL.* IMD's deployer launches through the factory
  after review; this job builds what it deploys. The site reads addresses from `deez.config.js`.
- *Top-N cutoff.* None. Every non-excluded wallet, however small, has a claimable share (it may round to
  zero wei only when the balance is below one part in `pot` of the eligible supply).

## Decisions the brief left open (named constants)

| Constant              | Where                      | Value | Reason                                                              |
| --------------------- | -------------------------- | ----- | ------------------------------------------------------------------- |
| `FEE_BPS`             | `DeezHook`                 | 200   | the brief's "exactly 2%"                                            |
| `EPOCH_LENGTH`        | `DeezRewards`              | 1 day | one claim per UTC day keeps claims gas-cheap and the math simple    |
| `CLAIM_WINDOW`        | `DeezRewards`              | 90    | 90 days to claim before an epoch's remainder is recycled: long enough for any holder, short enough that the share of contracts that cannot claim (the swarm distributor's 10% at launch) returns to holders within a quarter |
| `CUMULATIVE_UNIT`     | `DeezToken`                | 1 day | cumulative balances in wei-days, so an epoch weight is an average balance in wei; `uint120` holds the full supply for 3.6 million years |
| `BURN_ADDRESS`        | `DeezRewards`              | 0x…dEaD | the conventional burn address; `address(0)` can never hold tokens |
| liquidity shave       | `DeezLiquidityLock`        | 1 ppm | guarantees the PoolManager's round-up never exceeds the balance held |

## Hook configuration record (OpenZeppelin Wizard shape)

```json
{
  "hook": "BaseHook",
  "name": "DeezHook",
  "pausable": false,
  "currencySettler": false,
  "safeCast": true,
  "transientStorage": false,
  "shares": { "options": false },
  "permissions": {
    "beforeInitialize": true, "afterInitialize": false,
    "beforeAddLiquidity": false, "beforeRemoveLiquidity": false,
    "afterAddLiquidity": false, "afterRemoveLiquidity": false,
    "beforeSwap": true, "afterSwap": true,
    "beforeDonate": false, "afterDonate": false,
    "beforeSwapReturnDelta": true, "afterSwapReturnDelta": true,
    "afterAddLiquidityReturnDelta": false, "afterRemoveLiquidityReturnDelta": false
  },
  "inputs": {},
  "access": "none",
  "info": { "license": "MIT" }
}
```

Callbacks added beyond the brief's wording: `beforeInitialize` (required for IMD launches: the factory
deploys the hook and opens the pool in one transaction, and the callback pins the hook to its one pool);
`beforeSwapReturnDelta` and `afterSwapReturnDelta` (the fee on the specified and unspecified side
respectively, so exact-input and exact-output swaps are both charged). The hook is written directly against
`IHooks` and v4-core (no v4-periphery dependency); `Hooks.validateHookPermissions` runs in the constructor.
`beforeSwapReturnDelta` is justified: the only delta the hook ever returns is the 2% fee it mints to itself,
never the swap amount, and `HookDeltaExceedsSwapAmount` in v4-core bounds it.

## Security notes and trust assumptions

- No owner, no admin, no upgrade, no `selfdestruct`/`delegatecall` in any runtime (checked by the floor).
- Every hook callback and both `unlockCallback`s require `msg.sender == poolManager`.
- Delta accounting: the hook's delta per swap is `+fee` (returned) and `−fee` (minted claim) = 0. Harvest
  burns `+amount` and takes `−amount` = 0. Tests assert the claims are fully backed by $IMD.
- Reentrancy: `claim` is `nonReentrant`; the hook holds no tokens; the lock's `unlockCallback` is
  manager-only. $IMD is a standard OFT ERC-20 without transfer callbacks.
- The reward token is $IMD, whose contract is owned by its own project (LayerZero OFT admin). If $IMD ever
  froze transfers, fee-bearing swaps would still succeed (the fee is a claim), harvest and claims would wait.
- The swarm's Merkle distributor holds up to 10% of supply and is not excluded: its address is unknown at
  build time, the brief does not exclude it, and the factory exposes no interface this tree could read it
  from safely (a wrong selector in `finalize` would brick every claim). Its share can only be claimed by the
  distributor itself (`claim` is self-only), so nobody can strand it there, and whatever it never claims is
  recycled to holders after `CLAIM_WINDOW` (90) epochs. The launch factory's own position is in the
  PoolManager and therefore excluded.
- Only the holder can claim its own share. A contract holding $DEEZ (another DEX pool, a locker, a vault, a
  CEX wallet contract) earns a share it can collect only if it can call `claim`; otherwise it is recycled.
- Gas: each $DEEZ transfer writes two one-slot checkpoints (≈ +45k gas on cold slots). `claim` costs a few
  reads per epoch (two binary searches per weight); `claimMany` over many epochs is bounded only by the
  caller's gas.
- Slither/Mythril were not available in this environment; the review in `.imd/reads/skills` checklists was
  applied by hand. An independent adversarial review before launch is the swarm's step, not replaced here.

## Tests

```bash
forge build
FOUNDRY_FUZZ_SEED=0xc0b32088ed4ea538fc6eb66714ec1bd09394ca1049d6a3df1c8591aba01bf9c6 forge test
forge fmt --check
```

113 tests across `test/`: token metadata, supply, transfers, checkpoint history and cumulative (time-
weighted) balances; hook permissions, initialization refusals, caller checks, the four fee cases (both
currency orders, fuzzed), partial fills refused on the $IMD-specified cases and charged correctly on the
$DEEZ-specified ones, a buy on a fresh PoolManager seeded with $DEEZ only, per-epoch harvest, zero-liquidity
collects; distributor accrual and hook credits, proportional and time-weighted claims, self-only claims,
exclusions, double/early/empty claims, recycling, fuzzed conservation with mid-epoch moves; the liquidity
lock in every mode, with dust on the other side and with a tick bound; and end-to-end trade → harvest →
claim flows including the last-second-buyer scenario. The pinned floor suites (hook, owners, token) were
rehearsed locally against the built creation code and pass. `test/mocks/` holds the `MockERC20` and
`Swapper` the floor imports; `src/HookFlags.sol` is the flag library it imports.

## Revision history

Review round 1 (2026-10-19) reopened the work with these findings, all reproduced and fixed here:

- **Fee on partial fills** (high): `afterSwap` now verifies the realised $IMD delta on $IMD-specified
  swaps and reverts with `PartialFill` when the pool filled less than requested, instead of charging the
  up-front fee on the full request.
- **Third-party claims** (high): `claim` is callable only by the account itself; `CLAIM_WINDOW` shortened
  from 365 to 90 epochs so shares of contracts that cannot claim return to holders sooner.
- **Harvest-timed epochs and one-second snapshots** (medium): fees are recorded per epoch in the hook and
  credited to the epoch they were traded in; weights are average balances over the epoch from the token's
  cumulative balance history, not the balance at the last second.
- **Lock mode from mutable state** (low): `lockAs(mode, minTick, maxTick)` with explicit modes and a tick
  bound; `lock()` kept as the convenience form.

Dependencies are vendored as plain files under `lib/` (v4-core at commit `46c6834`, forge-std, OpenZeppelin
Contracts v5.1.0, solmate's `Owned.sol` for v4-core's `ProtocolFees`); no submodules.
