# CuCLARK Minimum Working Example

This MWE demonstrates the full CuCLARK classification pipeline using 3 small viral genomes from NCBI.

## What it does

1. Downloads phiX174 (~5kb), Lambda phage (~48kb), and T4 phage (~169kb) from NCBI RefSeq
2. Creates a targets file mapping genome files to taxon names
3. Generates 150 simulated reads (50 per genome, 150bp each)
4. Runs cuCLARK-l (light mode) classification
5. Shows a summary of classification results

## Running with Docker Compose (alkanlab workflow)

```bash
# Start the container
docker compose up -d

# Enter the container
docker exec -it rica_s_id_cuclark bash

# Run the MWE inside the container
bash /opt/cuclark/mwe/run_mwe.sh

# Or specify a custom output directory
bash /opt/cuclark/mwe/run_mwe.sh /rica_s/data/cuclark_mwe
```

## Running with Docker directly

```bash
docker run --rm --gpus all -v ./data:/data alkanlab/cuclark:2.0 bash -c \
  "bash /opt/cuclark/mwe/run_mwe.sh /data/mwe"
```

## Expected output

All 150 reads should be classified with high confidence:

```
Classification Summary
  File:           /data/mwe/results.csv
  Total reads:    150
  Classified:     150 (100.0%)
  Unclassified:   0 (0.0%)

  Top 3 taxa:
    phiX174   50  (33.3%)
    lambda    50  (33.3%)
    T4        50  (33.3%)
```

## Useful follow-up commands

```bash
# JSON output
cuclark summary /data/mwe/results.csv --format json

# Krona-compatible TSV
cuclark summary /data/mwe/results.csv --krona

# Filter by confidence
cuclark summary /data/mwe/results.csv --min-confidence 0.9

# Check GPU info
cuclark version
```

---

## Bigger Example: Viral Reference Genomes (RTX 3070 Laptop)

`run_viral_mwe.sh` is a larger example designed for consumer GPUs like the RTX 3070 laptop (8 GB VRAM). Instead of 3 hardcoded phages it downloads up to 50 representative/reference viral genomes from NCBI RefSeq — spanning coronaviruses, herpesviruses, poxviruses, retroviruses, flaviviruses, and more.

### What it does

1. Fetches the NCBI RefSeq viral `assembly_summary.txt`
2. Filters for `reference genome` / `representative genome` complete assemblies
3. Downloads up to 50 genomes (~50–300 MB total)
4. Generates 50 simulated reads per genome (2,500 reads total)
5. Runs `cuclark classify` — auto-selects **cuCLARK-l** on 8 GB VRAM
6. Shows a classification summary

### GPU notes

The RTX 3070 laptop has 8 GB VRAM total. With display and system overhead the free VRAM is typically ~7–7.5 GB, which falls below the 8192 MB threshold for full mode. The auto-selector will choose **light mode** (`cuCLARK-l`), which is well suited to this dataset:

| Variant | HTSIZE | DB parts/GPU | Reserved/batch | RAM needed |
|---------|--------|-------------|----------------|------------|
| cuCLARK-l | 57.7 M | 1 | ~300 MB | ~4 GB |
| cuCLARK   | 1.6 B  | 3 | ~400 MB | ~40 GB |

### Running with Docker Compose

```bash
docker compose up -d
docker exec -it rica_s_id_cuclark bash

# Default: 50 genomes into /data/viral_mwe
bash /opt/cuclark/mwe/run_viral_mwe.sh

# Custom output directory and genome count
bash /opt/cuclark/mwe/run_viral_mwe.sh /rica_s/data/viral_mwe 30
```

### Running with Docker directly

```bash
docker run --rm --gpus all -v ./data:/data alkanlab/cuclark:2.0 bash -c \
  "bash /opt/cuclark/mwe/run_viral_mwe.sh /data/viral_mwe 50"
```

### Expected output

```
Classification Summary
  File:           /data/viral_mwe/results.csv
  Total reads:    2500
  Classified:     ~2450 (>98%)
  Unclassified:   ~50  (<2%)

  Top 10 taxa:
    SARS-CoV-2_...         50  (2.0%)
    Human_alphaherpesvirus_1  50  (2.0%)
    ...
```

### Tuning

- Increase `MAX_GENOMES` (second argument) up to the full reference genome set (~300–500 viral species) — the database will still fit in light mode.
- Add `--batches 4` if you see GPU memory errors on the 3070 laptop: `cuclark classify ... --batches 4`
