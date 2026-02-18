#pragma once

#include <nlohmann/json.hpp>

#include "types.hpp"

namespace kbld {

using json = nlohmann::json;

namespace detail {

    inline auto is_cxx_file(const fs::path &p) -> bool {
        static const std::set<std::string> exts = {
            ".c", ".cc", ".cpp", ".cxx", ".h", ".hh", ".hpp"};
        return exts.contains(p.extension().string());
    }

    inline auto is_hlx_file(const fs::path &p) -> bool { return p.extension() == ".hlx"; }

    inline auto should_skip(const fs::path                 &p,
                            const std::vector<std::string> &skip_dirs,
                            const fs::path                 &root) -> bool {
        auto rel = fs::relative(p, root);
        for (auto &skip : skip_dirs) {
            auto it = rel.begin();
            if (it != rel.end() && *it == skip)
                return true;
        }
        return false;
    }

}  // namespace detail

inline auto generate_compile_commands(const Config &cfg, const fs::path &root) -> bool {
    json entries = json::array();
    auto cwd     = fs::absolute(root).string();

    std::set<fs::path> entry_paths;
    for (auto &t : cfg.targets) {
        entry_paths.insert(fs::absolute(t.entry));
    }

    const auto &first = cfg.targets.front();

    std::vector<fs::path> cxx_files;
    std::vector<fs::path> hlx_non_entry;

    std::error_code ec;
    for (auto &de : fs::recursive_directory_iterator(
             root, fs::directory_options::skip_permission_denied, ec)) {
        if (!de.is_regular_file())
            continue;

        auto abs = fs::absolute(de.path());
        if (detail::should_skip(de.path(), cfg.workspace.skip_dirs, root))
            continue;

        auto rel = fs::relative(de.path(), root);
        if (rel.begin() != rel.end() && *rel.begin() == "build")
            continue;

        if (detail::is_cxx_file(de.path())) {
            cxx_files.push_back(abs);
        } else if (detail::is_hlx_file(de.path())) {
            if (!entry_paths.contains(abs)) {
                hlx_non_entry.push_back(abs);
            }
        }
    }

    for (auto &f : cxx_files) {
        json args = json::array();

        if (is_windows()) {
            args.push_back("cl.exe");
            args.push_back("/nologo");
            args.push_back("/std:c++latest");
            args.push_back("/MT");
            args.push_back("/w");
            for (auto &inc : first.includes) {
                args.push_back("/I" + inc);
            }
            args.push_back("/EHsc");
            for (auto &def : first.defines) {
                args.push_back("/D" + def);
            }
        } else {
            args.push_back("clang++");
            args.push_back("-std=c++23");
            args.push_back("-stdlib=libc++");
            args.push_back("-lc++");
            args.push_back("-lc++abi");
            args.push_back("-O3");
            args.push_back("-w");
            for (auto &inc : first.includes) {
                args.push_back("-I" + inc);
            }
            for (auto &def : first.defines) {
                args.push_back("-D" + def);
            }
        }
        args.push_back(f.string());

        json entry;
        entry["directory"] = cwd;
        entry["arguments"] = std::move(args);
        entry["file"]      = fs::relative(f, root).string();
        entries.push_back(std::move(entry));
    }

    for (auto &f : hlx_non_entry) {
        json args = json::array();
        for (auto &inc : first.includes) {
            args.push_back("-I" + inc);
        }

        json entry;
        entry["directory"] = cwd;
        entry["arguments"] = std::move(args);
        entry["file"]      = f.string();
        entries.push_back(std::move(entry));
    }

    for (auto &t : cfg.targets) {
        json args = json::array();
        for (auto &inc : t.includes) {
            args.push_back("-I" + inc);
        }

        json entry;
        entry["directory"] = cwd;
        entry["arguments"] = std::move(args);
        entry["file"]      = fs::absolute(t.entry).string();
        entries.push_back(std::move(entry));
    }

    auto          out_path = root / "compile_commands.json";
    std::ofstream ofs(out_path, std::ios::trunc);
    if (!ofs) {
        log::warn("Failed to write compile_commands.json");
        return false;
    }
    ofs << entries.dump(2) << '\n';
    return ofs.good();
}

}  // namespace kbld
