#!/bin/bash
set -euo pipefail

#
#   cuCLARK, CLARK for CUDA-enabled GPUs.
#   Copyright 2016-2017, Robin Kobus <rkobus@students.uni-mainz.de>
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
#   download_data_newest.sh: To download newest RefSeq genomes from NCBI site (for Bacteria,
#		      	Viruses, etc.).

NCBI_BASE="https://ftp.ncbi.nlm.nih.gov"

if [ $# -ne 2 ]; then
	echo "Usage: $0 <Directory for the sequences> <Database: bacteria, viruses, ...> "
	exit 1
fi

download_refseq() {
	local label="$1"
	local refseq_name="$2"
	local hidden_file="$3"
	local dir_name="$4"

	if [ ! -s "$hidden_file" ]; then
		rm -Rf "$dir_name" "${hidden_file}."*
		mkdir -m 775 "$dir_name"
		cd "$dir_name"
		echo "Downloading now ${label} genomes:"
		wget -q "${NCBI_BASE}/genomes/refseq/${refseq_name}/assembly_summary.txt"
		if [ -s "assembly_summary.txt" ]; then
			awk -F "\t" '$12=="Complete Genome" && $11=="latest"{print $20}' assembly_summary.txt > ftpdirpaths
			awk 'BEGIN{FS=OFS="/";filesuffix="genomic.fna.gz"}{ftpdir=$0;asm=$10;file=asm"_"filesuffix;print ftpdir,file}' ftpdirpaths > ftpfilepaths
			sed -i 's|ftp://ftp.ncbi.nlm.nih.gov|https://ftp.ncbi.nlm.nih.gov|g' ftpfilepaths
			wget -nc -i ftpfilepaths || true

			echo "Downloading done. Uncompressing files... "
			gunzip *.gz 2>/dev/null || true

			rm -f ftpdirpaths ftpfilepaths assembly_summary.txt
		else
			echo "Error: Couldn't find assembly_summary text file!"
			exit 1
		fi

		find "$(pwd)" -name '*.fna' > "../${hidden_file##*/}"
		cd ..
		if [ ! -s "${hidden_file##*/}" ]; then
			echo "Error: Failed to download ${label} sequences. "
			exit 1
		fi
		echo "${label} sequences downloaded!"
	else
		echo "${label} sequences already in $1."
	fi
}

if [ "$2" = "bacteria" ]; then
	download_refseq "Bacteria" "bacteria" "$1/.bacteria" "$1/Bacteria"
	exit
fi

if [ "$2" = "viruses" ]; then
	download_refseq "Viruses" "viral" "$1/.viruses" "$1/Viruses"
	exit
fi

download_refseq "'$2'" "$2" "$1/.$2" "$1/$2"
exit
