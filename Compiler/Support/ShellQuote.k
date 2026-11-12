/// --- The Kairo Project ------------------------- Support/ShellQuote.k --- ///
///
///   shell_quote: a string as one POSIX shell word, for printed commands.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

/// \p s as one shell word: unchanged when no shell would split or expand
/// it, otherwise in single quotes, each quote inside spelled '\''.
pub fn shell_quote(s: string) -> string {
    if s.empty() {
        return "''"
    }

    var r     = s
    var plain = true
    for var i: usize = 0; i < r.size(); ++i {
        var c = r[i]
        var ok = c >= ('a' as u8) && c <= ('z' as u8)
            || c >= ('A' as u8) && c <= ('Z' as u8)
            || c >= ('0' as u8) && c <= ('9' as u8)
            || c == ('-' as u8)
            || c == ('_' as u8)
            || c == ('=' as u8)
            || c == ('/' as u8)
            || c == ('.' as u8)
            || c == (',' as u8)
            || c == (':' as u8)
            || c == ('+' as u8)
            || c == ('@' as u8)
            || c == ('%' as u8)
        if !ok {
            plain = false
            break
        }
    }

    if plain {
        return s
    }

    var out: string = "'"
    for var i: usize = 0; i < r.size(); ++i {
        if r[i] == ('\'' as u8) {
            out = out + "'\\''"
            continue
        }

        var one: string = r.subslice(i, 1)
        out = out + one
    }

    return out + "'"
}
