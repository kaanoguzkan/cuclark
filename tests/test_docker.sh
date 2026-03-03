#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "=== CuCLARK Docker Test ==="

cd "$PROJECT_DIR"

PASS=true

echo "[1/3] Building Docker image..."
if docker build -t cuclark:test . ; then
	echo "  PASS: Docker image built successfully"
else
	echo "  FAIL: Docker image build failed"
	exit 1
fi

echo "[2/3] Running help command in container..."
if docker run --rm cuclark:test --help 2>&1 | grep -q "CuCLARK"; then
	echo "  PASS: Container runs and shows help"
else
	echo "  FAIL: Container failed to run help"
	PASS=false
fi

echo "[3/3] Checking GPU access (requires nvidia-docker)..."
if docker run --rm --gpus all cuclark:test --help 2>&1 | grep -q "CuCLARK"; then
	echo "  PASS: Container runs with GPU access"
else
	echo "  WARN: GPU access test failed (may need nvidia-docker runtime)"
fi

if $PASS; then
	echo ""
	echo "=== Docker test PASSED ==="
	exit 0
else
	echo ""
	echo "=== Docker test FAILED ==="
	exit 1
fi
