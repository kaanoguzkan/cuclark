# CuCLARK Modernization — COMPLETE

All five phases of the CuCLARK modernization have been implemented.

---

## Phase 1: Build System ✅ COMPLETE

- **CMakeLists.txt** created — CMake 3.20+, native CUDA language support, C++17
- Target architectures: `70;75;80;86;89;90` (Volta through Hopper)
- Two build variants (`cuCLARK` and `cuCLARK-l`) via `-DCUCLARK_LIGHT` compile definition
- **parameters.hh** merged with light variant using `#ifdef CUCLARK_LIGHT`
- `parameters_light_hh` deleted
- **GPU checks updated** in `src/CuClarkDB.cu`: removed hardcoded device names, `major >= 7`
- **install.sh** updated to use CMake
- Old `Makefile` and `src/Makefile` deleted
- C++17 headers: `<cstdint>`, `<cstdio>`, `<cstring>`, `<cinttypes>`

---

## Phase 2: C++ Modernization ✅ COMPLETE

### 2.1 `sVector` → `std::vector`
- Deleted custom `sVector<T>` struct from `src/dataType.hh`
- Updated `src/hashTable_hh.hh` to use `std::vector<std::vector<htCell<...>>>`

### 2.2 `sprintf` → `std::string`
- Replaced all `calloc` + `sprintf` + `free` patterns with `std::string` concatenation
- Files changed: `CuCLARK_hh.hh`, `hashTable_hh.hh`, `CuClarkDB.cu`
- `getdbName` signature changed from `char*` to `std::string&`

### 2.3 `atoi`/`atoll`/`atol` → safe alternatives
- All replaced with `std::stoi`, `std::stoll`, `std::stoull`
- Files changed: `main.cc`, `file.cc`, `getAccssnTaxID.cc`, `getfilesToTaxNodes.cc`, `getTargetsDef.cc`, `HashTableStorage_hh.hh`

### 2.4 `NULL` → `nullptr`
- Global replacement across all source files

### 2.5 CUDA RAII wrappers (`src/cuda_utils.hh`)
- `CUDA_CHECK(call)` macro — wraps CUDA calls with error checking
- `CudaDevicePtr<T>` — RAII for `cudaMalloc`/`cudaFree` (stores device_id for multi-GPU)
- `CudaPinnedPtr<T>` — RAII for `cudaMallocHost`/`cudaFreeHost`
- `CudaEvent` — RAII for `cudaEventCreateWithFlags`/`cudaEventDestroy`

### 2.6 RAII applied in `src/CuClarkDB.cu`
- Deleted `CUERR` and `CUMEMERR` macros, replaced all usages with `CUDA_CHECK()`
- Each CUDA API call individually wrapped

### 2.7 `std::unique_ptr` for owning pointers
- `m_centralHt` → `std::unique_ptr<EHashtable<HKMERr, rElement>>`
- `m_cuClarkDb` → `std::unique_ptr<CuClarkDB<HKMERr>>`
- Removed manual `delete` in destructor, `new` → `std::make_unique`

### 2.8 Modern file I/O
- `src/file.hh` / `src/file.cc`: `FILE*` → `std::ifstream` for text I/O functions
- POSIX `getline()` + `char*` → `std::getline()` + `std::string`
- `rewind()` → `clear()` + `seekg(0)`
- `fopen`/`fclose` → `std::ifstream` constructor / RAII
- Binary I/O in hash table read/write retained `FILE*` for performance

### 2.9 Removed `using namespace std;`
- Removed from all headers: `CuCLARK_hh.hh`, `hashTable_hh.hh`, `HashTableStorage_hh.hh`
- Removed from all source files: `main.cc`, `file.cc`, `kmersConversion.cc`, `getAccssnTaxID.cc`, `getfilesToTaxNodes.cc`, `getTargetsDef.cc`
- All standard library types fully qualified with `std::`

---

## Phase 3: Fix NCBI Download Scripts ✅ COMPLETE

### 3.1 FTP → HTTPS
- All scripts updated: `ftp://ftp.ncbi.nih.gov/` → `https://ftp.ncbi.nlm.nih.gov/`
- Scripts: `download_data.sh`, `download_data_newest.sh`, `download_data_release.sh`, `download_taxondata.sh`, `updateTaxonomy.sh`

### 3.2 Fixed broken paths in `download_data.sh`
- Replaced deprecated archive paths with NCBI Datasets CLI (primary) + `assembly_summary.txt` (fallback)
- Added `download_via_assembly_summary()` helper function

### 3.3 Fixed GI number handling in `download_data_release.sh`
- `sed` command updated to tolerate missing `gi|` prefix (modern accession-only headers)

### 3.4 Created `setup_custom_db.sh`
- Helper script for custom database setup
- Takes FASTA directory + taxonomy mapping TSV, creates `.fileToTaxIDs` format

### 3.5 Script hardening
- All scripts: `#!/bin/bash` + `set -euo pipefail`
- Proper variable quoting throughout

---

## Phase 4: Containerization ✅ COMPLETE

- **Dockerfile**: Multi-stage build (CUDA 12.4 devel → runtime), `libgomp1` for OpenMP
- **.dockerignore**: Excludes `build/`, `exe/`, `data/`, `.git/`
- **docker-compose.yml**: GPU-enabled compose config with volume mount

---

## Phase 5: Testing & Verification ✅ COMPLETE

### Test scripts created in `tests/`:

| Script | Purpose |
|--------|---------|
| `test_build.sh` | CMake build verification for `cuCLARK` and `cuCLARK-l` |
| `test_cli.sh` | CLI argument parsing: `--help`, `--version`, no args, invalid args |
| `test_classify.sh` | Smoke test with synthetic FASTA data — verifies no crash |
| `test_docker.sh` | Docker image build + container execution + GPU access |
| `test_downloads.sh` | NCBI HTTPS URL reachability (HEAD requests) |

---

## Files Summary

| File | Status |
|------|--------|
| `CMakeLists.txt` | Created (Phase 1) |
| `src/cuda_utils.hh` | Created (Phase 2) — CUDA RAII wrappers |
| `setup_custom_db.sh` | Created (Phase 3) — custom DB helper |
| `Dockerfile` | Created (Phase 4) |
| `.dockerignore` | Created (Phase 4) |
| `docker-compose.yml` | Created (Phase 4) |
| `tests/test_build.sh` | Created (Phase 5) |
| `tests/test_cli.sh` | Created (Phase 5) |
| `tests/test_classify.sh` | Created (Phase 5) |
| `tests/test_docker.sh` | Created (Phase 5) |
| `tests/test_downloads.sh` | Created (Phase 5) |
| `src/CuClarkDB.cu` | Modernized (Phases 1, 2) |
| `src/CuCLARK_hh.hh` | Modernized (Phase 2) |
| `src/dataType.hh` | Modernized (Phase 2) — sVector removed |
| `src/hashTable_hh.hh` | Modernized (Phase 2) |
| `src/HashTableStorage_hh.hh` | Modernized (Phase 2) |
| `src/file.cc` / `src/file.hh` | Modernized (Phase 2) |
| `src/main.cc` | Modernized (Phase 2) |
| `src/kmersConversion.cc` | Modernized (Phase 2) |
| `src/getAccssnTaxID.cc` | Modernized (Phase 2) |
| `src/getfilesToTaxNodes.cc` | Modernized (Phase 2) |
| `src/getTargetsDef.cc` | Modernized (Phase 2) |
| `src/parameters.hh` | Merged with light variant (Phase 1) |
| `download_data.sh` | Modernized (Phase 3) |
| `download_data_newest.sh` | Modernized (Phase 3) |
| `download_data_release.sh` | Modernized (Phase 3) |
| `download_taxondata.sh` | Modernized (Phase 3) |
| `updateTaxonomy.sh` | Modernized (Phase 3) |
| `install.sh` | Updated for CMake (Phase 1) |
| `Makefile` / `src/Makefile` | Deleted (Phase 1) |
| `src/parameters_light_hh` | Deleted (Phase 1) |
