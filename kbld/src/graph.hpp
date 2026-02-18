#pragma once

#include <queue>

#include "types.hpp"

namespace kbld {

inline auto topo_sort(const std::vector<Target> &targets) -> std::vector<std::string> {

    std::unordered_map<std::string, std::vector<std::string>> adj;  // dep -> dependents
    std::unordered_map<std::string, int>                      in_deg;
    std::unordered_set<std::string>                           all_names;

    for (auto &t : targets) {
        all_names.insert(t.name);
        in_deg[t.name];  // ensure entry exists
    }

    for (auto &t : targets) {
        for (auto &dep : t.deps) {
            if (!all_names.contains(dep)) {
                throw std::runtime_error(
                    fmt("Target '{}' depends on unknown target '{}'", t.name, dep));
            }
            adj[dep].push_back(t.name);
            in_deg[t.name]++;
        }
    }

    std::queue<std::string> q;
    for (auto &[name, deg] : in_deg) {
        if (deg == 0)
            q.push(name);
    }

    std::vector<std::string> order;
    order.reserve(targets.size());

    while (!q.empty()) {
        auto cur = q.front();
        q.pop();
        order.push_back(cur);

        if (adj.contains(cur)) {
            for (auto &next : adj[cur]) {
                if (--in_deg[next] == 0) {
                    q.push(next);
                }
            }
        }
    }

    if (order.size() != targets.size()) {
        std::string                     cycle_msg = "Dependency cycle detected: ";
        std::unordered_set<std::string> sorted_set(order.begin(), order.end());
        std::vector<std::string>        unsorted;
        for (auto &t : targets) {
            if (!sorted_set.contains(t.name)) {
                unsorted.push_back(t.name);
            }
        }
        for (std::size_t i = 0; i < unsorted.size(); ++i) {
            cycle_msg += unsorted[i];
            if (i + 1 < unsorted.size())
                cycle_msg += " -> ";
        }
        throw std::runtime_error(cycle_msg);
    }

    return order;
}

inline auto build_waves(const std::vector<Target> &targets, const std::vector<std::string> &order)
    -> std::vector<std::vector<std::string>> {

    std::unordered_map<std::string, const Target *> by_name;
    for (auto &t : targets)
        by_name[t.name] = &t;

    std::unordered_map<std::string, int>  wave_of;  // target -> which wave it's in
    std::vector<std::vector<std::string>> waves;

    for (auto &name : order) {
        int   my_wave = 0;
        auto *t       = by_name[name];
        for (auto &dep : t->deps) {
            my_wave = std::max(my_wave, wave_of[dep] + 1);
        }

        if (my_wave >= static_cast<int>(waves.size())) {
            waves.resize(my_wave + 1);
        }
        waves[my_wave].push_back(name);
        wave_of[name] = my_wave;
    }

    return waves;
}

}  // namespace kbld
