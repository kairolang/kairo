// -*- C++ -*-
//===------------------------------------------------------------------------------------------===//
//
// Part of the Kairo Project, under the Attribution 4.0 International license (CC BY 4.0).
// You are allowed to use, modify, redistribute, and create derivative works, even for commercial
// purposes, provided that you give appropriate credit, and indicate if changes were made.
// For more information, please visit: https://creativecommons.org/licenses/by/4.0/
//
// SPDX-License-Identifier: CC-BY-4.0
// Copyright (c) 2024 (CC BY 4.0)
//
//===------------------------------------------------------------------------------------------===//

#ifndef __ADVANCED_COMPTIME_MAP_H__
#define __ADVANCED_COMPTIME_MAP_H__

#include <algorithm>
#include <array>
#include <functional>
#include <optional>
#include <utility>

namespace kairo {
template <typename Kt, typename Vt, int N>
struct CompTimeMap {
    using value_type = std::pair<Kt, Vt>;
    using array_type = std::array<value_type, N>;
    using hash_type  = std::array<std::pair<std::size_t, std::size_t>, N>;

    array_type data;
    hash_type  key_hash_map;
    hash_type  value_hash_map;

    constexpr CompTimeMap(array_type init_data)
        : data(init_data) {
        // Sort the array by the hash values of the key
        std::sort(data.begin(), data.end(), [](const auto &first, const auto &second) {
            return std::hash<Kt>{}(first.first) < std::hash<Kt>{}(second.first);
        });

        // Fill the hash maps
        for (std::size_t i = 0; i < N; ++i) {
            key_hash_map[i]   = {std::hash<Kt>{}(data[i].first), i};
            value_hash_map[i] = {std::hash<Vt>{}(data[i].second), i};
        }

        // Sort the hash maps for efficient lookup
        std::sort(key_hash_map.begin(), key_hash_map.end());
        std::sort(value_hash_map.begin(), value_hash_map.end());
    }

    [[nodiscard]] constexpr std::optional<Kt> at(Vt val) const noexcept {
        auto val_hash = std::hash<Vt>{}(val);
        auto iterator = std::lower_bound(
            value_hash_map.begin(),
            value_hash_map.end(),
            std::make_pair(val_hash, 0UL),
            [](const auto &first, const auto &second) { return first.first < second.first; });

        if (iterator != value_hash_map.end() && iterator->first == val_hash) {
            return data[iterator->second].first;
        }
        return std::nullopt;
    }

    [[nodiscard]] constexpr std::optional<Vt> at(Kt key) const noexcept {
        auto key_hash = std::hash<Kt>{}(key);
        auto iterator = std::lower_bound(
            key_hash_map.begin(),
            key_hash_map.end(),
            std::make_pair(key_hash, 0UL),
            [](const auto &first, const auto &second) { return first.first < second.first; });

        if (iterator != key_hash_map.end() && iterator->first == key_hash) {
            return data[iterator->second].second;
        }
        return std::nullopt;
    }

    [[nodiscard]] constexpr auto size() const noexcept { return data.size(); }

    [[nodiscard]] constexpr auto begin() const noexcept { return data.begin(); }

    [[nodiscard]] constexpr auto end() const noexcept { return data.end(); }
};

#define MP std::make_pair
}  // end namespace kairo

#endif  // __ADVANCED_COMPTIME_MAP_H__