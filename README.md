# IMDeezNutz ($DEEZ) — Uniswap v4 hook launch on Ethereum

A custom-token / `univ4_hook` launch: a fixed-supply ERC-20, a Uniswap v4 hook that takes exactly 2% of
every buy and sell on the $DEEZ/$IMD pool, and a permissionless distributor that pays that 2% to every
holder in $IMD, weighted strictly by balance. No contract has an owner, an admin function, a pause or an
upgrade path.

| Contract            | Solidity name       | Deployed by                   | Purpose                                                                 |
| ------------------- | ------------------- | ----------------------------- | ----------------------------------------------------------------------- |
| `src/DeezToken.sol` | `DeezToken`         | the launch factory            | $DEEZ: 1,000,000,000 × 10^18 minted once to `msg.sender` (the factory)  |
| `src/DeezHook.sol`  | `DeezHook`          | the launch factory            | the 2% fee on the $IMD side of every swap, held as ERC-6909 claims      |
| `src/DeezRewards.sol` | `DeezRewards`     | `DeezHook`'s constructor      | daily-epoch, balance-weighted $IMD rewards; `hook.rewards()`            |
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
balance history: every transfer writes a timestamp-keyed checkpoint for the sender and the receiver
(OpenZeppelin `Checkpoints.Trace208`), and `getPastBalanceOf(account, timepoint)` returns the balance held
at the end of that second. This is what lets rewards be weighted by *actual* balances with no staking, no
registration and no admin snapshot. The brief's "no transfer taxes outside the trading fee" holds: the fee
lives entirely in the hook.

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
ever make a fee-bearing swap revert. `harvest()` (anyone) unlocks the manager, burns the claims, takes the
$IMD into `DeezRewards` and credits the current epoch.

`beforeInitialize` accepts exactly one pool, the first one initialized, and only if its currencies are
`{ $DEEZ, $IMD }`; any fee tier and tick spacing the factory chooses is accepted. Every callback checks
`msg.sender == poolManager`. The hook declares no liquidity callbacks, so the launch factory's fee collect
(a zero liquidity change) is never touched and can never be blocked.

### The distributor (`DeezRewards`)

- `EPOCH_LENGTH = 1 days`; epoch `e` is `[e·86400, (e+1)·86400)`; `snapshotOf(e) = (e+1)·86400 − 1`.
- `accrue()` credits any $IMD received since the last call to the current epoch's pot. The hook calls it
  after each harvest; anyone may donate $IMD and call it.
- `eligibleSupplyAt(e) = totalSupply − balanceAt(PoolManager) − balanceAt(0x…dEaD) − balanceAt(hook) −
  balanceAt(rewards)` at the snapshot. The PoolManager is where the pool's $DEEZ lives (Uniswap v4 is a
  singleton), so "the pool / LP position" is excluded as the brief asks.
- `claimable(account, e) = pots[e].total × balanceAt(account, snapshot) / eligibleSupplyAt(e)`. Bigger bags
  get proportionally more; there is no cutoff and no minimum.
- `claim(account, epochs[])` pays `account` for each listed ended epoch; anyone can call it for anyone.
  Double claims, excluded addresses, un-ended epochs and empty claims revert.
- `recycle(e)`, after `CLAIM_WINDOW = 365` epochs, folds whatever was never claimed for `e` into the current
  pot and closes `e`. This keeps $IMD from being stranded by wallets that never claim (abandoned wallets,
  the swarm's Merkle distributor while its allocation sits there, rounding dust).
- Fees belong to the epoch they are harvested in, not the epoch they were traded in. Harvesting often (the
  site has a button; any keeper can call it) keeps rewards close to the trades that earned them.

### The liquidity lock (`DeezLiquidityLock`)

Anyone can send $DEEZ and/or $IMD to it and call `lock()`. Both tokens present: a full-range position.
$DEEZ only: a position in the range just above the current price (permanent sell-side depth). $IMD only: a
position just below the price (a permanent buy wall). The position is owned by the lock, which has no
remove function, no owner and no fee collection, so the liquidity and its LP fees stay in the pool forever.

## After launch (operational responsibilities)

1. **Requester's 2% (20,000,000 $DEEZ) → at least 1% locked.** From the wallet that received the 2%
   (`$owner`), transfer ≥ 10,000,000 $DEEZ to `hook.liquidityLock()` and call `lock()` from any wallet. To
   lock a balanced position instead, send $IMD alongside; to add a buy wall, send $IMD alone. The lock is
   permanent: do not send anything you want back. The rest of the 2% is the requester's to keep or lock.
2. **Harvest and claim.** `DeezHook.harvest()`, `DeezRewards.accrue()`, `DeezRewards.claim(holder, epochs)`
   and `DeezRewards.recycle(epoch)` are permissionless. Nothing runs by itself: somebody (any holder, a
   keeper, the site's buttons) has to send those transactions. A claim for an epoch needs the epoch to have
   ended (UTC day boundary).
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
| `CLAIM_WINDOW`        | `DeezRewards`              | 365   | a year to claim before an epoch's remainder is recycled             |
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
- The swarm's Merkle distributor holds up to 10% of supply and is not excluded (its address is unknown at
  build time and the brief does not exclude it); its share is unclaimable and is recycled to holders after
  the claim window. The launch factory's own position is in the PoolManager and therefore excluded.
- Gas: each $DEEZ transfer writes two checkpoints (≈ +45k gas on a cold slot). `claim` costs a few reads
  per epoch; `claimMany` over many epochs is bounded only by the caller's gas.
- Slither/Mythril were not available in this environment; the review in `.imd/reads/skills` checklists was
  applied by hand. An independent adversarial review before launch is the swarm's step, not replaced here.

## Tests

```bash
forge build
FOUNDRY_FUZZ_SEED=0xc0b32088ed4ea538fc6eb66714ec1bd09394ca1049d6a3df1c8591aba01bf9c6 forge test
forge fmt --check
```

80 tests across `test/`: token metadata, supply, transfers and checkpoint history; hook permissions,
initialization refusals, caller checks, the four fee cases (both currency orders, fuzzed), a buy on a fresh
PoolManager seeded with $DEEZ only, harvest, zero-liquidity collects; distributor accrual, proportional
claims, exclusions, double/early/empty claims, recycling, fuzzed conservation; the liquidity lock in all
three modes; and an end-to-end trade → harvest → claim flow. The pinned floor suites (hook, owners, token)
were rehearsed locally against the built creation code and pass. `test/mocks/` holds the `MockERC20` and
`Swapper` the floor imports; `src/HookFlags.sol` is the flag library it imports.

Dependencies are vendored as plain files under `lib/` (v4-core at commit `46c6834`, forge-std, OpenZeppelin
Contracts v5.1.0, solmate's `Owned.sol` for v4-core's `ProtocolFees`); no submodules.
