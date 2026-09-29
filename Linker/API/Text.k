/// --- The Kairo Project ------------------------- Linker/API/Text.k ------ ///
///
///   \brief String helpers the linker API shares: slicing, searching, path
///          joins, shell and response-file quoting. Pure Kairo.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

class LinkText {
    /// \p s over [b, e), clamped. Empty when the range is.
    static fn slice(s: string, b: usize, e: usize) -> string {
        var end = e;
        if end > s.size() { end = s.size(); }
        if (end <= b) || (b >= s.size()) { return ""; }
        return string(s.raw_string().substr(b, end - b));
    }

    static fn starts_with(s: string, p: string) -> bool {
        if p.size() > s.size() { return false; }
        for var i: usize = 0; i < p.size(); ++i {
            if s[i] != p[i] { return false; }
        }
        return true;
    }

    static fn ends_with(s: string, p: string) -> bool {
        if p.size() > s.size() { return false; }
        var off = s.size() - p.size();
        for var i: usize = 0; i < p.size(); ++i {
            if s[off + i] != p[i] { return false; }
        }
        return true;
    }

    /// First index of \p p in \p s at or after \p from; s.size() if absent.
    static fn find(s: string, p: string, from: usize) -> usize {
        var n = s.size();
        var m = p.size();
        if from >= n { return n; }
        if m == 0 { return from; }
        if m > n { return n; }
        for var i: usize = from; (i + m) <= n; ++i {
            var hit = true;
            for var j: usize = 0; j < m; ++j {
                if s[i + j] != p[j] { hit = false; break; }
            }
            if hit { return i; }
        }
        return n;
    }

    static fn contains(s: string, p: string) -> bool {
        if p.empty() { return true; }
        return LinkText::find(s, p, 0) < s.size();
    }

    static fn trim(s: string) -> string {
        var b: usize = 0;
        var e = s.size();
        while (b < e) && LinkText::_space(s, b) { b += 1; }
        while (e > b) && LinkText::_space(s, e - 1) { e -= 1; }
        return LinkText::slice(s, b, e);
    }

    /// Lines of \p s without their terminators; a trailing CR is dropped.
    static fn split_lines(s: string) -> vec::<string> {
        var out = vec::<string>();
        var b: usize = 0;
        for var i: usize = 0; i < s.size(); ++i {
            if s[i] == '\n' {
                var e = i;
                if (e > b) && (s[e - 1] == '\r') { e -= 1; }
                out.push_back(LinkText::slice(s, b, e));
                b = i + 1;
            }
        }
        if b < s.size() { out.push_back(LinkText::slice(s, b, s.size())); }
        return out;
    }

    /// Path join with '/'. An absolute \p b replaces \p a; "." is \p a.
    static fn join(a: string, b: string) -> string {
        if b.empty() || (b == ".") { return a; }
        if a.empty() || (b[0] == '/') { return b; }
        if a[a.size() - 1] == '/' { return a + b; }
        return a + "/" + b;
    }

    /// Drops trailing slashes, but never turns "/" into "".
    static fn strip_slash(s: string) -> string {
        var e = s.size();
        while (e > 1) && (s[e - 1] == '/') { e -= 1; }
        return LinkText::slice(s, 0, e);
    }

    /// POSIX shell quoting, so --print-ld-args and -v output paste straight
    /// back into a shell.
    static fn quote_shell(a: string) -> string {
        if a.empty() { return "\x27\x27"; }
        var plain = true;
        for var i: usize = 0; i < a.size(); ++i {
            var c = a[i];
            var ok = ((c >= 'a') && (c <= 'z')) || ((c >= 'A') && (c <= 'Z'))
                  || ((c >= '0') && (c <= '9'))
                  || (c == '-') || (c == '_') || (c == '.') || (c == '/')
                  || (c == '=') || (c == ',') || (c == ':') || (c == '+') || (c == '@');
            if !ok { plain = false; break; }
        }
        if plain { return a; }

        var s = "\x27";
        var b: usize = 0;
        for var i: usize = 0; i < a.size(); ++i {
            if a[i] == '\x27' {
                s += LinkText::slice(a, b, i);
                s += "\x27\x5C\x27\x27";
                b = i + 1;
            }
        }
        s += LinkText::slice(a, b, a.size());
        s += "\x27";
        return s;
    }

    /// One argument for a GNU-quoted response file: double quotes, with
    /// backslash and double quote escaped.
    static fn quote_rsp(a: string) -> string {
        var s = "\x22";
        var b: usize = 0;
        for var i: usize = 0; i < a.size(); ++i {
            if (a[i] == '\x22') || (a[i] == '\\') {
                s += LinkText::slice(a, b, i);
                s += "\x5C";
                b = i;
            }
        }
        s += LinkText::slice(a, b, a.size());
        s += "\x22";
        return s;
    }

    priv static fn _space(s: string, i: usize) -> bool {
        var c = s[i];
        return (c == ' ') || (c == '\t') || (c == '\r') || (c == '\n');
    }
}