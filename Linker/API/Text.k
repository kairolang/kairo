/// --- The Kairo Project ----------------------------------- API/Text.k --- ///
///
///   String helpers the linker API shares: slicing, paths and shell quoting.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "vector"

pub class LinkText {
    /// `s` over [b, e), clamped. Empty when the range is.
    pub static fn slice(const s: string, b: usize, e: usize) -> string {
        var end = e
        if end > s.size() {
            end = s.size()
        }

        if end <= b || b >= s.size() {
            return ""
        }

        return s.subslice(b, end - b)
    }

    pub static fn starts_with(s: string, p: string) -> bool {
        if p.size() > s.size() {
            return false
        }

        for var i: usize = 0; i < p.size(); ++i {
            if s.data()[i] != p.data()[i] {
                return false
            }
        }

        return true
    }

    pub static fn ends_with(s: string, p: string) -> bool {
        if p.size() > s.size() {
            return false
        }

        var off = s.size() - p.size()
        for var i: usize = 0; i < p.size(); ++i {
            if s.data()[off + i] != p.data()[i] {
                return false
            }
        }

        return true
    }

    /// First index of `p` in `s` at or after `from`; s.size() if absent.
    pub static fn find(s: string, p: string, from: usize) -> usize {
        var n = s.size()
        var m = p.size()
        if from >= n {
            return n
        }

        if m == 0 {
            return from
        }

        if m > n {
            return n
        }

        for var i: usize = from; i + m <= n; ++i {
            var hit = true
            for var j: usize = 0; j < m; ++j {
                if s.data()[i + j] != p.data()[j] {
                    hit = false
                    break
                }
            }

            if hit {
                return i
            }
        }

        return n
    }

    pub static fn contains(const s: string, const p: string) -> bool {
        if p.is_empty() {
            return true
        }

        return LinkText::find(s.copy(), p.copy(), 0) < s.size()
    }

    pub static fn trim(const s: string) -> string {
        var b: usize = 0
        var e        = s.size()
        while b < e && LinkText::_space(s.copy(), b) {
            b += 1
        }

        while e > b && LinkText::_space(s.copy(), e - 1) {
            e -= 1
        }

        return LinkText::slice(s, b, e)
    }

    /// Lines of `s` without their terminators; a trailing CR is dropped.
    pub static fn split_lines(s: string) -> cxx::std::vector<string> {
        var out       = cxx::std::vector<string>()
        var b:  usize = 0
        for var i: usize = 0; i < s.size(); ++i {
            if s.data()[i] == ('\n' as u8) {
                var e = i
                if e > b && s.data()[e - 1] == ('\r' as u8) {
                    e -= 1
                }

                out.push_back(LinkText::slice(s, b, e))
                b = i + 1
            }
        }

        if b < s.size() {
            out.push_back(LinkText::slice(s, b, s.size()))
        }

        return out
    }

    /// Path join with '/'. An absolute `b` replaces `a`; "." is `a`.
    pub static fn join(a: string, b: string) -> string {
        if b.is_empty() || b == "." {
            return a
        }

        if a.is_empty() || b.data()[0] == ('/' as u8) {
            return b
        }

        if a.data()[a.size() - 1] == ('/' as u8) {
            return a.copy() + b
        }

        return a.copy() + "/" + b
    }

    /// Drops trailing slashes, but never turns "/" into "".
    pub static fn strip_slash(s: string) -> string {
        var e = s.size()
        while e > 1 && s.data()[e - 1] == ('/' as u8) {
            e -= 1
        }

        return LinkText::slice(s, 0, e)
    }

    /// POSIX shell quoting, so --print-ld-args and -v output paste straight
    /// back into a shell.
    static fn quote_shell(a: string) -> string {
        if a.is_empty() {
            return "''"
        }

        var plain = true
        for var i: usize = 0; i < a.size(); ++i {
            var c = a.data()[i]
            var ok = c >= ('a' as u8) && c <= ('z' as u8)
                || c >= ('A' as u8) && c <= ('Z' as u8)
                || c >= ('0' as u8) && c <= ('9' as u8)
                || c == ('-' as u8)
                || c == ('_' as u8)
                || c == ('.' as u8)
                || c == ('/' as u8)
                || c == ('=' as u8)
                || c == (',' as u8)
                || c == (':' as u8)
                || c == ('+' as u8)
                || c == ('@' as u8)
            if !ok {
                plain = false
                break
            }
        }

        if plain {
            return a
        }

        var s        = "'"
        var b: usize = 0
        for var i: usize = 0; i < a.size(); ++i {
            if a.data()[i] == ('\x27' as u8) {
                s += LinkText::slice(a, b, i)
                s += "'\x5C''"
                b = i + 1
            }
        }

        s += LinkText::slice(a, b, a.size())
        s += "'"
        return s
    }

    /// One argument for a GNU-quoted response file: double quotes, with
    /// backslash and double quote escaped.
    static fn quote_rsp(a: string) -> string {
        var s        = "\""
        var b: usize = 0
        for var i: usize = 0; i < a.size(); ++i {
            if a.data()[i] == ('\x22' as u8) || a.data()[i] == ('\\' as u8) {
                s += LinkText::slice(a, b, i)
                s += "\x5C"
                b = i
            }
        }

        s += LinkText::slice(a, b, a.size())
        s += "\""
        return s
    }

    priv static fn _space(s: string, i: usize) -> bool {
        var c = s.data()[i]
        return c == (' ' as u8) || c == ('\t' as u8) || c == ('\r' as u8) || c == ('\n' as u8)
    }
}
