# Setup Guide

## Docker (Recommended)

### Requirements

- Docker
- NVIDIA GPU with driver installed
- [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html)

### Build and test

```bash
docker build -t cuclark .

# Run MWE (override entrypoint to run bash script)
docker run --gpus all --entrypoint bash -v ${PWD}:/data cuclark \
  /opt/cuclark/mwe/test_example_fasta.sh

# Interactive shell
docker run --gpus all --entrypoint bash -it -v ${PWD}:/data cuclark
```

### Classify reads

```bash
docker run --gpus all -v ${PWD}:/data cuclark \
  classify --reads /data/reads.fa --targets /data/targets.txt \
  --db-dir /data/db/ --output /data/results

# View results
docker run --gpus all -v ${PWD}:/data cuclark \
  summary /data/results.csv
```

## Build from Source

### Requirements

- Linux (64-bit), CMake 3.20+, GCC with C++17, CUDA Toolkit 11.0+
- NVIDIA GPU (compute capability 7.0+)

```bash
cmake -B build -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_CUDA_ARCHITECTURES="70;75;80;86;89;90"
cmake --build build -j$(nproc)
cmake --install build --prefix /usr/local
```

Binaries: `cuCLARK`, `cuCLARK-l`, `getTargetsDef`, `getAccssnTaxID`, `getfilesToTaxNodes`.

## Tuning

| Flag | Default | Description |
|------|---------|-------------|
| `--batches` / `-b` | auto | Increase if you get GPU OOM errors |
| `--threads` / `-n` | 1 | CPU threads for parallel classification |
| `--devices` / `-d` | all | Number of GPUs to use |
| `--light` | auto | Force light mode (less VRAM) |
| `--full` | auto | Force full mode (more VRAM, faster) |
