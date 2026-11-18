/// --- The Kairo Project ---------------------- Analyzer/DocComment.k --- ///
///
///   Documentation comments: finding a declaration's comment in its text,
///   turning Doxygen and HeaderDoc commands into the Markdown convention,
///   and reading a declaration's head for the documentation stub.
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

import std::io

/// The start of the last `needle` that ends at or before `end`, `usize::MAX`
/// for none.
pub fn rfind_from(const s: string, const needle: string, end: usize) -> usize {
    var n = needle.size()
    var e = if end < s.size() => end else => s.size()
    if n > e {
        return usize::MAX
    }

    var p = e - n
    while true {
        var j: usize = 0
        while (j < n) && (s.data()[p + j] == needle.data()[j]) {
            j += 1
        }

        if j == n {
            return p
        }

        if p == 0 {
            return usize::MAX
        }

        p -= 1
    }

    return usize::MAX
}

/// Appends the character whose lead byte is at `i` of `s`; a continuation byte
/// appends nothing, because its lead byte already carried it. A byte loop
/// whose default path copies every byte so far builds the same text.
pub fn push_char_at(out: *string, const s: string, i: usize) {
    var c = s.data()[i]
    if c < 0x80 {
        out->push(c)
        return
    }

    if (c & 0xC0) == 0x80 {
        return
    }

    var e = i + 1
    while (e < s.size()) && ((s.data()[e] & 0xC0) == 0x80) {
        e += 1
    }

    out->push_str(s[i..e])
}

// Everything here works on text alone: the index walker reads a C or C++
// header's comment with it (clang's tree carries no comments the compiler
// keeps), the server reads a buffer that does not parse while it is typed,
// and kunit links it with nothing else of the server (Test, at the end).

// --- bytes and lines ---------------------------------------------------------

fn is_ws_(c: u8) -> bool {
    return (c == (' ' as u8)) || (c == ('\t' as u8)) || (c == ('\r' as u8))
}

fn is_ident_(c: u8) -> bool {
    return ((c >= ('a' as u8)) && (c <= ('z' as u8)))
        || ((c >= ('A' as u8)) && (c <= ('Z' as u8)))
        || ((c >= ('0' as u8)) && (c <= ('9' as u8)))
        || (c == ('_' as u8))
}

fn is_alpha_(c: u8) -> bool {
    return ((c >= ('a' as u8)) && (c <= ('z' as u8))) || ((c >= ('A' as u8)) && (c <= ('Z' as u8)))
}

/// `s` without its leading and trailing blanks.
fn trim_(const s: string) -> string {
    var b: usize = 0
    var e        = s.size()
    while (b < e) && is_ws_(s.data()[b]) {
        b += 1
    }

    while (e > b) && is_ws_(s.data()[e - 1]) {
        e -= 1
    }

    return s.subslice(b, e - b)
}

/// The number of blanks `s` starts with.
fn lead_(const s: string) -> usize {
    var n: usize = 0
    while (n < s.size()) && ((s.data()[n] == (' ' as u8)) || (s.data()[n] == ('\t' as u8))) {
        n += 1
    }

    return n
}

fn rest_(const s: string, from: usize) -> string {
    if from >= s.size() {
        return ""
    }

    return s.subslice(from, s.size() - from)
}

fn find_(const s: string, const needle: string, from: usize) -> usize {
    if needle.size() > s.size() {
        return usize::MAX
    }

    for var i: usize = from; (i + needle.size()) <= s.size(); ++i {
        var hit = true
        for var k: usize = 0; k < needle.size(); ++k {
            if s.data()[i + k] != needle.data()[k] {
                hit = false
                break
            }
        }

        if hit {
            return i
        }
    }

    return usize::MAX
}

fn split_lines_(const s: string) -> [string] {
    var out: [string]
    var b:   usize    = 0
    for var i: usize = 0; i <= s.size(); ++i {
        if (i == s.size()) || (s.data()[i] == ('\n' as u8)) {
            var e = i
            if (e > b) && (s.data()[e - 1] == ('\r' as u8)) {
                e -= 1
            }

            out.push(s.subslice(b, e - b))
            b = i + 1
        }
    }

    return out
}

fn join_lines_(const v: [string]) -> string {
    var out: string = ""
    for var i: usize = 0; i < v.size(); ++i {
        if i > 0 {
            out += "\n"
        }

        out += v[i]
    }

    return out
}

/// Where the line that holds `at` starts.
fn line_start_(const text: string, at: usize) -> usize {
    var p = at
    if p > text.size() {
        p = text.size()
    }

    while (p > 0) && (text.data()[p - 1] != ('\n' as u8)) {
        p -= 1
    }

    return p
}

/// One past the last byte of the line that starts at `ls` (its `\n`).
fn line_end_(const text: string, ls: usize) -> usize {
    var p = ls
    while (p < text.size()) && (text.data()[p] != ('\n' as u8)) {
        p += 1
    }

    return p
}

/// `lines` with the indentation every non-blank line shares removed.
fn dedent_(const lines: [string]) -> [string] {
    var cut = usize::MAX
    for var i: usize = 0; i < lines.size(); ++i {
        if !trim_(lines[i]).is_empty() {
            var l = lead_(lines[i])
            if l < cut {
                cut = l
            }
        }
    }

    var out: [string]
    for var i: usize = 0; i < lines.size(); ++i {
        if trim_(lines[i]).is_empty() {
            out.push("")
        } else {
            var t = rest_(lines[i], cut)
            while (!t.is_empty()) && is_ws_(t.data()[t.size() - 1]) {
                t = t.subslice(0, t.size() - 1)
            }

            out.push(t)
        }
    }

    // Blank lines at either end are no part of the text.
    var b: usize = 0
    var e        = out.size()
    while (b < e) && out[b].is_empty() {
        b += 1
    }

    while (e > b) && out[e - 1].is_empty() {
        e -= 1
    }

    var res: [string]
    for var i: usize = b; i < e; ++i {
        res.push(out[i].copy())
    }

    return res
}

// --- finding the comment -----------------------------------------------------

/// The content of a `/** ... */` or `/*! ... */` comment, `text[open, close)`
/// with `close` past its `*/`: the opener and closer removed and, when every
/// line after the first starts with `*` (the usual decoration), that `*` and
/// the blank after it.
fn block_lines_(const text: string, open: usize, close: usize) -> [string] {
    var body = text.subslice(open + 3, close - open - 5)
    if body.starts_with("<") {
        body = rest_(body, 1)
    }

    var raw     = split_lines_(body)
    var starred = true
    for var i: usize = 1; i < raw.size(); ++i {
        var t = trim_(raw[i])
        if (!t.is_empty()) && (!t.starts_with("*")) {
            starred = false
        }
    }

    var out: [string]
    for var i: usize = 0; i < raw.size(); ++i {
        var ln = raw[i].copy()
        if (i > 0) && starred {
            var p = lead_(ln)
            if (p < ln.size()) && (ln.data()[p] == ('*' as u8)) {
                p += 1
                if (p < ln.size()) && (ln.data()[p] == (' ' as u8)) {
                    p += 1
                }

                ln = rest_(ln, p)
            }
        } else if i == 0 {
            // Text on the opener's line: `/** Brief. */`.
            ln = trim_(ln)
        }

        out.push(ln)
    }

    return out
}

/// The text of a line comment's marker run: `///`, `//!`, or "" for none
/// (`////` is a rule, not documentation).
fn doc_marker_(const t: string) -> string {
    if t.starts_with("///") && (!t.starts_with("////")) {
        return "///"
    }

    if t.starts_with("//!") {
        return "//!"
    }

    return ""
}

/// The documentation comment of the declaration whose first line holds
/// `at`, as written: comment markers removed, the common indentation
/// removed, lines joined by `\n`. "" when it has none.
///
/// It is the run of `///` or `//!` lines, or the one `/** */` or `/*! */`
/// block, directly above that line; attribute lines, a visibility keyword
/// alone on its line, a C++ `template <...>` line or a `[[...]]` line may
/// stand between. Without one, a trailing `///<` (`//!<`, `/**<`, `/*!<`)
/// on the declaration's own line, and the `///<` lines right below it,
/// document it. A `///<` line above belongs to the declaration before, and
/// a block that opens the file with a `/// ---` rule is its license banner.
pub fn doc_comment_text(const text: string, at: usize) -> string {
    var ls                   = line_start_(text, at)
    var rev:        [string]
    var cur                  = ls
    var block:      [string]
    var walked_attr          = false
    while cur > 0 {
        var ps = line_start_(text, cur - 1)
        var ln = text.subslice(ps, cur - 1 - ps)
        var t  = trim_(ln)
        if t.starts_with("///<") || t.starts_with("//!<") {
            break
        }

        var mk = doc_marker_(t)
        if !mk.is_empty() {
            var c = rest_(t, 3)
            if c.starts_with(" ") {
                c = rest_(c, 1)
            }

            // Keep the line's own indentation past the one blank, so a
            // nested list or a code block keeps its shape.
            rev.push(c)
            cur = ps
            continue
        }

        if rev.is_empty() && t.ends_with("*/") {
            var k = ln.size()
            while (k >= 2) && (ln.subslice(k - 2, 2) != "*/") {
                k -= 1
            }

            var close = ps + k
            var open  = usize::MAX
            var q     = close - 2
            while q > 0 {
                q -= 1
                if (text.data()[q] == ('/' as u8))
                    && ((q + 1) < text.size())
                    && (text.data()[q + 1] == ('*' as u8)) {
                    open = q
                    break
                }
            }

            if open == usize::MAX {
                break
            }

            var ol         = line_start_(text, open)
            var only_blank = trim_(text.subslice(ol, open - ol)).is_empty()
            var opener     = text.subslice(open, 3)
            var is_doc = ((opener == "/**") || (opener == "/*!"))
                && ((close - open) >= 5)
                && (text.subslice(open, 4) != "/**/")
                && (text.subslice(open, 4) != "/**<")
                && (text.subslice(open, 4) != "/*!<")
            if only_blank && is_doc {
                block = block_lines_(text, open, close)
            }

            break
        }

        if rev.is_empty()
            && ((t.starts_with("@") && (t.size() > 1) && is_alpha_(t.data()[1]))
                || (t == "pub")
                || (t == "priv")
                || (t == "prot")
                || t.starts_with("template ")
                || t.starts_with("template<")
                || t.starts_with("[[")) {
            walked_attr = true
            cur         = ps
            continue
        }

        break
    }

    var lines: [string]
    if !block.is_empty() {
        lines = block
    } else {
        var n = rev.size()
        for var i: usize = 0; i < n; ++i {
            lines.push(rev[n - 1 - i].copy())
        }
    }

    if (!lines.is_empty()) && lines[0].starts_with("--- ") {
        return ""
    }

    if lines.is_empty() && (!walked_attr) {
        lines = trailing_doc_(text, ls)
    }

    return join_lines_(dedent_(lines))
}

/// A trailing `///<` (or `//!<`, `/**< */`, `/*!< */`) on the line at `ls`,
/// outside a string, and the `///<` lines that continue it.
fn trailing_doc_(const text: string, ls: usize) -> [string] {
    var out:   [string]
    var le              = line_end_(text, ls)
    var p               = ls
    var quote: u8       = 0
    while p < le {
        var c = text.data()[p]
        if quote != 0 {
            if c == ('\\' as u8) {
                p += 2
                continue
            }

            if c == quote {
                quote = 0
            }

            p += 1
            continue
        }

        if (c == ('"' as u8)) || (c == ('\'' as u8)) {
            quote = c
            p += 1
            continue
        }

        if (c == ('/' as u8)) && ((p + 3) < le) {
            var m = text.subslice(p, 4)
            if (m == "///<") || (m == "//!<") {
                out.push(trim_(text.subslice(p + 4, le - p - 4)))
                break
            }

            if (m == "/**<") || (m == "/*!<") {
                var e = find_(text, "*/", p + 4)
                if e == usize::MAX {
                    return out
                }

                var lines = split_lines_(text.subslice(p + 4, e - p - 4))
                for var i: usize = 0; i < lines.size(); ++i {
                    out.push(trim_(lines[i]))
                }

                return out
            }

            if (text.data()[p + 1] == ('/' as u8)) || (text.data()[p + 1] == ('*' as u8)) {
                return out // some other comment ends the code on this line
            }
        }

        p += 1
    }

    if out.is_empty() {
        return out
    }

    // `///<` lines right below continue it (a parameter's note in C++).
    var nl = le + 1
    while nl < text.size() {
        var ne = line_end_(text, nl)
        var t  = trim_(text.subslice(nl, ne - nl))
        if !(t.starts_with("///<") || t.starts_with("//!<")) {
            break
        }

        out.push(trim_(rest_(t, 4)))
        nl = ne + 1
    }

    return out
}

/// The documentation of the declaration at `at` in `text`, as Markdown:
/// doc_comment_text, then doc_to_markdown.
pub fn doc_markdown_at(const text: string, at: usize, cxx: bool) -> string {
    var raw = doc_comment_text(text, at)
    if raw.is_empty() {
        return raw
    }

    return doc_to_markdown(raw, cxx)
}

/// True for a path whose declarations are C or C++ (a header or a source
/// clang reads): a `\code` block in their comments is `cpp`.
pub fn is_cxx_path(const path: string) -> bool {
    var slash = rfind_from(path, "/", path.size())
    var base = if (slash == usize::MAX) => (path.copy()) else => rest_(path, slash + 1)
    if base.ends_with(".k") {
        return false
    }

    // A C++ standard header has no extension (`vector`).
    if rfind_from(base, ".", base.size()) == usize::MAX {
        return true
    }

    var exts: [string] = [
        ".h",   ".hh",  ".hpp", ".hxx", ".h++", ".inc", ".c", ".cc",
        ".cpp", ".cxx", ".ipp", ".tcc",
    ]

    for var i: usize = 0; i < exts.size(); ++i {
        if base.ends_with(exts[i]) {
            return true
        }
    }

    return false
}

// --- Doxygen and HeaderDoc to Markdown ----------------------------------------

const EK_TEXT:    u8 = 0   ///< a paragraph, kept as written
const EK_BRIEF:   u8 = 1   ///< `\brief`, `@abstract`: the summary
const EK_PARAM:   u8 = 2   ///< `\param`, `@param`
const EK_TPARAM:  u8 = 3   ///< `\tparam`
const EK_RETURNS: u8 = 4   ///< `\return(s)`, `\result`, `@result`
const EK_THROWS:  u8 = 5   ///< `\throw(s)`, `\exception`
const EK_LABEL:   u8 = 6   ///< `\note`, `\warning`, ...: a bold label before the text
const EK_SEE:     u8 = 7   ///< `\see`, `\sa`
const EK_CODE:    u8 = 8   ///< `\code` ... `\endcode`, `\verbatim` ... `\endverbatim`
const EK_RAW:     u8 = 9   ///< a Markdown fence, kept as written
const EK_PAR:     u8 = 10  ///< `\par Title`: a bold title over the paragraph
const EK_ITEM:    u8 = 11  ///< `\li`, `\arg`: a list item
const EK_DROP:    u8 = 12  ///< a structural command with no text of its own (`\file`, `@{`)
const EK_EXAMPLE: u8 = 13  ///< `\example`: what follows is the example section
const EK_NONE:    u8 = 255

struct Ent {
    var kind:  u8       = EK_TEXT
    var name:  string   = "" ///< a parameter's or an exception's name, a label, a title, a code block's language
    var dir:   string   = "" ///< `\param[out]`: the direction
    var lines: [string]
}

/// What block command `name` is (without its `\` or `@`), and for a label
/// the label's text. EK_NONE for a name that is not one: it stays text.
fn block_kind_(const name: string, label: *string) -> u8 {
    (*label) = ""
    if (name == "brief") || (name == "short") || (name == "abstract") {
        return EK_BRIEF
    }

    if (name == "details") || (name == "discussion") {
        return EK_TEXT
    }

    if name == "param" {
        return EK_PARAM
    }

    if name == "tparam" || (name == "templatefield") {
        return EK_TPARAM
    }

    if (name == "return") || (name == "returns") || (name == "result") {
        return EK_RETURNS
    }

    if (name == "throw") || (name == "throws") || (name == "exception") {
        return EK_THROWS
    }

    if (name == "see") || (name == "sa") || (name == "seealso") {
        return EK_SEE
    }

    if (name == "code") || (name == "verbatim") {
        return EK_CODE
    }

    if name == "par" {
        return EK_PAR
    }

    if (name == "li") || (name == "arg") {
        return EK_ITEM
    }

    if name == "example" {
        return EK_EXAMPLE
    }

    var labels: [string] = [
        "note",    "Note",          "remark",       "Note",         "remarks",    "Note",
        "warning", "Warning",       "attention",    "Warning",      "pre",        "Precondition",
        "post",    "Postcondition", "invariant",    "Invariant",    "deprecated", "Deprecated",
        "since",   "Since",         "availability", "Availability", "todo",       "TODO",
        "bug",     "Bug",           "safety",       "Safety",
    ]

    for var i: usize = 0; (i + 1) < labels.size(); i += 2 {
        if labels[i] == name {
            (*label) = labels[i + 1].copy()
            return EK_LABEL
        }
    }

    var drops: [string] = [
        "file",            "class",   "struct",    "union",       "enum",       "fn",
        "var",             "typedef", "namespace", "def",         "interface",  "protocol",
        "function",        "method",  "header",    "ingroup",     "defgroup",   "addtogroup",
        "weakgroup",       "name",    "internal",  "endinternal", "private",    "public",
        "protected",       "{",       "}",         "const",       "group",      "functiongroup",
        "updated",         "dir",     "page",      "mainpage",    "copydoc",    "nosubgrouping",
        "hideinitializer", "related", "relates",   "memberof",    "headerfile",
    ]

    for var i: usize = 0; i < drops.size(); ++i {
        if drops[i] == name {
            return EK_DROP
        }
    }

    return EK_NONE
}

/// The command a line starts with (`\param`, `@return`, `@{`): its name,
/// and in `after` the offset just past it. "" when the line starts with
/// none.
fn leading_command_(const t: string, after: *usize) -> string {
    (*after) = 0
    if (t.size() < 2) || ((t.data()[0] != ('\\' as u8)) && (t.data()[0] != ('@' as u8))) {
        return ""
    }

    if (t.data()[1] == ('{' as u8)) || (t.data()[1] == ('}' as u8)) {
        (*after) = 2
        return t.subslice(1, 1)
    }

    var e: usize = 1
    while (e < t.size()) && is_alpha_(t.data()[e]) {
        e += 1
    }

    if e == 1 {
        return ""
    }

    // `@inline(...)`, `@align(8)`: a Kairo attribute, not a command.
    if (t.data()[0] == ('@' as u8)) && (e < t.size()) && (t.data()[e] == ('(' as u8)) {
        return ""
    }

    if (e < t.size()) && is_ident_(t.data()[e]) {
        return ""
    }

    (*after) = e
    return t.subslice(1, e - 1)
}

/// True when `name` starts a block in the middle of a line too
/// (`/** \brief A. \param x B. */` is three blocks). `@` names are split
/// only for the commands HeaderDoc writes, so prose mentioning an
/// attribute stays whole.
fn splits_midline_(const name: string, at_sign: bool) -> bool {
    if at_sign {
        return (name == "param")
            || (name == "return")
            || (name == "returns")
            || (name == "result")
            || (name == "brief")
            || (name == "abstract")
            || (name == "discussion")
    }

    var l: string = ""
    var k         = block_kind_(name, &l)
    return (k != EK_NONE)
        && (k != EK_DROP)
        && (k != EK_CODE)
        && (k != EK_ITEM)
        && (name != "par")
        && (name != "example")
        && (name != "since")
        && (name != "li")
}

/// `ln` cut before each block command it holds after its start, outside
/// a code span.
fn split_midline_(const ln: string, out: *[string]) {
    var from: usize = 0
    var ticks       = 0
    for var i: usize = 1; i < ln.size(); ++i {
        if ln.data()[i] == ('`' as u8) {
            ticks += 1
            continue
        }

        if ((ticks % 2) != 0) || ((ln.data()[i] != ('\\' as u8)) && (ln.data()[i] != ('@' as u8))) {
            continue
        }

        if !is_ws_(ln.data()[i - 1]) {
            continue
        }

        var after: usize = 0
        var name         = leading_command_(rest_(ln, i), &after)
        if name.is_empty() || (!splits_midline_(name, ln.data()[i] == ('@' as u8))) {
            continue
        }

        var piece = trim_(ln.subslice(from, i - from))
        if !piece.is_empty() {
            out->push(piece)
        }

        from = i
    }

    if from == 0 {
        out->push(ln.copy())
    } else {
        out->push(trim_(rest_(ln, from)))
    }
}

/// True when some line of `lines` (outside a Markdown fence) starts with a
/// block command, or holds one after its start: the comment is Doxygen or
/// HeaderDoc, not Markdown.
fn has_block_command_(const lines: [string]) -> bool {
    var fence = false
    for var i: usize = 0; i < lines.size(); ++i {
        var t = trim_(lines[i])
        if t.starts_with("```") || t.starts_with("~~~") {
            fence = !fence
            continue
        }

        if fence {
            continue
        }

        var after: usize  = 0
        var label: string = ""
        var name          = leading_command_(t, &after)
        if (!name.is_empty()) && (block_kind_(name, &label) != EK_NONE) {
            return true
        }

        var parts: [string]
        split_midline_(t, &parts)
        if parts.size() > 1 {
            return true
        }
    }

    return false
}

/// `tok` with its trailing punctuation moved into `trail`: `\p x.` is
/// `` `x`. ``
fn split_trail_(const tok: string, trail: *string) -> string {
    var t = tok.copy()
    (*trail) = ""
    while (!t.is_empty()) {
        var c = t.data()[t.size() - 1]
        var close_paren = (c == (')' as u8)) && (count_(t, '(' as u8) < count_(t, ')' as u8))
        var close_brack = (c == (']' as u8)) && (count_(t, '[' as u8) < count_(t, ']' as u8))
        if (c == ('.' as u8))
            || (c == (',' as u8))
            || (c == (';' as u8))
            || (c == (':' as u8))
            || (c == ('!' as u8))
            || (c == ('?' as u8))
            || close_paren
            || close_brack {
            (*trail) = t.subslice(t.size() - 1, 1) + *trail
            t        = t.subslice(0, t.size() - 1)
            continue
        }

        break
    }

    if t.ends_with("'s") && (t.size() > 2) {
        (*trail) = "'s" + *trail
        t        = t.subslice(0, t.size() - 2)
    }

    return t
}

fn count_(const s: string, c: u8) -> usize {
    var n: usize = 0
    for var i: usize = 0; i < s.size(); ++i {
        if s.data()[i] == c {
            n += 1
        }
    }

    return n
}

/// `\p x`, `\c x`, `\a x`, `\ref x` as `` `x` ``, `\e x` / `\em x` as
/// `*x*`, `\b x` as `**x**`, in a stretch of text with no code span.
fn inline_plain_(const s: string) -> string {
    var out: string = ""
    var i:   usize  = 0
    while i < s.size() {
        var c = s.data()[i]
        if ((c == ('\\' as u8)) || (c == ('@' as u8)))
            && ((i == 0) || ((!is_ident_(s.data()[i - 1])) && (s.data()[i - 1] != ('\\' as u8)))) {
            var e = i + 1
            while (e < s.size()) && is_alpha_(s.data()[e]) {
                e += 1
            }

            var name          = s.subslice(i + 1, e - i - 1)
            var open:  string = ""
            var close: string = ""
            if (name == "p") || (name == "c") || (name == "a") || (name == "ref") {
                open  = "`"
                close = "`"
            } else if (name == "e") || (name == "em") {
                open  = "*"
                close = "*"
            } else if name == "b" {
                open  = "**"
                close = "**"
            }

            if (!open.is_empty())
                && (e < s.size())
                && ((s.data()[e] == (' ' as u8)) || (s.data()[e] == ('\t' as u8))) {
                var w0 = e
                while (w0 < s.size()) && is_ws_(s.data()[w0]) {
                    w0 += 1
                }

                var w1 = w0
                if (w1 < s.size()) && (s.data()[w1] == ('"' as u8)) {
                    w1 += 1
                    while (w1 < s.size()) && (s.data()[w1] != ('"' as u8)) {
                        w1 += 1
                    }

                    if w1 < s.size() {
                        w1 += 1
                    }
                } else {
                    while (w1 < s.size()) && (!is_ws_(s.data()[w1])) {
                        w1 += 1
                    }
                }

                var trail: string = ""
                var word = split_trail_(s.subslice(w0, w1 - w0), &trail)
                if word.starts_with("\"") && word.ends_with("\"") && (word.size() >= 2) {
                    word = word.subslice(1, word.size() - 2)
                }

                if !word.is_empty() {
                    out += open + word + close + trail
                    i = w1
                    continue
                }
            }
        }

        // `Box<T>` in prose: `<T>` reads as an HTML tag to a Markdown
        // renderer, which drops it. A `<` after a name is a bracket.
        if (c == ('<' as u8)) && (i > 0) && is_ident_(s.data()[i - 1]) {
            out += "\\<"
            i += 1
            continue
        }

        push_char_at(&out, s, i)
        i += 1
    }

    return out
}

/// inline_plain_ over the parts of `ln` outside code spans; `in_span`
/// carries a span that a line break cuts.
fn inline_line_(const ln: string, in_span: *bool) -> string {
    var out:   string = ""
    var piece: string = ""
    for var i: usize = 0; i < ln.size(); ++i {
        if ln.data()[i] == ('`' as u8) {
            if *in_span {
                out += piece
            } else {
                out += inline_plain_(piece)
            }

            piece = ""
            out.push('`')
            (*in_span) = !*in_span
            continue
        }

        push_char_at(&piece, ln, i)
    }

    if *in_span {
        out += piece
    } else {
        out += inline_plain_(piece)
    }

    return out
}

/// The inline commands of `lines`, outside fences and code spans.
fn inline_all_(const lines: [string]) -> [string] {
    var out:    [string]
    var fence            = false
    var in_span          = false
    for var i: usize = 0; i < lines.size(); ++i {
        var t = trim_(lines[i])
        if t.starts_with("```") || t.starts_with("~~~") {
            fence   = !fence
            in_span = false
            out.push(lines[i].copy())
            continue
        }

        if fence {
            out.push(lines[i].copy())
            continue
        }

        if t.is_empty() {
            in_span = false
        }

        out.push(inline_line_(lines[i], &in_span))
    }

    return out
}

fn push_par_(out: *[string], const lines: [string]) {
    if lines.is_empty() {
        return
    }

    if (!out->is_empty()) && (!(*out)[out->size() - 1].is_empty()) {
        out->push("")
    }

    for var i: usize = 0; i < lines.size(); ++i {
        out->push(lines[i].copy())
    }
}

/// An entry's lines as one Markdown block.
fn render_ent_(const e: Ent, cxx: bool) -> [string] {
    var out: [string]
    if (e.kind == EK_TEXT) || (e.kind == EK_BRIEF) || (e.kind == EK_RAW) || (e.kind == EK_RETURNS) {
        for var i: usize = 0; i < e.lines.size(); ++i {
            out.push(e.lines[i].copy())
        }
    } else if e.kind == EK_LABEL {
        var first = "**" + e.name + ":**"
        if (!e.lines.is_empty()) && (!e.lines[0].is_empty()) {
            first += " " + e.lines[0]
        }

        out.push(first)
        for var i: usize = 1; i < e.lines.size(); ++i {
            out.push(e.lines[i].copy())
        }
    } else if e.kind == EK_PAR {
        if !e.name.is_empty() {
            out.push("**" + e.name + "**")
        }

        for var i: usize = 0; i < e.lines.size(); ++i {
            out.push(e.lines[i].copy())
        }
    } else if e.kind == EK_ITEM {
        for var i: usize = 0; i < e.lines.size(); ++i {
            if i == 0 {
                out.push("- " + e.lines[i])
            } else {
                out.push("  " + e.lines[i])
            }
        }
    } else if e.kind == EK_SEE {
        var text: string = ""
        for var i: usize = 0; i < e.lines.size(); ++i {
            if i > 0 {
                text += " "
            }

            text += e.lines[i]
        }

        text = trim_(text)
        // A list of names (`\sa foo, bar::baz()`), or a sentence.
        var pieces: [string]
        var cur:    string   = ""
        for var i: usize = 0; i <= text.size(); ++i {
            if (i == text.size())
                || (text.data()[i] == (',' as u8))
                || (text.data()[i] == (' ' as u8)) {
                var p = trim_(cur)
                if p.ends_with(".") && (i == text.size()) {
                    p = p.subslice(0, p.size() - 1)
                }

                if !p.is_empty() {
                    pieces.push(p)
                }

                cur = ""
                continue
            }

            push_char_at(&cur, text, i)
        }

        var names = (pieces.size() > 0) && (pieces.size() <= 3)
        for var i: usize = 0; i < pieces.size(); ++i {
            var pc = pieces[i].copy()
            var ok = is_ident_(pc.data()[0])
                || (pc.data()[0] == ('`' as u8))
                || (pc.data()[0] == (':' as u8))
                || (pc.data()[0] == ('~' as u8))
            for var k: usize = 0; k < pc.size(); ++k {
                var c = pc.data()[k]
                if !(is_ident_(c)
                    || (c == (':' as u8))
                    || (c == ('(' as u8))
                    || (c == (')' as u8))
                    || (c == ('`' as u8))
                    || (c == ('~' as u8))
                    || (c == ('.' as u8))
                    || (c == ('#' as u8))) {
                    ok = false
                }
            }

            var stop: [string] = ["and", "or", "for", "the", "a", "an", "also", "in", "of", "to"]
            for var k: usize = 0; k < stop.size(); ++k {
                if pc == stop[k] {
                    ok = false
                }
            }

            names = names && ok
        }

        if text.is_empty() {
            return out
        }

        if names {
            var line = "See "
            for var i: usize = 0; i < pieces.size(); ++i {
                if i > 0 {
                    line += ", "
                }

                if pieces[i].starts_with("`") {
                    line += pieces[i]
                } else {
                    line += "`" + pieces[i] + "`"
                }
            }

            out.push(line + ".")
        } else {
            var line = "See " + text
            var last = line.data()[line.size() - 1]
            if (last != ('.' as u8)) && (last != ('!' as u8)) && (last != ('?' as u8)) {
                line += "."
            }

            out.push(line)
        }
    } else if e.kind == EK_CODE {
        var lang = e.name.copy()
        if lang.is_empty() {
            lang = if (cxx) => ("cpp") else => "kairo"
        }

        if lang == "-" {
            lang = ""
        }

        out.push("```" + lang)
        var body = dedent_(e.lines)
        for var i: usize = 0; i < body.size(); ++i {
            out.push(body[i].copy())
        }

        out.push("```")
    }

    return out
}

/// A `### Parameters`-style list: one `` - `name`: text `` item per entry.
fn render_items_(const ents: [Ent], kind: u8, const heading: string, out: *[string]) {
    var items: [string]
    for var i: usize = 0; i < ents.size(); ++i {
        if ents[i].kind != kind {
            continue
        }

        var head = "- `" + ents[i].name + "`"
        if !ents[i].dir.is_empty() {
            head += " (" + ents[i].dir + ")"
        }

        var first = true
        for var k: usize = 0; k < ents[i].lines.size(); ++k {
            if first {
                items.push(head.copy() + ": " + ents[i].lines[k])
                first = false
            } else {
                items.push("  " + ents[i].lines[k])
            }
        }

        if first {
            items.push(head)
        }
    }

    if items.is_empty() {
        return
    }

    var block: [string]
    block.push(heading.copy())
    for var i: usize = 0; i < items.size(); ++i {
        block.push(items[i].copy())
    }

    push_par_(out, block)
}

/// A comment's text (doc_comment_text) in the Markdown convention
/// (language/comments.mdx).
///
/// Markdown is returned as written. Doxygen and HeaderDoc commands become
/// the convention's forms: `\brief` / `@abstract` the summary, `\details` /
/// `@discussion` the detail, `\param[dir] name text` / `@param` a
/// `### Parameters` list (the direction in parentheses), `\tparam` a
/// `### Type parameters` list, `\return(s)` / `\result` / `@result` the
/// `### Returns` section, `\throw(s)` a `### Panics` list (`### Throws` for
/// C and C++, which throw), `\note`, `\warning`, `\pre`, `\post`,
/// `\invariant`, `\deprecated`, `\since`, `@availability` bold labels,
/// `\see` / `\sa` a `See` line, `\code` ... `\endcode` a fenced block
/// (`cpp` when `cxx`, else `kairo`, unless `\code{.lang}` names one), and
/// `\p` / `\c` / `\a` / `\ref` inline code. A command it does not know is
/// left as text.
pub fn doc_to_markdown(const raw: string, cxx: bool) -> string {
    var lines = split_lines_(raw)
    if !has_block_command_(lines) {
        return join_lines_(inline_all_(lines))
    }

    // One block command per line: `\brief A. \param x B.` is two.
    var cut:    [string]
    var in_code          = false
    var fence            = false
    for var i: usize = 0; i < lines.size(); ++i {
        var t = trim_(lines[i])
        if t.starts_with("```") || t.starts_with("~~~") {
            fence = !fence
        }

        var after: usize = 0
        var name         = leading_command_(t, &after)
        if (name == "code") || (name == "verbatim") {
            in_code = true
        }

        if (name == "endcode") || (name == "endverbatim") {
            in_code = false
        }

        if in_code || fence {
            cut.push(lines[i].copy())
        } else {
            split_midline_(lines[i], &cut)
        }
    }

    var ents:   [Ent]
    var tail:   [Ent]
    var in_tail       = false
    var cur           = usize::MAX // the entry a line continues
    var i:      usize = 0
    while i < cut.size() {
        var ln = cut[i].copy()
        var t  = trim_(ln)
        i += 1
        if t.starts_with("```") || t.starts_with("~~~") {
            var e = Ent{}
            e.kind = EK_RAW
            e.lines.push(ln.copy())
            while i < cut.size() {
                e.lines.push(cut[i].copy())
                var ct = trim_(cut[i])
                i += 1
                if ct.starts_with("```") || ct.starts_with("~~~") {
                    break
                }
            }

            if in_tail {
                tail.push(e)
            } else {
                ents.push(e)
            }

            cur = usize::MAX
            continue
        }

        if t.is_empty() {
            cur = usize::MAX
            continue
        }

        var after: usize  = 0
        var label: string = ""
        var name          = leading_command_(t, &after)
        var kind          = EK_NONE
        if !name.is_empty() {
            kind = block_kind_(name, &label)
        }

        if kind == EK_NONE {
            var text = if (cur == usize::MAX) => (ln.copy()) else => trim_(ln)
            if cur == usize::MAX {
                var e = Ent{}
                e.kind = EK_TEXT
                e.lines.push(text)
                if in_tail {
                    tail.push(e)
                    cur = tail.size() - 1
                } else {
                    ents.push(e)
                    cur = ents.size() - 1
                }
            } else if in_tail {
                tail[cur].lines.push(text)
            } else {
                ents[cur].lines.push(text)
            }

            continue
        }

        var rest = trim_(rest_(t, after))
        if kind == EK_DROP {
            cur = usize::MAX
            continue
        }

        if kind == EK_EXAMPLE {
            in_tail = true
            cur     = usize::MAX
            continue
        }

        var e = Ent{}
        e.kind = kind
        e.name = label.copy()
        if kind == EK_CODE {
            // `\code{.cpp}`: the block's language.
            if rest.starts_with("{") {
                var close = find_(rest, "}", 0)
                if close != usize::MAX {
                    var l = trim_(rest.subslice(1, close - 1))
                    if l.starts_with(".") {
                        l = rest_(l, 1)
                    }

                    e.name = l
                }
            } else if name == "verbatim" {
                e.name = "-"
            }

            while i < cut.size() {
                var ct        = trim_(cut[i])
                var a2: usize = 0
                var n2        = leading_command_(ct, &a2)
                i += 1
                if (n2 == "endcode") || (n2 == "endverbatim") {
                    break
                }

                e.lines.push(cut[i - 1].copy())
            }

            if in_tail {
                tail.push(e)
            } else {
                ents.push(e)
            }

            cur = usize::MAX
            continue
        }

        if (kind == EK_PARAM) || (kind == EK_TPARAM) || (kind == EK_THROWS) {
            if rest.starts_with("[") {
                var close = find_(rest, "]", 0)
                if close != usize::MAX {
                    e.dir = trim_(rest.subslice(1, close - 1))
                    var d2: string = ""
                    for var k: usize = 0; k < e.dir.size(); ++k {
                        if e.dir.data()[k] != (' ' as u8) {
                            push_char_at(&d2, e.dir, k)
                        }
                    }

                    e.dir = if (d2 == "in,out") => ("in, out") else => d2
                    rest  = trim_(rest_(rest, close + 1))
                }
            }

            var w = 0 as usize
            while (w < rest.size()) && (!is_ws_(rest.data()[w])) {
                w += 1
            }

            e.name = rest.subslice(0, w)
            if e.name.ends_with(":") {
                e.name = e.name.subslice(0, e.name.size() - 1)
            }

            rest = trim_(rest_(rest, w))
            // `\param x - the value`, `@param x: the value`
            if rest.starts_with("- ") || rest.starts_with(": ") {
                rest = trim_(rest_(rest, 2))
            }
        } else if kind == EK_PAR {
            e.name = rest.copy()
            rest   = ""
        }

        if !rest.is_empty() {
            e.lines.push(rest)
        } else if (kind == EK_LABEL) || (kind == EK_PAR) {
            e.lines.push("")
        }

        if in_tail {
            tail.push(e)
            cur = tail.size() - 1
        } else {
            ents.push(e)
            cur = ents.size() - 1
        }
    }

    var out: [string]
    for var k: usize = 0; k < ents.size(); ++k {
        if ents[k].kind == EK_BRIEF {
            push_par_(&out, render_ent_(ents[k], cxx))
        }
    }

    for var k: usize = 0; k < ents.size(); ++k {
        var kd = ents[k].kind
        if (kd != EK_BRIEF)
            && (kd != EK_PARAM)
            && (kd != EK_TPARAM)
            && (kd != EK_RETURNS)
            && (kd != EK_THROWS) {
            push_par_(&out, render_ent_(ents[k], cxx))
        }
    }

    render_items_(ents, EK_TPARAM, "### Type parameters", &out)
    render_items_(ents, EK_PARAM, "### Parameters", &out)
    var ret: [string]
    for var k: usize = 0; k < ents.size(); ++k {
        if ents[k].kind == EK_RETURNS {
            if !ret.is_empty() {
                ret.push("")
            }

            for var q: usize = 0; q < ents[k].lines.size(); ++q {
                ret.push(ents[k].lines[q].copy())
            }
        }
    }

    if !ret.is_empty() {
        var block: [string]
        block.push("### Returns")
        for var q: usize = 0; q < ret.size(); ++q {
            block.push(ret[q].copy())
        }

        push_par_(&out, block)
    }

    render_items_(
        ents,
        EK_THROWS,
        if (cxx) => ("### Throws") else => "### Panics",
        &out,
    )

    if !tail.is_empty() {
        var block: [string]
        block.push("### Example")
        push_par_(&out, block)
        for var k: usize = 0; k < tail.size(); ++k {
            var r = render_ent_(tail[k], cxx)
            if k == 0 {
                for var q: usize = 0; q < r.size(); ++q {
                    out.push(r[q].copy())
                }
            } else {
                push_par_(&out, r)
            }
        }
    }

    // Prose outside the `\code` blocks: the inline commands.
    return join_lines_(inline_all_(out))
}

// --- reading it back -----------------------------------------------------------

/// `md` as plain text, for a client that takes no Markdown: fences, `###`,
/// bold and code-span marks removed, an escaped `\<` unescaped.
pub fn markdown_to_plain(const md: string) -> string {
    var lines          = split_lines_(md)
    var out:  [string]
    var fence          = false
    for var i: usize = 0; i < lines.size(); ++i {
        var t = trim_(lines[i])
        if t.starts_with("```") || t.starts_with("~~~") {
            fence = !fence
            continue
        }

        if fence {
            out.push(lines[i].copy())
            continue
        }

        var ln = lines[i].copy()
        if t.starts_with("#") {
            var h: usize = 0
            while (h < t.size()) && (t.data()[h] == ('#' as u8)) {
                h += 1
            }

            ln = trim_(rest_(t, h)) + ":"
        }

        var plain: string = ""
        var k:     usize  = 0
        while k < ln.size() {
            if (ln.data()[k] == ('*' as u8))
                && ((k + 1) < ln.size())
                && (ln.data()[k + 1] == ('*' as u8)) {
                k += 2
                continue
            }

            if ln.data()[k] == ('`' as u8) {
                k += 1
                continue
            }

            if (ln.data()[k] == ('\\' as u8))
                && ((k + 1) < ln.size())
                && (ln.data()[k + 1] == ('<' as u8)) {
                k += 1
                continue
            }

            push_char_at(&plain, ln, k)
            k += 1
        }

        out.push(plain)
    }

    return join_lines_(out)
}

/// The text of `name`'s item in the `### Parameters` section of `md`
/// (`` - `name`: text ``, its continuation lines joined to it), or of the
/// `### Type parameters` section when `tparams`. "" when it has none.
pub fn param_doc(const md: string, const name: string, tparams: bool) -> string {
    var want          = if (tparams) => ("### Type parameters") else => "### Parameters"
    var lines         = split_lines_(md)
    var in_sec        = false
    var fence         = false
    var out:   string = ""
    var taking        = false
    for var i: usize = 0; i < lines.size(); ++i {
        var t = trim_(lines[i])
        if t.starts_with("```") {
            fence = !fence
        }

        if fence {
            taking = false
            continue
        }

        if t.starts_with("#") {
            in_sec = t == want
            taking = false
            continue
        }

        if !in_sec {
            continue
        }

        if lines[i].starts_with("- ") {
            if taking {
                break
            }

            var head = "- `" + name + "`"
            if lines[i].starts_with(head) {
                var r = rest_(lines[i], head.size())
                if r.starts_with(" (") {
                    var close = find_(r, ")", 0)
                    if close != usize::MAX {
                        out = r.subslice(1, close) + " "
                        r   = rest_(r, close + 1)
                    }
                }

                if r.starts_with(":") || r.is_empty() {
                    out += trim_(rest_(r, 1))
                    taking = true
                }
            }

            continue
        }

        if taking {
            if t.is_empty() {
                break
            }

            out += " " + t
        }
    }

    return trim_(out)
}

/// The name a parameter is declared with, from its text in a signature:
/// the name before the `:` (`const s: string`, `@inout x: T`,
/// `...args: A`), or for a C-style one without a `:` the last name
/// (`int count`). "" for `self` and for none.
pub fn param_name_of(const piece_in: string) -> string {
    var piece      = trim_(piece_in)
    var eq         = usize::MAX
    var depth: i64 = 0
    var colon      = usize::MAX
    for var i: usize = 0; i < piece.size(); ++i {
        var c = piece.data()[i]
        if (c == ('(' as u8)) || (c == ('[' as u8)) || (c == ('<' as u8)) || (c == ('{' as u8)) {
            depth += 1
        } else if ((c == (')' as u8))
            || (c == (']' as u8))
            || (c == ('>' as u8))
            || (c == ('}' as u8)))
            && (depth > 0) {
            depth -= 1
        } else if (c == (':' as u8)) && (depth == 0) && (colon == usize::MAX) {
            var dbl = (((i + 1) < piece.size()) && (piece.data()[i + 1] == (':' as u8)))
                || ((i > 0) && (piece.data()[i - 1] == (':' as u8)))
            if !dbl {
                colon = i
            }
        } else if (c == ('=' as u8)) && (depth == 0) && (eq == usize::MAX) {
            eq = i
        }
    }

    var end = piece.size()
    if colon != usize::MAX {
        end = colon
    } else if eq != usize::MAX {
        end = eq
    }

    var e = end
    while (e > 0) && is_ws_(piece.data()[e - 1]) {
        e -= 1
    }

    if (e > 0) && (piece.data()[e - 1] == (']' as u8)) && (colon == usize::MAX) {
        // `int a[4]`
        while (e > 0) && (piece.data()[e - 1] != ('[' as u8)) {
            e -= 1
        }

        if e > 0 {
            e -= 1
        }
    }

    var b = e
    while (b > 0) && is_ident_(piece.data()[b - 1]) {
        b -= 1
    }

    var nm = piece.subslice(b, e - b)
    if nm == "self" {
        return ""
    }

    return nm
}

// --- a declaration's head, for the stub and the headings -----------------------

/// What a documentation stub needs from a declaration: read from its text.
pub struct DeclHead {
    var ok:      bool     = false
    var kind:    string   = "" ///< `fn`, `class`, `struct`, `enum`, `union`, `interface`, `type`
    var name:    string   = ""
    var params:  [string] ///< names, `self` left out
    var tparams: [string]
    var returns: bool     = false ///< `-> T` with `T` not `void`
    var panics:  bool     = false ///< a `panic` specifier
    var first:   usize    = 0 ///< where its first line starts (its attributes', when it has them)
    var head:    usize    = 0 ///< where the line with its keyword starts
    var indent:  string   = ""
}

fn skip_ws_nl_(const text: string, p: usize) -> usize {
    var q = p
    while (q < text.size()) && (is_ws_(text.data()[q]) || (text.data()[q] == ('\n' as u8))) {
        q += 1
    }

    return q
}

fn skip_ws_(const text: string, p: usize) -> usize {
    var q = p
    while (q < text.size()) && is_ws_(text.data()[q]) {
        q += 1
    }

    return q
}

/// One past the bracket that closes the one at `open` (`(`, `<`, `[`,
/// `{`), counting every kind; `->` is not a closing angle. text.size()
/// when it does not close.
fn close_of_(const text: string, open: usize) -> usize {
    var depth: i64 = 0
    var p          = open
    while p < text.size() {
        var c = text.data()[p]
        if (c == ('(' as u8)) || (c == ('<' as u8)) || (c == ('[' as u8)) || (c == ('{' as u8)) {
            depth += 1
        } else if (c == (')' as u8))
            || (c == (']' as u8))
            || (c == ('}' as u8))
            || ((c == ('>' as u8)) && (!((p > 0) && (text.data()[p - 1] == ('-' as u8))))) {
            depth -= 1
            if depth == 0 {
                return p + 1
            }
        }

        p += 1
    }

    return text.size()
}

/// The top-level comma-separated pieces of `text[from, to)`.
fn pieces_(const text: string, from: usize, to: usize) -> [string] {
    var out:   [string]
    var depth: i64      = 0
    var start           = from
    for var p: usize = from; p <= to; ++p {
        if p == to {
            var s = trim_(text.subslice(start, p - start))
            if !s.is_empty() {
                out.push(s)
            }

            break
        }

        var c = text.data()[p]
        if (c == ('(' as u8)) || (c == ('<' as u8)) || (c == ('[' as u8)) || (c == ('{' as u8)) {
            depth += 1
        } else if ((c == (')' as u8))
            || (c == (']' as u8))
            || (c == ('}' as u8))
            || ((c == ('>' as u8)) && (!((p > 0) && (text.data()[p - 1] == ('-' as u8))))))
            && (depth > 0) {
            depth -= 1
        } else if (c == (',' as u8)) && (depth == 0) {
            var s = trim_(text.subslice(start, p - start))
            if !s.is_empty() {
                out.push(s)
            }

            start = p + 1
        }
    }

    return out
}

/// A type parameter's name: `T`, `U impl Hash`, `...A`, `N: usize`.
fn tparam_name_(const piece: string) -> string {
    var p: usize = 0
    while (p < piece.size()) && (!is_ident_(piece.data()[p])) {
        p += 1
    }

    var e = p
    while (e < piece.size()) && is_ident_(piece.data()[e]) {
        e += 1
    }

    var nm = piece.subslice(p, e - p)
    if (nm == "const") || (nm == "eval") {
        return tparam_name_(rest_(piece, e))
    }

    return nm
}

fn word_at_(const text: string, p: usize) -> string {
    var e = p
    while (e < text.size()) && is_ident_(text.data()[e]) {
        e += 1
    }

    return text.subslice(p, e - p)
}

/// The declaration whose first line (attribute lines included) starts at
/// `ls`, read from the text: what kind it is, its name, its parameters
/// and type parameters, whether it returns a value and declares panics.
/// `ok` is false when the line starts no function, method, class, struct,
/// enum, union, interface or type alias.
pub fn decl_head(const text: string, ls: usize) -> DeclHead {
    var h = DeclHead{}
    h.first = ls
    var p = skip_ws_(text, ls)
    h.indent = text.subslice(ls, p - ls)
    var limit = ls + 4000
    if limit > text.size() {
        limit = text.size()
    }

    // Attributes (`@inline`, `@align(8)`), on this line or lines of their own.
    while (p < limit) && (text.data()[p] == ('@' as u8)) {
        p += 1
        while (p < limit) && (is_ident_(text.data()[p]) || (text.data()[p] == (':' as u8))) {
            p += 1
        }

        if (p < limit) && (text.data()[p] == ('(' as u8)) {
            p = close_of_(text, p)
        }

        p = skip_ws_nl_(text, p)
    }

    var mods: [string] = [
        "pub",  "priv",  "prot",   "static", "virtual",  "override", "final",  "inline",
        "eval", "async", "unsafe", "extern", "abstract", "const",    "export",
    ]

    var kw: string = ""
    while p < limit {
        var w = word_at_(text, p)
        if w.is_empty() {
            return h
        }

        var is_mod = false
        for var i: usize = 0; i < mods.size(); ++i {
            if mods[i] == w {
                is_mod = true
            }
        }

        if is_mod {
            p = skip_ws_(text, p + w.size())
            continue
        }

        if (w == "fn")
            || (w == "class")
            || (w == "struct")
            || (w == "enum")
            || (w == "union")
            || (w == "interface")
            || (w == "type") {
            kw = w.copy()
            p  = p + w.size()
        }

        break
    }

    if kw.is_empty() {
        return h
    }

    h.head = line_start_(text, p)
    h.kind = kw.copy()
    p      = skip_ws_(text, p)
    // `fn <T> name`, `class <T> Box`, `type <T> Matrix`
    if (p < limit) && (text.data()[p] == ('<' as u8)) {
        var e   = close_of_(text, p)
        var tps = pieces_(text, p + 1, e - 1)
        for var i: usize = 0; i < tps.size(); ++i {
            var nm = tparam_name_(tps[i])
            if !nm.is_empty() {
                h.tparams.push(nm)
            }
        }

        p = skip_ws_(text, e)
    }

    var ns = p
    if word_at_(text, p) == "op" {
        // `fn op + (self, ...)`, `fn op [] (...)`: the name runs to the `(`.
        while (p < limit) && (text.data()[p] != ('(' as u8)) && (text.data()[p] != ('\n' as u8)) {
            p += 1
        }

        h.name = trim_(text.subslice(ns, p - ns))
    } else {
        while (p < limit) && (is_ident_(text.data()[p]) || (text.data()[p] == (':' as u8))) {
            p += 1
        }

        h.name = text.subslice(ns, p - ns)
    }

    if h.name.is_empty() {
        return h
    }

    h.ok = true
    if kw != "fn" {
        return h
    }

    p = skip_ws_(text, p)
    if (p >= limit) || (text.data()[p] != ('(' as u8)) {
        return h
    }

    var pe = close_of_(text, p)
    var ps = pieces_(text, p + 1, pe - 1)
    for var i: usize = 0; i < ps.size(); ++i {
        var nm = param_name_of(ps[i])
        if !nm.is_empty() {
            h.params.push(nm)
        }
    }

    // After the parameters, to the body or the end of the line: the
    // modifiers (`panic`, `panic(E)`), the return type.
    p = pe
    while (p < limit) && (text.data()[p] != ('\n' as u8)) && (text.data()[p] != ('{' as u8)) {
        if is_ident_(text.data()[p]) {
            var w = word_at_(text, p)
            if (w == "where") || (w == "requires") {
                break
            }

            if (w == "panic") && ((p == 0) || (!is_ident_(text.data()[p - 1]))) {
                h.panics = true
            }

            p += w.size()
            continue
        }

        if (text.data()[p] == ('-' as u8))
            && ((p + 1) < limit)
            && (text.data()[p + 1] == ('>' as u8)) {
            var r = skip_ws_(text, p + 2)
            var w = word_at_(text, r)
            h.returns = (w != "void")
                && (r < limit)
                && (text.data()[r] != ('{' as u8))
                && (text.data()[r] != ('\n' as u8))
            p = r
            continue
        }

        if (text.data()[p] == ('=' as u8))
            && (((p + 1) >= limit) || (text.data()[p + 1] != ('=' as u8))) {
            break // `= default`, an expression body
        }

        p += 1
    }

    return h
}

/// Escapes `$`, `}` and `\` for a snippet's literal text.
fn snippet_text_(const s: string) -> string {
    var out: string = ""
    for var i: usize = 0; i < s.size(); ++i {
        if (s.data()[i] == ('$' as u8))
            || (s.data()[i] == ('}' as u8))
            || (s.data()[i] == ('\\' as u8)) {
            out.push('\\')
        }

        push_char_at(&out, s, i)
    }

    return out
}

/// The documentation stub for `h`, one `///` line each (no indentation): a
/// summary placeholder, a blank `///`, then the sections that apply (type
/// parameters, parameters, what it returns, what it panics with). With
/// `snippet`, the placeholders are tab stops of an LSP snippet.
pub fn doc_stub(const h: DeclHead, snippet: bool) -> [string] {
    var out:  [string]
    var stop: usize    = 1
    var ph = fn (n: usize, const text: string, snip: bool) -> string {
        if !snip {
            return text.copy()
        }

        if text.is_empty() {
            return "$" + f"{n}"
        }

        return "${" + f"{n}" + ":" + text + "}"
    }

    out.push("/// " + ph(stop, "Summary.", snippet))
    stop += 1
    var sec = fn (out: *[string], const title: string) {
        out->push("///")
        out->push("/// ### " + title)
    }

    if !h.tparams.is_empty() {
        sec(&out, "Type parameters")
        for var i: usize = 0; i < h.tparams.size(); ++i {
            var nm = if (snippet) => (snippet_text_(h.tparams[i])) else => h.tparams[i].copy()
            if snippet {
                out.push("/// - `" + nm + "`: " + ph(stop, "", true))
                stop += 1
            } else {
                out.push("/// - `" + nm + "`:")
            }
        }
    }

    if !h.params.is_empty() {
        sec(&out, "Parameters")
        for var i: usize = 0; i < h.params.size(); ++i {
            var nm = if (snippet) => (snippet_text_(h.params[i])) else => h.params[i].copy()
            if snippet {
                out.push("/// - `" + nm + "`: " + ph(stop, "", true))
                stop += 1
            } else {
                out.push("/// - `" + nm + "`:")
            }
        }
    }

    if h.returns {
        sec(&out, "Returns")
        out.push("/// " + ph(stop, "What it returns.", snippet))
        stop += 1
    }

    if h.panics {
        sec(&out, "Panics")
        out.push(
            "/// " + ph(stop, "Each panic type and when it is raised.", snippet),
        )

        stop += 1
    }

    return out
}

/// The section headings that fit `h`, in the convention's order, leaving
/// out those in `present`: `### Type parameters` for a generic,
/// `### Parameters` when it has parameters, `### Returns` when it returns
/// a value, `### Panics` when it declares panics, `### Example` always.
pub fn headings_for(const h: DeclHead, const present: [string]) -> [string] {
    var out: [string]
    var all: [string] = [
        "### Type parameters",
        "### Parameters",
        "### Returns",
        "### Panics",
        "### Example",
    ]

    var fits: [bool] = [!h.tparams.is_empty(), !h.params.is_empty(), h.returns, h.panics, true]
    for var i: usize = 0; i < all.size(); ++i {
        var have = false
        for var k: usize = 0; k < present.size(); ++k {
            if present[k] == all[i] {
                have = true
            }
        }

        if fits[i] && (!have) {
            out.push(all[i].copy())
        }
    }

    return out
}

/// The convention's inline labels.
pub fn inline_labels() -> [string] {
    return [
        "**Note:**",
        "**Warning:**",
        "**Precondition:**",
        "**Postcondition:**",
        "**Invariant:**",
    ]
}

// --- tests -------------------------------------------------------------------

fn check_(const what: string, const got: string, const want: string) -> i32 {
    if got == want {
        return 0
    }

    io::println(f"FAIL: {what}")
    io::println("--- want")
    io::println(want)
    io::println("--- got")
    io::println(got)
    return 1
}

/// The Markdown of the declaration that follows `src` (a header's text
/// ending with the declaration's line).
fn md_of_(const src: string, cxx: bool) -> string {
    var at = src.size()
    if (at > 0) && (src.data()[at - 1] == ('\n' as u8)) {
        at -= 1
    }

    return doc_markdown_at(src, line_start_(src, at), cxx)
}

pub fn Test() -> i32 {
    var errors = 0

    // Kairo Markdown is returned as written.
    var kmd = "/// Splits `s` at each occurrence of `sep`.\n"
        "///\n"
        "/// Adjacent separators produce empty pieces. An `@inout` parameter\n"
        "/// or `@deprecated` in prose stays as written.\n"
        "///\n"
        "/// ### Parameters\n"
        "/// - `s`: the text to split\n"
        "/// - `sep`: the separator\n"
        "///\n"
        "/// ### Example\n"
        "/// ```kairo\n"
        "/// @inline fn f() {}\n"
        "/// ```\n"
        "fn split(const s: string, const sep: string) -> [string] {\n"
    errors += check_(
        "Kairo Markdown passes through",
        md_of_(kmd, false),
        "Splits `s` at each occurrence of `sep`.\n\nAdjacent separators produce empty pieces. An `@inout` parameter\n"
            "or `@deprecated` in prose stays as written.\n\n### Parameters\n- `s`: the text to split\n"
            "- `sep`: the separator\n\n### Example\n```kairo\n@inline fn f() {}\n```",
    )

    errors += check_(
        "an attribute line between the comment and the declaration",
        md_of_("/// Bumps.\n@inline\npub fn bump(self)\n", false),
        "Bumps.",
    )

    errors += check_(
        "a license banner is not documentation",
        md_of_(
            "/// --- The Kairo Project --- ///\n///\n///   x\nfn f()\n",
            false,
        ),
        "",
    )

    errors += check_(
        "a trailing ///< documents the declaration in front of it",
        md_of_("enum Mode {\n    Read,   ///< open for reading\n", false),
        "open for reading",
    )

    errors += check_(
        "a ///< line above belongs to the declaration before",
        md_of_(
            "    Read,   ///< open for reading\n    ///< more on Read\n    Write,\n",
            false,
        ),
        "",
    )

    errors += check_(
        "a /** */ block in Kairo",
        md_of_(
            "/**\n * A growable buffer of bytes.\n */\nclass Buffer {\n",
            false,
        ),
        "A growable buffer of bytes.",
    )

    errors += check_(
        "a plain // comment is not documentation",
        md_of_("// helper\nfn f()\n", false),
        "",
    )

    // --- Doxygen from LLVM headers (llvm/Support/Program.h, ADT/StringRef.h,
    // ADT/STLExtras.h, ADT/Bitfields.h, ADT/MapVector.h, ADT/RadixTree.h,
    // Support/CommandLine.h, ADT/CoalescingBitVector.h)
    errors += check_(
        "LLVM 1: \\p inline and \\param / \\returns sections",
        md_of_(
            "/// Find the first executable file \\p Name in \\p Paths.\n"
            "///\n"
            "/// This does not perform hashing as a shell would but instead stats each PATH\n"
            "/// entry individually so should generally be avoided.\n"
            "///\n"
            "/// \\param Name name of the executable to find. If it contains any system\n"
            "///   slashes, it will be returned as is.\n"
            "/// \\param Paths optional list of paths to search for \\p Name. If empty it\n"
            "///   will use the system PATH environment instead.\n"
            "///\n"
            "/// \\returns The fully qualified path to the first \\p Name in \\p Paths if it\n"
            "///   exists. \\p Name if \\p Name has slashes in it. Otherwise an error.\n"
            "LLVM_ABI ErrorOr<std::string> findProgramByName(StringRef Name,\n",
            true,
        ),
        "Find the first executable file `Name` in `Paths`.\n\n"
            "This does not perform hashing as a shell would but instead stats each PATH\n"
            "entry individually so should generally be avoided.\n\n"
            "### Parameters\n"
            "- `Name`: name of the executable to find. If it contains any system\n"
            "  slashes, it will be returned as is.\n"
            "- `Paths`: optional list of paths to search for `Name`. If empty it\n"
            "  will use the system PATH environment instead.\n\n"
            "### Returns\n"
            "The fully qualified path to the first `Name` in `Paths` if it\n"
            "exists. `Name` if `Name` has slashes in it. Otherwise an error.",
    )

    errors += check_(
        "LLVM 2: \\returns after a paragraph",
        md_of_(
            "/// This function executes the program using the arguments provided.\n"
            "/// This function waits for the program to finish.\n"
            "/// \\returns an integer result code indicating the status of the program.\n"
            "/// -1 indicates failure to execute\n"
            "LLVM_ABI int ExecuteAndWait(\n",
            true,
        ),
        "This function executes the program using the arguments provided.\n"
            "This function waits for the program to finish.\n\n"
            "### Returns\nan integer result code indicating the status of the program.\n"
            "-1 indicates failure to execute",
    )

    errors += check_(
        "LLVM 3: a [[nodiscard]] declaration, \\param with \\p",
        md_of_(
            "  /// Return a reference to the substring from [Start, Start + N).\n"
            "  ///\n"
            "  /// \\param Start The index of the starting character in the substring.\n"
            "  ///\n"
            "  /// \\param N The number of characters to included in the substring. The\n"
            "  /// suffix (starting with \\p Start) will be returned.\n"
            "  [[nodiscard]] constexpr StringRef substr(size_t Start,\n",
            true,
        ),
        "Return a reference to the substring from [Start, Start + N).\n\n"
            "### Parameters\n"
            "- `Start`: The index of the starting character in the substring.\n"
            "- `N`: The number of characters to included in the substring. The\n"
            "  suffix (starting with `Start`) will be returned.",
    )

    errors += check_(
        "LLVM 4: \\code ... \\endcode is a cpp block, a template line is stepped over",
        md_of_(
            "/// An iterator adaptor that filters the elements of given inner iterators.\n"
            "///\n"
            "/// \\code\n"
            "///   int A[] = { 1, 2, 3, 4 };\n"
            "///   auto R = make_filter_range(A, [](int N) { return N % 2 == 1; });\n"
            "/// \\endcode\n"
            "///\n"
            "/// Note: filter_iterator_base implements support for forward iteration.\n"
            "template <typename WrappedIteratorT, typename PredicateT, typename IterTag>\n"
            "class filter_iterator_base\n",
            true,
        ),
        "An iterator adaptor that filters the elements of given inner iterators.\n\n"
            "```cpp\nint A[] = { 1, 2, 3, 4 };\nauto R = make_filter_range(A, [](int N) { return N % 2 == 1; });\n```\n\n"
            "Note: filter_iterator_base implements support for forward iteration.",
    )

    errors += check_(
        "LLVM 5: aligned \\tparam items",
        md_of_(
            "  /// Describes an element of a Bitfield.\n"
            "  /// \\tparam T         The type of the field once in unpacked form.\n"
            "  /// \\tparam Offset    The position of the first bit.\n"
            "  template <typename T, unsigned Offset>\n"
            "  struct Element {\n",
            true,
        ),
        "Describes an element of a Bitfield.\n\n"
            "### Type parameters\n"
            "- `T`: The type of the field once in unpacked form.\n"
            "- `Offset`: The position of the first bit.",
    )

    errors += check_(
        "LLVM 6: \\note with \\a, continuation aligned",
        md_of_(
            "  /// Remove the element given by Iterator.\n"
            "  ///\n"
            "  /// \\note This is a deceivingly expensive operation (linear time).  It's\n"
            "  /// usually better to use \\a remove_if() if possible.\n"
            "  typename VectorType::iterator erase(typename VectorType::iterator Iterator) {\n",
            true,
        ),
        "Remove the element given by Iterator.\n\n"
            "**Note:** This is a deceivingly expensive operation (linear time).  It's\n"
            "usually better to use `remove_if()` if possible.",
    )

    errors += check_(
        "LLVM 7: \\param[in] / \\param[out] and \\return",
        md_of_(
            "  /// Looks for the specified configuration file.\n"
            "  ///\n"
            "  /// \\param[in]  FileName Name of the file to search for.\n"
            "  /// \\param[out] FilePath File absolute path, if it was found.\n"
            "  /// \\return True if file was found.\n"
            "  bool findConfigFile(StringRef FileName, SmallVectorImpl<char> &FilePath);\n",
            true,
        ),
        "Looks for the specified configuration file.\n\n"
            "### Parameters\n"
            "- `FileName` (in): Name of the file to search for.\n"
            "- `FilePath` (out): File absolute path, if it was found.\n\n"
            "### Returns\nTrue if file was found.",
    )

    errors += check_(
        "LLVM 8: \\tparam with a dash, a class template",
        md_of_(
            "/// Compared to SparseBitVector, CoalescingBitVector offers more predictable\n"
            "/// performance for non-sequential find() operations.\n"
            "///\n"
            "/// \\tparam IndexT - The type of the index into the bitvector.\n"
            "template <typename IndexT> class CoalescingBitVector {\n",
            true,
        ),
        "Compared to SparseBitVector, CoalescingBitVector offers more predictable\n"
            "performance for non-sequential find() operations.\n\n"
            "### Type parameters\n- `IndexT`: The type of the index into the bitvector.",
    )

    errors += check_(
        "LLVM 9: a \\note on a line of its own, a \\code block first",
        md_of_(
            "/// A radix tree.\n"
            "///\n"
            "/// \\code\n"
            "///   for (const auto &[Key, Value] : Tree)\n"
            "///     llvm::outs() << Key;\n"
            "/// \\endcode\n"
            "///\n"
            "/// \\note\n"
            "/// The `RadixTree` takes ownership of the `KeyType` and `T` objects.\n"
            "template <typename KeyType, typename T> class RadixTree {\n",
            true,
        ),
        "A radix tree.\n\n"
            "```cpp\nfor (const auto &[Key, Value] : Tree)\n  llvm::outs() << Key;\n```\n\n"
            "**Note:**\nThe `RadixTree` takes ownership of the `KeyType` and `T` objects.",
    )

    errors += check_(
        "LLVM 10: a parameter's ///< below is not the function's",
        doc_markdown_at(
            "LLVM_ABI int ExecuteAndWait(\n"
            "    StringRef Program, ///< Path of the program to be executed. It is\n"
            "    ///< presumed this is the result of the findProgramByName method.\n",
            0,
            true,
        ),
        "",
    )

    errors += check_(
        "LLVM 10b: the trailing comment, read from the parameter's own line",
        doc_markdown_at(
            "    StringRef Program, ///< Path of the program to be executed. It is\n"
            "    ///< presumed this is the result of \\p findProgramByName.\n",
            0,
            true,
        ),
        "Path of the program to be executed. It is\npresumed this is the result of `findProgramByName`.",
    )

    errors += check_(
        "Doxygen 1 (written for the test): \\brief mid-line, \\sa, \\deprecated, \\warning, std::vector<int> in prose",
        md_of_(
            "/** \\brief Packs the bits. \\sa unpack\n"
            " *\n"
            " * Takes a std::vector<int> of flags.\n"
            " * \\deprecated Use pack2 instead.\n"
            " * \\warning Not thread-safe.\n"
            " * \\throws std::bad_alloc when out of memory\n"
            " */\n"
            "int pack(int flags);\n",
            true,
        ),
        "Packs the bits.\n\nSee `unpack`.\n\nTakes a std::vector\\<int> of flags.\n\n"
            "**Deprecated:** Use pack2 instead.\n\n**Warning:** Not thread-safe.\n\n"
            "### Throws\n- `std::bad_alloc`: when out of memory",
    )

    // --- HeaderDoc
    errors += check_(
        "HeaderDoc 1: @abstract, @discussion, @param, @result",
        md_of_(
            "/*!\n"
            "  @function CFArrayGetCount\n"
            "  @abstract Returns the number of values in the array.\n"
            "  @discussion Counts every value, including duplicates.\n"
            "  @param theArray The array to examine.\n"
            "  @result The number of values in the array.\n"
            "*/\n"
            "CFIndex CFArrayGetCount(CFArrayRef theArray);\n",
            true,
        ),
        "Returns the number of values in the array.\n\nCounts every value, including duplicates.\n\n"
            "### Parameters\n- `theArray`: The array to examine.\n\n### Returns\nThe number of values in the array.",
    )

    errors += check_(
        "Doxygen 2: //! lines with @brief and @return",
        md_of_(
            "//! @brief Opens a stream.\n"
            "//! @param path where it is\n"
            "//! @return the stream, or null\n"
            "Stream *open_stream(const char *path);\n",
            true,
        ),
        "Opens a stream.\n\n### Parameters\n- `path`: where it is\n\n### Returns\nthe stream, or null",
    )

    errors += check_(
        "HeaderDoc 3: @availability, @c, a @class tag dropped",
        md_of_(
            "/*!\n"
            " * @class Cache\n"
            " * @abstract A cache of @c Entry values.\n"
            " * @availability macOS 10.4 and later.\n"
            " */\n"
            "class Cache {\n",
            true,
        ),
        "A cache of `Entry` values.\n\n**Availability:** macOS 10.4 and later.",
    )

    errors += check_(
        "Doxygen 3: \\code{.c} names its language, \\since",
        md_of_(
            "/**\n"
            " * Frees a buffer.\n"
            " * @param buf the buffer\n"
            " * \\since 2.1\n"
            " * \\code{.c}\n"
            " * buf_free(b);\n"
            " * \\endcode\n"
            " */\n"
            "void buf_free(Buf *buf);\n",
            true,
        ),
        "Frees a buffer.\n\n**Since:** 2.1\n\n```c\nbuf_free(b);\n```\n\n### Parameters\n- `buf`: the buffer",
    )

    errors += check_(
        "Doxygen 4: an unknown command stays text, @{ dropped, Kairo \\code is kairo",
        md_of_(
            "/// @{\n"
            "/// Reads a byte. \\unknowncmd stays.\n"
            "/// \\return the byte\n"
            "/// \\code\n"
            "/// var b = read()\n"
            "/// \\endcode\n"
            "fn read() -> u8\n",
            false,
        ),
        "Reads a byte. \\unknowncmd stays.\n\n```kairo\nvar b = read()\n```\n\n### Returns\nthe byte",
    )

    errors += check_(
        "Doxygen 5: \\details, \\result, \\pre, \\post, \\ref",
        md_of_(
            "/// \\brief Moves the cursor.\n"
            "/// \\details Steps over a whole code point; see \\ref Cursor::back.\n"
            "/// \\pre the cursor is not at the end\n"
            "/// \\post the cursor is one code point further on\n"
            "/// \\result the code point stepped over\n"
            "char32_t advance(Cursor &c);\n",
            true,
        ),
        "Moves the cursor.\n\nSteps over a whole code point; see `Cursor::back`.\n\n"
            "**Precondition:** the cursor is not at the end\n\n"
            "**Postcondition:** the cursor is one code point further on\n\n"
            "### Returns\nthe code point stepped over",
    )

    errors += check_(
        "HeaderDoc 4: @function with a continued @discussion, @availability",
        md_of_(
            "/*!\n"
            "    @function CFStringGetLength\n"
            "    @abstract Returns the number of UTF-16 code units in a string.\n"
            "    @discussion The count is of code units, not of characters a\n"
            "        reader sees: a surrogate pair counts two.\n"
            "    @param theString The string to measure.\n"
            "    @result The number of code units.\n"
            "    @availability Mac OS X 10.0 and later.\n"
            "*/\n"
            "CFIndex CFStringGetLength(CFStringRef theString);\n",
            true,
        ),
        "Returns the number of UTF-16 code units in a string.\n\n"
            "The count is of code units, not of characters a\nreader sees: a surrogate pair counts two.\n\n"
            "**Availability:** Mac OS X 10.0 and later.\n\n"
            "### Parameters\n- `theString`: The string to measure.\n\n### Returns\nThe number of code units.",
    )

    errors += check_(
        "HeaderDoc 5: a @typedef tag dropped, @discussion paragraphs",
        md_of_(
            "/*!\n"
            "    @typedef CFArrayRef\n"
            "    @abstract A reference to an immutable array.\n"
            "    @discussion Arrays hold values in order.\n"
            "\n"
            "    Values are retained by the callbacks the array was made with.\n"
            "*/\n"
            "typedef const struct __CFArray *CFArrayRef;\n",
            true,
        ),
        "A reference to an immutable array.\n\nArrays hold values in order.\n\n"
            "Values are retained by the callbacks the array was made with.",
    )

    errors += check_(
        "HeaderDoc 6: @method with @throws and @c",
        md_of_(
            "/*!\n"
            " * @method openFile:\n"
            " * @abstract Opens the file at a path.\n"
            " * @param path Where the file is; @c nil is not allowed.\n"
            " * @throws NSInvalidArgumentException when the path is empty\n"
            " * @result The open handle.\n"
            " */\n"
            "Handle *openFile(const char *path);\n",
            true,
        ),
        "Opens the file at a path.\n\n### Parameters\n- `path`: Where the file is; `nil` is not allowed.\n\n"
            "### Returns\nThe open handle.\n\n### Throws\n- `NSInvalidArgumentException`: when the path is empty",
    )

    // --- reading it back
    var md = "Sums.\n\n### Parameters\n- `a`: the first\n  of two\n- `b` (out): the second\n\n### Returns\nthe sum"
    errors += check_(
        "param_doc: continuation joined",
        param_doc(md, "a", false),
        "the first of two",
    )

    errors += check_(
        "param_doc: a direction",
        param_doc(md, "b", false),
        "(out) the second",
    )

    errors += check_("param_doc: none", param_doc(md, "c", false), "")
    errors += check_(
        "markdown_to_plain",
        markdown_to_plain(
            "**Note:** use `x`\n\n### Returns\n```kairo\nvar a = 1\n```\nBox\\<T>",
        ),
        "Note: use x\n\nReturns:\nvar a = 1\nBox<T>",
    )

    errors += check_(
        "param_name_of: const",
        param_name_of("const s: string"),
        "s",
    )

    errors += check_(
        "param_name_of: a default",
        param_name_of("x: i32 = 3"),
        "x",
    )

    errors += check_(
        "param_name_of: a pack",
        param_name_of("...args: A"),
        "args",
    )

    errors += check_("param_name_of: self", param_name_of("const self"), "")
    errors += check_(
        "param_name_of: C",
        param_name_of("const char *path"),
        "path",
    )

    errors += check_(
        "param_name_of: a qualified type",
        param_name_of("v: std::vector<i32>"),
        "v",
    )

    // --- the head and the stub
    var src = "    @inline\n    pub fn <T, U impl Hash> put(self, const k: T, v: U) panic(Full) -> bool {\n"
    var h = decl_head(src, 0)
    errors += check_("decl_head: name", h.name, "put")
    errors += check_("decl_head: indent", h.indent, "    ")
    errors += check_("decl_head: params", join_lines_(h.params), "k\nv")
    errors += check_("decl_head: tparams", join_lines_(h.tparams), "T\nU")
    errors += check_(
        "decl_head: returns and panics",
        f"{h.returns} {h.panics}",
        "true true",
    )

    errors += check_(
        "doc_stub: plain",
        join_lines_(doc_stub(h, false)),
        "/// Summary.\n///\n/// ### Type parameters\n/// - `T`:\n/// - `U`:\n///\n/// ### Parameters\n/// - `k`:\n"
            "/// - `v`:\n///\n/// ### Returns\n/// What it returns.\n///\n/// ### Panics\n"
            "/// Each panic type and when it is raised.",
    )

    errors += check_(
        "doc_stub: snippet",
        join_lines_(doc_stub(decl_head("fn f(x: i32) -> void {\n", 0), true)),
        "/// ${1:Summary.}\n///\n/// ### Parameters\n/// - `x`: $2",
    )

    var none: [string]
    errors += check_(
        "headings_for: a function with no value",
        join_lines_(headings_for(decl_head("fn g(a: i32) {}\n", 0), none)),
        "### Parameters\n### Example",
    )

    var have: [string] = ["### Parameters"]
    errors += check_(
        "headings_for: one present",
        join_lines_(headings_for(h, have)),
        "### Type parameters\n### Returns\n### Panics\n### Example",
    )

    var cls = decl_head("class <T> Box derives Base {\n", 0)
    errors += check_(
        "decl_head: a class",
        cls.kind.copy() + " " + cls.name + " " + join_lines_(cls.tparams),
        "class Box T",
    )

    var al = decl_head("type <T> Matrix = [[T]]\n", 0)
    errors += check_(
        "decl_head: a type alias",
        al.kind.copy() + " " + al.name,
        "type Matrix",
    )

    var oph = decl_head("    fn op + (const self, other: Self) -> Self\n", 0)
    errors += check_(
        "decl_head: an operator",
        oph.name.copy() + " " + join_lines_(oph.params),
        "op + other",
    )

    var nd = decl_head("var x = 1\n", 0)
    errors += check_("decl_head: not a declaration", f"{nd.ok}", "false")
    return errors
}
