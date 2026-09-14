# Alchemix V3 Bug Bounty — Scope

Source: <https://immunefi.com/bug-bounty/alchemix-1/scope/> · Chains: Arbitrum, ETH, Optimism, Base · Category: Smart Contract · extracted 2026-06-12 (verbatim).

Total Assets in Scope: **2** · Total Impacts in Scope: **14**

## Assets in Scope

| Target | Name | Added on |
|---|---|---|
| <https://github.com/alchemix-finance/v3/tree/master/src> | V3 Contracts | 6 April 2026 |
| Primacy Of Impact | — | 26 February 2026 |

> **Primacy of Impact** applies to smart contract findings at all severity levels — impact takes priority over specific listed asset scope.

## Impacts in Scope

### Critical
- Direct theft of any user funds, whether at-rest or in-motion, other than unclaimed yield
- Direct theft of any user NFTs, whether at-rest or in-motion, other than unclaimed royalties
- Permanent freezing of funds
- Permanent freezing of NFTs
- Unauthorized minting of NFTs
- Protocol insolvency

### High
- Permanent freezing of unclaimed yield
- Theft of unclaimed yield
- Temporary Freezing of Funds at 0 cost or profit to attacker for greater than 1 day

### Medium
- Griefing at minimal no to cost to attacker
- Smart contract unable to operate due to lack of token funds
- Miner Extractable Value in excess of 0.75%

## Out of Scope (Program-Specific)

- **Yield Strategies** — Only yield strategies that are deployed and hooked up to the MYT on at least one chain are in scope.
- **Trusted Admin** — Admin, Curator, Allocator, and Sentinel are all trusted roles. This will change in the future with onchain governance, but for now are assumed trusted. As an example, strategies receive a high/med/low risk rating, which dictates maximum relative caps. However, these relative caps are not yet enforced onchain and instead are enforced by trusted curators/allocators.
- **Perpetual Gauge** — Unused and out of scope, related to "Trusted Admin" above.
- **OraclePricedSwapStrategy** — Currently in audit and out of scope.
- **Known AI Audit Report Issues** — The items located at <https://github.com/alchemix-finance/v3/blob/scoopy-ai-scan-findings/REJECTED.md> are AI-assisted audit reports that were reviewed internally and deemed invalid. The list can be cross referenced with the findings here: <https://github.com/alchemix-finance/v3/blob/scoopy-ai-scan-findings/FINDINGS-INDEX.md>
- **Bad Debt** — The transmuter has a calculator to distribute bad debt more fairly when detected (claim value in the transmuter is reduced when bad debt is detected). This mechanism is not meant to be perfect — once bad debt happens, there is not really a perfect mechanism. It is simply meant to be more fair than a simple race to the exit scenario. There are scenarios where there may be some bad debt where the bad debt mechanism may not trigger — that is OK. Thus, any report akin to "bad debt distribution isn't totally fair" is not in scope.
- **How transmuter returns are viewed** — When a user deposits to the transmuter, they deposit alAsset and expect to get MYT back after a fixed period of time. We view the alAsset to MYT conversion as "promised returns", NOT "user funds". Ie, the user does not own MYT until the conversion. They own the alAsset. If they are unable to claim the MYT, then their position is still alAsset denominated and they have not received the promised returns.

## Out of Scope (Default)

### Smart Contract specific
- Incorrect data supplied by third party oracles — *not to exclude oracle manipulation/flash loan attacks*
- Impacts requiring basic economic and governance attacks (e.g. 51% attack)
- Lack of liquidity impacts
- Impacts from Sybil attacks
- Impacts involving centralization risks

### All categories
- Impacts requiring attacks that the reporter has already exploited themselves, leading to damage
- Impacts caused by attacks requiring access to leaked keys/credentials
- Impacts caused by attacks requiring access to privileged addresses (including, but not limited to: governance and strategist contracts) without additional modifications to the privileges attributed
- Impacts relying on attacks involving the depegging of an external stablecoin where the attacker does not directly cause the depegging due to a bug in code
- Mentions of secrets, access tokens, API keys, private keys, etc. in Github will be considered out of scope without proof that they are in-use in production
- Best practice recommendations
- Feature requests
- Impacts on test files and configuration files unless stated otherwise in the bug bounty program
- Impacts requiring phishing or other social engineering attacks against project's employees and/or customers
