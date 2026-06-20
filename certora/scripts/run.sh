#!/usr/bin/env bash
#
# Runs the local (offline) Certora prover against an AlchemistV3 spec.
#
# Usage:
#   ./certora/scripts/run.sh <spec_name>
#   ./certora/scripts/run.sh calculateLiquidation
#   ./certora/scripts/run.sh normalization
#   ./certora/scripts/run.sh feeBounds
#   ./certora/scripts/run.sh conservation
#   ./certora/scripts/run.sh collateralizationInvariant
#
# The prover is a self-built, offline build at /tmp/certora-build (NOT the
# certora-cli cloud product). Local run mode is auto-detected: setting
# CERTORA=<dir> causes the wrapper to find emv.jar there, which makes
# Util.is_local() return true (no cloud request is made).
#
# Compiler flags:
#   --solc_via_ir   is REQUIRED — without it solc fails with "Stack too deep".
#   --solc_optimize is deliberately OMIT. The via_ir optimizer (even at a low
#                   runs value) produces bytecode whose internal-function
#                   annotations the prover cannot reconstruct, crashing the
#                   control-flow-graph build ("Incoherent graph" /
#                   FUNCTION_BUILDER errors) on functions like _forceRepay.
#                   The optimizer only changes gas/representation, not logical
#                   results, so verifying unoptimized bytecode proves the same
#                   properties.
# Prover JVM flags:
#   --java_args "-Xmx10g"  raises the JVM max heap (default is ~25% of RAM,
#                          ~3.75 GB here), which is insufficient — analyzing
#                          all of AlchemistV3's internal functions during the
#                          global build phase overflows the default heap
#                          (OutOfMemoryError: Java heap space). 20 GB leans on
#                          swap (15 GB RAM + 31 GB swap) but gives ample headroom.
set -euo pipefail

SPEC_NAME="${1:?usage: $0 <spec_name>}"
SPEC="certora/specs/${SPEC_NAME}.spec"

[[ -f "$SPEC" ]] || { echo "spec not found: $SPEC" >&2; exit 1; }

CERTORA_BUILD="${CERTORA_BUILD:-/tmp/certora-build}"
export CERTORA="$CERTORA_BUILD"        # tells the wrapper where its scripts + emv.jar live

# solc 0.8.28 (selected via solc-select). certora calls `solc` off PATH.
command -v solc >/dev/null || { echo "solc not on PATH" >&2; exit 1; }

CERTORA_BIN="python3 ${CERTORA_BUILD}/certoraRun.py"

# End-to-end specs use the scene harness with typed anchors; pure-function
# specs use the original lightweight harness.
case "$SPEC_NAME" in
    conservation|collateralizationInvariant)
        HARNESS="AlchemistV3SceneHarness"
        SOURCES=(
            certora/harnesses/AlchemistV3SceneHarness.sol
            src/AlchemistV3.sol
        )
        ;;
    *)
        HARNESS="AlchemistV3Harness"
        SOURCES=(
            certora/harnesses/AlchemistV3Harness.sol
            src/AlchemistV3.sol
        )
        ;;
esac

echo "==> Verifying ${SPEC_NAME} with the local prover (via_ir, no optimizer)"
echo "    Harness: ${HARNESS}"

$CERTORA_BIN \
    "${SOURCES[@]}" \
    --verify "${HARNESS}":"${SPEC}" \
    --solc solc \
    --solc_allow_path . \
    --solc_via_ir \
    --java_args "-Xmx20g" \
    --packages "@openzeppelin/contracts=lib/openzeppelin-contracts/contracts" \
    --msg "local prover: ${SPEC_NAME}"
