#!/bin/bash
set -euo pipefail

#
#   cuCLARK, CLARK for CUDA-enabled GPUs.
#   Copyright 2016-2017, Robin Kobus <rkobus@students.uni-mainz.de>
#
#   based on CLARK version 1.1.3, CLAssifier based on Reduced K-mers.
#   Copyright 2013-2016, Rachid Ounit <rouni001@cs.ucr.edu>
#
#
#   This program is free software: you can redistribute it and/or modify
#   it under the terms of the GNU General Public License as published by
#   the Free Software Foundation, either version 3 of the License, or
#   (at your option) any later version.
#
#   This program is distributed in the hope that it will be useful,
#   but WITHOUT ANY WARRANTY; without even the implied warranty of
#   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#   GNU General Public License for more details.
#
#   You should have received a copy of the GNU General Public License
#   along with this program.  If not, see <http://www.gnu.org/licenses/>.
#
#   download_data.sh: To download genomes from NCBI site (for Bacteria,
#		      Viruses, and Human).

if [ $# -ne 2 ]; then
	echo "Usage: $0 <Directory for the sequences> <Database: bacteria, viruses or human> "
	exit 1
fi

NCBI_BASE="https://ftp.ncbi.nlm.nih.gov"

download_via_assembly_summary() {
	local taxon="$1"
	local refseq_path="$2"
	local summary_url="${NCBI_BASE}/genomes/refseq/${refseq_path}/assembly_summary.txt"

	echo "Downloading assembly summary for ${taxon}..."
	wget -q "${summary_url}" -O assembly_summary.txt

	if [ ! -s assembly_summary.txt ]; then
		echo "Error: Failed to download assembly summary for ${taxon}."
		exit 1
	fi

	awk -F "\t" '$12=="Complete Genome" && $11=="latest"{print $20}' assembly_summary.txt > ftpdirpaths
	awk 'BEGIN{FS=OFS="/";filesuffix="genomic.fna.gz"}{ftpdir=$0;asm=$10;file=asm"_"filesuffix;print ftpdir,file}' ftpdirpaths > ftpfilepaths

	# Convert ftp:// to https:// in generated paths
	sed -i 's|ftp://ftp.ncbi.nlm.nih.gov|https://ftp.ncbi.nlm.nih.gov|g' ftpfilepaths

	echo "Downloading ${taxon} genomes..."
	wget -nc -i ftpfilepaths || true

	echo "Downloading done. Uncompressing files... "
	gunzip *.gz 2>/dev/null || true

	rm -f ftpdirpaths ftpfilepaths assembly_summary.txt
}

if [ "$2" = "bacteria" ]; then

if [ ! -s "$1/.bacteria" ]; then
	rm -Rf "$1/Bacteria" "$1/.bacteria."*
	mkdir -m 775 "$1/Bacteria"
	cd "$1/Bacteria/"

	if command -v datasets &>/dev/null; then
		echo "Using NCBI Datasets CLI to download bacteria genomes..."
		datasets download genome taxon "bacteria" --reference --include genome --filename bacteria.zip
		unzip -o bacteria.zip -d datasets_out
		find datasets_out -name '*.fna' -exec mv {} . \;
		rm -rf bacteria.zip datasets_out
	else
		download_via_assembly_summary "Bacteria" "bacteria"
	fi

	find "$(pwd)" -name '*.fna' > ../.bacteria
	cd ..
	if  [ ! -s .bacteria ]; then
		echo "Error: Failed to download bacteria sequences. "
		exit 1
	fi
	echo "Bacteria sequences downloaded!"
else
	echo "Bacteria sequences already in $1."
fi
exit

fi

if [ "$2" = "viruses" ]; then
if [ ! -s "$1/.viruses" ]; then
	rm -Rf "$1/Viruses" "$1/.viruses."*
	mkdir -m 775 "$1/Viruses"
	cd "$1/Viruses/"

	if command -v datasets &>/dev/null; then
		echo "Using NCBI Datasets CLI to download virus genomes..."
		datasets download genome taxon "viruses" --reference --include genome --filename viruses.zip
		unzip -o viruses.zip -d datasets_out
		find datasets_out -name '*.fna' -exec mv {} . \;
		rm -rf viruses.zip datasets_out
	else
		download_via_assembly_summary "Viruses" "viral"
	fi

	find "$(pwd)" -name '*.fna' > ../.viruses
	cd ..
	if  [ ! -s .viruses ]; then
                echo "Error: Failed to download viruses sequences. "
                exit 1
        fi
	echo "Viruses sequences downloaded!"
else
        echo "Viruses sequences already in $1."
fi
exit
fi

if [ "$2" = "human" ]; then
if [ ! -s "$1/.human" ]; then
	rm -Rf "$1/Human" "$1/.human."*
	mkdir -m 775 "$1/Human"
	cd "$1/Human/"

	if command -v datasets &>/dev/null; then
		echo "Using NCBI Datasets CLI to download human genome..."
		datasets download genome taxon "human" --reference --include genome --filename human.zip
		unzip -o human.zip -d datasets_out
		find datasets_out -name '*.fna' -exec mv {} . \;
		rm -rf human.zip datasets_out
	else
		echo "Downloading human genome from RefSeq..."
		download_via_assembly_summary "Human" "vertebrate_mammalian/Homo_sapiens"
	fi

	find "$(pwd)" -name '*.fna' > ../.human
	cd ../
	if  [ ! -s .human ]; then
                echo "Error: Failed to download human sequences. "
                exit 1
        fi
	echo "Human sequences downloaded!"
else
        echo "Human sequences already in $1."
fi
exit
fi

echo "Failed to recognize parameter: $2. Please choose between: bacteria, viruses, human."
exit 1
