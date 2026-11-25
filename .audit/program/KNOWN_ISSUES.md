# Alchemix V3 Bug Bounty — Known Issues & Program Rules

Source: <https://immunefi.com/bug-bounty/alchemix-1/information/> · Program: Alchemix (max bounty $300,000) · Live since 26 Feb 2026 · Last updated 08 Jun 2026 · extracted 2026-06-12 (verbatim).

> Bug reports covering previously-discovered bugs (listed below) are not eligible for a reward within this program. This includes known issues that the project is aware of but has consciously decided not to "fix", perform necessary code changes, or any implemented operational mitigating procedures that can lessen potential risk.

## Prior Audits

| Auditor | Link | Completed |
|---|---|---|
| Spearbit and Cantina | <https://cantina.xyz/portfolio/f638950d-a8ad-4df8-a6ec-8b067e416d7b> | 15 May 2025 |
| Aleph V | <https://hackmd.io/@geistermeister/SkSZiU9ybe> | 15 December 2025 |
| immunefi | <https://drive.google.com/file/d/18LmIajwn6NOCbxKQJ49MVLyLSKb9gmD1/view> | 1 January 2026 |
| Nethermind | <https://docs.alchemix.fi/assets/files/v3-nethermind-3195e302f55244d130f49ec41e6d1539.pdf> | 2 February 2026 |
| yAudit | <https://docs.alchemix.fi/assets/files/v3-yearn-e44c37454c3ba188ea81d6d583c399aa.pdf> | 15 March 2026 |

## Known Issues (Smart Contract)

### 1. Fundamental-backing pricing & withdrawal queues — *Updated 1 October 2025*
We are pricing strategies based on the fundamental backing, rather than dex price, whenever possible. This means there may be scenarios where the fundamental backing has a queue to access (such as the exit queue for wstETH). In these scenarios, as an example, 1 alETH in the transmuter would return 1 ETH worth of MYT, but that 1 ETH of MYT would not be accessible until the withdrawal queue clears, OR the user could sell the 1 ETH of MYT for < 1 ETH. Thus, the MYT market price may be < 1 ETH, which may bring the price of the alAsset < 1 ETH. This is intended behavior, as should the withdrawal queue clear the 1 ETH of MYT value would once again be instantly accessible and thus the alAsset would be redeemable for 1 ETH.
*Ref: audit competition scope*

### 2. MYT below LTV / arbitrage minting — *Updated 1 October 2025*
IF the price of the MYT drops below the LTV (say 1 ETH of MYT has a market price of 0.85 ETH) due to withdrawal queues, then it would be expected that arbitragers mint alETH to sell at > 100% LTV. However, so long as the value of the MYT these arbitragers collateralize returns to 1:1, there is no bad debt created in the system. Only a situation that returns permanent bad debt, even after MYT recovery, would be in scope (or a situation where the MYT is prevented from recovering).
*Ref: audit competition scope*

### 3. DAO Multisig is trusted — *Updated 1 October 2025*
The DAO Multisig on each chain, which takes on an admin role in the system, is trusted.
*Ref: <https://alchemix-stats.com/>*

### 4. Self-liquidation for profit — *Updated 13 October 2025*
Technically an individual could open numerous small positions at max LTV, hoping that they become eligible for liquidation so they can liquidate themselves and get paid from the feeVault for a net profit. However, the feeVault ONLY pays out when the alchemist is globally undercollateralized, NOT for liquidate individually undercollateralized positions when global collateralization is otherwise acceptable. This is an acceptable risk and therefore not considered in scope.
*Ref: <https://github.com/alchemix-finance/v3-poc/tree/immunefi_audit>*

### 5. Curators and allocators are trusted — *Updated 3 April 2026*
All curators and allocators are trusted (ie, low/med/high risk strategy cap maximums are not enforced on chain, assumed done by curators/allocators/admin)
*Ref: <https://docs.alchemix.fi/user>*

## Known AI-Audit Findings (also out of scope)

Per the Scope page: AI-assisted audit reports that were reviewed internally and deemed invalid.
- REJECTED findings: <https://github.com/alchemix-finance/v3/blob/scoopy-ai-scan-findings/REJECTED.md>
- Findings index (cross-reference): <https://github.com/alchemix-finance/v3/blob/scoopy-ai-scan-findings/FINDINGS-INDEX.md>

## Program Rules

- **KYC:** No KYC information is required for payout processing.
- **Proof of Concept:** Proof of concept is always required for all severities. Must comply with the Immunefi PoC Guidelines and Rules.
- **Responsible Publication:** Category 3 — Approval Required.

### Prohibited Activities (default)
- Any testing on mainnet or public testnet deployed code; all testing should be done on local-forks of either public testnet or mainnet
- Any testing with pricing oracles or third-party smart contracts
- Attempting phishing or other social engineering attacks against our employees and/or customers
- Any testing with third-party systems and applications (e.g. browser extensions) as well as websites (e.g. SSO providers, advertising networks)
- Any denial of service attacks that are executed against project assets
- Automated testing of services that generates significant amounts of traffic
- Public disclosure of an unpatched vulnerability in an embargoed bounty
- Any other actions prohibited by the Immunefi Rules

### Feasibility Limitation Standards (default citable set)
- Chain Rollbacks
- Pre-Impact Bug Monitoring
- Attack Investment Amount
- Attacks With A Financial Risk To The Attacker
- When Is An Impactful Attack Downgraded To Griefing?
