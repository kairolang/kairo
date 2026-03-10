///--- The Kairo Project ------------------------------------------------------------------------///
///                                                                                              ///
///   Part of the Kairo Project, under the Attribution 4.0 International license (CC BY 4.0).    ///
///   You are allowed to use, modify, redistribute, and create derivative works, even for        ///
///   commercial purposes, provided that you give appropriate credit, and indicate if changes    ///
///   were made.                                                                                 ///
///                                                                                              ///
///   For more information on the license terms and requirements, please visit:                  ///
///     https://creativecommons.org/licenses/by/4.0/                                             ///
///                                                                                              ///
///   SPDX-License-Identifier: Apache-2.0                                                        ///
///   Copyright (c) 2024 The Kairo Project (CC BY 4.0)                                           ///
///                                                                                              ///
///-------------------------------------------------------------------------------------- C++ ---///

#ifndef __MAPPING_HH__
#define __MAPPING_HH__

#include <algorithm>
#include <array>
#include <optional>
#include <string>
#include <string_view>
#include <utility>

using std::string;

namespace token {
template <typename Enum, int N>
struct Mapping {
    std::array<std::pair<Enum, std::string_view>, N> data;

    constexpr explicit Mapping(std::array<std::pair<Enum, std::string_view>, N> init_data)
        : data(init_data) {
        // Sort the array by the string_view for binary search
        std::sort(data.begin(), data.end(), [](const auto &first, const auto &second) {
            return first.second < second.second;
        });
    }

    [[nodiscard]] constexpr std::optional<Enum> at(std::string_view str) const noexcept {
        auto iterator =
            std::lower_bound(data.begin(), data.end(), str, [](const auto &pair, const auto &val) {
                return pair.second < val;
            });
        if (iterator != data.end() && iterator->second == str) {
            return iterator->first;
        }
        return std::nullopt;
    }

    [[nodiscard]] constexpr std::optional<std::string_view> at(Enum token_type) const noexcept {
        auto iterator = std::find_if(
            data.begin(), data.end(), [&](const auto &pair) { return pair.first == token_type; });
        if (iterator != data.end()) {
            return iterator->second;
        }
        return std::nullopt;
    }

    [[nodiscard]] constexpr auto size() const noexcept { return data.size(); }
    [[nodiscard]] constexpr auto begin() const noexcept { return data.begin(); }
    [[nodiscard]] constexpr auto end() const noexcept { return data.end(); }
};
}  // namespace token

#endif  // __MAPPING_HH__