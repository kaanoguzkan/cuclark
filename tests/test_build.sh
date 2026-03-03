#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "=== CuCLARK Build Test ==="

cd "$PROJECT_DIR"

echo "[1/4] Cleaning previous build..."
rm -rf build

echo "[2/4] Configuring with CMake..."
cmake -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_CUDA_ARCHITECTURES="70;75;80;86;89;90"

echo "[3/4] Building..."
cmake --build build -j$(nproc)

echo "[4/4] Checking binaries..."
PASS=true

if [ -x build/cuCLARK ]; then
	echo "  PASS: cuCLARK binary exists and is executable"
else
	echo "  FAIL: cuCLARK binary not found or not executable"
	PASS=false
fi

if [ -x build/cuCLARK-l ]; then
	echo "  PASS: cuCLARK-l binary exists and is executable"
else
	echo "  FAIL: cuCLARK-l binary not found or not executable"
	PASS=false
fi

if $PASS; then
	echo ""
	echo "=== Build test PASSED ==="
	exit 0
else
	echo ""
	echo "=== Build test FAILED ==="
	exit 1
fi
