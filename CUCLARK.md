# CuCLARK

## Overview

CuCLARK (CLARK for CUDA-enabled GPUs) classifies metagenomic DNA reads by comparing them against a reference database of discriminative k-mers, with classification accelerated on NVIDIA GPUs. Given a FASTA/FASTQ file of reads, it assigns each read to a taxonomic ID.

Two variants are available:
- **cuCLARK** — full, requires large RAM (~40 GB for bacterial DB) and VRAM
- **cuCLARK-l** — light, low-memory (~4 GB RAM, 1 GB VRAM)

CuCLARK uses **canonical k-mers**, so its databases are NOT compatible with original CLARK.

## 1. Docker Image

```
alkanlab/cuclark:latest
```

This is a custom image built from CuCLARK source with CUDA 11.4. It supports GPUs from Kepler (K20, sm_35) to Hopper (H100, sm_90).

## 2. Docker Compose

Create a `docker-compose.yml`:

```yaml
services:
  rica_s_id_cuclark:
    container_name: rica_s_id_cuclark

    entrypoint:
      - /bin/bash

    hostname: rica_s_id_cuclark

    image: alkanlab/cuclark:latest

    ipc: private

    logging:
      driver: json-file
      options: {}

    networks:
      - rica_s_net

    stdin_open: true

    tty: true

    volumes:
      - /path/to/your/project:/rica_s

    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]

networks:
  rica_s_net:
```

Replace `/path/to/your/project` with the directory containing your data.

## 3. Data Setup

Organize your data under the project directory before starting:

```
your_project/
  data/
    DB/
      Custom/
        references.fasta   # Reference genomes
    reads/
      sample.fastq         # Reads to classify
    results/               # Classification output will go here
```

## 4. How to run CuCLARK

### Pull the image and start the container

```bash
docker compose up -d
docker exec -it rica_s_id_cuclark bash
```

### Inside the container

#### Step 1: Build the database

```bash
cd /opt/cuclark/scripts
./set_targets.sh /rica_s/data/DB custom --species
```

This will:
1. Download NCBI taxonomy data
2. Map each accession number in the reference FASTA to its taxonomy ID
3. Build the taxonomy tree for species-level classification

Available taxonomy ranks: `--species` (default), `--genus`, `--family`, `--order`, `--class`, `--phylum`.

#### Step 2: Classify reads

**cuCLARK-l** (light, recommended for limited GPU memory):

```bash
./classify_metagenome.sh -O /rica_s/data/reads/sd_0001.fastq -R /rica_s/data/results/sample -n <threads> -b <batches> --light
```

**cuCLARK** (full, requires large RAM and VRAM):

```bash
./classify_metagenome.sh -O /rica_s/data/reads/sd_0001.fastq -R /rica_s/data/results/sample -n <threads> -b <batches>
```

Replace `<threads>` with the number of CPU threads (e.g., 4) and `<batches>` with the number of GPU batches (increase if you get OOM errors, e.g., 4 or 8).

The first classification run builds the discriminative k-mer database (`.ky`, `.lb`, `.sz` files). This is done once per reference set; subsequent runs reuse it.

#### Alternative: Using the `cuclark` CLI wrapper

```bash
# Auto-selects full/light variant based on available RAM and VRAM
cuclark classify --reads /rica_s/data/reads/sd_0001.fastq \
  --targets /rica_s/data/DB/targets.txt \
  --db-dir /rica_s/data/DB/ \
  --output /rica_s/data/results/sample

# Force light mode
cuclark classify --reads /rica_s/data/reads/sd_0001.fastq \
  --targets /rica_s/data/DB/targets.txt \
  --db-dir /rica_s/data/DB/ \
  --output /rica_s/data/results/sample --light
```

#### Step 3: View results

Results are stored in `data/results/sample.csv`.

**Using the CLI wrapper:**

```bash
cuclark summary /rica_s/data/results/sample.csv
cuclark summary /rica_s/data/results/sample.csv --format json
cuclark summary /rica_s/data/results/sample.csv --min-confidence 0.90
```

**Output Format:**

| Column | Description |
|--------|-------------|
| Object_ID | Read name |
| Length | Read length (bp) |
| Gamma | Ratio of discriminative k-mers found vs read length |
| 1st_assignment | Tax ID of best match (NA = unclassified) |
| hit count of first | Number of discriminative k-mers matching 1st assignment |
| 2nd_assignment | Tax ID of second-best match |
| hit count of second | k-mer count for 2nd assignment |
| confidence | score1 / (score1 + score2) |

### Parameters

| Flag | Description |
|------|-------------|
| `-O <file>` | Input FASTQ/FASTA file |
| `-P <f1> <f2>` | Paired-end reads |
| `-R <file>` | Output results path (without `.csv` extension) |
| `-n <int>` | Number of CPU threads |
| `-b <int>` | Number of GPU batches (increase for OOM errors) |
| `-d <int>` | Number of CUDA devices to use (default: all) |
| `-k <int>` | K-mer length (default: 31 for cuCLARK, 27 for cuCLARK-l) |
| `-g <int>` | Gap for non-overlapping k-mers in DB creation (cuCLARK-l only, default: 4) |
| `-s <int>` | Sampling factor (cuCLARK full only) |
| `--light` | Use cuCLARK-l (low memory variant) |
| `--tsk` | Create detailed target-specific k-mer files |
| `--extended` | Extended output with hit counts for all targets |
| `--gzipped` | Input files are gzipped |
