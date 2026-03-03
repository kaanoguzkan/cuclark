/*
 * CLARK, CLAssifier based on Reduced K-mers.
 */

/*
   This program is free software: you can redistribute it and/or modify
   it under the terms of the GNU General Public License as published by
   the Free Software Foundation, either version 3 of the License, or
   (at your option) any later version.

   This program is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
   GNU General Public License for more details.

   You should have received a copy of the GNU General Public License
   along with this program.  If not, see <http://www.gnu.org/licenses/>.

   Copyright 2013-2016, Rachid Ounit <rouni001@cs.ucr.edu>
 */

/*
 * @author: Rachid Ounit, Ph.D Candidate.
 * @project: CLARK, Metagenomic and Genomic Sequences Classification project.
 * @note: C++ IMPLEMENTATION supported on latest Linux and Mac OS.
 *
 */

#include <cstdlib>
#include <iostream>
#include <vector>
#include <cstring>
#include <iomanip>
#include <cstdint>
#include "./file.hh"
#include <map>

struct seqData
{
	std::string 	Name;
	std::string	Accss; 
	seqData():Name(""),Accss("")
	{}
};

int main(int argc, char** argv)
{
	if (argc != 4)
	{
		std::cerr << "Usage: "<< argv[0] << " <./file of filenames> <./nucl_accession2taxid> <./merged.dmp>"<< std::endl;
		exit(-1);
	}
	std::ifstream oldTx(argv[3]);
        if (!oldTx.is_open())
        {
                std::cerr << "Failed to open " << argv[3] << std::endl;
                exit(-1);
        }
	std::ifstream accToTx(argv[2]);
	if (!accToTx.is_open())
	{
		std::cerr << "Failed to open " << argv[2] << std::endl;
		exit(-1);
	}
	std::ifstream meta_f(argv[1]);
	if (!meta_f.is_open())
	{
		std::cerr << "Failed to open " << argv[1] << std::endl;
		exit(1);
	}
	///////////////////////////////////
	std::string line, file;
	std::vector<std::string> ele, eles;
        std::vector<char> sep, seps;
        sep.push_back('|');
	sep.push_back('.');
	sep.push_back('>');
	seps.push_back(' ');
	seps.push_back('\t');
	seps.push_back(':');
	std::vector<int> TaxIDs;
	std::map<std::string,uint32_t> accToidx;
	std::vector<seqData> seqs;
	std::map<std::string,uint32_t>::iterator it;
	uint32_t idx = 0, i_accss = 0;
	std::string acc = "";
	std::cerr << "Loading accession number of all files... " ;
	while (getLineFromFile(meta_f, file))
	{
		std::ifstream fd(file.c_str());
		if (!fd.is_open())
		{
			std::cerr << "Failed to open sequence file: " <<  file << std::endl;
			std::cout << file << "\tUNKNOWN" << std::endl;
			continue;
		}
		if (getLineFromFile(fd, line))
		{
			ele.clear();
			getElementsFromLine(line, seps, ele);
			if (line[0] != '>' || ele.size() < 1)
			{
				continue;
			}
			eles.clear();
			getElementsFromLine(ele[0], sep, eles);

			i_accss = eles.size()>1?eles.size()-2:0;
			acc = eles[i_accss];
			it = accToidx.find(acc);

			if (it == accToidx.end())
			{
				TaxIDs.push_back(-1);
				accToidx[acc] = idx++;
			}
			seqData s;
			s.Name = file;
			s.Accss = acc;
			seqs.push_back(s);
		}
		fd.close();
	}
	meta_f.close();
	std::cerr << "done ("<< accToidx.size() << ")" << std::endl;

	std::string on_line;
	sep.push_back(' ');
	sep.push_back('\t');
	std::map<int, int> 		oldTonew;
	std::map<int, int>::iterator	it_on;

	std::cerr << "Loading merged Tax ID... " ;
	while (getLineFromFile(oldTx,on_line))
	{
		ele.clear();
		getElementsFromLine(on_line, sep, ele);
		it_on = oldTonew.find(std::stoi(ele[0]));
		if (it_on == oldTonew.end())
		{
			oldTonew[std::stoi(ele[0])] = std::stoi(ele[1]);
		}
	}	
	oldTx.close();
	std::cerr << "done" << std::endl;

	std::string pair;
	int taxID, new_taxID;
        std::vector<char> sepg;
        sepg.push_back(' ');
        sepg.push_back('\t');
	uint32_t cpt = 0, cpt_u = 0;
        std::cerr << "Retrieving taxonomy ID for each file... " ;
        size_t taxidTofind = TaxIDs.size(), taxidFound = 0;
	while (getLineFromFile(accToTx, pair) && taxidFound < taxidTofind)
        {
                ele.clear();
                getElementsFromLine(pair, sepg, ele);
                acc = ele[0];
		taxID = std::stoi(ele[2]);
                it = accToidx.find(acc);
		if (it != accToidx.end())
		{
			taxidFound++;
			new_taxID = taxID;
			it_on = oldTonew.find(taxID);
			if (it_on != oldTonew.end())
			{	new_taxID = it_on->second;	}
			TaxIDs[it->second] = new_taxID;
		}
        }
        accToTx.close();
	for(size_t t = 0; t < seqs.size(); t++)
	{
		std::cout << seqs[t].Name << "\t" ;
		it = accToidx.find(seqs[t].Accss);
		std::cout << seqs[t].Accss << "\t" << TaxIDs[it->second] << std::endl;
		if (TaxIDs[it->second]  == -1)
		{	cpt_u++; }
		else
		{	cpt++;	 }
	}
	std::cerr << "done (" << cpt << " files were successfully mapped";
	if (cpt_u > 0)
	{	std::cerr <<  ", and "<< cpt_u << " unidentified";	}
	std::cerr << ")." << std::endl;
	return 0;
}

