/* --- The Kairo Project ---------------------------- Analyzer/kals_num.h --- *
 *
 *   Correctly rounded text to double for the JSON reader.
 *
 *   WHY C++: the conversion is strtod, which reads the decimal point from the
 *   process locale (the server calls setlocale(LC_ALL, "") at start), so the
 *   token's '.' is swapped for the locale's point on a private copy; the
 *   library's parser is not importable from the Analyzer on both builtin
 *   libraries.
 *
 *   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
 *   Copyright (c) 2026 Dhruvan Kartik
 *
 * ------------------------------------------------------------------------ */

#pragma once

#include <clocale>
#include <cstddef>
#include <cstdlib>
#include <string>

/* `p[0..n)` must be a valid JSON number token: it is rounded once, to the
 * nearest double; a value past the range gives an infinity, a value below it
 * gives a zero. */
static inline double kals_parse_f64(const unsigned char *p, size_t n) {
    const char *point = ::localeconv()->decimal_point;
    std::string tok;
    tok.reserve(n + 4);
    for (size_t i = 0; i < n; ++i) {
        if (p[i] == '.' && point != nullptr) {
            tok += point;
        } else {
            tok += static_cast<char>(p[i]);
        }
    }

    return ::strtod(tok.c_str(), nullptr);
}
