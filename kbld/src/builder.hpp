#pragma once

#include "compile_commands.hpp"
#include "graph.hpp"
#include "metadata.hpp"
#include "staleness.hpp"
#include "state.hpp"
#include "types.hpp"

namespace kbld {

/// Construct the kairo invocation command for a target.
inline auto build_command(const Target     &target,
                          const Config     &cfg,
                          BuildMode         mode,
                          const fs::path   &output_dir,
                          const fs::path   &gen_dir,
                          const CLIOptions &opts) -> std::string {
    std::string cmd = cfg.build.compiler;

    cmd += " " + target.entry;

    fs::path out_bin = output_dir / "bin" / target.name;
    cmd += " -o" + out_bin.string();

    for (auto &inc : target.includes) {
        cmd += " -I" + inc;
    }

    for (auto &link : target.links) {
        cmd += " -L" + link;
    }

    for (auto &lib : target.libs) {
        cmd += " -l" + lib;
    }

    cmd += (mode == BuildMode::Debug) ? " --debug" : " --release";

    if (opts.verbose)
        cmd += " --verbose";

    if (opts.emit_ir)
        cmd += " --emit-ir";
    if (opts.emit_ast)
        cmd += " --emit-ast";

    std::vector<std::string> passthrough;

    for (auto &def : target.defines) {
        passthrough.push_back("-D" + def);
    }

    for (auto &lf : target.ld_flags) {
        passthrough.push_back(lf);
    }

    for (auto &src : target.cxx_sources) {
        passthrough.push_back(src);
    }

    auto meta_file = gen_dir / (target.name + "_meta.cpp");
    if (fs::exists(meta_file)) {
        passthrough.push_back(meta_file.string());
    }

    for (auto &pt : target.cxx_passthrough) {
        passthrough.push_back(pt);
    }

    if (is_windows()) {
        auto rc_file = gen_dir / (target.name + ".rc");
        if (fs::exists(rc_file)) {
            auto res_file = gen_dir / (target.name + ".res");
            passthrough.push_back(res_file.string());
        }
    }

    if (!passthrough.empty()) {
        cmd += " --";
        for (auto &pt : passthrough) {
            cmd += " " + pt;
        }
    }

    return cmd;
}

inline auto target_output_path(const Target &target, BuildMode mode) -> fs::path {
    auto triple   = get_triple();
    auto mode_str = to_string(mode);
    return fs::path("build") / triple / mode_str / "bin" / target.name;
}

inline auto build_target(const Target     &target,
                         const Config     &cfg,
                         BuildMode         mode,
                         const CLIOptions &opts,
                         BuildState       &state,
                         std::mutex       &state_mutex) -> int {

    auto triple     = get_triple();
    auto mode_str   = to_string(mode);
    auto output_dir = fs::path("build") / triple / mode_str;
    auto gen_dir    = fs::path("build") / ".gen";
    auto cache_dir  = fs::path("build") / ".cache" / "deps";
    auto state_path = fs::path("build") / ".cache" / "state.json";

    fs::create_directories(output_dir / "bin");
    fs::create_directories(gen_dir);
    fs::create_directories(cache_dir);

    auto output_path = output_dir / "bin" / target.name;

    {
        std::lock_guard lk(state_mutex);
        auto            result = check_staleness(
            target, state, cfg.build.compiler, output_path, cache_dir, opts.verbose);
        if (!result.stale) {
            log::info(fmt("'{}' is up to date", target.name));
            return 0;
        }
        log::verbose(fmt("'{}' stale: {}", target.name, result.reason), opts.verbose);
    }

    if (!fs::exists(target.entry)) {
        log::error(fmt("Entry file '{}' not found for target '{}'", target.entry, target.name));
        return 1;
    }

    if (!target.pre_build.empty()) {
        log::info(fmt("'{}' pre-build: {}", target.name, target.pre_build));
        if (!opts.dry_run) {
            int rc = run_command(target.pre_build);
            if (rc != 0) {
                log::error(fmt("Pre-build hook failed for '{}' (exit {})", target.name, rc));
                return rc;
            }
        }
    }

    generate_metadata(cfg.project, target, gen_dir);

    if (is_windows()) {
        auto rc_file = gen_dir / (target.name + ".rc");
        if (fs::exists(rc_file)) {
            auto res_file = gen_dir / (target.name + ".res");
            
            // locate rc.exe via vswhere
            std::string rc_exe = "rc.exe"; // fallback
            {
                std::string vswhere_out;
                run_capture(
                    "\"C:\\Program Files (x86)\\Microsoft Visual Studio\\Installer\\vswhere.exe\""
                    " -latest -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64"
                    " -property installationPath",
                    vswhere_out);
                // trim whitespace
                while (!vswhere_out.empty() && (vswhere_out.back() == '\n' ||
                                                vswhere_out.back() == '\r' ||
                                                vswhere_out.back() == ' '))
                    vswhere_out.pop_back();
                if (!vswhere_out.empty()) {
                    // try Windows SDK rc.exe via VS dev env — but easiest is MSVC bin
                    fs::path vs_rc = fs::path(vswhere_out)
                        / "VC" / "Tools" / "MSVC";
                    if (fs::exists(vs_rc)) {
                        // pick the first (only) MSVC version dir
                        for (auto &entry : fs::directory_iterator(vs_rc)) {
                            auto candidate = entry.path()
                                / "bin" / "Hostx64" / "x64" / "rc.exe";
                            if (fs::exists(candidate)) {
                                rc_exe = candidate.string();
                                break;
                            }
                        }
                    }
                }
            }

            auto rc_cmd = fmt("\"{}\" /nologo /fo\"{}\" \"{}\"",
                            rc_exe, res_file.string(), rc_file.string());
            if (!opts.dry_run) {
                int rc = run_command(rc_cmd);
                if (rc != 0)
                    log::warn(fmt("RC compilation failed for '{}', continuing", target.name));
            }
        }
    }

    auto cmd = build_command(target, cfg, mode, output_dir, gen_dir, opts);

    log::info(fmt("Building '{}'", target.name));
    if (opts.verbose || opts.dry_run) {
        log::info(fmt("  {}", cmd));
    }

    if (opts.dry_run)
        return 0;

    std::string out, err;
    int         rc = run_capture_all(cmd, out, err);

    // Replace the output printing block after run_capture_all:
    if (rc != 0) {
        log::error(fmt("Target '{}' failed (exit {})", target.name, rc));
        if (!out.empty())
            puts_err(fmt("{}", out));
        if (!err.empty())
            puts_err(fmt("{}", err));
        return rc;
    }

    // Always print kairo output — it contains diagnostics
    if (!out.empty())
        puts_out(fmt("{}", out));
    if (!err.empty() && opts.verbose)
        puts_err(fmt("{}", err));

    if (!target.post_build.empty()) {
        log::info(fmt("'{}' post-build: {}", target.name, target.post_build));
        int post_rc = run_command(target.post_build);
        if (post_rc != 0) {
            log::error(fmt("Post-build hook failed for '{}' (exit {})", target.name, post_rc));
            return post_rc;
        }
    }

    {
        std::lock_guard lk(state_mutex);
        record_state(target, state, cfg.build.compiler, output_path, cache_dir, opts.verbose);
        save_state(state_path, state);
    }

    log::info(fmt("'{}' built successfully", target.name));
    return 0;
}

inline auto execute_build(const Config &cfg, const CLIOptions &opts) -> int {
    auto mode = opts.mode_override.value_or(cfg.build.mode);

    log::info("Generating compile_commands.json");
    if (!generate_compile_commands(cfg, fs::current_path())) {
        log::warn("Failed to generate compile_commands.json, continuing...");
    }

    std::vector<Target> selected;
    if (opts.positional.empty()) {
        selected = cfg.targets;
    } else {
        std::unordered_map<std::string, const Target *> by_name;
        for (auto &t : cfg.targets)
            by_name[t.name] = &t;

        for (auto &name : opts.positional) {
            if (!by_name.contains(name)) {
                log::error(fmt("Unknown target: '{}'", name));
                return 1;
            }
            selected.push_back(*by_name[name]);
        }

        std::unordered_set<std::string>          needed;
        std::function<void(const std::string &)> add_deps = [&](const std::string &name) {
            if (needed.contains(name))
                return;
            needed.insert(name);
            if (by_name.contains(name)) {
                for (auto &dep : by_name[name]->deps) {
                    add_deps(dep);
                }
            }
        };

        for (auto &t : selected)
            add_deps(t.name);

        selected.clear();
        for (auto &t : cfg.targets) {
            if (needed.contains(t.name)) {
                selected.push_back(t);
            }
        }
    }

    auto order = topo_sort(selected);
    auto waves = build_waves(selected, order);

    std::unordered_map<std::string, const Target *> by_name;
    for (auto &t : selected)
        by_name[t.name] = &t;

    auto       state_path = fs::path("build") / ".cache" / "state.json";
    auto       state      = load_state(state_path);
    std::mutex state_mutex;

    int max_jobs =
        opts.jobs > 0 ? opts.jobs : static_cast<int>(std::thread::hardware_concurrency());
    if (max_jobs < 1)
        max_jobs = 1;

    std::atomic<bool> any_failed{false};

    for (auto &wave : waves) {
        if (any_failed.load() && !opts.keep_going)
            break;

        if (wave.size() == 1) {
            auto *t  = by_name[wave[0]];
            int   rc = build_target(*t, cfg, mode, opts, state, state_mutex);
            if (rc != 0) {
                any_failed.store(true);
                if (!opts.keep_going)
                    return rc;
            }
        } else {
            std::counting_semaphore<> sem(max_jobs);
            std::vector<std::jthread> threads;
            std::atomic<int>          wave_rc{0};

            for (auto &name : wave) {
                if (any_failed.load() && !opts.keep_going)
                    break;

                sem.acquire();
                threads.emplace_back([&, name]() {
                    auto *t  = by_name[name];
                    int   rc = build_target(*t, cfg, mode, opts, state, state_mutex);
                    if (rc != 0) {
                        wave_rc.store(rc);
                        any_failed.store(true);
                    }
                    sem.release();
                });
            }

            threads.clear();

            if (wave_rc.load() != 0 && !opts.keep_going) {
                return wave_rc.load();
            }
        }
    }

    return any_failed.load() ? 1 : 0;
}

}  // namespace kbld
