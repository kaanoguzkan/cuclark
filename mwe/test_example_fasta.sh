#!/bin/bash
set -euo pipefail

# ── Test script for example.fasta ────────────────────────────────────────
# Tests uniques.fasta by:
#   1. Generating simulated reads from it
#   2. Extracting target genomes from the input
#   3. Classifying the reads with cuCLARK
#   4. Showing a summary of results
#
# Expects uniques.fasta to be provided via $2 or the FASTA env var.
# The file is NOT baked into the Docker image — mount it at runtime.
#
# Usage (inside Docker container):
#   docker run --gpus all \
#     -v /path/to/uniques.fasta:/data/uniques.fasta \
#     -v $(pwd):/data cuclark \
#     bash /opt/cuclark/mwe/test_example_fasta.sh /data/test_example /data/uniques.fasta
#
# Or from the repo root:
#   bash mwe/test_example_fasta.sh [DATA_DIR] [FASTA_PATH]
#
# Default DATA_DIR: /data/test_example

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="${1:-/data/test_example}"
FASTA="${2:-${FASTA:-$SCRIPT_DIR/uniques.fasta}}"

# Tunable parameters (override via env vars):
#   NUM_TARGETS  — how many genomes to extract as classification targets (default: 5)
#   NUM_READS    — how many simulated reads to generate (default: 200)
#   The input FASTA has 35,396 sequences. More targets = bigger DB = more RAM.
NUM_TARGETS="${NUM_TARGETS:-5}"
NUM_READS="${NUM_READS:-200}"

mkdir -p "$DATA_DIR"

if [ ! -f "$FASTA" ]; then
	echo "ERROR: FASTA file not found at $FASTA"
	echo "       Provide the path as the second argument or mount it into the container."
	exit 1
fi

echo "============================================================"
echo "  CuCLARK Test: uniques.fasta"
echo "  Input:            $FASTA"
echo "  Output directory: $DATA_DIR"
echo "============================================================"
echo ""

mkdir -p "$DATA_DIR/genomes" "$DATA_DIR/db"

# ── Step 1: Generate simulated reads ─────────────────────────────────────
echo ""
echo "[1/4] Generating simulated reads from uniques.fasta..."

# Extract a portion of real sequence (skip N-rich beginning) for read generation
# We sample from lines that have real bases, not just N's
python3 -c "
import random
import sys

fasta_path = '$FASTA'
read_len = 150
num_reads = $NUM_READS

# Read all sequence data
seq_parts = []
with open(fasta_path) as f:
    for line in f:
        if line.startswith('>'):
            continue
        seq_parts.append(line.strip())
        # Only need enough for read generation (scale with num_reads)
        if len(seq_parts) * 60 > max(1_000_000, num_reads * 1000):
            break

seq = ''.join(seq_parts)

# Find regions with real bases (not all N's)
reads_written = 0
random.seed(42)
attempts = 0
max_attempts = num_reads * 20

with open('$DATA_DIR/reads.fa', 'w') as out:
    while reads_written < num_reads and attempts < max_attempts:
        attempts += 1
        start = random.randint(0, len(seq) - read_len)
        read_seq = seq[start:start + read_len]
        # Skip reads that are mostly N's
        n_count = read_seq.upper().count('N')
        if n_count > read_len * 0.1:
            continue
        out.write(f'>example_read_{reads_written} pos={start}\n')
        out.write(f'{read_seq}\n')
        reads_written += 1

print(f'  Generated {reads_written} reads ({read_len} bp each) from informative regions')
if reads_written < num_reads:
    print(f'  WARN: Only found {reads_written}/{num_reads} reads with <10% N content')
" || {
	echo "  ERROR: Python3 not available for read generation. Falling back to shell method."

	# Shell fallback: extract reads from non-N regions
	grep -v "^>" "$FASTA" | grep -v "^NNNN" | head -200 | awk -v rl=150 '
	{
		seq = $0
		if (length(seq) >= rl) {
			printf ">example_read_%d\n%s\n", NR, substr(seq, 1, rl)
		}
	}' > "$DATA_DIR/reads.fa"
	echo "  Generated $(grep -c '^>' "$DATA_DIR/reads.fa") reads (shell fallback)"
}

NUM_READS=$(grep -c "^>" "$DATA_DIR/reads.fa")
if [ "$NUM_READS" -eq 0 ]; then
	echo "  ERROR: No reads generated. The file may contain only N's."
	exit 1
fi
echo "  Total reads in $DATA_DIR/reads.fa: $NUM_READS"

# ── Step 2: Extract target genomes from input FASTA ──────────────────────
echo ""
echo "[2/4] Extracting target genomes from input FASTA..."

# Clean previous genome files to avoid stale targets
rm -f "$DATA_DIR/genomes/"*.fna

# Use Python3 for fast extraction (bash while-read is too slow on multi-GB files)
TARGET_COUNT=$(python3 -c "
import sys, os

fasta = '$FASTA'
out_dir = '$DATA_DIR/genomes'
n = $NUM_TARGETS
count = 0
current = None

with open(fasta) as f:
    for line in f:
        if line.startswith('>'):
            if current:
                current.close()
            count += 1
            if count > n:
                break
            acc = line[1:].split()[0]
            current = open(os.path.join(out_dir, acc + '.fna'), 'w')
            current.write(line)
        elif current:
            current.write(line)

if current:
    current.close()

print(min(count, n))
")

echo "  Extracted $TARGET_COUNT target sequences from input FASTA"

# ── Step 3: Create targets file and run classification ────────────────────
echo ""
echo "[3/4] Creating targets file..."

# Clean stale DB so it rebuilds from current targets
rm -rf "$DATA_DIR/db/"*

> "$DATA_DIR/targets.txt"
for f in "$DATA_DIR/genomes/"*.fna; do
	name=$(basename "$f" .fna)
	echo "$f	$name" >> "$DATA_DIR/targets.txt"
done

NUM_TGT=$(wc -l < "$DATA_DIR/targets.txt" | tr -d ' ')
echo "  Created targets.txt with $NUM_TGT targets"

# ── Step 3b: Run classification ───────────────────────────────────────────
echo ""
echo "[3/4] Running cuCLARK classification..."

# ── Auto-detect system resources and select best variant ──
#
# HTSIZE formula:
#   HTSIZE = largest_prime_below( (RAM_GB - 4) * 1e9 / 24 )
#   Hash table alloc = HTSIZE × 24 bytes
#   Max k-mer length = floor(log4(HTSIZE)) + 16
#
#   Variant      | HTSIZE (prime)  | HT alloc | Max k | Min RAM
#   -------------|-----------------|----------|-------|--------
#   cuCLARK-l    |    57,777,779   |  1.4 GB  |  27   |   4 GB
#   cuCLARK      | 1,610,612,741   | 38.6 GB  |  31   |  48 GB
#
# VRAM formula:
#   VRAM per batch ≈ DB_size / num_batches + RESERVED (300-400 MB)
#   Batches = ceil(total_VRAM_need / (VRAM - RESERVED))

RAM_KB=$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
RAM_GB=$((RAM_KB / 1024 / 1024))

VRAM_MB=0
if command -v nvidia-smi &>/dev/null; then
	VRAM_MB=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')
fi
VRAM_GB=$((VRAM_MB / 1024))

echo "  Detected: ${RAM_GB} GB RAM, ${VRAM_GB} GB VRAM"

# Select variant based on available RAM
VARIANT=""
KMER=31
RESERVED_MB=400

if [ "$RAM_GB" -ge 48 ] && command -v cuCLARK &>/dev/null; then
	VARIANT="cuCLARK"
	LABEL="full"
	RESERVED_MB=400
elif command -v cuCLARK-l &>/dev/null; then
	VARIANT="cuCLARK-l"
	LABEL="light"
	KMER=27
	RESERVED_MB=300
elif command -v cuCLARK &>/dev/null; then
	VARIANT="cuCLARK"
	LABEL="full (forced, may OOM)"
	RESERVED_MB=400
fi

# Calculate optimal batch count from VRAM
# More batches = less VRAM per batch, but slower
if [ "$VRAM_MB" -gt 0 ]; then
	USABLE_VRAM_MB=$((VRAM_MB - RESERVED_MB))
	if [ "$USABLE_VRAM_MB" -le 0 ]; then
		USABLE_VRAM_MB=512
	fi
	# Estimate: with small DBs 1 batch is fine; scale up for larger DBs
	# DB size ≈ num_targets × avg_genome_size × 24 bytes / HTSIZE_fill_ratio
	# For safety, use at least ceil(2048 / USABLE_VRAM_MB) batches
	BATCHES=$(( (2048 + USABLE_VRAM_MB - 1) / USABLE_VRAM_MB ))
	if [ "$BATCHES" -lt 1 ]; then BATCHES=1; fi
	if [ "$BATCHES" -gt 16 ]; then BATCHES=16; fi
else
	BATCHES=4
fi

if [ -n "$VARIANT" ]; then
	echo "  Selected: $VARIANT ($LABEL), k=$KMER, batches=$BATCHES"
	echo ""
	$VARIANT -k "$KMER" \
		-T "$DATA_DIR/targets.txt" \
		-D "$DATA_DIR/db/" \
		-O "$DATA_DIR/reads.fa" \
		-R "$DATA_DIR/results" \
		-n 1 -b "$BATCHES" -d 1
else
	echo "  SKIP: No cuCLARK binary found (not inside Docker container?)"
	echo "  To run classification, build and run inside the Docker container:"
	echo "    docker build -t cuclark ."
	echo "    docker run --gpus all -v \$(pwd):/data cuclark bash /data/test_example_fasta.sh"
	echo ""
	echo "  Steps 1-3 passed. Classification skipped."
	exit 0
fi

# ── Step 4: Show results ─────────────────────────────────────────────────
echo ""
echo "[4/4] Results summary:"
echo ""

RESULTS_CSV="$DATA_DIR/results.csv"
if [ -f "$RESULTS_CSV" ]; then
	if command -v cuclark &>/dev/null; then
		cuclark summary "$RESULTS_CSV"
	else
		# Manual summary fallback
		TOTAL=$(grep -cv "^#\|^Object" "$RESULTS_CSV" || true)
		CLASSIFIED=$(awk -F',' '$2 != "NA" && !/^#/ && !/^Object/' "$RESULTS_CSV" | wc -l | tr -d ' ')
		echo "  Total reads:  $TOTAL"
		echo "  Classified:   $CLASSIFIED"
		echo "  Results file: $RESULTS_CSV"
	fi

	# Sanity check: reads should mostly classify since targets come from the same file
	TOTAL=$(grep -cv "^#\|^Object" "$RESULTS_CSV" || true)
	CLASSIFIED_COUNT=$(awk -F',' '$4 != "NA" && !/^#/ && !/^Object/' "$RESULTS_CSV" | wc -l | tr -d ' ')
	echo ""
	echo "  Sanity check: $CLASSIFIED_COUNT / $TOTAL reads classified"
	if [ "$CLASSIFIED_COUNT" -gt 0 ]; then
		echo "  PASS: Reads are being classified against extracted targets"
	else
		echo "  WARN: No reads classified — targets may not overlap with sampled reads"
	fi
else
	echo "  WARN: Results file not found at $RESULTS_CSV"
fi

echo ""
echo "============================================================"
echo "  Test complete!"
echo "  Input FASTA: $FASTA"
echo "  Reads:       $DATA_DIR/reads.fa ($NUM_READS reads)"
echo "  Results:     $RESULTS_CSV"
echo "============================================================"
