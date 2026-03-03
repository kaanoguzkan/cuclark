#!/bin/bash
set -euo pipefail

#
#   cuCLARK, CLARK for CUDA-enabled GPUs.
#   Copyright 2016-2017, Robin Kobus <rkobus@students.uni-mainz.de>
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
#   download_data_release.sh: To download genomes of latest RefSeq release from NCBI site
#			(for Bacteria, Viruses, etc.).

NCBI_BASE="https://ftp.ncbi.nlm.nih.gov"

if [ $# -ne 2 ]; then
	echo "Usage: $0 <Directory for the sequences> <RefSeq Database: bacteria, viral, ...> "
	exit 1
fi

download_release() {
	local label="$1"
	local release_name="$2"
	local hidden_file="$3"
	local dir_name="$4"

	if [ ! -s "$hidden_file" ]; then
		rm -Rf "$dir_name" "${hidden_file}."*
		mkdir -m 775 "$dir_name"
		cd "$dir_name"
		wget -q "${NCBI_BASE}/refseq/release/RELEASE_NUMBER"
		relnum=$(cat RELEASE_NUMBER)
		echo "RefSeq release ${relnum} found."
		echo "Downloading now ${label} genomes:"
		wget "${NCBI_BASE}/refseq/release/${release_name}/${release_name}.*.genomic.fna.gz"

		if ! ls ${release_name}.*.genomic.fna.gz 1>/dev/null 2>&1; then
			echo "Error: Failed to download '${release_name}' sequences. Are you sure '${release_name}' database exists in RefSeq?"
			cd ..
			rm -rf "${dir_name}"
			exit 1
		fi

		echo "Downloading done. Uncompressing files... "
		gunzip *.gz

		echo "Creating single file for each genome... "
		# Handle both old gi|...|ref|ACCESSION| and modern accession-only headers
		sed -i 's/^>\(gi|[0-9]*|ref|\)\([[:graph:]]*\)|/>\2/' ${release_name}.*.genomic.fna 2>/dev/null || true
		awk '/^>/ {close(file); file=sprintf("%s.fna",substr($1,2,length($1)-1)); print > file; next;} { print >> file; }' ${release_name}.*.genomic.fna
		rm -f ${release_name}.*.genomic.fna RELEASE_NUMBER

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
	download_release "Bacteria" "bacteria" "$1/.bacteria" "$1/Bacteria"
	exit
fi

if [ "$2" = "viruses" ]; then
	download_release "Viruses" "viral" "$1/.viruses" "$1/Viruses"
	exit
fi

download_release "'$2'" "$2" "$1/.$2" "$1/$2"
exit
