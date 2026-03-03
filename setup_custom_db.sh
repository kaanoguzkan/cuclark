#!/bin/bash
set -euo pipefail

#
#   cuCLARK, CLARK for CUDA-enabled GPUs.
#
#   setup_custom_db.sh: Helper script for setting up a custom database.
#   Takes a directory of FASTA files and a taxonomy mapping file,
#   creates the .fileToTaxIDs format expected by getTargetsDef.
#

if [ $# -lt 2 ]; then
	echo "Usage: $0 <FASTA directory> <taxonomy mapping file> [output directory]"
	echo ""
	echo "  FASTA directory:      Directory containing .fna/.fasta/.fa genome files"
	echo "  taxonomy mapping file: Tab-separated file with columns: filename<TAB>taxid"
	echo "  output directory:     Directory for database output (default: ./db)"
	echo ""
	echo "Example taxonomy mapping file:"
	echo "  genome1.fna	12345"
	echo "  genome2.fasta	67890"
	exit 1
fi

FASTA_DIR="$1"
TAX_MAP="$2"
OUTPUT_DIR="${3:-./db}"

if [ ! -d "$FASTA_DIR" ]; then
	echo "Error: FASTA directory '$FASTA_DIR' does not exist."
	exit 1
fi

if [ ! -f "$TAX_MAP" ]; then
	echo "Error: Taxonomy mapping file '$TAX_MAP' does not exist."
	exit 1
fi

mkdir -p "$OUTPUT_DIR"

echo "Setting up custom database in $OUTPUT_DIR ..."

# Create .fileToTaxIDs: each line is "full_path_to_fasta<TAB>taxid"
> "$OUTPUT_DIR/.fileToTaxIDs"

while IFS=$'\t' read -r filename taxid; do
	# Skip empty lines and comments
	[[ -z "$filename" || "$filename" == \#* ]] && continue

	fasta_path="$FASTA_DIR/$filename"
	if [ ! -f "$fasta_path" ]; then
		echo "Warning: File '$fasta_path' not found, skipping."
		continue
	fi

	echo "$(cd "$FASTA_DIR" && pwd)/$filename	$taxid" >> "$OUTPUT_DIR/.fileToTaxIDs"
done < "$TAX_MAP"

# Create file list for targets
find "$(cd "$FASTA_DIR" && pwd)" -name '*.fna' -o -name '*.fasta' -o -name '*.fa' > "$OUTPUT_DIR/.custom"

count=$(wc -l < "$OUTPUT_DIR/.fileToTaxIDs")
echo "Custom database setup complete: ${count} genome(s) mapped."
echo "Database directory: $OUTPUT_DIR"
echo ""
echo "Next steps:"
echo "  1. Download taxonomy data:  ./download_taxondata.sh $OUTPUT_DIR/taxonomy"
echo "  2. Run classification:      ./exe/cuCLARK -T $OUTPUT_DIR/.fileToTaxIDs -D $OUTPUT_DIR/ -O <reads> -R <results>"
