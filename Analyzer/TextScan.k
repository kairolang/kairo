/// --- The Kairo Project -------------------------- Analyzer/TextScan.k --- ///
///
///   What the server can answer from a buffer's text alone.
///
///   Folding, selection ranges and "which call is the cursor in" are about
///   brackets, not about meaning. Answering them from the text has two
///   properties the snapshot cannot offer: they are exact for the buffer as
///   it is THIS keystroke, and they work on a buffer that does not parse.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///


/// A matched bracket pair, or a run of comment lines (`kind` 3).
pub struct Span {
    var open:  usize = 0 ///< offset of the opener (or the run's first byte)
    var close: usize = 0 ///< offset of the closer (or one past the run)
    var kind:  u8    = 0 ///< 0 `{}`, 1 `()`, 2 `[]`, 3 comment run
}

/// Byte classes of \p text: 0 code, 1 comment, 2 string or char literal.
/// One pass, so every scanner below skips the same things the same way.
pub fn classify(const text: string) -> [u8] {
    var cls: [u8]
    cls.resize(text.size())
    var i: usize = 0
    var n        = text.size()
    while i < n {
        var c = text[i]
        if (c == ('/' as u8)) && ((i + 1) < n) && (text[i + 1] == ('/' as u8)) {
            while (i < n) && (text[i] != ('\n' as u8)) {
                cls[i] = 1
                i += 1
            }

            continue
        }

        if (c == ('/' as u8)) && ((i + 1) < n) && (text[i + 1] == ('*' as u8)) {
            cls[i]     = 1
            cls[i + 1] = 1
            i += 2
            while i < n {
                cls[i] = 1
                if (text[i] == ('/' as u8)) && (text[i - 1] == ('*' as u8)) {
                    i += 1
                    break
                }

                i += 1
            }

            continue
        }

        if (c == ('"' as u8)) || (c == ('\'' as u8)) {
            // A quote opens a literal that ends at the same quote, a
            // backslash escaping whatever follows. A `'` that is a lifetime
            // or a digit separator does not open one: it is followed by no
            // closing quote on the line, and the scan then stops at the
            // newline instead of swallowing the file.
            var q      = c
            var j      = i + 1
            var closed = false
            while (j < n) && (text[j] != ('\n' as u8) || q == ('"' as u8)) {
                if text[j] == ('\\' as u8) {
                    j += 2
                    continue
                }

                if text[j] == q {
                    closed = true
                    break
                }

                // A plain "..." string does not span lines either; a
                // triple-quoted one does, and is handled by its own quotes.
                if (text[j] == ('\n' as u8))
                    && (!((i + 2) < n
                        && text[i + 1] == ('"' as u8)
                        && text[i + 2] == ('"' as u8))) {
                    break
                }

                j += 1
            }

            if closed {
                for var k: usize = i; (k <= j) && (k < n); ++k {
                    cls[k] = 2
                }

                i = j + 1
                continue
            }
        }

        i += 1
    }

    return cls
}

/// Every matched bracket pair and comment run of \p text, in order of opener.
pub fn spans(const text: string) -> [Span] {
    var out:   [Span]
    var cls            = classify(text)
    var stack: [usize]                  // indices into `out` of unclosed pairs
    var n              = text.size()

    var i: usize = 0
    while i < n {
        if cls[i] == 1 {
            // A run of comment bytes, extended across lines that hold only
            // more comment: a `///` block folds as one.
            var s = i
            var e = i
            while i < n {
                while (i < n) && (cls[i] == 1) {
                    i += 1
                }

                e = i
                var j = i
                while (j < n)
                    && ((text[j] == (' ' as u8))
                        || (text[j] == ('\t' as u8))
                        || (text[j] == ('\n' as u8))
                        || (text[j] == ('\r' as u8))) {
                    j += 1
                }

                // Only a single line break may separate the lines of a run.
                var breaks: usize = 0
                for var k: usize = i; k < j; ++k {
                    if text[k] == ('\n' as u8) {
                        breaks += 1
                    }
                }

                if (j < n) && (cls[j] == 1) && (breaks == 1) {
                    i = j
                    continue
                }

                break
            }

            var sp = Span{}
            sp.open  = s
            sp.close = e
            sp.kind  = 3
            out.push_back(sp)
            continue
        }

        if cls[i] == 0 {
            var c = text[i]
            if (c == ('{' as u8)) || (c == ('(' as u8)) || (c == ('[' as u8)) {
                var sp = Span{}
                sp.open  = i
                sp.close = usize::MAX
                sp.kind = if c == ('{' as u8) => (0 as u8)
                          else => (if c == ('(' as u8) => (1 as u8) else => (2 as u8))
                out.push_back(sp)
                stack.push_back(out.size() - 1)
            } else if (c == ('}' as u8)) || (c == (')' as u8)) || (c == (']' as u8)) {
                var want: u8 = if c == ('}' as u8) => (0 as u8)
                               else => (if c == (')' as u8) => (1 as u8) else => (2 as u8))
                // Close the nearest opener of this kind; anything opened
                // after it was never closed and is dropped, which keeps one
                // missing bracket from unbalancing the rest of the file.
                var k = stack.size()
                while k > 0 {
                    k -= 1
                    if out[stack[k]].kind == want {
                        out[stack[k]].close = i
                        while stack.size() > k {
                            stack.pop_back()
                        }

                        break
                    }
                }
            }
        }

        i += 1
    }

    return out
}

/// The call the cursor at \p at is inside: the offset of its `(`, and how
/// many top-level commas precede the cursor. `open` is usize::MAX when the
/// cursor is not inside a call's parentheses.
pub struct CallSite {
    var open:   usize = usize::MAX
    var commas: usize = 0
}

pub fn call_at(const text: string, at: usize) -> CallSite {
    var site         = CallSite{}
    var cls          = classify(text)
    var depth: usize = 0
    var i            = at
    var steps: usize = 0
    while (i > 0) && (steps < 8192) {
        i -= 1
        steps += 1
        if cls[i] != 0 {
            continue
        }

        var c = text[i]
        if (c == (')' as u8)) || (c == (']' as u8)) || (c == ('}' as u8)) {
            depth += 1
        } else if c == ('(' as u8) {
            if depth == 0 {
                site.open = i
                return site
            }

            depth -= 1
        } else if (c == ('[' as u8)) || (c == ('{' as u8)) {
            if depth == 0 {
                return site // inside an index or a block, not an argument list
            }

            depth -= 1
        } else if (c == (',' as u8)) && (depth == 0) {
            site.commas += 1
        } else if (c == (';' as u8)) && (depth == 0) {
            return site
        }
    }

    return site
}


/// "Generate interface for 'Name'": what to insert, found from the text
/// alone, so it is offered on a buffer whose last run is stale too. Offsets
/// are into the text the plan was made from.
pub struct InterfacePlan {
    pub var ok:        bool   = false
    pub var name:      string = ""    ///< the class or struct
    pub var insert_at: usize  = 0     ///< start of the line the interface goes above
    pub var text:      string = ""    ///< the interface, ending in a blank line
    pub var impl_at:   usize  = 0     ///< where the `impl` clause goes in the header
    pub var impl_text: string = ""
    pub var methods:   usize  = 0
}

/// A byte of a name: ASCII letters, digits, `_`, and every byte of a
/// non-ASCII character (Server::TextUtil's rule, which the completion
/// site reads with).
pub fn is_ident_byte(c: u8) -> bool {
    return ((c >= ('a' as u8)) && (c <= ('z' as u8)))
        || ((c >= ('A' as u8)) && (c <= ('Z' as u8)))
        || ((c >= ('0' as u8)) && (c <= ('9' as u8)))
        || (c == ('_' as u8))
        || (c >= 128)
}

fn is_blank_byte(c: u8) -> bool {
    return (c == (' ' as u8)) || (c == ('\t' as u8)) || (c == ('\r' as u8))
}

/// The word of code bytes starting at \p p, or "".
fn word_at(const text: string, const cls: [u8], p: usize) -> string {
    var e = p
    while (e < text.size()) && (cls[e] == 0) && is_ident_byte(text[e]) {
        e += 1
    }

    return text.subslice(p, e - p)
}

/// Whitespace runs that hold a line break become one space: a signature
/// written over several lines is one line in the interface.
fn one_line(const s: string) -> string {
    var out: string = ""
    var i:   usize  = 0
    while i < s.size() {
        var c = s[i]
        if (c == ('\n' as u8)) || is_blank_byte(c) {
            var nl = false
            var j  = i
            while (j < s.size()) && ((s[j] == ('\n' as u8)) || is_blank_byte(s[j])) {
                if s[j] == ('\n' as u8) {
                    nl = true
                }

                j += 1
            }

            if nl {
                out += " "
            } else {
                out += s.subslice(i, j - i)
            }

            i = j
            continue
        }

        out.push_back(c)
        i += 1
    }

    var e = out.size()
    while (e > 0) && (out[e - 1] == (' ' as u8)) {
        e -= 1
    }

    return out.subslice(0, e)
}

/// The plan for the class or struct whose declared name holds \p at, with
/// the interface called \p iname ("" for `I<Name>`). `ok` is false when
/// \p at is not on such a name, or the type has no public instance method
/// (an interface must have a requirement).
///
/// Taken from the class body: every `pub` method that is not `static`, a
/// constructor (`fn Name`) or the destructor (`fn op finally`), its
/// signature as written up to the body, with the `///` lines above it. A
/// method declared with a bare `panic` is left out with a comment: an
/// interface requirement must name its set (interfaces-requirements).
/// Extension methods live outside the body, so they are never taken.
pub fn interface_for(const text: string, at: usize, const iname_in: string) -> InterfacePlan {
    var plan = InterfacePlan{}
    var cls  = classify(text)
    var n    = text.size()
    if (at > n) || (n == 0) {
        return plan
    }

    var a = at
    while (a > 0) && (cls[a - 1] == 0) && is_ident_byte(text[a - 1]) {
        a -= 1
    }

    var b = at
    while (b < n) && (cls[b] == 0) && is_ident_byte(text[b]) {
        b += 1
    }

    if a == b {
        return plan
    }

    var name = text.subslice(a, b - a)

    // Back over `<...>` generic parameters to the keyword.
    var p = a
    while (p > 0) && is_blank_byte(text[p - 1]) {
        p -= 1
    }

    var generics: string = ""
    if (p > 0) && (text[p - 1] == ('>' as u8)) {
        var depth: usize = 0
        var q            = p
        var found        = false
        while q > 0 {
            q -= 1
            if text[q] == ('>' as u8) {
                depth += 1
            } else if text[q] == ('<' as u8) {
                depth -= 1
                if depth == 0 {
                    found = true
                    break
                }
            } else if (text[q] == ('\n' as u8))
                || (text[q] == ('{' as u8))
                || (text[q] == ('}' as u8)) {
                break
            }
        }

        if !found {
            return plan
        }

        generics = text.subslice(q, p - q)
        p        = q
        while (p > 0) && is_blank_byte(text[p - 1]) {
            p -= 1
        }
    }

    var kw_end = p
    while (p > 0) && is_ident_byte(text[p - 1]) {
        p -= 1
    }

    var kw = text.subslice(p, kw_end - p)
    if (kw != "class") && (kw != "struct") {
        return plan
    }

    var kw_at = p

    // The body: the first `{` after the name, and its match.
    var open = b
    while (open < n) && (!((cls[open] == 0) && (text[open] == ('{' as u8)))) {
        open += 1
    }

    if open >= n {
        return plan
    }

    var close       = open + 1
    var bd:   usize = 1
    while close < n {
        if cls[close] == 0 {
            if text[close] == ('{' as u8) {
                bd += 1
            } else if text[close] == ('}' as u8) {
                bd -= 1
                if bd == 0 {
                    break
                }
            }
        }

        close += 1
    }

    if close >= n {
        return plan
    }

    var iname = iname_in
    if iname.empty() {
        iname = "I" + name
    }

    // The interface's type arguments in the `impl` clause: each generic
    // parameter's own name, without its bounds.
    var args: string = ""
    if !generics.empty() {
        args = "<"
        var i:    usize = 1
        var first       = true
        while i < (generics.size() - 1) {
            while (i < generics.size()) && (!is_ident_byte(generics[i])) {
                i += 1
            }

            var s = i
            while (i < generics.size()) && is_ident_byte(generics[i]) {
                i += 1
            }

            if i > s {
                if !first {
                    args += ", "
                }

                args += generics.subslice(s, i - s)
                first = false
            }

            // Skip the bound to the next top-level comma.
            var depth: usize = 0
            while i < (generics.size() - 1) {
                var c = generics[i]
                if c == ('<' as u8) {
                    depth += 1
                } else if (c == ('>' as u8)) && (depth > 0) {
                    depth -= 1
                } else if (c == (',' as u8)) && (depth == 0) {
                    i += 1
                    break
                }

                i += 1
            }
        }

        args += ">"
    }

    // The header's end, where ` impl IName` (or `, IName` after an
    // existing clause) goes.
    var he = open
    while (he > b) && (is_blank_byte(text[he - 1]) || (text[he - 1] == ('\n' as u8))) {
        he -= 1
    }

    var has_impl = false
    for var i: usize = b; i < he; ++i {
        if (cls[i] == 0)
            && ((i == 0) || (!is_ident_byte(text[i - 1])))
            && (word_at(text, cls, i) == "impl") {
            has_impl = true
        }
    }

    plan.impl_at = he
    if has_impl {
        plan.impl_text = ", " + iname + args
    } else {
        plan.impl_text = " impl " + iname + args
    }

    // The line the interface goes above: the class line, or the top of the
    // `///` and attribute lines over it, so its documentation stays its own.
    var ls = kw_at
    while (ls > 0) && (text[ls - 1] != ('\n' as u8)) {
        ls -= 1
    }

    var indent: string = ""
    var ip             = ls
    while (ip < kw_at) && is_blank_byte(text[ip]) {
        indent.push_back(text[ip])
        ip += 1
    }

    while ls > 0 {
        var prev = ls - 1
        while (prev > 0) && (text[prev - 1] != ('\n' as u8)) {
            prev -= 1
        }

        var fp = prev
        while (fp < ls) && is_blank_byte(text[fp]) {
            fp += 1
        }

        var doc = ((fp + 2) < ls)
            && (text[fp] == ('/' as u8))
            && (text[fp + 1] == ('/' as u8))
            && (text[fp + 2] == ('/' as u8))
        var attr = (fp < ls) && (text[fp] == ('@' as u8))
        if (!doc) && (!attr) {
            break
        }

        ls = prev
    }

    plan.insert_at = ls

    // The members, one line at a time at the body's own depth.
    var lines:        [string]
    var docs:         [string]
    var depth:        usize    = 0
    var i                      = open + 1
    var at_line_start          = false
    while i < close {
        var c = text[i]
        if at_line_start && (depth == 0) {
            var q = i
            while (q < close) && is_blank_byte(text[q]) {
                q += 1
            }

            var le = q
            while (le < close) && (text[le] != ('\n' as u8)) {
                le += 1
            }

            if (q < le) && (cls[q] == 1) {
                if ((q + 2) < le) && (text[q + 2] == ('/' as u8)) && (text[q + 1] == ('/' as u8)) {
                    var e = le
                    while (e > q) && is_blank_byte(text[e - 1]) {
                        e -= 1
                    }

                    docs.push_back(text.subslice(q, e - q))
                } else {
                    docs.clear()
                }
            } else if (q < le) && (cls[q] == 0) {
                // Modifiers up to `fn`.
                var w         = q
                var is_pub    = false
                var is_static = false
                var fn_at     = usize::MAX
                var attr_only = text[q] == ('@' as u8)
                while w < le {
                    while (w < le) && is_blank_byte(text[w]) {
                        w += 1
                    }

                    if (w < le) && (text[w] == ('@' as u8)) {
                        w += 1
                        while (w < le) && is_ident_byte(text[w]) {
                            w += 1
                        }

                        continue
                    }

                    var word = word_at(text, cls, w)
                    if word.empty() {
                        break
                    }

                    attr_only = false
                    if word == "fn" {
                        fn_at = w
                        break
                    }

                    if word == "pub" {
                        is_pub = true
                    } else if word == "static" {
                        is_static = true
                    }

                    w += word.size()
                }

                if attr_only {
                    i = q // an attribute line: the docs above still belong to what follows
                } else {
                    if (fn_at != usize::MAX) && is_pub && (!is_static) {
                        // The signature: up to the body's `{` or `= default`.
                        var e         = fn_at
                        var pd: usize = 0
                        while e < close {
                            if cls[e] == 0 {
                                var ch = text[e]
                                if (ch == ('(' as u8)) || (ch == ('[' as u8)) {
                                    pd += 1
                                } else if ((ch == (')' as u8)) || (ch == (']' as u8))) && (pd > 0) {
                                    pd -= 1
                                } else if (pd == 0) && (ch == ('{' as u8)) {
                                    break
                                } else if (pd == 0)
                                    && (ch == ('=' as u8))
                                    && ((e + 1) < close)
                                    && (text[e + 1] != ('=' as u8))
                                    && (text[e - 1] != ('=' as u8))
                                    && (text[e - 1] != ('!' as u8))
                                    && (text[e - 1] != ('<' as u8))
                                    && (text[e - 1] != ('>' as u8)) {
                                    break
                                }
                            }

                            e += 1
                        }

                        var sig = one_line(text.subslice(fn_at, e - fn_at))

                        // The method's name: after `fn` and its generics.
                        var np = fn_at + 2
                        while (np < e) && is_blank_byte(text[np]) {
                            np += 1
                        }

                        if (np < e) && (text[np] == ('<' as u8)) {
                            var gd: usize = 0
                            while np < e {
                                if text[np] == ('<' as u8) {
                                    gd += 1
                                } else if text[np] == ('>' as u8) {
                                    gd -= 1
                                    if gd == 0 {
                                        np += 1
                                        break
                                    }
                                }

                                np += 1
                            }

                            while (np < e) && is_blank_byte(text[np]) {
                                np += 1
                            }
                        }

                        var mname = word_at(text, cls, np)
                        var skip  = mname == name
                        if mname == "op" {
                            var opp = np + 2
                            while (opp < e) && is_blank_byte(text[opp]) {
                                opp += 1
                            }

                            if word_at(text, cls, opp) == "finally" {
                                skip = true
                            }
                        }

                        // A bare `panic`: the set is inferred from a body an
                        // interface does not have.
                        var bare_panic       = false
                        var sp:        usize = 0
                        while (sp + 5) <= sig.size() {
                            if (sig.subslice(sp, 5) == "panic")
                                && ((sp == 0) || (!is_ident_byte(sig[sp - 1])))
                                && (((sp + 5) == sig.size()) || (!is_ident_byte(sig[sp + 5]))) {
                                var t = sp + 5
                                while (t < sig.size()) && (sig[t] == (' ' as u8)) {
                                    t += 1
                                }

                                if (t >= sig.size()) || (sig[t] != ('(' as u8)) {
                                    bare_panic = true
                                }
                            }

                            sp += 1
                        }

                        if (!skip) && bare_panic {
                            lines.push_back(
                                "// " + mname + ": declared with a bare `panic`; a requirement needs its set, `panic(E)`",
                            )
                        } else if !skip {
                            for var k: usize = 0; k < docs.size(); ++k {
                                lines.push_back(docs[k])
                            }

                            lines.push_back(sig)
                            plan.methods += 1
                        }
                    }

                    docs.clear()
                }
            } else if q >= le {
                docs.clear()
            }

            at_line_start = false
            if i < q {
                i = q
                continue
            }
        }

        if cls[i] == 0 {
            if c == ('{' as u8) {
                depth += 1
            } else if (c == ('}' as u8)) && (depth > 0) {
                depth -= 1
            }
        }

        if c == ('\n' as u8) {
            at_line_start = true
        }

        i += 1
    }

    if plan.methods == 0 {
        return plan
    }

    var out = indent + "pub interface "
    if !generics.empty() {
        out += generics
        out += " "
    }

    out += iname
    out += " {\n"
    for var k: usize = 0; k < lines.size(); ++k {
        out += indent
        out += "    "
        out += lines[k]
        out += "\n"
    }

    out += indent
    out += "}\n\n"

    plan.ok   = true
    plan.name = name
    plan.text = out
    return plan
}
