# CuCLARK Full Modernization Plan

## Context

CuCLARK is a 2016-era GPU-accelerated metagenomic classifier (last updated 2018). It cannot compile on any modern CUDA toolkit (11+) because it targets `sm_30` (Kepler, 2012). The codebase uses pre-C++11 patterns, broken NCBI download URLs, and manual Makefiles.

**Goal:** Fully modernize the project — C++17, CMake, RAII, safe code, fixed NCBI scripts, and Docker containerization targeting `sm_70+` (Volta and newer) GPUs.

---

## Phase 1: Build System — Get It Compiling on Modern CUDA

### 1.1 Create `CMakeLists.txt`
Replace both Makefiles with CMake 3.20+ using native CUDA language support.

- Target architectures: `70;75;80;86;89;90`
- Build two variants (`cuCLARK` and `cuCLARK-l`) via compile definitions (`-DCUCLARK_LIGHT`) instead of the current file-swapping hack
- Enable C++17 for both CXX and CUDA
- Auto-detect OpenMP

### 1.2 Merge `parameters.hh` and `parameters_light_hh`
Use `#ifdef CUCLARK_LIGHT` to select hash table sizes at compile time. Delete `parameters_light_hh`.

```cpp
#ifdef CUCLARK_LIGHT
  #define HTSIZE       57777779
  #define MAXHITS      23
  #define RESERVED     300000000
  #define DBPARTSPERDEVICE 1
#else
  #define HTSIZE       1610612741
  #define MAXHITS      15
  #define RESERVED     400000000
  #define DBPARTSPERDEVICE 3
#endif
```

### 1.3 Fix sm_30-era GPU checks in `src/CuClarkDB.cu`
- Remove hardcoded `"GeForce GTX TITAN X"` device name check
- Update compute capability check from `major >= 2` to `major >= 7`

### 1.4 Update `install.sh`
Replace `make` with:
```bash
cmake -B build -DCMAKE_CUDA_ARCHITECTURES="70;75;80;86;89;90"
cmake --build build -j$(nproc)
```

### 1.5 Delete old Makefiles
Remove `Makefile` (root) and `src/Makefile`.

### 1.6 Fix C++17 compilation issues
- Replace `<stdint.h>` → `<cstdint>`, `<stdio.h>` → `<cstdio>`
- Qualify unqualified `vector` with `std::`
- Fix any other C++17 incompatibilities

---

## Phase 2: C++ Modernization

### 2.1 Replace `sVector` with `std::vector`
Delete custom `sVector<T>` struct in `src/dataType.hh` (lines 214-286). Update all usages in `src/hashTable_hh.hh`.

> **Risk note:** `sVector::resize` doesn't value-initialize while `std::vector::resize` does. Verified safe — all call sites write immediately after resize.

### 2.2 Replace `sprintf` with `std::string` operations
14 instances across:
- `src/CuCLARK_hh.hh`
- `src/hashTable_hh.hh`
- `src/HashTableStorage_hh.hh`
- `src/CuClarkDB.cu`

Replace the `calloc` + `sprintf` + `free` pattern with `std::string` concatenation:
```cpp
// Before:
char* fname = (char*) calloc(100, sizeof(char));
sprintf(fname, "%s/%s_k%lu.ht", m_folder, m_labels[t], m_kmerSize);
// ... use fname ...
free(fname);

// After:
std::string fname = std::string(m_folder) + "/" + m_labels[t] + "_k" + std::to_string(m_kmerSize) + ".ht";
```

### 2.3 Replace `atoi`/`atoll` with safe alternatives
19 instances across `src/main.cc`, `src/getAccssnTaxID.cc`, `src/file.cc`, `src/getfilesToTaxNodes.cc`.

Replace with `std::stoi`/`std::stoll`/`std::stoull` with proper error handling.

### 2.4 Replace `NULL` with `nullptr`
Global find-and-replace across all `.cc`, `.hh`, `.cu`, `.cuh` files.

### 2.5 Create CUDA RAII wrappers
New file `src/cuda_utils.hh`:

| Wrapper | Replaces |
|---------|----------|
| `CUDA_CHECK()` | `CUERR` / `CUMEMERR` macros |
| `CudaDevicePtr<T>` | `cudaMalloc` / `cudaFree` (with device ID tracking for multi-GPU) |
| `CudaPinnedPtr<T>` | `cudaMallocHost` / `cudaFreeHost` |
| `CudaEvent` | `cudaEventCreateWithFlags` / `cudaEventDestroy` |

> **Risk note:** RAII destructors for device memory must call `cudaSetDevice(device_id)` before freeing. The wrappers store the device ID at allocation time.

### 2.6 Apply RAII wrappers in `src/CuClarkDB.cu`
- Replace all manual CUDA memory management with RAII types
- Simplify destructor (`~CuClarkDB`) and `freeBatchMemory` — RAII handles cleanup
- Replace `CUERR` macro with `CUDA_CHECK()`

### 2.7 Use `std::unique_ptr` for owning pointers
In `src/CuCLARK_hh.hh`:
- `m_centralHt` → `std::unique_ptr<EHashtable<HKMERr, rElement>>`
- `m_cuClarkDb` → `std::unique_ptr<CuClarkDB<HKMERr>>`
- Remove manual `delete` in destructor

### 2.8 Modernize file I/O in `src/file.cc`
- Replace `FILE*` + `fopen`/`fclose` with `std::ifstream`/`std::ofstream` for text I/O
- Keep `FILE*` with RAII wrapper for binary I/O in hash table read/write (performance-critical for multi-GB databases):
  ```cpp
  struct FileCloser { void operator()(FILE* f) { if (f) fclose(f); } };
  using UniqueFile = std::unique_ptr<FILE, FileCloser>;
  ```

### 2.9 Remove `using namespace std;` from headers
In `src/hashTable_hh.hh` and `src/HashTableStorage_hh.hh`. Qualify all standard library types with `std::`.

---

## Phase 3: Fix NCBI Download Scripts

### 3.1 Update all FTP URLs to HTTPS
NCBI dropped plain FTP access. Change `ftp://ftp.ncbi.nih.gov/` → `https://ftp.ncbi.nlm.nih.gov/` in:
- `download_data.sh`
- `download_data_newest.sh`
- `download_data_release.sh`
- `download_taxondata.sh`
- `updateTaxonomy.sh`

### 3.2 Fix `download_data.sh` broken paths
The old archive paths are removed from NCBI:

| Old (broken) | New |
|---|---|
| `genomes/archive/old_refseq/Bacteria/` | NCBI Datasets CLI or `genomes/refseq/bacteria/` |
| `genomes/Viruses/` | NCBI Datasets CLI or `genomes/refseq/viral/` |
| `genomes/H_sapiens/CHR_*` | NCBI Datasets CLI or `genomes/refseq/vertebrate_mammalian/Homo_sapiens/` |

Add NCBI Datasets CLI as primary download method with `assembly_summary.txt` fallback:
```bash
if command -v datasets &>/dev/null; then
    datasets download genome taxon "bacteria" --reference --include genome --filename bacteria.zip
else
    # Fallback: assembly_summary approach
    wget https://ftp.ncbi.nlm.nih.gov/genomes/refseq/bacteria/assembly_summary.txt
    # ... awk pipeline ...
fi
```

### 3.3 Fix `download_data_release.sh` GI number handling
The `sed` command for GI numbers (line ~43) is obsolete — NCBI removed GI numbers. Update to handle modern accession-only FASTA headers.

### 3.4 Add `setup_custom_db.sh`
New helper script for custom database setup:
1. Takes a directory of FASTA files + taxonomy mapping file
2. Creates the `.fileToTaxIDs` format expected by `getTargetsDef`
3. Calls the existing pipeline

---

## Phase 4: Containerization

### 4.1 Create `Dockerfile`
Multi-stage build for minimal image size:

```dockerfile
# Build stage
FROM nvidia/cuda:12.4-devel-ubuntu22.04 AS builder
RUN apt-get update && apt-get install -y cmake g++ wget unzip
WORKDIR /cuclark
COPY . .
RUN cmake -B build -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_CUDA_ARCHITECTURES="70;75;80;86;89;90" \
    && cmake --build build -j$(nproc) \
    && cmake --install build --prefix /usr/local

# Runtime stage
FROM nvidia/cuda:12.4-runtime-ubuntu22.04
RUN apt-get update && apt-get install -y wget gawk coreutils
# Install NCBI datasets CLI
RUN wget -q https://ftp.ncbi.nlm.nih.gov/datasets/docs/v2/datasets-linux-amd64 \
    -O /usr/local/bin/datasets && chmod +x /usr/local/bin/datasets
COPY --from=builder /usr/local/bin/ /usr/local/bin/
COPY *.sh /opt/cuclark/scripts/
WORKDIR /data
ENTRYPOINT ["/usr/local/bin/cuCLARK"]
```

### 4.2 Create `.dockerignore`
```
build/
exe/
data/
.git/
*.o
```

### 4.3 Create `docker-compose.yml`
```yaml
services:
  cuclark:
    build: .
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]
    volumes:
      - ./data:/data
```

**Runtime usage:**
```bash
# Build
docker compose build

# Run classification
docker compose run cuclark -k 31 -T /data/targets.txt -D /data/db/ -O /data/reads.fa -R /data/results

# Or without compose
docker run --gpus all -v $(pwd)/data:/data cuclark:2.0 -k 31 ...
```

---

## Phase 5: Testing & Verification

### 5.1 Build verification
```bash
cmake -B build -DCMAKE_CUDA_ARCHITECTURES="70;80" && cmake --build build
./build/cuCLARK --help
./build/cuCLARK-l --help
```

### 5.2 Test scripts
Create `tests/` directory with:
- `test_build.sh` — Verify CMake build for both variants
- `test_cli.sh` — CLI argument parsing (help, version, invalid args)
- `test_classify.sh` — Small synthetic dataset classification

### 5.3 Docker test
```bash
docker build -t cuclark:2.0 .
docker run --gpus all cuclark:2.0 --help
```

### 5.4 Multi-GPU test
Verify peer-to-peer access works after RAII refactoring with `-d 2` flag.

### 5.5 NCBI download test
Verify all download scripts work against live NCBI endpoints.

---

## Critical Files Summary

| File | Key Changes |
|------|-------------|
| `src/CuClarkDB.cu` | CUDA arch checks, RAII wrappers, CUDA_CHECK, sprintf removal |
| `src/CuCLARK_hh.hh` | unique_ptr, sprintf→string, atoi→stoi, FILE*→ifstream, NULL→nullptr |
| `src/dataType.hh` | Delete sVector, modernize types |
| `src/hashTable_hh.hh` | sVector→vector, sprintf removal, remove `using namespace std` |
| `src/parameters.hh` | Merge with light variant using `#ifdef` |
| `src/main.cc` | Safe arg parsing, modern includes |
| `src/file.cc` / `src/file.hh` | ifstream/ofstream, stoi/stoll |
| `src/Makefile` + `Makefile` | **DELETE** (replaced by CMakeLists.txt) |
| All `download_*.sh` scripts | Fix URLs, add NCBI datasets CLI |
| **New:** `CMakeLists.txt` | Modern CMake build system |
| **New:** `src/cuda_utils.hh` | CUDA RAII wrappers |
| **New:** `Dockerfile` | Multi-stage container build |
| **New:** `docker-compose.yml` | GPU-enabled compose config |
| **New:** `.dockerignore` | Build context exclusions |
| **New:** `setup_custom_db.sh` | Custom database helper |

## Risk Areas

| Risk | Mitigation |
|------|------------|
| CUDA RAII + multi-GPU: destructors must free on correct device | Store `device_id` in RAII wrappers, call `cudaSetDevice` in destructor |
| `sVector` → `std::vector` value-initialization difference | Verified all call sites write immediately after resize |
| Binary I/O performance with `std::ifstream` | Keep `FILE*` with RAII for binary hash table I/O |
| NCBI URL stability | Use Datasets CLI as primary, FTP as fallback |
