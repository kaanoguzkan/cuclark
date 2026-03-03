#!/bin/bash
set -euo pipefail

#
#   CLARK, CLAssifier based on Reduced K-mers.
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
#   Copyright 2013-2016, Rachid Ounit <rouni001@cs.ucr.edu>
#   updateTaxonomy.sh: To download latest files of taxonomy tree data from NCBI site.
#

NCBI_BASE="https://ftp.ncbi.nlm.nih.gov"

for DIR in $(cat ./.DBDirectory)
do
cd "$DIR/taxonomy/"

echo "Downloading... "
wget "${NCBI_BASE}/pub/taxonomy/accession2taxid/nucl_gb.accession2taxid.gz"
wget "${NCBI_BASE}/pub/taxonomy/accession2taxid/nucl_wgs.accession2taxid.gz"
wget "${NCBI_BASE}/pub/taxonomy/taxdump.tar.gz"

if [ -s nucl_gb.accession2taxid.gz ] && [ -s taxdump.tar.gz ] && [ -s nucl_wgs.accession2taxid.gz ] ; then
        echo "Uncompressing files... "
        gunzip nucl_wgs.accession2taxid.gz
        gunzip nucl_gb.accession2taxid.gz
        tar -zxf taxdump.tar.gz
        if [ -s nucl_gb.accession2taxid ] && [ -s nodes.dmp ] && [ -s nucl_wgs.accession2taxid ]; then
                cat nucl_gb.accession2taxid > ./nucl_accss
                cat nucl_wgs.accession2taxid >> ./nucl_accss
                touch ../.taxondata
        else
                echo "Failed to uncompress taxonomy data."
        fi
else
        echo "Failed to download taxonomy data!"
        exit 1
fi

done
