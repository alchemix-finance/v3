# Verification snapshot

This branch contains the generated DinoSAT suite and the Certora reuse review. Formal verification is not complete. Halmos has not run.

| Check | Result |
|---|---:|
| Planned property groups linked to tests | 377 / 377 |
| Public/external function entries linked to tests | 260 / 260 |
| Compiled symbolic test instances | 820 |
| Compiled fuzz test instances | 554 |
| Test contracts | 93 |
| Maximum symbolic tests in one contract | 27 |
| Final forced build | Passed |
| Final fixture smoke check | 1,352 passed, 1 failed |

A test link does not prove the full property group. The maps retain untested subclaims, bounded input domains, and limits on operation sequences.

The final smoke command uses one fuzz case per test. It excludes candidate contracts and the ratio-ordering candidate. These checks test the fixtures. They do not replace the planned proof and fuzz campaigns.

```sh
FOUNDRY_PROFILE=halmos forge build --force
python3 verification/dinosat/scripts/check_phase3.py
FOUNDRY_PROFILE=halmos forge test --fuzz-runs 1 --fuzz-seed 0xd105a7 \
  --no-match-contract 'Candidate|Counterexample' \
  --no-match-test 'acceptedSequencePreservesRatioOrdering'
```

The remaining smoke failure is `DinosatTransmuterStateSymbolicTest.test_fuzz_claimCases`. It reverted for the input saved in [the final smoke log](phase3-fixture-smoke-final.json). Its cause is not yet classified as a fixture error or a source defect. Preserve the input when work resumes.

Two separate boundary checks reproduced source behavior that violates their test assertions:

- `divQ128(2^128, 2^129)` returns zero instead of `2^127`.
- A graph insertion with start `2^32 - 3` and duration `1` passes the endpoint bounds but reverts during resizing.

[The boundary evidence](library-boundary-counterexamples.json) states the input domains and production reachability limits. It does not establish an exploitable protocol vulnerability. Other candidate tests remain untested in the smoke run.

The suite calls current production code. Unit fixtures model external token, price, vault, and strategy behavior. Integration tests combine real v3 contracts with VaultV2 and an ERC4626 strategy. [The test coverage map](PHASE3_COVERAGE.md) and [structured coverage data](phase3-coverage.json) record the scope.

The formatter damaged inline branches during cleanup. All generated Solidity files were restored from their original writes and edits before the final build. Recovery manifests remain in this directory. Production source files were not changed.

Next, classify the remaining smoke failure and address the recorded test gaps. Then run Halmos with Z3, record successful paths, and complete the planned fuzz campaigns. Keep proofs, fuzz results, counterexamples, timeouts, and unverified areas separate in the final report.
