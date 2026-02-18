/// kbld — Build tool for Kairo projects
/// Single-file build: g++ -std=c++23 -O2 -o kbld src/main.cpp

#include "builder.hpp"
#include "cli.hpp"
#include "commands.hpp"
#include "config.hpp"

using namespace kbld;

auto main(int argc, char *argv[]) -> int {
    try {
        auto opts = parse_cli(argc, argv);

        // Find build.toml
        fs::path config_path = "build.toml";
        if (!fs::exists(config_path)) {
            // Walk up directories
            auto dir = fs::current_path();
            while (dir.has_parent_path() && dir != dir.root_path()) {
                if (fs::exists(dir / "build.toml")) {
                    config_path = dir / "build.toml";
                    fs::current_path(dir);
                    break;
                }
                dir = dir.parent_path();
            }
        }

        if (!fs::exists(config_path)) {
            log::error("build.toml not found in current or parent directories");
            return 1;
        }

        auto cfg = parse_config(config_path);

        if (opts.mode_override.has_value()) {
            cfg.build.mode = *opts.mode_override;
        }

        switch (opts.command) {
            case Command::Build:
                return execute_build(cfg, opts);

            case Command::Clean:
                return execute_clean(cfg, opts);

            case Command::Test:
                return execute_test(cfg, opts);

            case Command::Deps:
                return execute_deps(cfg, opts);

            case Command::Index:
                return execute_index(cfg);

            case Command::Install:
                return execute_install(cfg, opts);

            case Command::Line:
                return execute_line(cfg, opts);
        }

        return 0;

    } catch (const std::exception &e) {
        log::error(e.what());
        return 1;
    }
}
