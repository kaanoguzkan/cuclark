// cuclark — Unified CLI wrapper for CuCLARK GPU-accelerated metagenomic classifier.
//
// Provides subcommands for classification, result summarization, database management,
// and GPU auto-tuning. Pure C++17, no external dependencies.

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <map>
#include <optional>
#include <set>
#include <sstream>
#include <string>
#include <unistd.h>
#include <vector>

namespace fs = std::filesystem;

static const char* VERSION     = "2.0.0";
static const char* ENGINE_VER  = "1.1";

// ── Helpers ──────────────────────────────────────────────────────────────

static void error(const std::string& msg) {
    std::cerr << "ERROR: " << msg << "\n";
    std::exit(1);
}

static void banner(const std::vector<std::string>& lines) {
    std::string sep(60, '=');
    std::cout << sep << "\n";
    for (auto& l : lines) std::cout << "  " << l << "\n";
    std::cout << sep << "\n" << std::flush;
}

// Run a command and capture stdout into `out`. Returns exit code.
static int capture(const std::string& cmd, std::string& out) {
    out.clear();
    FILE* p = popen(cmd.c_str(), "r");
    if (!p) return -1;
    char buf[512];
    while (fgets(buf, sizeof buf, p)) out += buf;
    int rc = pclose(p);
#ifdef _WIN32
    return rc;
#else
    return WIFEXITED(rc) ? WEXITSTATUS(rc) : rc;
#endif
}

// Trim whitespace from both ends.
static std::string trim(const std::string& s) {
    auto a = s.find_first_not_of(" \t\r\n");
    if (a == std::string::npos) return {};
    auto b = s.find_last_not_of(" \t\r\n");
    return s.substr(a, b - a + 1);
}

// Split string by delimiter.
static std::vector<std::string> split(const std::string& s, char delim) {
    std::vector<std::string> parts;
    std::istringstream ss(s);
    std::string tok;
    while (std::getline(ss, tok, delim)) parts.push_back(tok);
    return parts;
}

// ── GPU / RAM detection ─────────────────────────────────────────────────

struct GpuInfo {
    int index;
    std::string name;
    int mem_total;
    int mem_free;
};

static std::vector<GpuInfo> detect_gpus() {
    std::vector<GpuInfo> gpus;
    std::string out;
    int rc = capture("nvidia-smi --query-gpu=index,name,memory.total,memory.free "
                     "--format=csv,noheader,nounits 2>/dev/null", out);
    if (rc != 0) return gpus;
    for (auto& line : split(out, '\n')) {
        auto parts = split(line, ',');
        if (parts.size() < 4) continue;
        GpuInfo g;
        g.index     = std::atoi(trim(parts[0]).c_str());
        g.name      = trim(parts[1]);
        g.mem_total  = std::atoi(trim(parts[2]).c_str());
        g.mem_free   = std::atoi(trim(parts[3]).c_str());
        gpus.push_back(g);
    }
    return gpus;
}

static std::vector<GpuInfo> usable_gpus(const std::vector<GpuInfo>& gpus, int min_free_mb = 1024) {
    std::vector<GpuInfo> out;
    for (auto& g : gpus)
        if (g.mem_free >= min_free_mb) out.push_back(g);
    return out;
}

static std::optional<int> detect_available_ram_mb() {
    std::ifstream f("/proc/meminfo");
    if (f) {
        std::string line;
        while (std::getline(f, line)) {
            if (line.rfind("MemAvailable:", 0) == 0) {
                auto parts = split(line, ' ');
                for (auto& p : parts) {
                    if (!p.empty() && std::isdigit(static_cast<unsigned char>(p[0]))) {
                        return std::atoi(p.c_str()) / 1024; // KB -> MB
                    }
                }
            }
        }
    }
    // macOS fallback
    std::string out;
    if (capture("sysctl -n hw.memsize 2>/dev/null", out) == 0) {
        auto v = trim(out);
        if (!v.empty()) return static_cast<int>(std::atoll(v.c_str()) / (1024 * 1024));
    }
    return std::nullopt;
}

// ── Binary finder ────────────────────────────────────────────────────────

static std::string find_binary(const std::string& name) {
    // Check PATH via "which"
    std::string out;
    if (capture("which " + name + " 2>/dev/null", out) == 0) {
        auto p = trim(out);
        if (!p.empty()) return p;
    }
    for (auto& d : {"/usr/local/bin", "/opt/cuclark/bin", "."}) {
        auto candidate = std::string(d) + "/" + name;
        if (fs::exists(candidate) && access(candidate.c_str(), X_OK) == 0)
            return candidate;
    }
    return {};
}

// ── Exit code translator ────────────────────────────────────────────────

static void translate_exit_code(int exit_code, const std::string& stderr_text, int batches) {
    if (exit_code == 139) {
        std::cerr << "\nERROR: cuCLARK crashed (segmentation fault).\n"
                  << "  Try increasing --batches to reduce GPU memory pressure.\n";
        if (batches > 0)
            std::cerr << "  Current: --batches " << batches
                      << ". Try: --batches " << batches * 2 << "\n";
    } else if (exit_code == 137) {
        std::cerr << "\nERROR: cuCLARK was killed (out of memory).\n"
                  << "  Try --light mode or increase --batches.\n";
    } else if (stderr_text.find("Batch overflow") != std::string::npos) {
        std::cerr << "\nERROR: Batch overflow — GPU memory exceeded.\n";
        if (batches > 0)
            std::cerr << "  Increase --batches (current: " << batches
                      << "). Try: --batches " << batches * 2 << "\n";
        else
            std::cerr << "  Try: --batches 4\n";
    } else if (stderr_text.find("less than 1GB") != std::string::npos ||
               stderr_text.find("no cuda") != std::string::npos ||
               stderr_text.find("No CUDA") != std::string::npos) {
        std::cerr << "\nERROR: No usable GPU detected.\n"
                  << "  Ensure nvidia-docker runtime is configured (--gpus all).\n";
    } else if (exit_code != 0) {
        std::cerr << "\nERROR: cuCLARK exited with code " << exit_code << ".\n";
    }
}

// ── Variant auto-selection ──────────────────────────────────────────────

static std::pair<std::string, std::string>
auto_select_variant(const std::vector<GpuInfo>& usable, std::optional<int> ram_mb) {
    if (ram_mb.has_value() && *ram_mb < 150000)
        return {"light", "auto (available RAM " + std::to_string(*ram_mb) + " MB < 150 GB)"};
    if (ram_mb.has_value())
        return {"full", "auto (available RAM " + std::to_string(*ram_mb) + " MB >= 150 GB)"};
    if (usable.empty())
        return {"light", "auto (could not detect RAM or VRAM)"};
    int min_free = usable[0].mem_free;
    for (auto& g : usable) min_free = std::min(min_free, g.mem_free);
    if (min_free >= 8192)
        return {"full", "auto (RAM unknown, VRAM " + std::to_string(min_free) + " MB >= 8 GB)"};
    return {"light", "auto (RAM unknown, VRAM " + std::to_string(min_free) + " MB < 8 GB)"};
}

// ── Argument parsing helpers ────────────────────────────────────────────

// Simple argument parser: finds --flag VALUE or -f VALUE, returns value or empty.
static std::string arg_val(int argc, char** argv, const std::string& longf,
                           const std::string& shortf = {}) {
    for (int i = 0; i < argc - 1; ++i) {
        if (argv[i] == longf || (!shortf.empty() && argv[i] == shortf))
            return argv[i + 1];
    }
    return {};
}

static bool arg_flag(int argc, char** argv, const std::string& longf,
                     const std::string& shortf = {}) {
    for (int i = 0; i < argc; ++i)
        if (argv[i] == longf || (!shortf.empty() && argv[i] == shortf))
            return true;
    return false;
}

// Get positional arg at position `pos` (0-based, among non-flag arguments after subcommand).
static std::string arg_positional(int argc, char** argv, int pos) {
    // Skip flags and their values; collect positionals
    std::vector<std::string> positionals;
    for (int i = 0; i < argc; ++i) {
        std::string a = argv[i];
        if (a[0] == '-') {
            // Skip flag value if it's a value-flag (heuristic: next arg doesn't start with -)
            if (i + 1 < argc && argv[i + 1][0] != '-') ++i;
            continue;
        }
        positionals.push_back(a);
    }
    if (pos < (int)positionals.size()) return positionals[pos];
    return {};
}

// Collect positional args (non-flag arguments).
static std::vector<std::string> arg_positionals(int argc, char** argv) {
    std::vector<std::string> positionals;
    for (int i = 0; i < argc; ++i) {
        std::string a = argv[i];
        if (a[0] == '-') {
            if (i + 1 < argc && argv[i + 1][0] != '-') ++i;
            continue;
        }
        positionals.push_back(a);
    }
    return positionals;
}

// ── Subcommand: classify ────────────────────────────────────────────────

static void cmd_classify(int argc, char** argv) {
    auto gpus   = detect_gpus();
    auto usable = usable_gpus(gpus);

    std::string reads    = arg_val(argc, argv, "--reads", "-O");
    std::string paired1, paired2;
    // Handle --paired / -P with two values
    for (int i = 0; i < argc - 2; ++i) {
        std::string a = argv[i];
        if (a == "--paired" || a == "-P") {
            paired1 = argv[i + 1];
            paired2 = argv[i + 2];
            break;
        }
    }
    std::string output   = arg_val(argc, argv, "--output", "-R");
    std::string targets  = arg_val(argc, argv, "--targets", "-T");
    std::string db_dir   = arg_val(argc, argv, "--db-dir", "-D");
    std::string kmer_s   = arg_val(argc, argv, "--kmer-size", "-k");
    std::string threads_s= arg_val(argc, argv, "--threads", "-n");
    std::string batches_s= arg_val(argc, argv, "--batches", "-b");
    std::string devices_s= arg_val(argc, argv, "--devices", "-d");
    std::string samp_s   = arg_val(argc, argv, "--sampling-factor", "-s");
    bool light_flag      = arg_flag(argc, argv, "--light");
    bool full_flag       = arg_flag(argc, argv, "--full");
    bool extended        = arg_flag(argc, argv, "--extended");
    bool tsk             = arg_flag(argc, argv, "--tsk");
    bool metadata        = arg_flag(argc, argv, "--metadata");

    if (reads.empty() && paired1.empty())
        error("Either --reads/-O or --paired/-P is required.");
    if (output.empty())
        error("--output/-R is required.");

    int devices = devices_s.empty() ? -1 : std::atoi(devices_s.c_str());
    int batches = batches_s.empty() ? -1 : std::atoi(batches_s.c_str());
    int threads = threads_s.empty() ? 1  : std::atoi(threads_s.c_str());

    if (devices < 0) {
        if (!usable.empty())
            devices = (int)usable.size();
        else
            error("No GPUs detected. Set --devices manually or ensure nvidia-docker is configured.");
    }

    auto ram = detect_available_ram_mb();
    bool light;
    std::string variant_reason;
    if (light_flag) {
        light = true; variant_reason = "user requested";
    } else if (full_flag) {
        light = false; variant_reason = "user requested";
    } else {
        auto [sel, reason] = auto_select_variant(usable, ram);
        light = (sel == "light");
        variant_reason = reason;
    }

    std::string binary_name = light ? "cuCLARK-l" : "cuCLARK";
    std::string binary = find_binary(binary_name);
    if (binary.empty())
        error("Cannot find " + binary_name + ". Is it installed? Check PATH.");

    int kmer = kmer_s.empty() ? (light ? 27 : 31) : std::atoi(kmer_s.c_str());
    if (batches < 0) batches = std::max(devices, threads);

    // Build command
    std::vector<std::string> cmd = {
        binary, "-k", std::to_string(kmer),
        "-n", std::to_string(threads),
        "-b", std::to_string(batches),
        "-d", std::to_string(devices)
    };
    if (!reads.empty()) {
        cmd.push_back("-O"); cmd.push_back(reads);
    } else {
        cmd.push_back("-P"); cmd.push_back(paired1); cmd.push_back(paired2);
    }
    cmd.push_back("-R"); cmd.push_back(output);
    if (!targets.empty()) { cmd.push_back("-T"); cmd.push_back(targets); }
    if (!db_dir.empty())  { cmd.push_back("-D"); cmd.push_back(db_dir); }
    if (!samp_s.empty())  { cmd.push_back("-s"); cmd.push_back(samp_s); }
    if (extended) cmd.push_back("--extended");
    if (tsk) cmd.push_back("--tsk");

    // Summary
    std::string ram_str = ram.has_value() ? std::to_string(*ram) + " MB" : "unknown";
    int min_free = 0;
    if (!usable.empty()) {
        min_free = usable[0].mem_free;
        for (auto& g : usable) min_free = std::min(min_free, g.mem_free);
    }
    std::vector<std::string> summary = {
        std::string("cuCLARK ") + (light ? "light " : "") + "classification",
        "Variant:   " + binary_name + " (" + variant_reason + ")",
        "RAM:       " + ram_str + " available",
        "GPUs:      " + std::to_string(devices) + " device(s)" +
            (usable.empty() ? "" : ", min " + std::to_string(min_free) + " MB free VRAM"),
    };
    int shown = 0;
    for (auto& g : usable) {
        if (shown++ >= devices) break;
        summary.push_back("           [" + std::to_string(g.index) + "] " + g.name);
    }
    std::string input_str = reads.empty() ? (paired1 + " " + paired2) : reads;
    summary.push_back("k-mer:     " + std::to_string(kmer));
    summary.push_back("Batches:   " + std::to_string(batches));
    summary.push_back("Threads:   " + std::to_string(threads));
    summary.push_back("Input:     " + input_str);
    summary.push_back("Output:    " + output);
    banner(summary);

    // Build shell command string
    std::string shell_cmd;
    for (size_t i = 0; i < cmd.size(); ++i) {
        if (i) shell_cmd += ' ';
        // Quote args with spaces
        if (cmd[i].find(' ') != std::string::npos)
            shell_cmd += '"' + cmd[i] + '"';
        else
            shell_cmd += cmd[i];
    }
    std::cout << "Running: " << shell_cmd << "\n" << std::flush;
    int rc = std::system(shell_cmd.c_str());
#ifndef _WIN32
    rc = WIFEXITED(rc) ? WEXITSTATUS(rc) : rc;
#endif

    if (rc != 0) {
        translate_exit_code(rc, "", batches);
        std::exit(rc);
    }

    // Metadata prepend
    std::string results_csv = output;
    if (results_csv.size() < 4 || results_csv.substr(results_csv.size() - 4) != ".csv")
        results_csv += ".csv";

    if (metadata && fs::exists(results_csv)) {
        // Get current time
        auto now = std::time(nullptr);
        char timebuf[64];
        std::strftime(timebuf, sizeof timebuf, "%Y-%m-%dT%H:%M:%S", std::localtime(&now));

        std::ifstream in(results_csv);
        std::string original((std::istreambuf_iterator<char>(in)),
                              std::istreambuf_iterator<char>());
        in.close();

        std::ofstream out_f(results_csv);
        out_f << "# cuclark classify " << (light ? "--light " : "") << "\n"
              << "# date: " << timebuf << "\n"
              << "# k=" << kmer << ", devices=" << devices
              << ", batches=" << batches << ", threads=" << threads << "\n"
              << "# variant: " << binary_name << "\n"
              << original;
        std::cout << "\nMetadata prepended to " << results_csv << "\n";
    }
    std::cout << "\nClassification complete.\n";
}

// ── Subcommand: summary ─────────────────────────────────────────────────

static void cmd_summary(int argc, char** argv) {
    std::string csv_path = arg_positional(argc, argv, 0);
    if (csv_path.empty()) error("Usage: cuclark summary RESULTS.CSV [options]");
    if (!fs::exists(csv_path)) error("Results file not found: " + csv_path);

    double min_conf = 0.0;
    int top_n = 10;
    std::string fmt = "text";
    bool krona = false;

    std::string mc = arg_val(argc, argv, "--min-confidence");
    if (!mc.empty()) min_conf = std::atof(mc.c_str());
    std::string tn = arg_val(argc, argv, "--top-n");
    if (!tn.empty()) top_n = std::atoi(tn.c_str());
    std::string fm = arg_val(argc, argv, "--format");
    if (!fm.empty()) fmt = fm;
    krona = arg_flag(argc, argv, "--krona");

    // Parse CSV
    std::ifstream f(csv_path);
    std::string line;
    std::vector<std::string> headers;
    int total = 0, classified = 0, unclassified = 0, passing = 0;
    std::map<std::string, int> taxa_counter;
    int bucket_lt50 = 0, bucket_50_75 = 0, bucket_75_90 = 0, bucket_ge90 = 0;

    // Find header columns
    int col_assignment = -1, col_confidence = -1;
    while (std::getline(f, line)) {
        if (line.empty() || line[0] == '#') continue;
        // First non-comment line is the header
        headers = split(line, ',');
        for (int i = 0; i < (int)headers.size(); ++i) {
            auto h = trim(headers[i]);
            if (h == "1st_assignment") col_assignment = i;
            if (h == "confidence") col_confidence = i;
        }
        break;
    }

    // Read data rows
    while (std::getline(f, line)) {
        if (line.empty() || line[0] == '#') continue;
        auto cols = split(line, ',');
        ++total;

        std::string taxon = (col_assignment >= 0 && col_assignment < (int)cols.size())
                            ? trim(cols[col_assignment]) : "NA";
        double conf = 0.0;
        if (col_confidence >= 0 && col_confidence < (int)cols.size()) {
            auto cs = trim(cols[col_confidence]);
            if (!cs.empty() && cs != "NA") conf = std::atof(cs.c_str());
        }

        if (taxon == "NA" || taxon.empty())
            ++unclassified;
        else
            ++classified;

        if (conf < 0.50)      ++bucket_lt50;
        else if (conf < 0.75) ++bucket_50_75;
        else if (conf < 0.90) ++bucket_75_90;
        else                  ++bucket_ge90;

        if (conf >= min_conf && taxon != "NA" && !taxon.empty()) {
            ++passing;
            ++taxa_counter[taxon];
        }
    }

    // Sort taxa by count descending
    std::vector<std::pair<std::string, int>> sorted_taxa(taxa_counter.begin(), taxa_counter.end());
    std::sort(sorted_taxa.begin(), sorted_taxa.end(),
              [](auto& a, auto& b) { return a.second > b.second; });
    if ((int)sorted_taxa.size() > top_n) sorted_taxa.resize(top_n);

    // Output
    if (krona) {
        for (auto& [taxon, count] : sorted_taxa)
            std::cout << count << "\t" << taxon << "\n";
        return;
    }

    if (fmt == "json") {
        std::cout << "{\n"
                  << "  \"total_reads\": " << total << ",\n"
                  << "  \"classified\": " << classified << ",\n"
                  << "  \"unclassified\": " << unclassified << ",\n"
                  << "  \"min_confidence_filter\": " << min_conf << ",\n"
                  << "  \"passing_filter\": " << passing << ",\n"
                  << "  \"top_taxa\": [\n";
        for (size_t i = 0; i < sorted_taxa.size(); ++i) {
            std::cout << "    {\"taxon\": \"" << sorted_taxa[i].first
                      << "\", \"count\": " << sorted_taxa[i].second << "}";
            if (i + 1 < sorted_taxa.size()) std::cout << ",";
            std::cout << "\n";
        }
        std::cout << "  ],\n"
                  << "  \"confidence_distribution\": {\n"
                  << "    \"<0.50\": " << bucket_lt50 << ",\n"
                  << "    \"0.50-0.75\": " << bucket_50_75 << ",\n"
                  << "    \"0.75-0.90\": " << bucket_75_90 << ",\n"
                  << "    \">=0.90\": " << bucket_ge90 << "\n"
                  << "  }\n}\n";
        return;
    }

    // Text output
    double pct_c = total ? classified * 100.0 / total : 0;
    double pct_u = total ? unclassified * 100.0 / total : 0;

    std::cout << "Classification Summary\n"
              << "  File:           " << csv_path << "\n"
              << "  Total reads:    " << total << "\n";
    std::printf("  Classified:     %d (%.1f%%)\n", classified, pct_c);
    std::printf("  Unclassified:   %d (%.1f%%)\n", unclassified, pct_u);

    if (min_conf > 0) {
        std::printf("\n  Confidence filter: >= %.2f\n", min_conf);
        std::cout << "  Passing filter:   " << passing << "\n";
    }

    if (!sorted_taxa.empty()) {
        int show = std::min(top_n, (int)sorted_taxa.size());
        std::cout << "\n  Top " << show << " taxa:\n";
        size_t max_name = 0;
        for (auto& [t, _] : sorted_taxa) max_name = std::max(max_name, t.size());
        for (auto& [taxon, count] : sorted_taxa) {
            double pct = total ? count * 100.0 / total : 0;
            std::printf("    %-*s  %6d  (%.1f%%)\n", (int)max_name, taxon.c_str(), count, pct);
        }
    }

    std::cout << "\n  Confidence distribution:\n";
    struct { const char* label; int count; } buckets[] = {
        {"<0.50", bucket_lt50}, {"0.50-0.75", bucket_50_75},
        {"0.75-0.90", bucket_75_90}, {">=0.90", bucket_ge90}
    };
    int max_count = 1;
    for (auto& b : buckets) max_count = std::max(max_count, b.count);
    for (auto& b : buckets) {
        int bar_len = b.count * 30 / max_count;
        std::string bar(bar_len, '#');
        std::printf("    %10s: %6d  %s\n", b.label, b.count, bar.c_str());
    }
}

// ── Subcommand: download ────────────────────────────────────────────────

static std::string find_script(const std::string& name) {
    // Check PATH
    std::string out;
    if (capture("which " + name + " 2>/dev/null", out) == 0) {
        auto p = trim(out);
        if (!p.empty()) return p;
    }
    for (auto& d : {"/opt/cuclark/scripts", "."}) {
        auto candidate = std::string(d) + "/" + name;
        if (fs::exists(candidate)) return candidate;
    }
    return {};
}

static void cmd_download(int argc, char** argv) {
    std::string db_dir = arg_val(argc, argv, "--db-dir");
    if (db_dir.empty()) error("--db-dir is required.");
    bool taxonomy = arg_flag(argc, argv, "--taxonomy");

    auto dbs = arg_positionals(argc, argv);
    if (dbs.empty()) error("Specify at least one database (bacteria, viruses, human).");

    auto script = find_script("download_data.sh");
    if (script.empty()) error("Cannot find download_data.sh. Ensure it is on PATH or in /opt/cuclark/scripts/.");

    for (auto& db : dbs) {
        std::cout << "\nDownloading " << db << " genomes to " << db_dir << "...\n" << std::flush;
        std::string cmd = "bash " + script + " " + db_dir + " " + db;
        int rc = std::system(cmd.c_str());
        if (rc != 0)
            std::cerr << "WARNING: download_data.sh exited with code " << rc << " for " << db << "\n";
    }

    if (taxonomy) {
        auto tax_script = find_script("download_taxondata.sh");
        if (!tax_script.empty()) {
            std::cout << "\nDownloading taxonomy data to " << db_dir << "...\n" << std::flush;
            std::system(("bash " + tax_script + " " + db_dir).c_str());
        } else {
            std::cerr << "WARNING: download_taxondata.sh not found, skipping taxonomy download.\n";
        }
    }
    std::cout << "\nDownload complete.\n";
}

// ── Subcommand: setup-db ────────────────────────────────────────────────

static void cmd_setup_db(int argc, char** argv) {
    std::string db_dir = arg_val(argc, argv, "--db-dir");
    if (db_dir.empty()) error("--db-dir is required.");
    std::string rank = arg_val(argc, argv, "--rank");
    if (rank.empty()) rank = "species";

    auto dbs = arg_positionals(argc, argv);
    if (dbs.empty()) error("Specify at least one database.");

    auto script = find_script("set_targets.sh");
    if (script.empty()) error("Cannot find set_targets.sh.");

    std::string cmd = "bash " + script + " " + db_dir;
    for (auto& db : dbs) cmd += " " + db;
    cmd += " --rank " + rank;

    std::cout << "Setting up database targets in " << db_dir << "...\n" << std::flush;
    int rc = std::system(cmd.c_str());
    if (rc != 0) error("set_targets.sh exited with code " + std::to_string(rc));
    std::cout << "Database setup complete.\n";
}

// ── Subcommand: list-db ─────────────────────────────────────────────────

static void cmd_list_db(int argc, char** argv) {
    std::string db_dir_s = arg_val(argc, argv, "--db-dir");
    if (db_dir_s.empty()) error("--db-dir is required.");
    fs::path db_dir(db_dir_s);
    if (!fs::is_directory(db_dir)) error("Database directory not found: " + db_dir_s);

    std::cout << "Database directory: " << fs::canonical(db_dir).string() << "\n\n";

    // Genome directories
    bool found_any = false;
    std::cout << "Downloaded genomes:\n";
    for (auto& name : {"bacteria", "viruses", "human", "custom"}) {
        auto gdir = db_dir / name;
        if (!fs::is_directory(gdir)) continue;
        int count = 0;
        for (auto& entry : fs::recursive_directory_iterator(gdir)) {
            if (!entry.is_regular_file()) continue;
            auto ext = entry.path().extension().string();
            if (ext == ".fna" || ext == ".fa" || ext == ".fasta") ++count;
        }
        std::printf("  %-15s %6d genome(s)\n", name, count);
        found_any = true;
    }
    if (!found_any) std::cout << "  (none found)\n";

    // Built k-mer databases
    std::cout << "\nBuilt k-mer databases:\n";
    bool found_ht = false;
    std::set<std::string> seen;
    for (auto& entry : fs::recursive_directory_iterator(db_dir)) {
        if (entry.is_regular_file() && entry.path().extension() == ".ht") {
            auto stem = entry.path().stem().string();
            if (seen.insert(stem).second) {
                std::cout << "  " << stem << "\n";
                found_ht = true;
            }
        }
    }
    if (!found_ht) std::cout << "  (none found)\n";

    // targets.txt
    auto targets = db_dir / "targets.txt";
    if (fs::exists(targets)) {
        std::ifstream f(targets);
        int lc = 0;
        std::string line;
        while (std::getline(f, line)) ++lc;
        std::cout << "\ntargets.txt: present (" << lc << " target(s))\n";
    } else {
        auto alt = db_dir.parent_path() / "targets.txt";
        if (fs::exists(alt)) {
            std::ifstream f(alt);
            int lc = 0;
            std::string line;
            while (std::getline(f, line)) ++lc;
            std::cout << "\ntargets.txt: found at " << alt.string() << " (" << lc << " target(s))\n";
        } else {
            std::cout << "\ntargets.txt: not found\n";
        }
    }
}

// ── Subcommand: version ─────────────────────────────────────────────────

static void cmd_version(int, char**) {
    std::cout << "cuclark wrapper version " << VERSION << "\n"
              << "CuCLARK engine version " << ENGINE_VER << "\n";

    for (auto& name : {"cuCLARK", "cuCLARK-l"}) {
        auto path = find_binary(name);
        std::cout << "\n" << name << ": " << (path.empty() ? "not found" : path) << "\n";
    }

    auto gpus = detect_gpus();
    if (!gpus.empty()) {
        std::cout << "\nGPU(s) detected: " << gpus.size() << "\n";
        for (auto& g : gpus)
            std::cout << "  [" << g.index << "] " << g.name
                      << " (" << g.mem_total << " MiB total, "
                      << g.mem_free << " MiB free)\n";
    } else {
        std::cout << "\nGPU(s) detected: 0 (nvidia-smi not available or no GPUs)\n";
    }
}

// ── Usage ───────────────────────────────────────────────────────────────

static void print_usage() {
    std::cout <<
        "cuclark — Unified CLI for CuCLARK GPU-accelerated metagenomic classifier.\n\n"
        "Commands:\n"
        "  classify   Run cuCLARK classification with GPU auto-tuning\n"
        "  summary    Summarize classification results\n"
        "  download   Download reference genomes from NCBI\n"
        "  setup-db   Set up database targets\n"
        "  list-db    Inspect available databases\n"
        "  version    Show version and GPU info\n\n"
        "Examples:\n"
        "  cuclark classify --reads reads.fa --output results --targets targets.txt --db-dir db/ --light\n"
        "  cuclark summary results.csv\n"
        "  cuclark summary results.csv --format json\n"
        "  cuclark download --db-dir ./db bacteria viruses\n"
        "  cuclark version\n";
}

// ── Main ────────────────────────────────────────────────────────────────

int main(int argc, char** argv) {
    if (argc < 2) {
        print_usage();
        return 1;
    }

    std::string cmd = argv[1];

    // Shell passthrough
    if (cmd == "bash" || cmd == "sh") {
        std::string shell_cmd;
        for (int i = 1; i < argc; ++i) {
            if (i > 1) shell_cmd += ' ';
            shell_cmd += argv[i];
        }
        return std::system(shell_cmd.c_str());
    }

    // Dispatch subcommands (pass remaining args after subcommand)
    int sub_argc = argc - 2;
    char** sub_argv = argv + 2;

    if (cmd == "classify")  cmd_classify(sub_argc, sub_argv);
    else if (cmd == "summary")   cmd_summary(sub_argc, sub_argv);
    else if (cmd == "download")  cmd_download(sub_argc, sub_argv);
    else if (cmd == "setup-db")  cmd_setup_db(sub_argc, sub_argv);
    else if (cmd == "list-db")   cmd_list_db(sub_argc, sub_argv);
    else if (cmd == "version")   cmd_version(sub_argc, sub_argv);
    else {
        std::cerr << "Unknown command: " << cmd << "\n\n";
        print_usage();
        return 1;
    }

    return 0;
}
