#!/bin/bash
set -euo pipefail

# ── CuCLARK Viral Reference Genomes Example ──────────────────────────────────
# A bigger MWE using up to MAX_GENOMES representative/reference viral genomes
# from NCBI RefSeq. Unlike the minimal 3-phage MWE, this demonstrates the
# classifier with diverse viral families (coronaviruses, herpesviruses,
# poxviruses, retroviruses, flaviviruses, etc.).
#
# Designed for RTX 3070 laptop (8 GB VRAM) using cuCLARK-l (light mode).
# Typical run: ~50 genomes, ~2,500 simulated reads, <150 MB database.
#
# Usage (inside Docker container):
#   bash /opt/cuclark/mwe/run_viral_mwe.sh [DATA_DIR] [MAX_GENOMES]
#
# Default DATA_DIR:    /data/viral_mwe
# Default MAX_GENOMES: 50

DATA_DIR="${1:-/data/viral_mwe}"
MAX_GENOMES="${2:-50}"

NCBI_BASE="https://ftp.ncbi.nlm.nih.gov"

echo "============================================================"
echo "  CuCLARK Viral Reference Genomes Example"
echo "  Output directory: $DATA_DIR"
echo "  Max genomes:      $MAX_GENOMES"
echo "============================================================"
echo ""

mkdir -p "$DATA_DIR/genomes" "$DATA_DIR/db"

# ── Step 1: Fetch viral assembly summary ─────────────────────────────────────
echo "[1/6] Fetching NCBI RefSeq viral assembly summary..."

SUMMARY="$DATA_DIR/assembly_summary.txt"
if [ ! -s "$SUMMARY" ]; then
	if command -v wget &>/dev/null; then
		wget -q "${NCBI_BASE}/genomes/refseq/viral/assembly_summary.txt" -O "$SUMMARY"
	elif command -v curl &>/dev/null; then
		curl -sfL "${NCBI_BASE}/genomes/refseq/viral/assembly_summary.txt" -o "$SUMMARY"
	else
		echo "  ERROR: neither wget nor curl found"
		exit 1
	fi
fi

TOTAL_ENTRIES=$(grep -c -v '^#' "$SUMMARY" || true)
echo "  Assembly summary: $TOTAL_ENTRIES entries."

# ── Step 2: Select representative/reference viral genomes ────────────────────
echo "[2/6] Selecting up to $MAX_GENOMES representative viral genomes..."

GENOME_LIST="$DATA_DIR/selected_genomes.tsv"

# Filter: latest complete genomes, deduplicated by first 2 words of organism name
# so we pick one representative per species group (one coronavirus, one herpesvirus,
# one T-phage family, etc.) rather than 50 variations of the same phage.
# Columns: $8=organism_name, $11=version_status, $12=assembly_level, $20=ftp_path
awk -F'\t' -v max="$MAX_GENOMES" '
	!/^#/ &&
	$11 == "latest" &&
	$12 == "Complete Genome" &&
	$20 != "na" {
		# Build a 2-word prefix as the deduplication key
		n = split($8, w, " ")
		key = (n >= 2) ? w[1] " " w[2] : w[1]
		if (!seen[key]++) {
			print $8 "\t" $20
			if (++count >= max) exit
		}
	}
' "$SUMMARY" > "$GENOME_LIST"

NUM_SELECTED=$(wc -l < "$GENOME_LIST" | tr -d ' ')
echo "  Selected $NUM_SELECTED genomes for download."

if [ "$NUM_SELECTED" -eq 0 ]; then
	echo "  ERROR: No genomes matched the filter. NCBI format may have changed."
	exit 1
fi

# ── Step 3: Download genomes ──────────────────────────────────────────────────
echo "[3/6] Downloading genomes from NCBI RefSeq..."

> "$DATA_DIR/targets.txt"
DOWNLOADED=0
FAILED=0

while IFS=$'\t' read -r org_name ftp_dir; do
	# Build a clean label: replace spaces/special chars, truncate to 40 chars
	# (OBJECTNAMEMAX limit in parameters.hh)
	label=$(printf '%s' "$org_name" | tr ' /()[],' '_' | sed 's/__*/_/g; s/^_//; s/_$//')
	label="${label:0:40}"

	outfile="$DATA_DIR/genomes/${label}.fna"

	if [ -f "$outfile" ] && [ -s "$outfile" ]; then
		echo "  Already exists: $label"
		echo -e "${outfile}\t${label}" >> "$DATA_DIR/targets.txt"
		DOWNLOADED=$((DOWNLOADED + 1))
		continue
	fi

	# Construct FNA URL from FTP directory entry
	asm_name="${ftp_dir##*/}"
	url="${ftp_dir}/${asm_name}_genomic.fna.gz"
	# NCBI migrated from ftp:// to https://
	url="${url/ftp:\/\/ftp.ncbi.nlm.nih.gov/https:\/\/ftp.ncbi.nlm.nih.gov}"

	tmpfile="${outfile}.gz"
	if command -v wget &>/dev/null; then
		wget -q "$url" -O "$tmpfile" 2>/dev/null || { echo "  WARN: Download failed for $label"; rm -f "$tmpfile"; FAILED=$((FAILED + 1)); continue; }
	else
		curl -sfL "$url" -o "$tmpfile" 2>/dev/null || { echo "  WARN: Download failed for $label"; rm -f "$tmpfile"; FAILED=$((FAILED + 1)); continue; }
	fi

	if [ ! -s "$tmpfile" ]; then
		echo "  WARN: Empty download for $label"
		rm -f "$tmpfile"
		FAILED=$((FAILED + 1))
		continue
	fi

	gzip -df "$tmpfile"

	if [ -s "$outfile" ]; then
		echo "  Downloaded: $label"
		echo -e "${outfile}\t${label}" >> "$DATA_DIR/targets.txt"
		DOWNLOADED=$((DOWNLOADED + 1))
	else
		echo "  WARN: Decompression failed for $label"
		FAILED=$((FAILED + 1))
	fi
done < "$GENOME_LIST"

echo "  Downloaded: $DOWNLOADED  Failed/skipped: $FAILED"

if [ "$DOWNLOADED" -eq 0 ]; then
	echo "  ERROR: No genomes downloaded successfully."
	exit 1
fi

# ── Step 4: Generate simulated reads ─────────────────────────────────────────
echo "[4/6] Generating simulated reads (50 per genome, 150 bp each)..."

generate_reads() {
	local genome="$1"
	local label="$2"
	local read_len=150
	local num_reads=50

	local seq
	seq=$(grep -v "^>" "$genome" | tr -d '\n\r ')
	local seq_len=${#seq}

	if [ "$seq_len" -lt "$read_len" ]; then
		echo "  WARN: $label genome too short ($seq_len bp), skipping" >&2
		return
	fi

	local i=0
	while [ "$i" -lt "$num_reads" ]; do
		local max_start=$((seq_len - read_len))
		local start=$((RANDOM % max_start))
		local read_seq="${seq:$start:$read_len}"
		echo ">${label}_read_${i}"
		echo "$read_seq"
		i=$((i + 1))
	done
}

> "$DATA_DIR/reads.fa"
while IFS=$'\t' read -r genome_path label; do
	generate_reads "$genome_path" "$label" >> "$DATA_DIR/reads.fa"
done < "$DATA_DIR/targets.txt"

NUM_READS=$(grep -c "^>" "$DATA_DIR/reads.fa")
echo "  Generated $NUM_READS simulated reads from $DOWNLOADED genomes."

# ── Step 5: Run classification ────────────────────────────────────────────────
echo "[5/6] Running cuCLARK classification (auto-selecting variant)..."
echo "  (light mode expected on RTX 3070 laptop with ~7-7.5 GB free VRAM)"
echo ""

cuclark classify \
	--reads "$DATA_DIR/reads.fa" \
	--output "$DATA_DIR/results" \
	--targets "$DATA_DIR/targets.txt" \
	--db-dir "$DATA_DIR/db/" \
	--metadata

# ── Step 6: Show summary ──────────────────────────────────────────────────────
echo ""
echo "[6/6] Classification results:"
echo ""

cuclark summary "$DATA_DIR/results.csv"

echo ""
echo "============================================================"
echo "  Viral MWE complete!"
echo "  Genomes:  $DOWNLOADED viral reference/representative sequences"
echo "  Reads:    $NUM_READS simulated reads"
echo "  Results:  $DATA_DIR/results.csv"
echo ""
echo "  Follow-up commands:"
echo "    cuclark summary $DATA_DIR/results.csv --format json"
echo "    cuclark summary $DATA_DIR/results.csv --krona"
echo "    cuclark summary $DATA_DIR/results.csv --min-confidence 0.9"
echo "============================================================"
