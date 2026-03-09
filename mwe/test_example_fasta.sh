#!/bin/bash
set -euo pipefail

# ── Test script for example.fasta ────────────────────────────────────────
# Validates example.fasta (human chr1) by:
#   1. Checking FASTA format integrity
#   2. Generating simulated reads from it
#   3. Downloading a few small reference genomes (human + viral)
#   4. Classifying the reads with cuCLARK
#   5. Showing a summary of results
#
# Usage (inside Docker container):
#   bash /opt/cuclark/mwe/test_example_fasta.sh [DATA_DIR]
#
# Or from the repo root:
#   bash test_example_fasta.sh [DATA_DIR]
#
# Default DATA_DIR: /data/test_example

DATA_DIR="${1:-/data/test_example}"
FASTA="${2:-$DATA_DIR/example.fasta}"
FASTA_URL="http://donut.cs.bilkent.edu.tr/share/rica_s/rica_s_tl_pbsim3/original_human_pathogen.fasta"

mkdir -p "$DATA_DIR"

# Download example.fasta if not found locally
if [ ! -f "$FASTA" ]; then
	echo "Downloading example.fasta..."
	if command -v wget &>/dev/null; then
		wget --progress=bar:force "$FASTA_URL" -O "$FASTA" || { echo "ERROR: Download failed"; exit 1; }
	elif command -v curl &>/dev/null; then
		curl -sfL "$FASTA_URL" -o "$FASTA" || { echo "ERROR: Download failed"; exit 1; }
	else
		echo "ERROR: neither wget nor curl found"
		exit 1
	fi
	if [ ! -s "$FASTA" ]; then
		echo "ERROR: Downloaded file is empty"
		rm -f "$FASTA"
		exit 1
	fi
	echo "  Downloaded to $FASTA"
fi

echo "============================================================"
echo "  CuCLARK Test: example.fasta"
echo "  Input:            $FASTA"
echo "  Output directory: $DATA_DIR"
echo "============================================================"
echo ""

mkdir -p "$DATA_DIR/genomes" "$DATA_DIR/db"

# ── Step 1: Validate FASTA format ────────────────────────────────────────
echo "[1/6] Validating FASTA format..."

ERRORS=0

# Check header line
HEADER=$(head -1 "$FASTA")
if [[ ! "$HEADER" =~ ^\> ]]; then
	echo "  FAIL: First line is not a FASTA header (expected '>')"
	ERRORS=$((ERRORS + 1))
else
	echo "  OK: Header found: $HEADER"
fi

# Count sequences
NUM_SEQS=$(grep -c "^>" "$FASTA")
echo "  Sequences: $NUM_SEQS"

# Check for invalid characters (sample first 10k lines to avoid scanning 3GB file)
INVALID_LINES=$(head -10001 "$FASTA" | grep -v "^>" | grep -c '[^ACGTNacgtnRYSWKMBDHVryswkmbdhv]' || true)
if [ "$INVALID_LINES" -gt 0 ]; then
	echo "  WARN: $INVALID_LINES lines contain non-standard characters (sampled first 10k lines)"
else
	echo "  OK: All sequence lines contain valid nucleotide characters (sampled first 10k lines)"
fi

# File size (use stat to avoid reading the file; fall back to wc)
FILE_SIZE=$(stat -c%s "$FASTA" 2>/dev/null || wc -c < "$FASTA" | tr -d ' ')
LINE_COUNT=$(wc -l < "$FASTA" | tr -d ' ')
echo "  File size:  $FILE_SIZE bytes"
echo "  Lines:      $LINE_COUNT"

# Check for empty sequences
EMPTY_SEQS=0
prev_header=false
while IFS= read -r line; do
	if [[ "$line" =~ ^\> ]]; then
		if $prev_header; then
			EMPTY_SEQS=$((EMPTY_SEQS + 1))
		fi
		prev_header=true
	else
		prev_header=false
	fi
done < <(head -1000 "$FASTA")  # sample first 1000 lines for speed

if [ "$EMPTY_SEQS" -gt 0 ]; then
	echo "  WARN: $EMPTY_SEQS empty sequence(s) detected (in first 1000 lines)"
else
	echo "  OK: No empty sequences (sampled first 1000 lines)"
fi

# Count actual bases (non-N, sampled — use head/tail to avoid scanning entire file)
SAMPLE_BASES=$(head -10001 "$FASTA" | tail -n +2 | tr -d '\n\r ' | wc -c | tr -d ' ')
SAMPLE_N=$(head -10001 "$FASTA" | tail -n +2 | tr -d '\n\r ' | tr -cd 'Nn' | wc -c | tr -d ' ')
NON_N=$((SAMPLE_BASES - SAMPLE_N))
if [ "$SAMPLE_BASES" -gt 0 ]; then
	N_PCT=$((SAMPLE_N * 100 / SAMPLE_BASES))
	echo "  Sampled first 10k lines: ${SAMPLE_BASES} bases, ${N_PCT}% N's, ${NON_N} informative bases"
fi

if [ "$ERRORS" -gt 0 ]; then
	echo ""
	echo "  FAIL: $ERRORS format error(s) found. Aborting."
	exit 1
fi
echo "  PASS: FASTA format validation complete."

# ── Step 2: Generate simulated reads ─────────────────────────────────────
echo ""
echo "[2/6] Generating simulated reads from example.fasta..."

# Extract a portion of real sequence (skip N-rich beginning) for read generation
# We sample from lines that have real bases, not just N's
python3 -c "
import random
import sys

fasta_path = '$FASTA'
read_len = 150
num_reads = 200

# Read all sequence data
seq_parts = []
with open(fasta_path) as f:
    for line in f:
        if line.startswith('>'):
            continue
        seq_parts.append(line.strip())
        # Only need enough for read generation
        if len(seq_parts) * 60 > 1_000_000:
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

# ── Step 3: Download reference genomes ────────────────────────────────────
echo ""
echo "[3/6] Downloading small reference genomes for classification targets..."

download_genome() {
	local name="$1"
	local url="$2"
	local outfile="$DATA_DIR/genomes/${name}.fna"

	if [ -f "$outfile" ] && [ -s "$outfile" ]; then
		echo "  Already exists: $name"
		return 0
	fi

	echo "  Downloading: $name"
	if command -v wget &>/dev/null; then
		wget -q "$url" -O "${outfile}.gz" || { echo "  WARN: Download failed for $name"; return 1; }
	elif command -v curl &>/dev/null; then
		curl -sfL "$url" -o "${outfile}.gz" || { echo "  WARN: Download failed for $name"; return 1; }
	else
		echo "  ERROR: neither wget nor curl found"
		return 1
	fi

	if [ ! -s "${outfile}.gz" ]; then
		echo "  WARN: Download empty for $name"
		rm -f "${outfile}.gz"
		return 1
	fi

	gzip -df "${outfile}.gz"
	echo "  OK: $name"
}

# Human (small contig for testing), plus a couple of viral genomes
# This lets us test whether reads from human chr1 get classified as human vs viral
download_genome "phiX174" \
	"https://ftp.ncbi.nlm.nih.gov/genomes/all/GCF/000/819/615/GCF_000819615.1_ViralProj14015/GCF_000819615.1_ViralProj14015_genomic.fna.gz"

download_genome "lambda" \
	"https://ftp.ncbi.nlm.nih.gov/genomes/all/GCF/000/840/245/GCF_000840245.1_ViralProj14204/GCF_000840245.1_ViralProj14204_genomic.fna.gz"

download_genome "T4" \
	"https://ftp.ncbi.nlm.nih.gov/genomes/all/GCF/000/845/945/GCF_000845945.1_ViralProj14520/GCF_000845945.1_ViralProj14520_genomic.fna.gz"

# Also use the example.fasta itself as a target (self-classification test)
cp "$FASTA" "$DATA_DIR/genomes/human_chr1.fna"
echo "  Copied example.fasta as human_chr1 target"

echo "  Done."

# ── Step 4: Create targets file ───────────────────────────────────────────
echo ""
echo "[4/6] Creating targets file..."

cat > "$DATA_DIR/targets.txt" <<EOF
$DATA_DIR/genomes/human_chr1.fna	human_chr1
$DATA_DIR/genomes/phiX174.fna	phiX174
$DATA_DIR/genomes/lambda.fna	lambda
$DATA_DIR/genomes/T4.fna	T4
EOF

echo "  Created targets.txt with 4 targets (human_chr1 + 3 viral)"

# ── Step 5: Run classification ────────────────────────────────────────────
echo ""
echo "[5/6] Running cuCLARK classification..."

if command -v cuclark &>/dev/null; then
	cuclark classify \
		--reads "$DATA_DIR/reads.fa" \
		--output "$DATA_DIR/results" \
		--targets "$DATA_DIR/targets.txt" \
		--db-dir "$DATA_DIR/db/" \
		--metadata
elif command -v cuCLARK-l &>/dev/null; then
	echo "  Using cuCLARK-l directly..."
	cuCLARK-l -k 27 \
		-T "$DATA_DIR/targets.txt" \
		-D "$DATA_DIR/db/" \
		-O "$DATA_DIR/reads.fa" \
		-R "$DATA_DIR/results" \
		-n 1 -b 1 -d 1
elif command -v cuCLARK &>/dev/null; then
	echo "  Using cuCLARK directly..."
	cuCLARK -k 31 \
		-T "$DATA_DIR/targets.txt" \
		-D "$DATA_DIR/db/" \
		-O "$DATA_DIR/reads.fa" \
		-R "$DATA_DIR/results" \
		-n 1 -b 1 -d 1
else
	echo "  SKIP: No cuCLARK binary found (not inside Docker container?)"
	echo "  To run classification, build and run inside the Docker container:"
	echo "    docker build -t cuclark ."
	echo "    docker run --gpus all -v \$(pwd):/data cuclark bash /data/test_example_fasta.sh"
	echo ""
	echo "  Validation steps 1-4 passed. Classification skipped."
	exit 0
fi

# ── Step 6: Show results ─────────────────────────────────────────────────
echo ""
echo "[6/6] Results summary:"
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

	# Sanity check: reads from human chr1 should mostly classify as human_chr1
	if [ -f "$RESULTS_CSV" ]; then
		HUMAN_HITS=$(awk -F',' '/human_chr1/ && !/^#/' "$RESULTS_CSV" | wc -l | tr -d ' ')
		echo ""
		echo "  Sanity check: $HUMAN_HITS reads classified as human_chr1"
		if [ "$HUMAN_HITS" -gt 0 ]; then
			echo "  PASS: Reads from human chr1 are being classified back to human_chr1"
		else
			echo "  WARN: No reads mapped to human_chr1 — check if reads contain enough informative sequence"
		fi
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
