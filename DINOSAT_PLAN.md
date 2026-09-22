# V3 formal verification plan

Status: environment ready. Property review complete. Test generation awaits the DinoSAT confirmation step.

## Scope

- Repository: `/Users/deepthought/Desktop/dev/v3`
- Branch: `formal-verification-ai-run`
- Source commit: `4891f80565911f88eed9e9410e5109439d988e5b`
- Scope: 43 Solidity files and 7772 lines under `src/`.
- Exclusions: interface directories, imported libraries, mocks and existing tests are not standalone proof targets.

Imported dependencies remain part of the executed bytecode and explicit trust assumptions.
Embedded test token `AlEth` stays in the inventory, with its intended test role stated.
Error-only files and abstract declarations remain in scope, with no false claim of executable coverage.

## Existing Certora work

Reuse the 38 existing Certora rules and invariants before adding tests for uncovered behavior.
[The reuse map](verification/dinosat/CERTORA_REUSE.md) identifies compatible properties, changed assumptions and harness corrections.
[The full matrix](verification/dinosat/PROOF_OBLIGATIONS.md) lists each proposed property group and its planned test file.

## Proof matrix summary

| Area | Property groups | Focus |
|---|---|---|
| core | 34 | Debt, collateral, redemption, cover, epochs and router flows |
| governance | 114 | Roles, token inheritance, allocation caps, NFT ownership and fee vaults |
| strategies | 146 | Real adapter entry points, valuation, swaps, queues and slippage |
| transmuter-libraries | 77 | Claims, graph accounting, arithmetic, helpers and gauge behavior |
| integration | 6 | Real contracts composed across protocol boundaries |

Total: 377 proposed property groups. These are not test counts or predicted proof results.

## Threat model

### Assets at risk

User collateral, vault shares, synthetic supply, redemption claims, fee funds and strategy positions.

### Actors

Position owners, approved spenders, liquidators, administrators, guardians, curators, allocators, bridge operators and external protocol contracts.
Untrusted callers can choose inputs and transaction order. Callback tests include hostile recipients and external contracts.

### Trust assumptions

- Each fixture states its token, oracle, vault, bridge and external protocol behavior.
- Initializers, roles and proxy wiring use reachable setup. Arbitrary storage injection requires a stated reachability argument.
- Arithmetic domains come from source guards or explicit limits. Excluded values receive boundary or rejection tests.
- A result for mocked dependencies applies only to those assumptions. Integration tests use real v3 and vault contracts where possible.

### Attack vectors

Unauthorized mint or withdrawal, inconsistent debt and shares, repeated cover credit, stale epoch checkpoints, rounding loss, cap bypass and callback attacks.
The module inventories retain source concerns as unverified candidates until a concrete test confirms them.

## Environment evidence

- Foundry 1.5.1 and Solidity 0.8.28.
- Halmos 0.3.3 with explicit Z3 selection. Z3 package: 4.12.6.0.
- Isolated Python 3.14.2 environment: `/Users/deepthought/.codex/tools/dinosat-venv`.
- PDF dependency `fpdf2` installed in that environment.
- Baseline build: 144 files compiled successfully, with compiler and style warnings.

The `halmos` profile disables optimization, enables AST and storage layout output, and uses separate cache and artifact directories.
The profile retains Cancun because the router uses transient storage. Unoptimized compilation requires `via_ir = true`.
The Graft command and local index are absent. Source review used direct file reads and recorded file hashes.

## Execution requirements

1. Correct and reuse compatible Certora helpers. Add meaningful tests for all planned P0 access and arithmetic properties.
2. Compile the full verification suite before solver execution. Keep production source unchanged unless a separate change is requested.
3. Run one Halmos contract at a time with Z3, 30-second assertion timeouts and recorded loop and sequence bounds.
4. Run one million fuzz trials per wrapper and 100,000 regression trials per symbolic test where feasible under the specified rejection protocol.
5. Check non-vacuity and counterexamples, then produce the Markdown report, rendered PDF and raw result log.

Split contracts with more than 30 tests. Retry unresolved solver cases at most three times.
A timeout is unproved. Only an executed passing fuzz run earns a fuzz result.
A rejected or skipped input is not meaningful coverage. Record successful paths and useful input counts.
For arithmetic safety, include unexpected panics in failure handling. For required successful calls, assert success explicitly.
Access tests must call the implementation and distinguish authorization rejection from unrelated failures.
Preserve integer rounding in transformations. A model lemma needs a separate refinement check against the implementation.

## Deliverables

- `test/dinosat/`: symbolic tests, fuzz companions and harnesses.
- `DINOSAT_REPORT.md`: results, threat model, assumptions, counterexamples and unverified areas.
- `DINOSAT_REPORT.pdf`: rendered and visually checked report.
- `dinosat-log.txt` and structured results: executed commands, counts, timing and raw solver outcomes.
- `verification/dinosat/`: source inventory, property matrix, Certora reuse map and environment record.

## Current state

The user approved Phase 3 with "ok, run phase 3". The tests are generated and compile. The final fixture check has one unresolved failure.
The full objective remains unfinished. Halmos and the full fuzz campaigns have not run.
A small Forge check found two library boundary failures. The evidence records their limited input domains and does not claim an exploitable protocol vulnerability.

DinoSAT's Phase 2h confirmation gate is satisfied. No further plan approval is required to generate the tests.
See `verification/dinosat/progress.json` for the current work stage and the separate goal-tool status.

[DinoSAT skill](/Users/deepthought/.codex/skills/dinosat-skill/SKILL.md)
