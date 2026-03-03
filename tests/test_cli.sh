#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "=== CuCLARK CLI Test ==="

CUCLARK="$PROJECT_DIR/build/cuCLARK"
CUCLARK_L="$PROJECT_DIR/build/cuCLARK-l"

PASS=true
TESTS=0
PASSED=0

run_test() {
	local desc="$1"
	local expected_exit="$2"
	shift 2
	TESTS=$((TESTS + 1))

	set +e
	output=$("$@" 2>&1)
	actual_exit=$?
	set -e

	if [ "$actual_exit" -eq "$expected_exit" ]; then
		echo "  PASS: $desc (exit=$actual_exit)"
		PASSED=$((PASSED + 1))
	else
		echo "  FAIL: $desc (expected exit=$expected_exit, got exit=$actual_exit)"
		PASS=false
	fi
}

if [ ! -x "$CUCLARK" ]; then
	echo "ERROR: cuCLARK binary not found. Run test_build.sh first."
	exit 1
fi

echo "[cuCLARK tests]"
run_test "help flag shows usage" 0 "$CUCLARK" --help
run_test "version flag shows version" 0 "$CUCLARK" --version
run_test "no arguments shows error" 255 "$CUCLARK"
run_test "invalid option shows error" 1 "$CUCLARK" --invalid-option

echo ""
echo "[cuCLARK-l tests]"
if [ -x "$CUCLARK_L" ]; then
	run_test "help flag shows usage" 0 "$CUCLARK_L" --help
	run_test "version flag shows version" 0 "$CUCLARK_L" --version
	run_test "no arguments shows error" 255 "$CUCLARK_L"
else
	echo "  SKIP: cuCLARK-l binary not found"
fi

echo ""
echo "Results: $PASSED/$TESTS tests passed"

if $PASS; then
	echo "=== CLI test PASSED ==="
	exit 0
else
	echo "=== CLI test FAILED ==="
	exit 1
fi
