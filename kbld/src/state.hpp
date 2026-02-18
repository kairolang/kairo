#pragma once

#include <nlohmann/json.hpp>

#include "types.hpp"

namespace kbld {

using json = nlohmann::json;

inline auto load_state(const fs::path &path) -> BuildState {
    BuildState st;
    if (!fs::exists(path))
        return st;

    std::ifstream ifs(path);
    if (!ifs)
        return st;

    try {
        json doc = json::parse(ifs);
        if (!doc.contains("targets"))
            return st;

        for (auto &[name, obj] : doc["targets"].items()) {
            TargetState ts;
            ts.entry_mtime  = obj.value("entry_mtime", std::int64_t{0});
            ts.output_mtime = obj.value("output_mtime", std::int64_t{0});

            if (obj.contains("dep_mtimes")) {
                for (auto &[k, v] : obj["dep_mtimes"].items()) {
                    ts.dep_mtimes[k] = v.get<std::int64_t>();
                }
            }
            if (obj.contains("cxx_source_mtimes")) {
                for (auto &[k, v] : obj["cxx_source_mtimes"].items()) {
                    ts.cxx_source_mtimes[k] = v.get<std::int64_t>();
                }
            }
            st.targets[name] = std::move(ts);
        }
    } catch (...) { return BuildState{}; }

    return st;
}

inline auto save_state(const fs::path &path, const BuildState &st) -> bool {
    json doc;
    json targets_obj = json::object();

    for (auto &[name, ts] : st.targets) {
        json tobj;
        tobj["entry_mtime"]  = ts.entry_mtime;
        tobj["output_mtime"] = ts.output_mtime;

        json deps = json::object();
        for (auto &[k, v] : ts.dep_mtimes)
            deps[k] = v;
        tobj["dep_mtimes"] = std::move(deps);

        json cxx = json::object();
        for (auto &[k, v] : ts.cxx_source_mtimes)
            cxx[k] = v;
        tobj["cxx_source_mtimes"] = std::move(cxx);

        targets_obj[name] = std::move(tobj);
    }

    doc["targets"] = std::move(targets_obj);

    fs::create_directories(path.parent_path());
    std::ofstream ofs(path, std::ios::trunc);
    if (!ofs)
        return false;
    ofs << doc.dump(2);
    return ofs.good();
}

}  // namespace kbld
