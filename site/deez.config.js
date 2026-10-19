// Fill these in once IMD's deployer has launched the contracts (the launch returns every address).
// Leave a field empty and the site shows "announced at launch" in its place.
window.DEEZ = {
  chainId: 1,
  token: "",          // DeezToken ($DEEZ) address
  hook: "",           // DeezHook address
  rewards: "",        // DeezRewards address: hook.rewards()
  liquidityLock: "",  // DeezLiquidityLock address: hook.liquidityLock()
  poolId: "",         // Uniswap v4 pool id (bytes32)
  imd: "0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7",
  poolManager: "",    // Uniswap v4 PoolManager on Ethereum, as the launch resolved $poolManager
  launchTx: "",       // launch transaction hash
  rpc: "https://ethereum-rpc.publicnode.com",
  links: {
    uniswap: "",      // e.g. https://app.uniswap.org/explore/pools/ethereum/<poolId>
    dexscreener: "",  // e.g. https://dexscreener.com/ethereum/<poolId>
    imd: "https://imd.fun",
    docs: "https://imd.fun/docs/",
    telegram: "https://imd.fun/telegram/",
  },
};
