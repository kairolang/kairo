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
#ifndef COLORS_H
#define COLORS_H

#include <array>
#include <string>

#define COLORS_ALLOWED

#ifdef COLORS_ALLOWED
    #define CREATE_COLOR(COLOR, CODE) inline const char *COLOR = CODE;
#else
    #define CREATE_COLOR(COLOR, CODE) inline const char *COLOR = "";
#endif

namespace colors {
CREATE_COLOR(reset, "\u001b[0m");

inline namespace effects {
    CREATE_COLOR(bold, "\u001b[1m");
    CREATE_COLOR(dim, "\u001b[2m");
    CREATE_COLOR(italic, "\u001b[3m");
    CREATE_COLOR(underline, "\u001b[4m");
    CREATE_COLOR(blink, "\u001b[5m");
    CREATE_COLOR(reverse, "\u001b[7m");
    CREATE_COLOR(hidden, "\u001b[8m");
}  // namespace effects

inline namespace fg8 {
    CREATE_COLOR(black, "\u001b[30m");
    CREATE_COLOR(red, "\u001b[31m");
    CREATE_COLOR(green, "\u001b[32m");
    CREATE_COLOR(yellow, "\u001b[33m");
    CREATE_COLOR(blue, "\u001b[34m");
    CREATE_COLOR(magenta, "\u001b[35m");
    CREATE_COLOR(cyan, "\u001b[36m");
    CREATE_COLOR(white, "\u001b[37m");
}  // namespace fg8

inline namespace bg8 {
    CREATE_COLOR(black, "\u001b[40m");
    CREATE_COLOR(red, "\u001b[41m");
    CREATE_COLOR(green, "\u001b[42m");
    CREATE_COLOR(yellow, "\u001b[43m");
    CREATE_COLOR(blue, "\u001b[44m");
    CREATE_COLOR(magenta, "\u001b[45m");
    CREATE_COLOR(cyan, "\u001b[46m");
    CREATE_COLOR(white, "\u001b[47m");
}  // namespace bg8

inline namespace fg16 {
    CREATE_COLOR(red, "\u001b[91m");
    CREATE_COLOR(green, "\u001b[92m");
    CREATE_COLOR(yellow, "\u001b[93m");
    CREATE_COLOR(blue, "\u001b[94m");
    CREATE_COLOR(magenta, "\u001b[95m");
    CREATE_COLOR(cyan, "\u001b[96m");
    CREATE_COLOR(white, "\u001b[97m");
    CREATE_COLOR(black, "\u001b[30m");
    CREATE_COLOR(gray, "\u001b[90m");
}  // namespace fg16

inline namespace bg16 {
    CREATE_COLOR(red, "\u001b[101m");
    CREATE_COLOR(green, "\u001b[102m");
    CREATE_COLOR(yellow, "\u001b[103m");
    CREATE_COLOR(blue, "\u001b[104m");
    CREATE_COLOR(magenta, "\u001b[105m");
    CREATE_COLOR(cyan, "\u001b[106m");
    CREATE_COLOR(white, "\u001b[107m");
    CREATE_COLOR(black, "\u001b[40m");
    CREATE_COLOR(gray, "\u001b[100m");
}  // namespace bg16

inline namespace fg256 {
    CREATE_COLOR(black, "\x1b[38;5;0m");
    CREATE_COLOR(maroon, "\x1b[38;5;1m");
    CREATE_COLOR(green, "\x1b[38;5;2m");
    CREATE_COLOR(olive, "\x1b[38;5;3m");
    CREATE_COLOR(navy, "\x1b[38;5;4m");
    CREATE_COLOR(purple, "\x1b[38;5;5m");
    CREATE_COLOR(teal, "\x1b[38;5;6m");
    CREATE_COLOR(silver, "\x1b[38;5;7m");
    CREATE_COLOR(grey, "\x1b[38;5;8m");
    CREATE_COLOR(red, "\x1b[38;5;9m");
    CREATE_COLOR(lime, "\x1b[38;5;10m");
    CREATE_COLOR(yellow, "\x1b[38;5;11m");
    CREATE_COLOR(blue, "\x1b[38;5;12m");
    CREATE_COLOR(fuchsia, "\x1b[38;5;13m");
    CREATE_COLOR(aqua, "\x1b[38;5;14m");
    CREATE_COLOR(white, "\x1b[38;5;15m");
    CREATE_COLOR(grey0, "\x1b[38;5;16m");
    CREATE_COLOR(grey1, "\x1b[38;5;232m");
    CREATE_COLOR(grey2, "\x1b[38;5;233m");
    CREATE_COLOR(grey3, "\x1b[38;5;234m");
    CREATE_COLOR(grey4, "\x1b[38;5;235m");
    CREATE_COLOR(grey5, "\x1b[38;5;236m");
    inline const char *custom(int red, int green, int blue) {
        const int BASE = 0x10;
        const int COLOR = 0x24;
        std::string code = "\x1b[38;5;";
        code += std::to_string(BASE + COLOR * red + 6 * green + blue);
        code += "m";
        const char *cstr = code.c_str();
        return cstr;
    }
}  // namespace fg256

inline namespace bg256 {
    CREATE_COLOR(black, "\x1b[48;5;0m");
    CREATE_COLOR(maroon, "\x1b[48;5;1m");
    CREATE_COLOR(green, "\x1b[48;5;2m");
    CREATE_COLOR(olive, "\x1b[48;5;3m");
    CREATE_COLOR(navy, "\x1b[48;5;4m");
    CREATE_COLOR(purple, "\x1b[48;5;5m");
    CREATE_COLOR(teal, "\x1b[48;5;6m");
    CREATE_COLOR(silver, "\x1b[48;5;7m");
    CREATE_COLOR(grey, "\x1b[48;5;8m");
    CREATE_COLOR(red, "\x1b[48;5;9m");
    CREATE_COLOR(lime, "\x1b[48;5;10m");
    CREATE_COLOR(yellow, "\x1b[48;5;11m");
    CREATE_COLOR(blue, "\x1b[48;5;12m");
    CREATE_COLOR(fuchsia, "\x1b[48;5;13m");
    CREATE_COLOR(aqua, "\x1b[48;5;14m");
    CREATE_COLOR(white, "\x1b[48;5;15m");
    CREATE_COLOR(grey0, "\x1b[48;5;16m");
    CREATE_COLOR(grey1, "\x1b[48;5;232m");
    CREATE_COLOR(grey2, "\x1b[48;5;233m");
    CREATE_COLOR(grey3, "\x1b[48;5;234m");
    CREATE_COLOR(grey4, "\x1b[48;5;235m");
    CREATE_COLOR(grey5, "\x1b[48;5;236m");
    inline const char *custom(int red, int green, int blue) {
        const int BASE = 0x10;
        const int COLOR = 0x24;
        std::string code = "\x1b[48;5;";
        code += std::to_string(BASE + COLOR * red + 6 * green + blue);
        code += "m";
        const char *cstr = code.c_str();
        return cstr;
    }
}  // namespace bg256
}  // namespace colors

#endif  // COLORS_H