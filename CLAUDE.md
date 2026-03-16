# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project is

CuCLARK is a GPU-accelerated metagenomic classifier built in CUDA/C++. It classifies DNA reads against a reference database using discriminative k-mers, running the classification on NVIDIA GPUs.

Two classification engines are built:
- **cuCLARK** (full): 1.6B hash table, ~40 GB RAM, for large databases (NCBI bacteria)
- **cuCLARK-l** (light): 58M hash table, ~1.4 GB RAM, for machines with limited resources

A modern CLI wrapper (`cuclark`) provides subcommands (`classify`, `summary`, `download`, `setup-db`, `list-db`, `version`) with GPU auto-detection and variant auto-selection.

## Build commands

```bash
# Build all targets (release)
cmake -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j$(nproc)

# Install to /usr/local (engines to exe/, wrapper to bin/)
cmake --install build --prefix /usr/local

# Target specific GPU architectures to reduce compile time
cmake -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_CUDA_ARCHITECTURES="86"
```

Requires: CMake 3.20+, GCC (C++17), CUDA Toolkit 11.0+, NVIDIA GPU compute capability 3.5+.

## Docker

```bash
# Build image (CUDA 11.4, sm_35 + sm_86 by default)
docker build -t cuclark .

# Run the MWE integration test
docker run --gpus all --entrypoint bash -v ${PWD}:/data cuclark \
  /opt/cuclark/mwe/test_example_fasta.sh

# Interactive shell
docker run --gpus all --entrypoint bash -it -v ${PWD}:/data cuclark
```

The Dockerfile uses a two-stage build: `nvidia/cuda:11.4.3-devel-ubuntu20.04` for compilation, then `nvidia/cuda:11.4.3-runtime-ubuntu20.04` for the runtime image.

## Testing

The only test is the MWE integration test in `mwe/test_example_fasta.sh`. It:
1. Splits `mwe/uniques.fasta` into per-accession genome files
2. Simulates 200 reads (150 bp) from *E. coli* K-12 (accession `NC_000913.3`)
3. Builds a cuCLARK database from the targets
4. Runs classification and asserts >90% correct species assignment

There are no unit tests. The test requires a GPU and is meant to be run inside the Docker container.

## Code architecture

### Classification pipeline (src/)

- **`CuCLARK_hh.hh`** — Main classifier class template `CuCLARK<HKMERr>`, parameterized by k-mer storage width (T16/T32/T64 = 2/4/8 bytes). Handles database creation, loading, and orchestrating GPU classification.
- **`CuClarkDB.cu` / `CuClarkDB.cuh`** — CUDA implementation of GPU database storage and k-mer lookup kernels.
- **`HashTableStorage_hh.hh`** / **`hashTable_hh.hh`** — In-memory hash table used for the discriminative k-mer database.
- **`main.cc`** — Entry point for `cuCLARK` and `cuCLARK-l` binaries (same source, `CUCLARK_LIGHT` macro selects variant at compile time).
- **`analyser.cc`** — Post-processing and result analysis.
- **`kmersConversion.cc`** — k-mer encoding/decoding utilities.
- **`parameters.hh`** — Compile-time constants: `HTSIZE` (hash table size), `SFACTORMAX`, `VERSION`.

### CLI wrapper (src/cuclark_cli.cc)

Pure C++17, no external dependencies. Implements all subcommands in a single file:
- `cmd_classify`: detects GPUs via `nvidia-smi`, auto-selects full/light variant based on available RAM (threshold: 150 GB), builds the command, and invokes the engine binary.
- `cmd_summary`: parses CSV results and outputs statistics (taxa counts, confidence distribution).
- `cmd_download` / `cmd_setup_db`: delegate to shell scripts in `scripts/`.

### Shell scripts (scripts/)

Legacy workflow scripts called by `cuclark download` and `cuclark setup-db`:
- `set_targets.sh` — Downloads NCBI genomes (if needed), maps accession → taxon ID, writes `targets.txt`
- `classify_metagenome.sh` — Thin wrapper around the `cuCLARK`/`cuCLARK-l` binary
- `download_data.sh` / `download_data_newest.sh` / `download_data_release.sh` — NCBI genome downloaders

### Key data flow

1. `set_targets.sh` → produces `targets.txt` (genome path → taxon ID pairs) and builds the `.ky/.lb/.sz` database files
2. `cuCLARK -T targets.txt -D db/ -O reads.fa -R results` → writes `results.csv`
3. CSV format: `Object_ID, Length, Gamma, 1st_assignment, hits1, 2nd_assignment, hits2, confidence`

### Important constants

- `HTSIZE`: distinguishes full vs light variant (set via `CUCLARK_LIGHT` macro at compile time)
- Default k-mer sizes: 31 (full), 27 (light)
- Database file extensions: `.ky` (k-mers), `.lb` (labels), `.sz` (sizes)
- CuCLARK uses **canonical k-mers** — databases are NOT compatible with original CLARK
