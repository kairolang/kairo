#pragma once

#include "compile_commands.hpp"
#include "deps.hpp"
#include "types.hpp"

namespace kbld {

inline auto execute_clean(const Config &cfg, const CLIOptions &opts) -> int {
    if (opts.positional.empty()) {
        log::info("Cleaning all build artifacts");
        std::error_code ec;
        fs::remove_all("build", ec);
        if (ec) {
            log::warn(fmt("Failed to remove build/: {}", ec.message()));
        }
        fs::remove("compile_commands.json", ec);
        return 0;
    }

    auto triple = get_triple();
    for (auto &name : opts.positional) {
        for (auto &mode_str : {"release", "debug"}) {
            auto bin = fs::path("build") / triple / mode_str / "bin" / name;
            if (fs::exists(bin)) {
                log::info(fmt("Removing {}", bin.string()));
                fs::remove(bin);
            }
        }

        auto state_path = fs::path("build") / ".cache" / "state.json";
        if (fs::exists(state_path)) {
            auto state = load_state(state_path);
            state.targets.erase(name);
            save_state(state_path, state);
        }

        auto meta_cpp = fs::path("build") / ".gen" / (name + "_meta.cpp");
        auto meta_rc  = fs::path("build") / ".gen" / (name + ".rc");
        auto meta_res = fs::path("build") / ".gen" / (name + ".res");
        for (auto &p : {meta_cpp, meta_rc, meta_res}) {
            std::error_code ec;
            fs::remove(p, ec);
        }
    }

    return 0;
}

inline auto execute_index(const Config &cfg) -> int {
    log::info("Regenerating compile_commands.json");
    if (!generate_compile_commands(cfg, fs::current_path())) {
        log::error("Failed to generate compile_commands.json");
        return 1;
    }
    log::info("compile_commands.json updated");
    return 0;
}

inline auto execute_deps(const Config &cfg, const CLIOptions &opts) -> int {
    if (opts.positional.empty()) {
        log::error("Usage: kbld deps <file.kro>");
        return 1;
    }

    auto file = opts.positional[0];
    if (!fs::exists(file)) {
        log::error(fmt("File not found: {}", file));
        return 1;
    }

    const auto &first = cfg.targets.front();

    std::string cmd = cfg.build.compiler + " " + file + " --deps";
    for (auto &inc : first.includes) {
        cmd += " -I" + inc;
    }

    log::info(fmt("Resolving dependencies for {}", file));

    std::string out;
    int         rc = run_capture(cmd + " 2>&1", out);

    auto deps = parse_dep_json(out);
    if (deps.empty()) {
        putln("No dependencies found (or --deps returned no JSON)");
        if (!out.empty())
            puts_out(fmt("{}", out));
        return rc;
    }

    putln(fmt("{}", file));
    for (std::size_t i = 0; i < deps.size(); ++i) {
        bool last = (i + 1 == deps.size());
        putln(fmt("  {} {}", last ? "└──" : "├──", deps[i]));
    }

    return 0;
}

inline auto execute_install(const Config &cfg, const CLIOptions &opts) -> int {
    auto mode    = opts.mode_override.value_or(cfg.build.mode);
    auto triple  = get_triple();
    auto bin_dir = fs::path("build") / triple / to_string(mode) / "bin";
    auto dest    = fs::path(opts.install_prefix) / "bin";

    if (!fs::exists(bin_dir)) {
        log::error(fmt("Build directory '{}' not found. Run kbld build first.", bin_dir.string()));
        return 1;
    }

    fs::create_directories(dest);

    int installed = 0;
    for (auto &t : cfg.targets) {
        if (t.type != TargetType::Binary)
            continue;

        auto src = bin_dir / t.name;
        if (!fs::exists(src)) {
            log::warn(fmt("Binary '{}' not found, skipping", t.name));
            continue;
        }

        auto dst = dest / t.name;
        log::info(fmt("Installing {} -> {}", src.string(), dst.string()));

        std::error_code ec;
        fs::copy_file(src, dst, fs::copy_options::overwrite_existing, ec);
        if (ec) {
            log::error(fmt("Failed to install '{}': {}", t.name, ec.message()));
            return 1;
        }

#ifndef _WIN32
        fs::permissions(dst,
                        fs::perms::owner_exec | fs::perms::group_exec | fs::perms::others_exec,
                        fs::perm_options::add,
                        ec);
#endif
        ++installed;
    }

    log::info(fmt("Installed {} binaries to {}", installed, dest.string()));
    return 0;
}

inline auto execute_test(const Config &cfg, const CLIOptions &opts) -> int {
    if (opts.positional.empty()) {
        log::error("Usage: kbld test <file.kro> [--perf] [--compile-only]");
        return 1;
    }

    auto file = opts.positional[0];
    if (!fs::exists(file)) {
        log::error(fmt("Test file not found: {}", file));
        return 1;
    }

    auto source = read_file(file);

    std::string stripped;
    stripped.reserve(source.size());
    for (std::size_t i = 0; i < source.size(); ++i) {
        if (i + 1 < source.size() && source[i] == '/' && source[i + 1] == '/') {
            while (i < source.size() && source[i] != '\n')
                ++i;
            stripped += '\n';
        } else if (i + 1 < source.size() && source[i] == '/' && source[i + 1] == '*') {
            i += 2;
            while (i + 1 < source.size() && !(source[i] == '*' && source[i + 1] == '/'))
                ++i;
            if (i + 1 < source.size())
                ++i;  // skip '/'
        } else {
            stripped += source[i];
        }
    }

    if (stripped.find("fn Test()") == std::string::npos &&
        stripped.find("fn Test ()") == std::string::npos) {
        log::error(fmt("{}: no 'fn Test() -> i32' found", file));
        return 1;
    }

    auto test_dir = fs::path("build") / ".shared" / "tests";
    fs::create_directories(test_dir);

    auto filename  = fs::path(file).filename().string();
    auto test_file = test_dir / filename;

    std::string test_source = source + "\n\nfn main() -> i32 {\n    return Test();\n}\n";
    write_file(test_file, test_source);

    auto gen_dir = fs::path("build") / ".gen";
    fs::create_directories(gen_dir);
    auto test_bin = gen_dir / "test_run";

    BuildMode   mode  = opts.perf ? BuildMode::Release : BuildMode::Debug;
    const auto &first = cfg.targets.front();

    std::string cmd = cfg.build.compiler;
    cmd += " " + test_file.string();
    cmd += " -o" + test_bin.string();
    for (auto &inc : first.includes) {
        cmd += " -I" + inc;
    }
    cmd += (mode == BuildMode::Debug) ? " --debug" : " --release";
    if (opts.verbose)
        cmd += " --verbose";

    log::info(fmt("Compiling test: {}", filename));
    if (opts.verbose)
        log::info(fmt("  {}", cmd));

    if (opts.dry_run)
        return 0;

    std::string out, err;
    int         rc = run_capture_all(cmd, out, err);

    if (rc != 0) {
        log::error(fmt("Test compilation failed (exit {})", rc));
        if (!out.empty())
            puts_err(fmt("{}", out));
        if (!err.empty())
            puts_err(fmt("{}", err));
        return rc;
    }

    if (opts.compile_only) {
        log::info(fmt("Test compiled: {}", test_bin.string()));
        return 0;
    }

    int         tw = terminal_width();
    std::string rule(tw, '\xe2');  // ─ character
    std::string hr(tw, '-');

    putln(fmt("{}", hr));
    int exit_code = run_command(test_bin.string());
    putln(fmt("{}", hr));

    if (exit_code == 0) {
        log::info("Test PASSED");
    } else {
        log::error(fmt("Test FAILED (exit {})", exit_code));
    }

    return exit_code;
}

inline auto execute_line(const Config &cfg, const CLIOptions &opts) -> int {
    if (opts.positional.empty()) {
        log::error("Usage: kbld line <file.kro> [start:end]");
        return 1;
    }

    auto file = opts.positional[0];
    if (!fs::exists(file)) {
        log::error(fmt("File not found: {}", file));
        return 1;
    }

    const auto &first = cfg.targets.front();

    std::string cmd = cfg.build.compiler + " " + file + " --emit-ir --verbose";
    for (auto &inc : first.includes) {
        cmd += " -I" + inc;
    }

    log::info(fmt("Extracting IR for {}", file));

    std::string out;
    run_capture(cmd + " 2>/dev/null", out);

    if (out.empty()) {
        log::error("No output from kairo --emit-ir");
        return 1;
    }

    std::string clean;
    clean.reserve(out.size());
    for (std::size_t i = 0; i < out.size(); ++i) {
        if (out[i] == '\033' && i + 1 < out.size() && out[i + 1] == '[') {
            i += 2;
            while (i < out.size() && !std::isalpha(static_cast<unsigned char>(out[i])))
                ++i;
            continue;
        }
        clean += out[i];
    }

    auto last_header = clean.rfind("#define __KAIRO_CORE_CXX__");
    if (last_header != std::string::npos) {
        auto endif_pos = clean.find("#endif", last_header);
        if (endif_pos != std::string::npos) {
            auto after_endif = clean.find('\n', endif_pos);
            if (after_endif != std::string::npos) {
                clean = clean.substr(after_endif + 1);
            }
        }
    }

    auto last_endif = clean.rfind("#endif");
    if (last_endif != std::string::npos) {
        clean = clean.substr(0, last_endif);
    }

    std::map<std::string, std::vector<std::string>> file_lines;
    std::map<std::string, int> file_line1_count;  // track second #line 1 per file

    std::string current_file;
    int         current_line_num = 0;

    std::istringstream iss(clean);
    std::string        line;

    while (std::getline(iss, line)) {
        if (line.starts_with("#line ")) {
            auto        rest = line.substr(6);
            std::size_t pos  = 0;
            int         ln   = 0;
            try {
                ln = std::stoi(rest, &pos);
            } catch (...) { continue; }

            auto quote1 = rest.find('"', pos);
            if (quote1 != std::string::npos) {
                auto quote2 = rest.find('"', quote1 + 1);
                if (quote2 != std::string::npos) {
                    auto fp = rest.substr(quote1 + 1, quote2 - quote1 - 1);

                    if (ln == 1) {
                        file_line1_count[fp]++;
                        if (file_line1_count[fp] >= 2) {
                            file_lines[fp].clear();
                        }
                    }

                    current_file     = fp;
                    current_line_num = ln;
                    continue;
                }
            }

            current_line_num = ln;
            continue;
        }

        if (!current_file.empty()) {
            auto &lines = file_lines[current_file];
            while (static_cast<int>(lines.size()) < current_line_num - 1) {
                lines.push_back("");
            }
            if (static_cast<int>(lines.size()) < current_line_num) {
                lines.push_back(line);
            } else {
                lines.push_back(line);
            }
            current_line_num++;
        }
    }

    fs::path    target_file = fs::absolute(file);
    std::string target_str  = target_file.string();

    std::string matched_key;
    for (auto &[key, _] : file_lines) {
        if (target_str.ends_with(key) || key.ends_with(fs::path(file).filename().string())) {
            matched_key = key;
            break;
        }
    }

    if (matched_key.empty()) {
        auto fname = fs::path(file).filename().string();
        for (auto &[key, _] : file_lines) {
            if (key.find(fname) != std::string::npos) {
                matched_key = key;
                break;
            }
        }
    }

    if (matched_key.empty()) {
        log::error(fmt("File '{}' not found in IR output", file));
        log::info("Available files in IR:");
        for (auto &[key, lines_vec] : file_lines) {
            putln(fmt("  {} ({} lines)", key, lines_vec.size()));
        }
        return 1;
    }

    auto &lines_vec = file_lines[matched_key];

    int start = 1;
    int end   = static_cast<int>(lines_vec.size());

    if (!opts.line_range.empty()) {
        auto &range = opts.line_range;
        auto  sep   = range.find(':');
        if (sep == std::string::npos)
            sep = range.find('-');

        if (sep != std::string::npos) {
            start = std::stoi(range.substr(0, sep));
            end   = std::stoi(range.substr(sep + 1));
        } else {
            start = end = std::stoi(range);
        }
    }

    start = std::max(1, start);
    end   = std::min(end, static_cast<int>(lines_vec.size()));

    std::vector<std::string> extracted;
    for (int i = start - 1; i < end; ++i) {
        if (i >= 0 && i < static_cast<int>(lines_vec.size())) {
            if (!lines_vec[i].empty()) {
                extracted.push_back(lines_vec[i]);
            }
        }
    }

    auto tmp = fs::temp_directory_path() / "kbld_ir_extract.cpp";
    {
        std::string content;
        for (auto &l : extracted)
            content += l + "\n";
        write_file(tmp, content);
    }

    std::string formatted_out;
    int         fmt_rc = run_capture("clang-format -style=file " + tmp.string(), formatted_out);

    if (fmt_rc == 0 && !formatted_out.empty()) {
        puts_out(fmt("{}", formatted_out));
    } else {
        for (auto &l : extracted) {
            putln(fmt("{}", l));
        }
    }

    fs::remove(tmp);
    return 0;
}

}  // namespace kbld