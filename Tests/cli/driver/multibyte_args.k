// Multibyte UTF-8 in command-line words and in the source a diagnostic
// quotes is read and printed whole: a joined flag value is split off only
// at a character boundary, flag values and unknown flags keep their
// characters, --print-from-clang shell-quotes words that hold them,
// and the pretty renderer's source line, caret and label line up on a line
// with multibyte characters before the error.

fn größe(n: i32) -> i32 {
    var s = "naïve ☃ text"
    return n + undefined_ñame
}

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo_bin --print-from-clang -- -DNAME=é '-Ipath with é' -Wé -mllvm -ké 'süß.cc' -o 'aus gabe é.o' | %FileCheck %s --check-prefix=FROM
// FROM: kairo: '--cxx-define=NAME=é' -I 'path with é' '--mllvm=-ké' 'süß.cc' -o 'aus gabe é.o'
// FROM-NEXT: clang-only: '-Wé'

// RUN: { %kairo -DNAMEé %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=JOINED
// JOINED: multibyte_args.k:10:16: error [R020E]: use of undeclared identifier 'undefined_ñame'

// RUN: { %kairo -é %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=SHORT
// SHORT: error [U002E]: unknown flag '-é'; run '--help' to see available options

// RUN: { %kairo -Oé %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=VALUE
// VALUE: error [U003E]: invalid value 'é' for flag '-O' / '--opt'

// RUN: { %kairo -xé %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=LANG
// LANG: language not recognized: 'é'

// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=BASIC
// BASIC: multibyte_args.k:10:16: error [R020E]: use of undeclared identifier 'undefined_ñame'

// RUN: { %kairo --error-format=pretty --no-color --type-check-only %s 2>&1 || true; } | %FileCheck %s --check-prefix=PRETTY --strict-whitespace
// PRETTY:      {{^}}    8 | fn größe(n: i32) -> i32 {
// PRETTY-NEXT: {{^}}    9 |     var s = "naïve ☃ text"
// PRETTY-NEXT: {{^}}   10 |     return n + undefined_ñame
// PRETTY-NEXT: {{^}}      |                ^^^^^^^^^^^^^^
// PRETTY-NEXT: {{^}}      |                [R020E] use of undeclared identifier 'undefined_ñame'
