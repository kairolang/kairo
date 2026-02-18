#pragma once

#include <nlohmann/json.hpp>

#include "types.hpp"

namespace kbld {

using json = nlohmann::json;

inline auto parse_dep_json(const std::string &raw) -> std::vector<std::string> {
    std::vector<std::string> result;

    auto pos = raw.find("{\"dependencies\":");
    if (pos == std::string::npos) {
        pos = raw.find("{ \"dependencies\":");
    }
    if (pos == std::string::npos)
        return result;

    int         depth = 0;
    std::size_t end   = pos;
    for (std::size_t i = pos; i < raw.size(); ++i) {
        if (raw[i] == '{')
            ++depth;
        else if (raw[i] == '}') {
            --depth;
            if (depth == 0) {
                end = i;
                break;
            }
        }
    }

    std::string json_str = raw.substr(pos, end - pos + 1);

    try {
        json doc = json::parse(json_str);
        if (doc.contains("dependencies") && doc["dependencies"].is_array()) {
            for (auto &dep : doc["dependencies"]) {
                if (dep.is_string()) {
                    result.push_back(dep.get<std::string>());
                }
            }
        }
    } catch (...) {
        // Malformed JSON
    }

    return result;
}

inline auto resolve_deps(const std::string              &compiler,
                         const fs::path                 &entry,
                         const std::vector<std::string> &includes,
                         const fs::path                 &cache_dir,
                         bool                            verbose) -> std::vector<std::string> {
    auto hash       = quick_hash(fs::absolute(entry).string());
    auto cache_file = cache_dir / (hash + ".json");

    std::string cmd = compiler + " " + entry.string() + " --deps";
    for (auto &inc : includes) {
        cmd += " -I" + inc;
    }

    log::verbose(fmt("Resolving deps: {}", cmd), verbose);

    std::string out;
    int         rc = run_capture(cmd, out);
    (void)rc;

    auto deps = parse_dep_json(out);

    if (!deps.empty()) {
        json doc;
        doc["dependencies"] = deps;
        write_file(cache_file, doc.dump(2));
    }

    return deps;
}

inline auto load_cached_deps(const fs::path &cache_dir, const fs::path &entry)
    -> std::vector<std::string> {
    auto hash       = quick_hash(fs::absolute(entry).string());
    auto cache_file = cache_dir / (hash + ".json");

    if (!fs::exists(cache_file))
        return {};

    auto content = read_file(cache_file);
    return parse_dep_json(content);
}

}  // namespace kbld
