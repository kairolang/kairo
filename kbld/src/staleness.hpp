#pragma once

#include "deps.hpp"
#include "state.hpp"
#include "types.hpp"

namespace kbld {

struct StalenessResult {
    bool        stale = true;
    std::string reason;
};

inline auto check_staleness(const Target      &target,
                            const BuildState  &state,
                            const std::string &compiler,
                            const fs::path    &output_path,
                            const fs::path    &cache_dir,
                            bool               verbose) -> StalenessResult {
    if (!state.targets.contains(target.name)) {
        return {true, "no previous build state"};
    }

    auto &ts = state.targets.at(target.name);

    if (!fs::exists(output_path)) {
        return {true, "output binary missing"};
    }

    auto entry_mtime   = file_mtime_ns(target.entry);
    bool entry_changed = (entry_mtime != ts.entry_mtime);

    std::vector<std::string> deps;
    if (entry_changed) {
        deps = resolve_deps(compiler, target.entry, target.includes, cache_dir, verbose);
    } else {
        deps = load_cached_deps(cache_dir, target.entry);
        if (deps.empty()) {
            deps = resolve_deps(compiler, target.entry, target.includes, cache_dir, verbose);
        }
    }

    auto output_mtime = file_mtime_ns(output_path);

    if (entry_mtime > output_mtime) {
        return {true, fmt("entry '{}' modified", target.entry)};
    }

    for (auto &dep : deps) {
        auto dep_mtime = file_mtime_ns(dep);
        if (dep_mtime > output_mtime) {
            return {true, fmt("dependency '{}' modified", dep)};
        }
    }

    for (auto &src : target.cxx_sources) {
        auto src_mtime = file_mtime_ns(src);
        if (src_mtime > output_mtime) {
            return {true, fmt("C++ source '{}' modified", src)};
        }
    }

    return {false, "up to date"};
}

inline auto record_state(const Target      &target,
                         BuildState        &state,
                         const std::string &compiler,
                         const fs::path    &output_path,
                         const fs::path    &cache_dir,
                         bool               verbose) -> void {
    TargetState ts;
    ts.entry_mtime  = file_mtime_ns(target.entry);
    ts.output_mtime = file_mtime_ns(output_path);

    auto deps = load_cached_deps(cache_dir, target.entry);
    if (deps.empty()) {
        deps = resolve_deps(compiler, target.entry, target.includes, cache_dir, verbose);
    }

    for (auto &dep : deps) {
        ts.dep_mtimes[dep] = file_mtime_ns(dep);
    }

    for (auto &src : target.cxx_sources) {
        ts.cxx_source_mtimes[src] = file_mtime_ns(src);
    }

    state.targets[target.name] = std::move(ts);
}

}  // namespace kbld
