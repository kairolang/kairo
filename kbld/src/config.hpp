#pragma once

#include <toml++/toml.hpp>

#include "types.hpp"

namespace kbld {

namespace detail {

    template <typename T>
    auto toml_get(const toml::table &tbl, std::string_view key, T default_val) -> T {
        if (auto v = tbl[key].value<T>())
            return *v;
        return default_val;
    }

    inline auto toml_string_array(const toml::table &tbl, std::string_view key)
        -> std::vector<std::string> {
        std::vector<std::string> result;
        if (auto *arr = tbl[key].as_array()) {
            for (auto &elem : *arr) {
                if (auto s = elem.value<std::string>()) {
                    result.push_back(*s);
                }
            }
        }
        return result;
    }

}  // namespace detail

inline auto parse_config(const fs::path &path) -> Config {
    Config cfg;

    toml::table doc;
    try {
        doc = toml::parse_file(path.string());
    } catch (const toml::parse_error &err) {
        throw std::runtime_error(fmt("{}:{}:{}: {}",
                                     path.string(),
                                     err.source().begin.line,
                                     err.source().begin.column,
                                     err.description()));
    }

    // [project]
    if (auto *proj = doc["project"].as_table()) {
        cfg.project.name    = detail::toml_get<std::string>(*proj, "name", "");
        cfg.project.version = detail::toml_get<std::string>(*proj, "version", "0.0.0");
        cfg.project.author  = detail::toml_get<std::string>(*proj, "author", "");
        cfg.project.license = detail::toml_get<std::string>(*proj, "license", "");
    }

    // [workspace]
    if (auto *ws = doc["workspace"].as_table()) {
        cfg.workspace.skip_dirs = detail::toml_string_array(*ws, "skip_dirs");
    }

    // [build]
    if (auto *b = doc["build"].as_table()) {
        cfg.build.compiler = detail::toml_get<std::string>(*b, "compiler", "kairo");
        auto mode_str      = detail::toml_get<std::string>(*b, "mode", "release");
        cfg.build.mode     = (mode_str == "debug") ? BuildMode::Debug : BuildMode::Release;
    }

    // [[target]]
    if (auto *targets = doc["target"].as_array()) {
        for (auto &elem : *targets) {
            if (auto *tbl = elem.as_table()) {
                Target t;
                t.name            = detail::toml_get<std::string>(*tbl, "name", "");
                t.entry           = detail::toml_get<std::string>(*tbl, "entry", "");
                auto type_str     = detail::toml_get<std::string>(*tbl, "type", "binary");
                t.type            = parse_target_type(type_str);
                t.includes        = detail::toml_string_array(*tbl, "includes");
                t.links           = detail::toml_string_array(*tbl, "links");
                t.libs            = detail::toml_string_array(*tbl, "libs");
                t.deps            = detail::toml_string_array(*tbl, "deps");
                t.defines         = detail::toml_string_array(*tbl, "defines");
                t.ld_flags        = detail::toml_string_array(*tbl, "ld_flags");
                t.cxx_sources     = detail::toml_string_array(*tbl, "cxx_sources");
                t.cxx_passthrough = detail::toml_string_array(*tbl, "cxx_passthrough");
                t.pre_build       = detail::toml_get<std::string>(*tbl, "pre_build", "");
                t.post_build      = detail::toml_get<std::string>(*tbl, "post_build", "");

                if (t.name.empty()) {
                    throw std::runtime_error("Target missing 'name'");
                }
                if (t.entry.empty()) {
                    throw std::runtime_error(fmt("Target '{}' missing 'entry'", t.name));
                }
                cfg.targets.push_back(std::move(t));
            }
        }
    }

    if (cfg.targets.empty()) {
        throw std::runtime_error("No [[target]] entries in build.toml");
    }

    return cfg;
}

}  // namespace kbld
