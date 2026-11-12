/// --- The Kairo Project -------------------- Analyzer/CompletionSite.k --- ///
///
///   Where a completion is asked: read off the buffer's text alone, which
///   as a rule does not parse while it is being typed. Outside Server/ (and
///   its import cycle) because the index walker's marker path reads the
///   same blocks to decide which locals are in scope.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///


ffi "c++" import "Native/Types.hh"

import TextScan::is_ident_byte

// Everything here reads bytes and the classes TextScan::classify gives them
// (0 code, 1 comment, 2 string): no token stream, no tree. The syntax pass's
// tokens arrive some milliseconds after the keystroke a completion follows,
// and a tree of a half-typed line is what the parser's recovery made of it.

// --- what is being completed -------------------------------------------------
pub const SITE_NONE:   u8 = 0  ///< nothing to offer: a comment, a string, a number, a name being declared
pub const SITE_NAME:   u8 = 1  ///< a bare name: locals, the file, imports, keywords, macros
pub const SITE_MEMBER: u8 = 2  ///< after `.`, `->` or `::`
pub const SITE_ATTR:   u8 = 3  ///< after `@`
pub const SITE_HEADER: u8 = 4  ///< inside the string of `ffi "c++" import "..."`

// --- where a bare name stands: which keywords can start there ---------------
pub const KC_STMT:  u32 = 1   ///< first on its line in a body: a statement can start
pub const KC_EXPR:  u32 = 2   ///< an expression
pub const KC_TYPE:  u32 = 4   ///< a type is written here
pub const KC_DECL:  u32 = 8   ///< file level or a type's body: a declaration starts
pub const KC_PARAM: u32 = 16  ///< a parameter list, before the `:`
pub const KC_ALL:   u32 = 31

pub struct Site {
    var what:     u8    = SITE_NONE
    var start:    usize = 0   ///< the identifier under the cursor, both halves
    var end:      usize = 0
    var recv_end: usize = 0   ///< SITE_MEMBER: one past the receiver (where the operator starts)
    var kc:       u32   = KC_ALL
    /// SITE_HEADER: where the path typed so far starts (after the quote).
    var path_at:  usize = 0
    /// SITE_HEADER: the language string of the import (`c`, `c++`).
    var lang: string = ""
    /// SITE_ATTR: the word that starts what follows the attribute (`fn`,
    /// `class`, ...), "" when it is not there yet.
    var next_word: string = ""
}

/// A `{ ... }` of the text, with what its header says it is.
pub struct Block {
    var hstart: usize  = 0           ///< where its header starts (a closure's: at its `fn`)
    var open:   usize  = 0           ///< its `{`
    var close:  usize  = usize::MAX  ///< its `}`; usize::MAX: still open at the cursor
    var word:   string = ""          ///< `fn`, `class`, `struct`, `enum`, `union`, `interface`, `extend`, `module`; "" for any other block
    /// What its header declares is the block's (a function's parameters, a
    /// `for` variable, an `if var`, a `case` binding). False for braces
    /// that are a value's (`var p = Point { x: 1 }`): what stands before
    /// them is declared in the block around.
    var scopes: bool = false
    var name:   string = ""          ///< what it declares; for `extend`, the last name of the target's path
}

/// A name the text itself declares in a function (the index does not have
/// it yet): its type as written, or what initialises it.
pub struct LexDecl {
    var name:  string = ""
    var off:   usize  = 0
    var type_: string = ""  ///< after the `:`, as written
    var init:  string = ""  ///< after the `=`, as written
    var param: bool   = false
}

fn blank(c: u8) -> bool {
    return (c == (' ' as u8)) || (c == ('\t' as u8))
}

/// The identifier that starts at \p p, "" for none.
fn word_from(const text: string, p: usize) -> string {
    var e = p
    while (e < text.size()) && is_ident_byte(text[e]) {
        e += 1
    }

    return text.subslice(p, e - p)
}

/// The identifier that ends at \p e (exclusive), "" for none.
fn word_before(const text: string, e: usize) -> string {
    var s = e
    while (s > 0) && is_ident_byte(text[s - 1]) {
        s -= 1
    }

    return text.subslice(s, e - s)
}

/// Where the statement or header that holds \p at starts: back to a line
/// start outside every bracket opened before \p at, or to the `{`, `}` or
/// `;` that ends what came before.
pub fn stmt_start(const text: string, const cls: [u8], at: usize) -> usize {
    var depth: i64 = 0
    var p = at
    while p > 0 {
        var c = text[p - 1]
        if cls[p - 1] != 0 {
            p -= 1
            continue
        }

        if (c == (')' as u8)) || (c == (']' as u8)) {
            depth += 1
        } else if (c == ('(' as u8)) || (c == ('[' as u8)) {
            depth -= 1
        } else if depth <= 0 {
            if (c == ('{' as u8)) || (c == ('}' as u8)) {
                break
            }

            if c == (';' as u8) {
                // `for var i = 0; i < n; ++i {`: the `;` of a `for` header
                // ends no statement. The header starts at its `for`.
                var ls = p - 1
                while (ls > 0) && (text[ls - 1] != ('\n' as u8)) {
                    ls -= 1
                }

                var f = ls
                while (f < p) && blank(text[f]) {
                    f += 1
                }

                if (cls[f] == 0) && (word_from(text, f) == "for") {
                    return f
                }

                break
            }

            if c == ('\n' as u8) {
                // Scanning back from inside a bracket, its opener is not
                // met yet: a line that ends in `,` or an opener goes on
                // (`fn f(a: T,` / `    b: U`). One that goes on any other
                // way (an operator first on the next line) is cut here:
                // rare in a language with no statement terminator.
                var q = p - 1
                while (q > 0) && ((cls[q - 1] != 0) || blank(text[q - 1]) || (text[q - 1] == ('\r' as u8))) {
                    if text[q - 1] == ('\n' as u8) {
                        break
                    }

                    q -= 1
                }

                var last: u8 = if (q > 0) => (text[q - 1]) else => ('\n' as u8)
                if !((last == (',' as u8)) || (last == ('(' as u8)) || (last == ('[' as u8))) {
                    break
                }
            }
        }

        p -= 1
    }

    while (p < at) && (blank(text[p]) || (text[p] == ('\n' as u8)) || (text[p] == ('\r' as u8))) {
        p += 1
    }

    return p
}

fn is_modifier(const w: string) -> bool {
    return (w == "pub") || (w == "priv") || (w == "prot") || (w == "static") || (w == "inline") || (w == "unsafe")
        || (w == "async") || (w == "virtual") || (w == "override") || (w == "final") || (w == "const") || (w == "eval")
        || (w == "ffi")
}

fn is_scope_word(const w: string) -> bool {
    return (w == "fn") || (w == "class") || (w == "struct") || (w == "enum") || (w == "union") || (w == "interface")
        || (w == "extend") || (w == "module") || (w == "test") || (w == "macro")
}

/// Reads the header [\p from, \p to) of a block into \p b: its declaring
/// word, after any modifiers and attributes, and the name.
fn read_header(const text: string, const cls: [u8], from: usize, to: usize, b: *Block) {
    var p = from
    while p < to {
        while (p < to) && (blank(text[p]) || (text[p] == ('\n' as u8)) || (text[p] == ('\r' as u8))) {
            p += 1
        }

        if p >= to {
            return
        }

        // `@attr` / `@attr(args)` before the declaration.
        if text[p] == ('@' as u8) {
            p += 1
            while (p < to) && (is_ident_byte(text[p]) || (text[p] == (':' as u8))) {
                p += 1
            }

            if (p < to) && (text[p] == ('(' as u8)) {
                var d: i64 = 0
                while p < to {
                    if cls[p] == 0 {
                        if text[p] == ('(' as u8) {
                            d += 1
                        } else if text[p] == (')' as u8) {
                            d -= 1
                            if d == 0 {
                                p += 1
                                break
                            }
                        }
                    }

                    p += 1
                }
            }

            continue
        }

        // A string between modifiers: `ffi "c++" class ...`.
        if cls[p] == 2 {
            while (p < to) && (cls[p] == 2) {
                p += 1
            }

            continue
        }

        var w = word_from(text, p)
        if w.empty() {
            return
        }

        p += w.size()
        if is_modifier(w) {
            continue
        }

        if !is_scope_word(w) {
            b->scopes = (w == "for") || (w == "if") || (w == "else") || (w == "while") || (w == "match") || (w == "case")
                || (w == "catch") || (w == "loop") || (w == "try") || (w == "finally") || (w == "default")
            // A closure's body (`var f = fn (a: T) -> R {`, `g(fn (x) {`):
            // the block is the closure's, from its `fn`, so its parameters
            // are the block's and what stands before the `fn` is not. The
            // last `fn (` of the header: an earlier one is a function TYPE
            // (`var f: fn(i32) -> i32 = fn (a: i32) -> i32 {`).
            var q = to
            while q > (p + 1) {
                q -= 1
                if (cls[q] == 0) && (text[q] == ('(' as u8)) {
                    var e = q
                    while (e > p) && blank(text[e - 1]) {
                        e -= 1
                    }

                    if (e >= (p + 2)) && (text[e - 1] == ('n' as u8)) && (text[e - 2] == ('f' as u8))
                        && ((e - 2 == from) || (!is_ident_byte(text[e - 3]))) {
                        b->word   = "fn"
                        b->scopes = true
                        b->hstart = e - 2
                        return
                    }
                }
            }

            return
        }

        b->word   = w
        b->scopes = true
        while (p < to) && blank(text[p]) {
            p += 1
        }

        // `fn <T> name(`, `struct <T> Pair`: the generic list comes first.
        if (p < to) && (text[p] == ('<' as u8)) {
            var d: i64 = 0
            while p < to {
                if text[p] == ('<' as u8) {
                    d += 1
                } else if text[p] == ('>' as u8) {
                    d -= 1
                    if d == 0 {
                        p += 1
                        break
                    }
                }

                p += 1
            }

            while (p < to) && blank(text[p]) {
                p += 1
            }
        }

        // The name; for `extend a::b::C<T>` the last name of the path.
        var name = word_from(text, p)
        p += name.size()
        while (w == "extend") && ((p + 1) < to) && (text[p] == (':' as u8)) && (text[p + 1] == (':' as u8)) {
            p += 2
            name = word_from(text, p)
            p += name.size()
        }

        b->name = name
        return
    }
}

/// Every block opened before \p at, in the order of its `{`.
pub fn blocks_before(const text: string, const cls: [u8], at: usize) -> [Block] {
    var out: [Block]
    var open: [usize] // indices into `out` of the blocks still open
    var i: usize = 0
    var n = at
    if n > text.size() {
        n = text.size()
    }

    while i < n {
        if cls[i] != 0 {
            i += 1
            continue
        }

        var c = text[i]
        if c == ('{' as u8) {
            var b = Block{}
            b.open   = i
            b.hstart = stmt_start(text, cls, i)
            read_header(text, cls, b.hstart, i, &b)
            open.push_back(out.size())
            out.push_back(b)
        } else if (c == ('}' as u8)) && (!open.empty()) {
            out[open[open.size() - 1]].close = i
            open.pop_back()
        }

        i += 1
    }

    return out
}

/// The outermost function (or `test`) block still open at the cursor
/// \p blocks were read for; usize::MAX when the cursor is in none.
pub fn function_block(const blocks: [Block]) -> usize {
    for var k: usize = 0; k < blocks.size(); ++k {
        if (blocks[k].close == usize::MAX) && ((blocks[k].word == "fn") || (blocks[k].word == "test")) {
            return k
        }
    }

    return usize::MAX
}

/// Whether a name declared at byte \p o is in scope at the cursor \p blocks
/// were read for (blocks_before): the block whose header declares it (a
/// parameter, a `for` variable, an `if var`, a `case` binding), else the
/// innermost block around it, is still open. Only blocks from \p from on
/// are looked at (the enclosing function's, function_block); a name before
/// all of them (a type parameter of a type around the function) is in
/// scope. The index path and the marker path's walk both ask this, so the
/// two lists agree on which locals a closed block took with it.
pub fn declared_in_scope(const blocks: [Block], from: usize, o: usize) -> bool {
    var owner = usize::MAX
    for var q = from; q < blocks.size(); ++q {
        if blocks[q].scopes && (blocks[q].hstart <= o) && (o < blocks[q].open) {
            owner = q
            break
        }
    }

    if owner == usize::MAX {
        for var q = from; q < blocks.size(); ++q {
            if (blocks[q].open < o) && ((blocks[q].close == usize::MAX) || (blocks[q].close > o)) {
                owner = q
            }
        }
    }

    return (owner == usize::MAX) || (blocks[owner].close == usize::MAX)
}

/// Classifies the cursor at byte \p at of \p text.
pub fn site_at(const text: string, const cls: [u8], at: usize) -> Site {
    var s = Site{}
    var n = text.size()
    s.start = at
    while (s.start > 0) && is_ident_byte(text[s.start - 1]) {
        s.start -= 1
    }

    s.end = at
    while (s.end < n) && is_ident_byte(text[s.end]) {
        s.end += 1
    }

    var ls = at
    while (ls > 0) && (text[ls - 1] != ('\n' as u8)) {
        ls -= 1
    }

    // --- `ffi "c++" import "path|`: the header's path, which is a string.
    var p = ls
    while (p < at) && blank(text[p]) {
        p += 1
    }

    for var m: usize = 0; m < 2; ++m {
        var w = word_from(text, p)
        if (w == "pub") || (w == "priv") || (w == "prot") {
            p += w.size()
            while (p < at) && blank(text[p]) {
                p += 1
            }
        }
    }

    if word_from(text, p) == "ffi" {
        var q = p + 3
        while (q < at) && blank(text[q]) {
            q += 1
        }

        if (q < at) && (text[q] == ('"' as u8)) {
            var le = q + 1
            while (le < at) && (text[le] != ('"' as u8)) {
                le += 1
            }

            var lang = text.subslice(q + 1, le - q - 1)
            q = le + 1
            while (q < at) && blank(text[q]) {
                q += 1
            }

            if (le < at) && (word_from(text, q) == "import") {
                q += 6
                while (q < at) && blank(text[q]) {
                    q += 1
                }

                if (q < at) && (text[q] == ('"' as u8)) {
                    var closed = false
                    for var k: usize = q + 1; k < at; ++k {
                        if text[k] == ('"' as u8) {
                            closed = true
                        }
                    }

                    if !closed {
                        s.what    = SITE_HEADER
                        s.lang    = lang
                        s.path_at = q + 1
                        // What is replaced is the last path segment.
                        s.start = at
                        while (s.start > (q + 1)) && (text[s.start - 1] != ('/' as u8)) {
                            s.start -= 1
                        }

                        s.end = at
                        while (s.end < n) && (text[s.end] != ('"' as u8)) && (text[s.end] != ('/' as u8)) && (text[s.end] != ('\n' as u8)) {
                            s.end += 1
                        }

                        return s
                    }
                }

                // Elsewhere in an ffi import there is nothing to name. (An
                // ffi DECLARATION, `ffi "c" fn f(x: T)`, is read as any
                // other line.)
                return s
            }
        }
    }

    // --- a comment, a string (but for an f-string's `{...}`).
    if (at > 0) && (cls[at - 1] == 1) {
        return s
    }

    if (at > 0) && (at < n) && (cls[at - 1] == 2) && (cls[at] == 2) {
        var b = at
        while (b > 0) && (cls[b - 1] == 2) {
            b -= 1
        }

        var depth: i64 = 0
        if (b > 0) && (text[b - 1] == ('f' as u8)) {
            for var k: usize = b + 1; k < at; ++k {
                if text[k] == ('{' as u8) {
                    depth += 1
                } else if (text[k] == ('}' as u8)) && (depth > 0) {
                    depth -= 1
                }
            }
        }

        if depth <= 0 {
            return s
        }
    } else {
        // A string still open on this line: an odd number of quotes.
        var quotes: usize = 0
        for var k: usize = ls; k < at; ++k {
            if (cls[k] == 0) && (text[k] == ('"' as u8)) && ((k == ls) || (text[k - 1] != ('\\' as u8))) {
                quotes += 1
            }
        }

        if (quotes % 2) == 1 {
            return s
        }
    }

    // --- a number being typed (`12`, `0x1F`, `1.5`).
    if (s.start < s.end) && (text[s.start] >= ('0' as u8)) && (text[s.start] <= ('9' as u8)) {
        return s
    }

    // --- `@word`.
    if (s.start > 0) && (text[s.start - 1] == ('@' as u8)) {
        s.what = SITE_ATTR
        var q = s.end
        // `@name(args)` already written: past its arguments.
        while (q < n) && (blank(text[q]) || (text[q] == ('\n' as u8)) || (text[q] == ('\r' as u8))) {
            q += 1
        }

        for var m: usize = 0; m < 6; ++m {
            var w = word_from(text, q)
            if w.empty() || (!is_modifier(w)) {
                break
            }

            q += w.size()
            while (q < n) && blank(text[q]) {
                q += 1
            }
        }

        s.next_word = word_from(text, q)
        return s
    }

    // --- after `.`, `->`, `::`.
    var before = s.start
    while (before > 0) && blank(text[before - 1]) {
        before -= 1
    }

    if before > 0 {
        var c = text[before - 1]
        if (c == ('.' as u8)) && (!((before > 1) && (text[before - 2] == ('.' as u8)))) {
            s.what     = SITE_MEMBER
            s.recv_end = before - 1
        } else if (c == ('>' as u8)) && (before > 1) && (text[before - 2] == ('-' as u8)) {
            s.recv_end = before - 2
            // `fn f() -> T`: a return type, not a member, when the
            // statement is a function's header.
            var st = stmt_start(text, cls, s.recv_end)
            var hb = Block{}
            hb.hstart = st
            read_header(text, cls, st, s.recv_end, &hb)
            var has_body = false
            for var k: usize = hb.hstart; k < s.recv_end; ++k {
                if (cls[k] == 0) && (text[k] == ('{' as u8)) {
                    has_body = true
                }
            }

            if (hb.word == "fn") && (!has_body) {
                s.what = SITE_NAME
                s.kc   = KC_TYPE
                return s
            }

            s.what = SITE_MEMBER
        } else if (c == (':' as u8)) && (before > 1) && (text[before - 2] == (':' as u8)) {
            s.what     = SITE_MEMBER
            s.recv_end = before - 2
        }
    }

    if s.what == SITE_MEMBER {
        // The receiver is a number (`1.`): a float being typed.
        var r = s.recv_end
        while (r > 0) && blank(text[r - 1]) {
            r -= 1
        }

        var rs = r
        while (rs > 0) && is_ident_byte(text[rs - 1]) {
            rs -= 1
        }

        if (rs < r) && (text[rs] >= ('0' as u8)) && (text[rs] <= ('9' as u8)) {
            s.what = SITE_NONE
        }

        return s
    }

    // --- a bare name. What stands before it says what it can be.
    s.what = SITE_NAME
    var prev = word_before(text, before)
    if (prev == "fn") || (prev == "class") || (prev == "struct") || (prev == "enum") || (prev == "union")
        || (prev == "interface") || (prev == "module") || (prev == "macro") || (prev == "type") || (prev == "var")
        || (prev == "catch") || (prev == "test") || (prev == "for") || (prev == "label") {
        // A name is being DECLARED: there is nothing to complete it from.
        // (`const` and `eval` are left out: `const self`, `eval if`.)
        s.what = SITE_NONE
        return s
    }

    if (prev == "as") || (prev == "derives") || (prev == "impl") || (prev == "extend") || (prev == "is") {
        s.kc = KC_TYPE
        return s
    }

    var st = stmt_start(text, cls, s.start)
    var head = Block{}
    head.hstart = st
    read_header(text, cls, st, s.start, &head)
    if (before > 0) && (text[before - 1] == (':' as u8)) {
        // `var x: T`: a type. Any other `:` may be a named field's value
        // or a map's (`Point { x: v }`, `{k: v}`): a type or an expression.
        var q = st
        var w = word_from(text, q)
        while (w == "pub") || (w == "priv") || (w == "prot") || (w == "static") || (w == "unsafe") || (w == "inline") {
            q += w.size()
            while (q < s.start) && blank(text[q]) {
                q += 1
            }

            w = word_from(text, q)
        }

        s.kc = if ((w == "var") || (w == "const") || (w == "eval")) => (KC_TYPE) else => (KC_TYPE | KC_EXPR)
        return s
    }

    // A header has no body yet: with a `{` since its `fn` this is a
    // statement that holds a finished closure, not a header.
    var body = false
    for var k: usize = head.hstart; (head.word == "fn") && (k < s.start); ++k {
        if (cls[k] == 0) && (text[k] == ('{' as u8)) {
            body = true
        }
    }

    if (head.word == "fn") && (!body) {
        // In a function's header: its parameter list. Before a `:` a
        // parameter is being named; `self` and `const` can stand there.
        var depth: i64 = 0
        var colon = false
        for var k: usize = head.hstart; k < s.start; ++k {
            if cls[k] != 0 {
                continue
            }

            if (text[k] == ('(' as u8)) || (text[k] == ('<' as u8)) {
                depth += 1
                colon = false
            } else if (text[k] == (')' as u8)) || (text[k] == ('>' as u8)) {
                depth -= 1
            } else if text[k] == (',' as u8) {
                colon = false
            } else if text[k] == (':' as u8) {
                colon = true
            }
        }

        if depth > 0 {
            s.kc = if (colon) => (KC_TYPE) else => KC_PARAM
            return s
        }
    }

    // File level, a type's body, or a function's.
    var blocks = blocks_before(text, cls, s.start)
    var inner = usize::MAX
    for var k: usize = 0; k < blocks.size(); ++k {
        if blocks[k].close == usize::MAX {
            inner = k
        }
    }

    var first = st == s.start
    if (inner == usize::MAX) || ((blocks[inner].word != "fn") && (blocks[inner].word != "test") && (!blocks[inner].word.empty())) {
        s.kc = if (first) => (KC_DECL) else => (KC_DECL | KC_EXPR | KC_TYPE)
        return s
    }

    s.kc = if (first) => (KC_STMT | KC_EXPR) else => KC_EXPR
    return s
}

/// The type name a written type \p t names: past `unsafe`, `const`, `*`,
/// `&`, up to its generic arguments or a `?`. May be a path (`a::B`).
pub fn type_head(const t: string) -> string {
    var p: usize = 0
    while p < t.size() {
        while (p < t.size()) && (blank(t[p]) || (t[p] == ('*' as u8)) || (t[p] == ('&' as u8))) {
            p += 1
        }

        var w = word_from(t, p)
        if (w == "unsafe") || (w == "const") {
            p += w.size()
            continue
        }

        break
    }

    var e = p
    while (e < t.size()) && (is_ident_byte(t[e]) || (t[e] == (':' as u8))) {
        e += 1
    }

    return t.subslice(p, e - p)
}

/// The type of what a subscript of a value of type \p t gives, as text:
/// the element of `[T]`, `[T; N]`, `[T;]`, the value of `{K: V}`; "" for any
/// other type (a `?` or a pointer after or before it included: the value
/// is not subscripted as it is).
pub fn elem_type_text(const t: string) -> string {
    var p: usize = 0
    while (p < t.size()) && blank(t[p]) {
        p += 1
    }

    if word_from(t, p) == "const" {
        p += 5
        while (p < t.size()) && blank(t[p]) {
            p += 1
        }
    }

    if (p >= t.size()) || ((t[p] != ('[' as u8)) && (t[p] != ('{' as u8))) {
        return ""
    }

    var close = usize::MAX
    var cut   = usize::MAX  // `;` in a `[`, `:` in a `{`, at the outer depth
    var depth: i64 = 0
    for var k = p; k < t.size(); ++k {
        var c = t[k]
        if (c == ('[' as u8)) || (c == ('{' as u8)) || (c == ('(' as u8)) || (c == ('<' as u8)) {
            depth += 1
        } else if (c == (']' as u8)) || (c == ('}' as u8)) || (c == (')' as u8)) || (c == ('>' as u8)) {
            depth -= 1
            if depth == 0 {
                close = k
                break
            }
        } else if (depth == 1) && (cut == usize::MAX) {
            if (t[p] == ('[' as u8)) && (c == (';' as u8)) {
                cut = k
            } else if (t[p] == ('{' as u8)) && (c == (':' as u8))
                && (!(((k + 1) < t.size()) && (t[k + 1] == (':' as u8)))) && (!((k > 0) && (t[k - 1] == (':' as u8)))) {
                cut = k
            }
        }
    }

    if close == usize::MAX {
        return ""
    }

    // Nothing after the brackets: `[T]?` is not subscripted as it is.
    for var k = close + 1; k < t.size(); ++k {
        if !blank(t[k]) {
            return ""
        }
    }

    var a = p + 1
    var b = close
    if t[p] == ('{' as u8) {
        if cut == usize::MAX {
            return "" // a set: no subscript
        }

        a = cut + 1
    } else if cut != usize::MAX {
        b = cut
    }

    while (a < b) && blank(t[a]) {
        a += 1
    }

    while (b > a) && blank(t[b - 1]) {
        b -= 1
    }

    return t.subslice(a, b - a)
}

/// The type a declaration's one-line text gives \p name (`var boxes:
/// [Vault]`, `const n: i32 = 3`, `fn f() -> [T]` with \p result), or "".
pub fn decl_type_text(const line: string, const name: string, result: bool) -> string {
    if result {
        // The last `->` at the outer depth: the function's result.
        var at = usize::MAX
        var depth: i64 = 0
        for var k: usize = 0; (k + 1) < line.size(); ++k {
            var c = line[k]
            if (c == ('(' as u8)) || (c == ('[' as u8)) || (c == ('{' as u8)) {
                depth += 1
            } else if (c == (')' as u8)) || (c == (']' as u8)) || (c == ('}' as u8)) {
                depth -= 1
            } else if (depth == 0) && (c == ('-' as u8)) && (line[k + 1] == ('>' as u8)) {
                at = k + 2
            }
        }

        if at == usize::MAX {
            return ""
        }

        var e = line.size()
        var w = find_word_(line, "where", at)
        if w != usize::MAX {
            e = w
        }

        return line.subslice(at, e - at)
    }

    var n = find_word_(line, name, 0)
    if n == usize::MAX {
        return ""
    }

    var p = n + name.size()
    while (p < line.size()) && blank(line[p]) {
        p += 1
    }

    if (p >= line.size()) || (line[p] != (':' as u8)) {
        return ""
    }

    p += 1
    var e = p
    var depth: i64 = 0
    while e < line.size() {
        var c = line[e]
        if (c == ('(' as u8)) || (c == ('[' as u8)) || (c == ('{' as u8)) || (c == ('<' as u8)) {
            depth += 1
        } else if (c == (')' as u8)) || (c == (']' as u8)) || (c == ('}' as u8)) || (c == ('>' as u8)) {
            depth -= 1
        } else if (depth == 0) && (c == ('=' as u8)) {
            break
        }

        e += 1
    }

    return line.subslice(p, e - p)
}

/// The first place at or after \p from where \p w stands as a whole word.
fn find_word_(const s: string, const w: string, from: usize) -> usize {
    var k = from
    while (k + w.size()) <= s.size() {
        if (s.subslice(k, w.size()) == w) && ((k == 0) || (!is_ident_byte(s[k - 1])))
            && (((k + w.size()) == s.size()) || (!is_ident_byte(s[k + w.size()]))) {
            return k
        }

        k += 1
    }

    return usize::MAX
}

/// Reads one declared name at \p p (after `var` / `const` / in a parameter
/// list) up to \p to: `unsafe *name: T = init`.
fn read_decl(const text: string, const cls: [u8], p_in: usize, to: usize, out: *[LexDecl], param: bool) {
    var p = p_in
    while p < to {
        while (p < to) && (blank(text[p]) || (text[p] == ('*' as u8)) || (text[p] == ('&' as u8)) || (text[p] == ('\n' as u8))) {
            p += 1
        }

        if (p < to) && (text[p] == ('@' as u8)) {
            // `@inout x: T`, `@move x: T`
            p += 1
            p += word_from(text, p).size()
            continue
        }

        var w = word_from(text, p)
        if (w == "unsafe") || (w == "const") || (w == "var") {
            p += w.size()
            continue
        }

        break
    }

    var name = word_from(text, p)
    if name.empty() || ((name[0] >= ('0' as u8)) && (name[0] <= ('9' as u8))) {
        return
    }

    var d = LexDecl{}
    d.name  = name
    d.off   = p
    d.param = param
    p += name.size()
    while (p < to) && blank(text[p]) {
        p += 1
    }

    // The rest of the declaration: to the line's end, or for a parameter
    // to the `,` or `)` that ends it.
    var e = p
    var depth: i64 = 0
    while e < to {
        var c = text[e]
        if cls[e] == 0 {
            if (c == ('(' as u8)) || (c == ('[' as u8)) || (c == ('<' as u8)) || (c == ('{' as u8)) {
                depth += 1
            } else if (c == (')' as u8)) || (c == (']' as u8)) || (c == ('>' as u8)) || (c == ('}' as u8)) {
                if depth == 0 {
                    break
                }

                depth -= 1
            } else if (depth == 0) && ((c == ('\n' as u8)) || (c == (';' as u8)) || (param && (c == (',' as u8)))) {
                break
            }
        }

        e += 1
    }

    var rest = text.subslice(p, e - p)
    var eq = usize::MAX
    var dd: i64 = 0
    for var k: usize = 0; k < rest.size(); ++k {
        var c = rest[k]
        if (c == ('(' as u8)) || (c == ('[' as u8)) || (c == ('<' as u8)) {
            dd += 1
        } else if (c == (')' as u8)) || (c == (']' as u8)) || (c == ('>' as u8)) {
            dd -= 1
        } else if (c == ('=' as u8)) && (dd <= 0) && (eq == usize::MAX) && (!(((k + 1) < rest.size()) && (rest[k + 1] == ('=' as u8)))) {
            eq = k
        }
    }

    var ty = rest
    if eq != usize::MAX {
        ty     = rest.subslice(0, eq)
        d.init = rest.subslice(eq + 1, rest.size() - eq - 1)
    }

    if (!ty.empty()) && (ty[0] == (':' as u8)) {
        d.type_ = ty.subslice(1, ty.size() - 1)
    }

    out->push_back(d)
}

/// The names \p text declares in [\p from, \p to): `var` / `const` / `eval`
/// / `static` declarations, `for x in`, `catch e`. For the lines the index
/// has no rows of (typed since it was built).
pub fn lex_decls(const text: string, const cls: [u8], from: usize, to: usize) -> [LexDecl] {
    var out: [LexDecl]
    var p = from
    while p < to {
        if (cls[p] != 0) || (!is_ident_byte(text[p])) || ((p > 0) && is_ident_byte(text[p - 1])) {
            p += 1
            continue
        }

        var w = word_from(text, p)
        var q = p + w.size()
        if (w == "var") || (w == "const") || (w == "eval") {
            read_decl(text, cls, q, to, &out, false)
        } else if (w == "for") || (w == "catch") {
            while (q < to) && blank(text[q]) {
                q += 1
            }

            var name = word_from(text, q)
            if (!name.empty()) && (name != "var") && (name != "const") {
                var after = q + name.size()
                while (after < to) && blank(text[after]) {
                    after += 1
                }

                if (w == "catch") || (word_from(text, after) == "in") {
                    var d = LexDecl{}
                    d.name = name
                    d.off  = q
                    out.push_back(d)
                }
            }
        }

        p = q
        if w.empty() {
            p += 1
        }
    }

    return out
}

/// The parameters a function's header [\p from, \p to) declares.
pub fn lex_params(const text: string, const cls: [u8], from: usize, to: usize) -> [LexDecl] {
    var out: [LexDecl]
    var p = from
    // The parameter list is the first `(` after the name (a generic list
    // has no parenthesis).
    while (p < to) && (!((cls[p] == 0) && (text[p] == ('(' as u8)))) {
        p += 1
    }

    if p >= to {
        return out
    }

    p += 1
    var depth: i64 = 0
    var item = p
    while p < to {
        var c = text[p]
        if cls[p] == 0 {
            if (c == ('(' as u8)) || (c == ('[' as u8)) || (c == ('<' as u8)) {
                depth += 1
            } else if (c == (']' as u8)) || (c == ('>' as u8)) {
                depth -= 1
            } else if (c == (')' as u8)) && (depth > 0) {
                depth -= 1
            } else if ((c == (',' as u8)) || (c == (')' as u8))) && (depth == 0) {
                read_decl(text, cls, item, p + 1, &out, true)
                item = p + 1
                if c == (')' as u8) {
                    break
                }
            }
        }

        p += 1
    }

    return out
}

/// One step of a receiver: a name, whether it is called, and how many
/// subscripts follow (`a.b()[i][j]`: b, called, then 2), in that order.
pub struct RecvStep {
    var name:  string = ""
    var call:  bool   = false
    var off:   usize  = 0
    var index: usize  = 0
}

/// The receiver that ends at \p end (exclusive), as its steps from the
/// head: `a.b().c` is a, b (called), c; `a[i].b` is a (one subscript), b;
/// a parenthesised chain (`(a.b).`, `(*p).`) is the chain; a `?` of a safe
/// access (`x?.`) is passed over. Empty when it is not a chain of names: a
/// literal, any other expression.
pub fn receiver_steps(const text: string, const cls: [u8], end: usize) -> [RecvStep] {
    var rev: [RecvStep]
    var none: [RecvStep]
    var p = end
    // Code, or the inside of the f-string the cursor is in.
    var here: u8 = if (end > 0) => (cls[end - 1]) else => (0 as u8)
    var guard: usize = 0
    while guard < 32 {
        guard += 1
        while (p > 0) && blank(text[p - 1]) {
            p -= 1
        }

        // `x?.`: a nullable's safe access names the members of what it
        // holds, which is the record the tables give a `T?` (through `?`).
        if (p > 0) && (text[p - 1] == ('?' as u8)) && (cls[p - 1] == here) && (!((p > 1) && (text[p - 2] == ('?' as u8)))) {
            p -= 1
            while (p > 0) && blank(text[p - 1]) {
                p -= 1
            }
        }

        var st = RecvStep{}
        // `v[i]`, `m[k][j]`: the subscripts after the step, back over
        // their brackets (these went to the compiler).
        while (p > 0) && (text[p - 1] == (']' as u8)) && (cls[p - 1] == here) {
            var close_at = p - 1
            var bd: i64 = 0
            var opened = false
            while p > 0 {
                var c = text[p - 1]
                if cls[p - 1] == here {
                    if c == (']' as u8) {
                        bd += 1
                    } else if c == ('[' as u8) {
                        bd -= 1
                        if bd == 0 {
                            p -= 1
                            opened = true
                            break
                        }
                    }
                }

                p -= 1
            }

            if !opened {
                return none
            }

            // `v[a..b]` is a slice of `v`, not an element: not read here.
            for var k = p + 1; (k + 1) < close_at; ++k {
                if (cls[k] == here) && (text[k] == ('.' as u8)) && (text[k + 1] == ('.' as u8)) {
                    return none
                }
            }

            st.index += 1
            while (p > 0) && blank(text[p - 1]) {
                p -= 1
            }
        }

        // `name<T>(args)` / `name(args)`: back over the call's brackets.
        var paren_close = usize::MAX
        var paren_open  = usize::MAX
        var generic = false
        if (p > 0) && (text[p - 1] == (')' as u8)) && (cls[p - 1] == here) {
            paren_close = p - 1
            var depth: i64 = 0
            while p > 0 {
                var c = text[p - 1]
                if cls[p - 1] == here {
                    if c == (')' as u8) {
                        depth += 1
                    } else if c == ('(' as u8) {
                        depth -= 1
                        if depth == 0 {
                            p -= 1
                            paren_open = p
                            break
                        }
                    }
                }

                p -= 1
            }

            st.call = true
            while (p > 0) && blank(text[p - 1]) {
                p -= 1
            }

            if (p > 0) && (text[p - 1] == ('>' as u8)) {
                generic = true
                var ad: i64 = 0
                while p > 0 {
                    var c = text[p - 1]
                    if c == ('>' as u8) {
                        ad += 1
                    } else if c == ('<' as u8) {
                        ad -= 1
                        if ad == 0 {
                            p -= 1
                            break
                        }
                    }

                    p -= 1
                }
            }
        }

        var e = p
        while (p > 0) && is_ident_byte(text[p - 1]) {
            p -= 1
        }

        // `(a.b).`, `(a)[i].`: brackets with no name before them are a
        // parenthesised expression; when what they hold is itself a chain
        // of names, the receiver is that chain (with the subscripts after
        // the brackets applied to its last step), and it is the head.
        if (p == e) && (paren_open != usize::MAX) && (!generic) {
            var open = paren_open
            var inner = receiver_steps(text, cls, paren_close)
            var first = open + 1
            while (first < paren_close) && (blank(text[first]) || (text[first] == ('\n' as u8))) {
                first += 1
            }

            // `(*p).`: a dereferenced chain is the record the chain's
            // pointer points at, which is what the tables give a pointer
            // (through `*`).
            if (first < paren_close) && (text[first] == ('*' as u8)) && (cls[first] == here) {
                first += 1
                while (first < paren_close) && blank(text[first]) {
                    first += 1
                }
            }

            if inner.empty() || (inner[0].off != first) {
                return none
            }

            var q0 = open
            while (q0 > 0) && blank(text[q0 - 1]) {
                q0 -= 1
            }

            // Nothing that would make the brackets part of a larger
            // expression this does not read (`x.(a)`, `f()(a)`, `@(a)`).
            if (q0 > 0) && ((text[q0 - 1] == ('.' as u8)) || (text[q0 - 1] == (':' as u8)) || (text[q0 - 1] == ('>' as u8))
                || (text[q0 - 1] == (')' as u8)) || (text[q0 - 1] == (']' as u8)) || (text[q0 - 1] == ('@' as u8))) {
                return none
            }

            inner[inner.size() - 1].index += st.index
            var ik = inner.size()
            while ik > 0 {
                rev.push_back(inner[ik - 1])
                ik -= 1
            }

            break
        }

        if (p == e) || (cls[p] != here) || ((text[p] >= ('0' as u8)) && (text[p] <= ('9' as u8))) {
            return none
        }

        st.name = text.subslice(p, e - p)
        st.off  = p
        rev.push_back(st)

        var q = p
        while (q > 0) && blank(text[q - 1]) {
            q -= 1
        }

        if (q > 0) && (text[q - 1] == ('.' as u8)) && (!((q > 1) && (text[q - 2] == ('.' as u8)))) {
            p = q - 1
            continue
        }

        if (q > 1) && (((text[q - 1] == ('>' as u8)) && (text[q - 2] == ('-' as u8))) || ((text[q - 1] == (':' as u8)) && (text[q - 2] == (':' as u8)))) {
            p = q - 2
            continue
        }

        // What stands before the head must not make it part of something
        // this does not read: `x[i].y`, `f(a).b` are handled above; a `)`
        // or `]` here is an expression's end.
        if (q > 0) && ((text[q - 1] == (')' as u8)) || (text[q - 1] == (']' as u8)) || (text[q - 1] == ('@' as u8))) {
            return none
        }

        break
    }

    var out: [RecvStep]
    var k = rev.size()
    while k > 0 {
        out.push_back(rev[k - 1])
        k -= 1
    }

    return out
}

/// The `///` block above line \p line (0-based) of \p text, the slashes and
/// one space dropped; attribute lines between it and the declaration are
/// stepped over, as the indexer's own reading does (Hovers.k, doc_).
pub fn doc_above(const text: string, line: usize) -> string {
    // Line starts up to and including `line`.
    var starts: [usize]
    starts.push_back(0)
    for var i: usize = 0; (i < text.size()) && (starts.size() <= line); ++i {
        if text[i] == ('\n' as u8) {
            starts.push_back(i + 1)
        }
    }

    if starts.size() <= line {
        return ""
    }

    var lines: [string]
    var k = line
    while k > 0 {
        var ls = starts[k - 1]
        var le = starts[k] - 1
        var p  = ls
        while (p < le) && blank(text[p]) {
            p += 1
        }

        if ((p + 2) < le) && (text[p] == ('/' as u8)) && (text[p + 1] == ('/' as u8)) && (text[p + 2] == ('/' as u8)) {
            var b = p + 3
            if (b < le) && (text[b] == (' ' as u8)) {
                b += 1
            }

            var e = le
            while (e > b) && ((text[e - 1] == ('\r' as u8)) || blank(text[e - 1])) {
                e -= 1
            }

            lines.push_back(text.subslice(b, e - b))
            k -= 1
            continue
        }

        // An attribute or a visibility keyword on a line of its own.
        if lines.empty() && (p < le) && ((text[p] == ('@' as u8)) || (word_from(text, p) == "pub") || (word_from(text, p) == "priv") || (word_from(text, p) == "prot")) {
            k -= 1
            continue
        }

        break
    }

    var out: string = ""
    var q = lines.size()
    while q > 0 {
        out += lines[q - 1]
        if q > 1 {
            out += "\n"
        }

        q -= 1
    }

    return out
}
