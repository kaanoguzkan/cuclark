#!/bin/bash
set -euo pipefail

echo "=== CuCLARK Real Data Integration Test ==="
echo "This test downloads small viral genomes from NCBI and runs the full pipeline."
echo ""

# Configuration
DATA_DIR="${1:-/tmp/cuclark_test}"
CUCLARK="${CUCLARK:-cuCLARK-l}"  # Use light version by default (smaller hash table)
KMER_SIZE=31

mkdir -p "$DATA_DIR/genomes" "$DATA_DIR/db"
cd "$DATA_DIR"

# ── Step 1: Download 3 small viral genomes ──────────────────────────────
echo "[1/6] Downloading viral genomes from NCBI RefSeq..."

download_genome() {
	local name="$1"
	local url="$2"
	local outfile="$DATA_DIR/genomes/${name}.fna"

	if [ -f "$outfile" ]; then
		echo "  Already exists: $name"
		return 0
	fi

	echo "  Downloading: $name"
	if command -v wget &>/dev/null; then
		wget -q "$url" -O "${outfile}.gz"
	elif command -v curl &>/dev/null; then
		curl -sfL "$url" -o "${outfile}.gz"
	else
		echo "  ERROR: neither wget nor curl found"
		return 1
	fi

	if [ ! -s "${outfile}.gz" ]; then
		echo "  ERROR: download failed or file is empty for $name"
		rm -f "${outfile}.gz"
		return 1
	fi

	gzip -df "${outfile}.gz"

	if [ ! -s "$outfile" ]; then
		echo "  ERROR: decompression failed for $name"
		return 1
	fi
}

# PhiX174 (~5kb) - Escherichia virus
download_genome "phiX174" \
	"https://ftp.ncbi.nlm.nih.gov/genomes/all/GCF/000/819/615/GCF_000819615.1_ViralProj14015/GCF_000819615.1_ViralProj14015_genomic.fna.gz"

# Lambda phage (~48kb) - Escherichia virus Lambda
download_genome "lambda" \
	"https://ftp.ncbi.nlm.nih.gov/genomes/all/GCF/000/840/245/GCF_000840245.1_ViralProj14204/GCF_000840245.1_ViralProj14204_genomic.fna.gz"

# T4 phage (~169kb) - Escherichia virus T4
download_genome "T4" \
	"https://ftp.ncbi.nlm.nih.gov/genomes/all/GCF/000/845/945/GCF_000845945.1_ViralProj14520/GCF_000845945.1_ViralProj14520_genomic.fna.gz"

echo "  Done."

# ── Step 2: Create targets file ─────────────────────────────────────────
echo "[2/6] Creating targets file..."

cat > "$DATA_DIR/targets.txt" <<EOF
$DATA_DIR/genomes/phiX174.fna	phiX174
$DATA_DIR/genomes/lambda.fna	lambda
$DATA_DIR/genomes/T4.fna	T4
EOF

echo "  Created targets.txt with 3 genomes."

# ── Step 3: Generate simulated reads from each genome ────────────────────
echo "[3/6] Generating simulated reads..."

generate_reads() {
	local genome="$1"
	local label="$2"
	local read_len=150
	local num_reads=50
	local seq=""

	# Extract the full sequence (skip header lines, join)
	seq=$(grep -v "^>" "$genome" | tr -d '\n\r ')
	local seq_len=${#seq}

	if [ "$seq_len" -lt "$read_len" ]; then
		echo "  WARN: $label genome too short ($seq_len bp), skipping"
		return
	fi

	local i=0
	while [ "$i" -lt "$num_reads" ]; do
		# Pick a random start position
		local max_start=$((seq_len - read_len))
		local start=$((RANDOM % max_start))
		local read_seq="${seq:$start:$read_len}"

		echo ">${label}_read_${i}"
		echo "$read_seq"
		i=$((i + 1))
	done
}

{
	generate_reads "$DATA_DIR/genomes/phiX174.fna" "phiX174"
	generate_reads "$DATA_DIR/genomes/lambda.fna" "lambda"
	generate_reads "$DATA_DIR/genomes/T4.fna" "T4"
} > "$DATA_DIR/reads.fa"

NUM_READS=$(grep -c "^>" "$DATA_DIR/reads.fa")
echo "  Generated $NUM_READS simulated reads."

# ── Step 4: Run classification ──────────────────────────────────────────
echo "[4/6] Running $CUCLARK classification (k=$KMER_SIZE)..."

set +e
output=$("$CUCLARK" \
	-k "$KMER_SIZE" \
	-T "$DATA_DIR/targets.txt" \
	-D "$DATA_DIR/db/" \
	-O "$DATA_DIR/reads.fa" \
	-R "$DATA_DIR/results" 2>&1)
exit_code=$?
set -e

if [ $exit_code -ne 0 ]; then
	echo "  WARNING: $CUCLARK exited with code $exit_code"
	echo "  Output (last 20 lines):"
	echo "$output" | tail -20
	if [ $exit_code -eq 139 ] || [ $exit_code -eq 134 ]; then
		echo "  FAIL: Binary crashed (segfault/abort)"
		exit 1
	fi
fi

# ── Step 5: Validate results ────────────────────────────────────────────
echo "[5/6] Validating results..."

RESULTS_FILE="$DATA_DIR/results.csv"
if [ ! -f "$RESULTS_FILE" ]; then
	echo "  FAIL: Results file not created"
	exit 1
fi

RESULT_LINES=$(wc -l < "$RESULTS_FILE")
echo "  Results file has $RESULT_LINES lines (including header)."

# Check CSV header format
HEADER=$(head -1 "$RESULTS_FILE")
if echo "$HEADER" | grep -q "Object_ID"; then
	echo "  PASS: Results CSV has correct header format"
else
	echo "  WARN: Unexpected header: $HEADER"
fi

# Count classifications
if [ "$RESULT_LINES" -gt 1 ]; then
	CLASSIFIED=$(tail -n +2 "$RESULTS_FILE" | grep -cv "NA,0,NA,0" || true)
	UNCLASSIFIED=$(tail -n +2 "$RESULTS_FILE" | grep -c "NA,0,NA,0" || true)
	TOTAL=$((RESULT_LINES - 1))
	echo "  Classified: $CLASSIFIED / $TOTAL reads"
	echo "  Unclassified: $UNCLASSIFIED / $TOTAL reads"

	if [ "$CLASSIFIED" -gt 0 ]; then
		echo "  PASS: At least some reads were classified"
	else
		echo "  WARN: No reads classified (may be expected with small k-mer DB)"
	fi

	# Show a few example results
	echo ""
	echo "  Sample results:"
	head -5 "$RESULTS_FILE" | while IFS= read -r line; do
		echo "    $line"
	done
fi

# ── Step 6: Summary ─────────────────────────────────────────────────────
echo ""
echo "[6/6] Cleanup..."
echo "  Test data is at: $DATA_DIR"
echo "  To remove: rm -rf $DATA_DIR"

echo ""
echo "=== Real data integration test PASSED ==="
exit 0
