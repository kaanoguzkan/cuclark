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
#include <string>
#include <vector>
#include <cstring>
#include <fstream>


#include "./file.hh"

void getElementsFromLine(char*& line, const size_t& len, const int _maxElement, std::vector< std::string >& _elements)
{
	size_t t = 0; 
	size_t cpt = 0;
	_elements.resize(0);
	while (t < len && cpt < _maxElement)
	{
		while ( t < len  && (line[t] == ' ' || line[t] == '\t' || line[t] == '\n' || line[t] == '\r'))
		{       t++;
		}
		std::string v = "";
		while ( t < len && line[t] != ' '  && line[t] != '\t' && line[t] != '\n' && line[t] != '\r')
		{
			v.push_back(line[t]);
			t++;
		}
		if (v != "")
		{
			_elements.push_back(v);
			cpt++;
		}
	}
	return;
}

void getElementsFromLine(const std::string& line, const size_t& _maxElement, std::vector< std::string >& _elements)
{
	size_t t = 0, len = line.size();
	size_t cpt = 0;
	_elements.resize(0);
	while (t < len && cpt < _maxElement)
	{
		while (t <  len && (line[t] == ' ' || line[t] == ',' || line[t] == '\n' || line[t] == '\t' || line[t] == '\r'))
		{       t++;
		}
		std::string v = "";
		while (t <  len && line[t] != ' '  && line[t] != ',' && line[t] != '\n' && line[t] != '\t' && line[t] != '\r')
		{
			v.push_back(line[t]);
			t++;
		}
		if (v != "")
		{	
			_elements.push_back(v);
			cpt++;
		}
	}
	return;
}

void getElementsFromLine(const std::string& line, const std::vector<char>& _seps, std::vector< std::string >& _elements)
{
	size_t t = 0, len = line.size();
	size_t cpt = 0;
	_elements.resize(0);
	while (t < len)
	{
		bool checkSep = true;
		while (t < len && checkSep)
		{
			checkSep = false;
			for(size_t i = 0; i < _seps.size() && !checkSep;i++)
			{ checkSep =  line[t] == _seps[i];}
			t += checkSep ? 1:0;
		}
		std::string v = "";
		checkSep = true;
		while (checkSep && t < len)
		{
			for(size_t i = 0 ; i < _seps.size() && checkSep; i++)
			{
				checkSep = checkSep && line[t] != _seps[i];
			}
			if (checkSep)
			{
				v.push_back(line[t]);
				t++;
			}
		}
		if (v != "")
		{_elements.push_back(v);}
	}
	return;
}

bool getLineFromFile(std::ifstream& _fileStream, std::string& _line)
{
	if (std::getline(_fileStream, _line))
	{
		if (!_line.empty() && _line.back() == '\r')
		{	_line.pop_back();	}
		return true;
	}
	else
	{
		_line = "";
		return false;
	}
}

bool getFirstElementInLineFromFile(std::ifstream& _fileStream, std::string& _line)
{
	std::string rawLine;
	if (std::getline(_fileStream, rawLine))
	{
		std::vector<std::string> ele;
		getElementsFromLine(rawLine, 1, ele);
		_line = ele[0];
		return true;
	}
	else
	{
		_line = "";
		return false;
	}
}

bool getFirstAndSecondElementInLine(std::ifstream& _fileStream, uint64_t& _kIndex, ITYPE& _index)
{
	std::string rawLine;
	if (std::getline(_fileStream, rawLine))
	{
		std::vector<std::string> ele;
		getElementsFromLine(rawLine, 2, ele);
		_kIndex = std::stoull(ele[0]);
		_index = std::stol(ele[1]);
		return true;
	}
	return false;
}

bool getFirstAndSecondElementInLine(std::ifstream& _fileStream, std::string& _line, ITYPE& _freq)
{
	std::string rawLine;
	if (std::getline(_fileStream, rawLine))
	{
		std::vector<std::string> ele;
		getElementsFromLine(rawLine, 2, ele);
		_line = ele[0];
		_freq = std::stoi(ele[1]);
		return true;
	}
	return false;
}


void mergePairedFiles(const char* _file1, const char* _file2, const char* _objFile)
{
        std::string line1, line2 = "";
        std::vector<std::string> ele1;
        std::vector<std::string> ele2;
        std::vector<char> sep;
        sep.push_back(' ');
        sep.push_back('/');
        sep.push_back('\t');
        std::ifstream fd1(_file1);
        std::ifstream fd2(_file2);
        getLineFromFile(fd1, line1);
        getLineFromFile(fd2, line2);
        if (line1[0] != line2[0])
        {
                perror("Error: the files have different format!");
                exit(1);
        }
        char delim = line1[0];
        if (delim != '@')
        {
                perror("Error: paired-end reads must be FASTQ files!");
                exit(1);
        }
        sep.push_back(delim);
        fd1.clear(); fd1.seekg(0);
        fd2.clear(); fd2.seekg(0);
        std::ofstream fout(_objFile, std::ios::binary);
        while(getLineFromFile(fd1, line1) && getLineFromFile(fd2, line2))
        {
                if (line1[0] == delim && line2[0] == delim)
                {
                        ele1.clear();
                        ele2.clear();
                        getElementsFromLine(line1, sep, ele1);
                        getElementsFromLine(line2, sep, ele2);
                        if (ele1[0] != ele2[0])
                        {
                                perror("Error: read id does not match between files!");
                                exit(1);
                        }
                        fout << ">" << ele1[0] << std::endl;
                        if (getLineFromFile(fd1, line1) && getLineFromFile(fd2, line2))
                        {
                                fout << line1 << "N" << line2 << std::endl;
                                if (getLineFromFile(fd1, line1) && getLineFromFile(fd2, line2))
                                {
                                        if (getLineFromFile(fd1, line1) && getLineFromFile(fd2, line2))
                                        {       continue;       }
                                }
                        }
                        else
                        {
                                perror("Error: Found read without sequence");
                                exit(1);
                        }
                        continue;
                }
        }
        fd1.close();
        fd2.close();
        fout.close();
}

void deleteFile(const char* _filename)
{
        if (_filename != nullptr)
                remove(_filename);
}

bool validFile(const char* _file)
{
        std::ifstream fd(_file);
        return fd.good();
}
