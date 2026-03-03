#!/bin/bash
set -euo pipefail

echo "=== CuCLARK Download URL Reachability Test ==="

NCBI_BASE="https://ftp.ncbi.nlm.nih.gov"
PASS=true
TESTS=0
PASSED=0

check_url() {
	local desc="$1"
	local url="$2"
	TESTS=$((TESTS + 1))

	if wget --spider -q --timeout=10 "$url" 2>/dev/null; then
		echo "  PASS: $desc"
		PASSED=$((PASSED + 1))
	else
		# Try with curl as fallback
		if curl -sf --head --max-time 10 "$url" >/dev/null 2>&1; then
			echo "  PASS: $desc (via curl)"
			PASSED=$((PASSED + 1))
		else
			echo "  FAIL: $desc ($url)"
			PASS=false
		fi
	fi
}

echo "[RefSeq assembly summaries]"
check_url "Bacteria assembly summary" "${NCBI_BASE}/genomes/refseq/bacteria/assembly_summary.txt"
check_url "Viral assembly summary" "${NCBI_BASE}/genomes/refseq/viral/assembly_summary.txt"

echo ""
echo "[Taxonomy data]"
check_url "nucl_gb.accession2taxid.gz" "${NCBI_BASE}/pub/taxonomy/accession2taxid/nucl_gb.accession2taxid.gz"
check_url "nucl_wgs.accession2taxid.gz" "${NCBI_BASE}/pub/taxonomy/accession2taxid/nucl_wgs.accession2taxid.gz"
check_url "taxdump.tar.gz" "${NCBI_BASE}/pub/taxonomy/taxdump.tar.gz"

echo ""
echo "[RefSeq release]"
check_url "RELEASE_NUMBER" "${NCBI_BASE}/refseq/release/RELEASE_NUMBER"

echo ""
echo "Results: $PASSED/$TESTS URLs reachable"

if $PASS; then
	echo "=== Download URL test PASSED ==="
	exit 0
else
	echo "=== Download URL test FAILED ==="
	exit 1
fi
