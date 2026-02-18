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
///   SPDX-License-Identifier: CC-BY-4.0                                                         ///
///   Copyright (c) 2024 The Kairo Project (CC BY 4.0)                                           ///
///                                                                                              ///
///-------------------------------------------------------------------------------------- C++ ---///

#ifndef __CXIR_LOC_H__
#define __CXIR_LOC_H__

#include "generator/include/config/Gen_config.def"
#include "neo-pprint/include/hxpprint.hh"
#include "parser/ast/include/AST.hh"

__CXIR_CODEGEN_BEGIN {
    // struct SourceLocation {
    //     size_t line;
    //     size_t column;
    //     size_t length;

    //     bool is_placeholder = false;
    // };

    // class SourceMap {
    //   public:
    //     /// 2D map of line and column to SourceLocation
    //     std::map<size_t, std::map<size_t, SourceLocation>> mappings;

    //     void append(const SourceLocation &kairo_loc, size_t cxir_line, size_t cxir_col) {
    //         mappings[cxir_line][cxir_col] = kairo_loc;
    //     }

    //     void debug_print() {
    //         // print like: [(line, col) -> (line, col)]\n
    //         for (const auto &line : mappings) {
    //             for (const auto &col : line.second) {
    //                 std::cout << "[(" << line.first << ", " << col.first << ") -> ("
    //                           << col.second.line << ", " << col.second.column << ")]\n";
    //             }
    //         }
    //     }

    //     SourceLocation find_loc(size_t line, size_t col) {
    //         // Check if the exact line and column mapping exists
    //         auto line_iter = mappings.find(line);
    //         if (line_iter != mappings.end()) {
    //             auto &line_map = line_iter->second;
    //             auto  col_iter = line_map.find(col);
    //             if (col_iter != line_map.end()) {
    //                 return col_iter->second;  // Exact match
    //             }
    //         }

    //         // Find the nearest line
    //         size_t nearest_line  = SIZE_MAX;
    //         size_t min_line_diff = SIZE_MAX;

    //         for (const auto &[mapped_line, _] : mappings) {
    //             size_t diff = (mapped_line > line) ? (mapped_line - line) : (line - mapped_line);
    //             if (diff < min_line_diff || (diff == min_line_diff && mapped_line > nearest_line)) {
    //                 nearest_line  = mapped_line;
    //                 min_line_diff = diff;
    //             }
    //         }

    //         if (nearest_line == SIZE_MAX) {
    //             return SourceLocation{.line=0, .column=0, .length=0, .is_placeholder=true};  // No lines found
    //         }

    //         // Find the nearest column within the nearest line
    //         const auto &nearest_line_map = mappings[nearest_line];
    //         size_t      nearest_col      = SIZE_MAX;
    //         size_t      min_col_diff     = SIZE_MAX;

    //         for (const auto &[mapped_col, _] : nearest_line_map) {
    //             size_t diff = (mapped_col > col) ? (mapped_col - col) : (col - mapped_col);
    //             if (diff < min_col_diff || (diff == min_col_diff && mapped_col > nearest_col)) {
    //                 nearest_col  = mapped_col;
    //                 min_col_diff = diff;
    //             }
    //         }

    //         if (nearest_col == SIZE_MAX) {
    //             return SourceLocation{0, 0, 0, true};  // No columns found
    //         }

    //         // Return the nearest SourceLocation
    //         return nearest_line_map.at(nearest_col);
    //     }
    // };

    // inline std::unordered_map<std::string, SourceMap>
    //     SOURCE_MAPS;  // NOLINT(cppcoreguidelines-avoid-non-const-global-variables)
}  // namespace __CXIR_CODEGEN_END

#endif  // __CXIR_LOC_H__