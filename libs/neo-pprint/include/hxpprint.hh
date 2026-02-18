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
#ifndef __PRINT_V2_HH__
#define __PRINT_V2_HH__

#include <iostream>
#include <sstream>
#include <algorithm>

namespace sysIO {
inline size_t __currentLine = 2;

struct endl {
    std::string end_l = "\n";
    endl()            = default;
    explicit endl(std::string end)
        : end_l(std::move(end)) {}
    friend std::ostream &operator<<(std::ostream &oss, const endl &end) {
        oss << end.end_l;
        return oss;
    }
};
}  // namespace sysIO

template <typename T>
inline std::string to_string(const T &obj) {
    std::ostringstream oss;
    if constexpr (requires { std::cout << obj; }) {
        oss << obj;
    } else if constexpr (requires { obj.to_string(); }) {
        return obj.to_string();
    } else if constexpr (requires { std::to_string(obj); }) {
        return std::to_string(obj);
    } else {
        return static_cast<std::string>(obj);
    }
    return oss.str();
}

template <typename... Args>
inline constexpr void print_pinned(Args &&...args) {
    // std::cout << "\033[?25l";  // Hide cursor
    // std::cout << "\033[0;0H";  // Move to top-left corner
    // std::cout << "\033[2K";    // Clear the line

    std::string str = (to_string(args) + ...);
    std::cout << str << "\n" << std::flush;

    // std::cout << "\033[?25h";                               // Show cursor
    // std::cout << "\033[" << sysIO::__currentLine << ";0H";  // Move to the current line
}

template <typename... Args>
inline constexpr void print(Args &&...args) {
    // std::cout << "\033[" << sysIO::__currentLine << ";0H";  // Move to the current line
    // std::cout << "\033[2K";                                 // Clear the line

    std::string str = (to_string(args) + ...);  // Concatenate all arguments
    std::cout << str << std::flush;

    // Count lines in the printed message
    int newLines = std::count(str.begin(), str.end(), '\n') + 1;
    sysIO::__currentLine += newLines;

    // Ensure line increments for implicit newline
    if (!str.empty() && str.back() != '\n') {
        std::cout << "\n" << std::flush;
    }
}

template <typename... Args>
inline constexpr void print_err(Args &&...args) {
    // std::cerr << "\033[" << sysIO::__currentLine << ";0H";  // Move to the current line
    // std::cerr << "\033[2K";                                 // Clear the line

    std::string str = (to_string(args) + ...);  // Concatenate all arguments
    std::cerr << str << std::flush;

    // Count lines in the printed message
    int newLines = std::count(str.begin(), str.end(), '\n') + 1;
    sysIO::__currentLine += newLines;

    // Ensure line increments for implicit newline
    if (!str.empty() && str.back() != '\n') {
        std::cerr << "\n" << std::flush;
    }
}

#endif  // __PRINT_V2_HH__