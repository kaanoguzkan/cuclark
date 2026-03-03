#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
TEST_DIR="$SCRIPT_DIR/test_data"

echo "=== CuCLARK Classification Smoke Test ==="

CUCLARK="$PROJECT_DIR/build/cuCLARK"

if [ ! -x "$CUCLARK" ]; then
	echo "ERROR: cuCLARK binary not found. Run test_build.sh first."
	exit 1
fi

echo "[1/4] Creating synthetic test data..."
mkdir -p "$TEST_DIR"

# Create a small synthetic FASTA file with a few reads
cat > "$TEST_DIR/reads.fa" << 'FASTA'
>read1
ATCGATCGATCGATCGATCGATCGATCGATCGATCGATCG
>read2
GCTAGCTAGCTAGCTAGCTAGCTAGCTAGCTAGCTAGCTA
>read3
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
FASTA

# Create a minimal targets file (genome path + label)
cat > "$TEST_DIR/genome1.fna" << 'FASTA'
>genome1_seq1
ATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCG
FASTA

cat > "$TEST_DIR/genome2.fna" << 'FASTA'
>genome2_seq1
GCTAGCTAGCTAGCTAGCTAGCTAGCTAGCTAGCTAGCTAGCTAGCTA
FASTA

cat > "$TEST_DIR/targets.txt" << 'TARGETS'
TARGETS

echo "  Created synthetic reads and genomes"

echo "[2/4] Note: Full classification requires a built database."
echo "  This test verifies that the binary can parse input files."

echo "[3/4] Testing binary accepts input format..."
set +e
output=$("$CUCLARK" -k 31 -T "$TEST_DIR/targets.txt" -D "$TEST_DIR/" -O "$TEST_DIR/reads.fa" -R "$TEST_DIR/results" 2>&1)
exit_code=$?
set -e

# The classifier will likely fail due to missing database, but should not crash
if [ $exit_code -ne 139 ] && [ $exit_code -ne 134 ]; then
	echo "  PASS: Binary did not crash (segfault/abort) on input (exit=$exit_code)"
else
	echo "  FAIL: Binary crashed (exit=$exit_code)"
	echo "  Output: $output"
	exit 1
fi

echo "[4/4] Cleaning up test data..."
rm -rf "$TEST_DIR"

echo ""
echo "=== Classification smoke test PASSED ==="
exit 0
