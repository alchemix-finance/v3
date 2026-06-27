#!/usr/bin/env bash
#
# Runs the Certora prover against a spec — locally or in the cloud.
#
# Usage:
#   ./certora/scripts/run.sh [--cloud] <spec_name>
#   ./certora/scripts/run.sh alchemist            # local (default)
#   ./certora/scripts/run.sh --cloud alchemist    # certora cloud
#   ./certora/scripts/run.sh alchemist --rule cvSoundMint   # single rule
#   ./certora/scripts/run.sh transmuter
#   ./certora/scripts/run.sh myt
#   ./certora/scripts/run.sh global               # not yet functional
#
# Modes:
#   --local  (default)  Uses the self-built offline prover at
#                       /tmp/certora-build.  Sets CERTORA=<dir> so the
#                       wrapper finds emv.jar and runs locally.
#   --cloud             Uses the official certora-cli (certoraRun on PATH).
#                       Uploads to the Certora cloud.  Requires CERTORA_KEY.
#
# Compiler flags (both modes):
#   --solc_via_ir   is REQUIRED — without it solc fails with "Stack too deep".
#   --solc_optimize is deliberately OMIT. The via_ir optimizer produces
#                   bytecode whose internal-function annotations the prover
#                   cannot reconstruct, crashing the CFG build.
#
# Local-only flags:
#   --java_args "-Xmx20g"  Raises JVM max heap (default ~25% of RAM is
#                          insufficient for AlchemistV3's global build phase).
#                          20 GB leans on swap (15 GB RAM + 31 GB swap).
set -euo pipefail

# -----------------------------------------------------------------------
# Parse mode flag
# -----------------------------------------------------------------------
MODE="local"
PASSTHROUGH=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --cloud) MODE="cloud"; shift ;;
        --local) MODE="local"; shift ;;
        --) shift; break ;;
        --rule|--rule_timeout|--exclude|--include|--multi_run_test)
            PASSTHROUGH+=("$1" "$2"); shift 2 ;;
        --*) PASSTHROUGH+=("$1"); shift ;;
        *) break ;;
    esac
done

SPEC_NAME="${1:?usage: $0 [--cloud|--local] <spec_name> [--certora-flags...]}"
shift
PASSTHROUGH+=("$@")
SPEC="certora/specs/${SPEC_NAME}.spec"

[[ -f "$SPEC" ]] || { echo "spec not found: $SPEC" >&2; exit 1; }

# solc 0.8.28 (selected via solc-select). certora calls `solc` off PATH.
command -v solc >/dev/null || { echo "solc not on PATH" >&2; exit 1; }

# -----------------------------------------------------------------------
# Select spec harness + sources
# -----------------------------------------------------------------------
EXTRA_EXCLUDE=""
case "$SPEC_NAME" in
    alchemist)
        HARNESS="AlchemistV3SceneHarness"
        SOURCES=(
            certora/harnesses/AlchemistV3SceneHarness.sol
            certora/harnesses/TypedAnchors.sol:VaultAnchor
            certora/harnesses/TypedAnchors.sol:DebtTokenAnchor
            certora/harnesses/TypedAnchors.sol:TransmuterAnchor
            src/AlchemistV3Position.sol
        )
        EXTRA_EXCLUDE="--exclude_method batchLiquidate(uint256[]) --exclude_rule *AlchemistV3Position*"
        ;;
    transmuter)
        HARNESS="TransmuterSceneHarness"
        SOURCES=(
            certora/harnesses/TransmuterSceneHarness.sol
            certora/harnesses/TransmuterMocks.sol:MockToken
            certora/harnesses/TransmuterMocks.sol:MockAlchemist
        )
        ;;
    myt)
        HARNESS="MYTSceneHarness"
        SOURCES=(
            certora/harnesses/MYTSceneHarness.sol
            certora/harnesses/MYTMocks.sol:MockAsset
            certora/harnesses/MYTMocks.sol:MockStrategy
        )
        EXTRA_EXCLUDE="--exclude_method multicall(bytes[])"
        ;;
    global)
        echo "global spec not yet functional — GlobalSceneHarness not implemented" >&2
        exit 1
        ;;
    *)
        echo "unknown spec: $SPEC_NAME" >&2
        echo "valid specs: alchemist, transmuter, myt, global" >&2
        exit 1
        ;;
esac

# -----------------------------------------------------------------------
# Build common args (shared between local and cloud)
# -----------------------------------------------------------------------
COMMON_ARGS=(
    --verify "${HARNESS}":"${SPEC}"
    --solc solc
    --solc_allow_path .
    --solc_via_ir
    --optimistic_loop
    --loop_iter 5
    --optimistic_hashing
    --smt_timeout 3600
    --rule_sanity none
    --packages "@openzeppelin/contracts=lib/openzeppelin-contracts/contracts"
)

# -----------------------------------------------------------------------
# Mode-specific setup
# -----------------------------------------------------------------------
if [[ "$MODE" == "local" ]]; then
    CERTORA_BUILD="${CERTORA_BUILD:-$CERTORA}"
    [[ -f "${CERTORA_BUILD}/emv.jar" ]] || { echo "emv.jar not found at ${CERTORA_BUILD}/emv.jar" >&2; exit 1; }

    export CERTORA="$CERTORA_BUILD"
    CERTORA_BIN="python3 ${CERTORA_BUILD}/certoraRun.py"
    EXTRA_ARGS=(--java_args "-Xmx20g")
    MSG="local prover: ${SPEC_NAME}"

    echo "==> Verifying ${SPEC_NAME} locally (via_ir, no optimizer, 20g heap)"
else
    command -v certoraRun >/dev/null || { echo "certoraRun not on PATH — install certora-cli (pip install certora-cli)" >&2; exit 1; }
    [[ -n "${CERTORA_KEY:-}" ]] || { echo "CERTORA_KEY not set — required for cloud runs" >&2; exit 1; }

    # Ensure CERTORA env doesn't point at the local build
    unset CERTORA

    CERTORA_BIN="certoraRun"
    EXTRA_ARGS=()
    MSG="cloud prover: ${SPEC_NAME}"

    echo "==> Verifying ${SPEC_NAME} in the Certora cloud (via_ir, no optimizer)"
fi

echo "    Harness: ${HARNESS}"
echo "    Mode:    ${MODE}"

# -----------------------------------------------------------------------
# Run
# -----------------------------------------------------------------------
$CERTORA_BIN \
    "${SOURCES[@]}" \
    "${COMMON_ARGS[@]}" \
    ${EXTRA_EXCLUDE} \
    "${EXTRA_ARGS[@]}" \
    --msg "${MSG}" \
    "${PASSTHROUGH[@]}"
