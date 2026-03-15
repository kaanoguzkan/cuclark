#!/bin/bash
set -euo pipefail

# ── Minimal cuCLARK test ─────────────────────────────────────────────
# Downloads 8 bacterial genomes from NCBI, simulates reads from one,
# and classifies them with cuCLARK. No local FASTA file needed.
#
# Always uses cuCLARK (full mode, k=31).
#
# Usage:
#   docker run --gpus all cuclark bash /opt/cuclark/mwe/test_minimal.sh
#   docker run --gpus all cuclark bash /opt/cuclark/mwe/test_minimal.sh /data/mwe_minimal

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="${1:-/data/mwe_minimal}"

# The 8 target accessions
ACCESSIONS=(
	NC_000913.3
	NC_007795.1
	NC_002516.2
	NC_017564.1
	NC_017565.1
	NZ_UHII01000002.1
	NZ_UHII01000001.1
	NZ_LR134352.1
)

READ_SOURCE="${READ_SOURCE:-NC_000913.3}"
NUM_READS="${NUM_READS:-200}"
READ_LEN="${READ_LEN:-150}"
KMER=31
BATCHES="${BATCHES:-4}"

mkdir -p "$DATA_DIR/genomes" "$DATA_DIR/db"

echo "============================================================"
echo "  cuCLARK Minimal Test"
echo "  Output directory: $DATA_DIR"
echo "  Read source:      $READ_SOURCE"
echo "  Reads:            $NUM_READS × ${READ_LEN}bp"
echo "  Targets:          ${#ACCESSIONS[@]} accessions"
echo "============================================================"
echo ""

# ── Step 1: Download genomes from NCBI ─────────────────────────────────
echo "[1/5] Downloading target genomes from NCBI..."

DOWNLOAD_COUNT=0
for acc in "${ACCESSIONS[@]}"; do
	OUTFILE="$DATA_DIR/genomes/${acc}.fna"
	if [ -f "$OUTFILE" ] && [ -s "$OUTFILE" ]; then
		echo "  $acc (cached)"
		DOWNLOAD_COUNT=$((DOWNLOAD_COUNT + 1))
		continue
	fi
	echo -n "  $acc ... "
	if wget -q -O "$OUTFILE" \
		"https://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi?db=nucleotide&id=${acc}&rettype=fasta&retmode=text"; then
		# Verify we got actual FASTA content
		if grep -q "^>" "$OUTFILE" 2>/dev/null; then
			size=$(wc -c < "$OUTFILE" | tr -d ' ')
			echo "OK ($(( size / 1024 )) KB)"
			DOWNLOAD_COUNT=$((DOWNLOAD_COUNT + 1))
		else
			echo "FAILED (not valid FASTA)"
			rm -f "$OUTFILE"
		fi
	else
		echo "FAILED (download error)"
		rm -f "$OUTFILE"
	fi
	# Be nice to NCBI
	sleep 1
done

echo "  Downloaded $DOWNLOAD_COUNT / ${#ACCESSIONS[@]} genomes"

if [ "$DOWNLOAD_COUNT" -lt "${#ACCESSIONS[@]}" ]; then
	echo "  WARNING: Some genomes failed to download. Continuing with available targets."
fi

SOURCE_FASTA="$DATA_DIR/genomes/${READ_SOURCE}.fna"
if [ ! -f "$SOURCE_FASTA" ]; then
	echo ""
	echo "  ERROR: Read source $READ_SOURCE not found. Cannot continue."
	exit 1
fi
echo ""

# ── Step 2: Simulate reads ────────────────────────────────────────────
echo "[2/5] Simulating $NUM_READS reads (${READ_LEN}bp) from $READ_SOURCE..."

READS_FILE="$DATA_DIR/reads.fa"

awk -v rl="$READ_LEN" -v num_reads="$NUM_READS" -v outfile="$READS_FILE" \
    -v src="$READ_SOURCE" '
BEGIN { seq = "" }
!/^>/ { seq = seq $0 }
END {
    srand(42)
    written = 0; attempts = 0; max_att = num_reads * 20
    seqlen = length(seq)
    while (written < num_reads && attempts < max_att) {
        attempts++
        start = int(rand() * (seqlen - rl)) + 1
        rd = substr(seq, start, rl)
        if (length(rd) < rl) continue
        n = gsub(/[Nn]/, "&", rd)
        if (n > rl * 0.1) continue
        printf ">read_%d src=%s pos=%d\n%s\n", written, src, start-1, rd > outfile
        written++
    }
    printf "  Generated %d reads from %s (%d bp genome)\n", written, src, seqlen
}' "$SOURCE_FASTA"

ACTUAL_READS=$(grep -c "^>" "$READS_FILE")
echo "  Total reads: $ACTUAL_READS"
echo ""

# ── Step 3: Create targets file ──────────────────────────────────────
echo "[3/5] Creating targets file..."

rm -rf "$DATA_DIR/db/"*
> "$DATA_DIR/targets.txt"
for acc in "${ACCESSIONS[@]}"; do
	f="$DATA_DIR/genomes/${acc}.fna"
	[ -f "$f" ] && echo "$f	$acc" >> "$DATA_DIR/targets.txt"
done

NUM_TGT=$(wc -l < "$DATA_DIR/targets.txt" | tr -d ' ')
echo "  Created targets.txt with $NUM_TGT targets"
echo ""

# ── Step 4: Run cuCLARK ─────────────────────────────────────────────
echo "[4/5] Running cuCLARK classification..."

if ! command -v cuCLARK &>/dev/null; then
	echo "  SKIP: cuCLARK binary not found (not inside Docker container?)"
	echo ""
	echo "  Steps 1-3 passed. To run classification:"
	echo "    docker build -t cuclark ."
	echo "    docker run --gpus all cuclark bash /opt/cuclark/mwe/test_minimal.sh"
	exit 0
fi

echo "  k=$KMER, batches=$BATCHES"
echo ""
cuCLARK -k "$KMER" \
	-T "$DATA_DIR/targets.txt" \
	-D "$DATA_DIR/db/" \
	-O "$READS_FILE" \
	-R "$DATA_DIR/results" \
	-n 1 -b "$BATCHES" -d 1

# ── Step 5: Evaluate results ────────────────────────────────────────
echo ""
echo "[5/5] Evaluating classification results..."
echo ""

RESULTS_CSV="$DATA_DIR/results.csv"
if [ ! -f "$RESULTS_CSV" ]; then
	echo "  ERROR: Results file not found at $RESULTS_CSV"
	exit 1
fi

TOTAL=$(grep -cv "^#\|^Object" "$RESULTS_CSV" || true)
CLASSIFIED=$(awk -F',' '$4 != "NA" && !/^#/ && !/^Object/' "$RESULTS_CSV" | wc -l | tr -d ' ')
CORRECT=$(awk -F',' -v expected="$READ_SOURCE" \
	'$4 == expected && !/^#/ && !/^Object/' "$RESULTS_CSV" | wc -l | tr -d ' ')
UNCLASSIFIED=$((TOTAL - CLASSIFIED))

HIGH_CONF=$(awk -F',' '!/^#/ && !/^Object/ && $NF+0 >= 0.90' "$RESULTS_CSV" | wc -l | tr -d ' ')

echo "  Ground truth: all reads from $READ_SOURCE"
echo ""
echo "  Total reads:       $TOTAL"
echo "  Classified:        $CLASSIFIED ($(( CLASSIFIED * 100 / TOTAL ))%)"
echo "  Unclassified:      $UNCLASSIFIED"
echo "  Correct species:   $CORRECT / $CLASSIFIED ($(( CLASSIFIED > 0 ? CORRECT * 100 / CLASSIFIED : 0 ))%)"
echo "  High confidence:   $HIGH_CONF (≥0.90)"

echo ""
echo "  Classification breakdown:"
awk -F',' '!/^#/ && !/^Object/ && $4 != "NA" {count[$4]++}
END {for (sp in count) printf "    %-40s %d\n", sp, count[sp]}' "$RESULTS_CSV" | sort -t' ' -k2 -rn

echo ""
if [ "$CORRECT" -eq "$CLASSIFIED" ] && [ "$CLASSIFIED" -gt 0 ]; then
	echo "  PASS: All classified reads correctly assigned to $READ_SOURCE"
elif [ "$CLASSIFIED" -gt 0 ] && [ "$CORRECT" -gt $((CLASSIFIED * 90 / 100)) ]; then
	echo "  PASS: >90% of classified reads correctly assigned"
else
	echo "  WARN: Classification accuracy lower than expected"
fi

echo ""
echo "============================================================"
echo "  Minimal test complete!"
echo "  References:  $NUM_TGT genomes"
echo "  Reads:       $ACTUAL_READS reads from $READ_SOURCE"
echo "  Results:     $RESULTS_CSV"
echo "============================================================"
