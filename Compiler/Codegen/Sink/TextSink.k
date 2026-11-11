/// --- The Kairo Project ---------------------- Codegen/Sink/TextSink.k --- ///
///
///   \brief EmitSink that writes bytes. The interop header (EmitCXXHeader)
///          and --print-cxx. Same emitter, same fragments as the token
///          stream; only the landing differs.
///
///   Formatting is minimal and deterministic: one space between tokens,
///   a newline after `;` `{` `}` and after a directive, brace-depth
///   indentation. It is a golden-file format, not a style.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "clang/Basic/TokenKinds.h"

import Codegen::Sink::EmitSink::EmitSink
import Location::SourceManager::SourceManager
import Location::SourceRange::SourceRange
import Token::Token::Token
import Token::TokenCacheManager::TokenCacheManager
import Token::TokenText::TokenText

pub class TextSink derives EmitSink {
    pub var out: string = ""

    priv var _sm:            unsafe *SourceManager
    priv var _tcm:           unsafe *TokenCacheManager
    priv var _depth:         usize                     = 0
    priv var _at_line_start: bool                      = true
    priv var _glue_next:     bool                      = false ///< suppress the space before the next token
    priv var _pending_brk:   bool                      = false ///< a `}` was written; break unless `;` follows
    priv var _after_op_kw:   bool                      = false ///< the last token was `operator`: glue a punctuator to it

    /// Line mode (EmitCXXHeader::line_directives, kals only): each line is
    /// built in `_line` and written at its break, under a `#line` naming the
    /// Kairo file and line of its first located token, or, for a line with
    /// none (guards, includes, glue the emitter invents), under one naming
    /// \ref self_path at the line's own number. A directive is written only
    /// where the attribution changes, so a run of lines from consecutive
    /// Kairo lines carries one.
    pub var line_mode: bool   = false
    pub var self_path: string = ""
    priv var _line:      string = ""
    priv var _line_file: string = ""
    priv var _line_no:   usize  = 0
    priv var _phys:      usize  = 0  ///< lines written to `out`
    priv var _map_file:  string = "" ///< what the next line of `out` is attributed to
    priv var _map_line:  usize  = 0

    /// Layout mode (EmitCXXHeader::layout, kals' clangd bridge only, on top
    /// of line mode). clangd reports a header location by its PHYSICAL line,
    /// whatever `#line` says, so a jump from C++ into a .k file lands where
    /// the header line is. Here lines are recorded, not written, and
    /// finish_layout() places each one attributed to the Kairo file on the
    /// physical line its declaration has in that file. A line is attributed
    /// to the LOWEST Kairo line among its tokens from the first file named
    /// on it: a declaration's name precedes its parameters and result type.
    pub var layout: bool = false
    priv var _rec_text: [string]
    priv var _rec_file: [string]
    priv var _rec_line: [usize]
    priv var _rec_dir:  [bool]
    priv var _line_dir: bool = false ///< the buffered line is a directive (own physical line)
    priv var _rec_depth: [usize]     ///< brace depth after each recorded line
    priv var _pl_text:  [string]     ///< finish_layout: physical line k is index k - 1
    priv var _pl_lock:  [bool]       ///< a directive: nothing joins it
    priv var _pl_depth: [usize]      ///< brace depth at the end of the line
    priv var _cursor:   usize  = 0   ///< the last physical line written in order
    priv var _run_dep:  usize  = 0
    priv var _mapped:   bool   = false
    priv var _home:     string = ""

    pub fn TextSink(self, sm: unsafe *SourceManager, tcm: unsafe *TokenCacheManager) {
        self._sm  = sm
        self._tcm = tcm
    }

    override fn create(self, t: Token) -> bool {
        self._flush_pending()
        self._note(t.range)
        self._word(*TokenText::resolve(t, self._tcm).get_text(), false)
        return true
    }

    override fn create_ident(self, at: SourceRange, const spelling: string) -> bool {
        self._flush_pending()
        self._note(at)
        self._word(spelling, false)
        // spell() lexes `operator` as a word, not through keyword().
        if spelling == "operator" {
            self._after_op_kw = true
        }

        return true
    }

    /// Spacing is a pure function of the punctuator kind, so a header's text
    /// is identical in every TU that emits the same decl: that is what the
    /// ODR diff compares. `}` defers its line break so `};` stays one line.
    override fn punct(self, at: SourceRange, k: clang::tok::TokenKind) -> bool {
        var unsafe *p = clang::tok::getPunctuatorSpelling(k)
        if p == &null {
            self.ice_at(at, "TextSink::punct: kind has no punctuator spelling")
        }

        var s = string(unsafe ((p as unsafe *const u8) as *const u8))

        var tight_before = k == clang::tok::semi || k == clang::tok::comma || k == clang::tok::r_paren
                        || k == clang::tok::greater || k == clang::tok::coloncolon || k == clang::tok::l_paren
                        || k == clang::tok::less || k == clang::tok::l_square || k == clang::tok::r_square
                        || k == clang::tok::star || k == clang::tok::amp || k == clang::tok::ampamp
                        // `operator+`, not `operator +`: the symbol is part of
                        // the name. `operator double` keeps its space, since
                        // an identifier is not a punctuator.
                        || self._after_op_kw
        var tight_after = k == clang::tok::l_paren
            || k == clang::tok::coloncolon
            || k == clang::tok::less
            || k == clang::tok::l_square
            || k == clang::tok::tilde

        if k == clang::tok::r_brace {
            // Layout mode records each line's depth at its break: the line a
            // pending `}` closes must break before this brace lowers it.
            if self.layout {
                self._flush_pending()
            }

            if self._depth > 0 {
                self._depth -= 1
            }

            self._flush_pending()
            self._note(at)
            self._word(s, false)
            self._pending_brk = true
            return true
        }

        if k == clang::tok::semi { // `};` stays on the line.
            self._pending_brk = false
        }

        if k != clang::tok::semi {
            self._flush_pending()
        }

        self._note(at)
        self._word(s, tight_before)
        if tight_after {
            self._glue_next = true
        }

        if k == clang::tok::semi {
            self.brk()
        }

        if k == clang::tok::l_brace {
            self._depth += 1
            self.brk()
        }

        return true
    }

    override fn keyword(self, at: SourceRange, k: clang::tok::TokenKind) -> bool {
        var unsafe *kw = clang::tok::getKeywordSpelling(k)
        if kw == &null {
            self.ice_at(at, "TextSink::keyword: kind is not a keyword")
        }

        self._flush_pending()
        self._note(at)
        self._word(string(unsafe ((kw as unsafe *const u8) as *const u8)), false)
        if k == clang::tok::kw_operator {
            self._after_op_kw = true
        }

        return true
    }

    override fn literal(self, at: SourceRange, k: clang::tok::TokenKind) -> bool {
        self._flush_pending()
        self._note(at)
        self._word(*TokenText::from_range(at, self._sm).get_text(), false)
        return true
    }

    override fn create_int(self, at: SourceRange, @inout cxx_v: string) -> bool {
        self._flush_pending()
        self._note(at)
        self._word(cxx_v, false)
        return true
    }

    override fn create_str(self, at: SourceRange, @inout cxx_v: string) -> bool {
        self._flush_pending()
        self._note(at)
        self._word(cxx_v, false)
        return true
    }

    override fn create_char(self, at: SourceRange, @inout cxx_v: string) -> bool {
        self._flush_pending()
        self._note(at)
        self._word(cxx_v, false)
        return true
    }

    /// Own line, always. The text is appended with _at_line_start still
    /// true, so without clearing it the trailing brk() is a no-op and the
    /// next directive runs onto this one (`#pragma once#include ...`).
    override fn directive(self, at: SourceRange, const text: string) -> bool {
        self._flush_pending()
        if !self._at_line_start {
            self.brk()
        }

        self._put(text)
        self._at_line_start = false
        self._line_dir      = true
        self.brk()
        return true
    }

    override fn system_header(self, at: SourceRange, const name: string) -> bool {
        return self.directive(at, "#include <" + name + ">")
    }

    override fn brk(self) {
        if self._at_line_start {
            return
        }

        if self.line_mode {
            self._flush_line()
        } else {
            self.out += "\n"
        }

        self._at_line_start = true
    }

    priv fn _put(self, const s: string) {
        if self.line_mode {
            self._line += s
        } else {
            self.out += s
        }
    }

    /// The first located token of the line names the line (line mode).
    priv fn _note(self, at: SourceRange) {
        if (!self.line_mode) || (!at.start.is_valid()) || (self._sm == &null) {
            return
        }

        if (!self.layout) && (!self._line_file.empty()) {
            return
        }

        // Offset 0 is where the emitter anchors what it invents for a whole
        // file (the lowering helpers, namespace braces): not a declaration.
        if self._sm->resolve(at.start).offset == 0 {
            return
        }

        var fl   = self._sm->get_line_col(at.start)
        var name = self._sm->get_filename(fl.file_id as u32)
        if (fl.line == 0) || (!name.ends_with(".k")) {
            return
        }

        if self._line_file.empty() {
            self._line_file = name
            self._line_no   = fl.line
        } else if (self._line_file == name) && (fl.line < self._line_no) {
            self._line_no = fl.line
        }
    }

    priv fn _flush_line(self) {
        if self.layout {
            self._rec_text.push_back(self._line)
            self._rec_file.push_back(self._line_file)
            self._rec_line.push_back(self._line_no)
            self._rec_dir.push_back(self._line_dir)
            self._rec_depth.push_back(self._depth)
            self._line      = ""
            self._line_file = ""
            self._line_no   = 0
            self._line_dir  = false
            return
        }

        self._line_dir = false
        var file = self._line_file
        var line = self._line_no
        if file.empty() {
            file = self.self_path
            line = self._phys + 1
            if (self._map_file != file) || (self._map_line != line) {
                line += 1 // the directive takes this physical line
            }
        }

        if (self._map_file != file) || (self._map_line != line) {
            self.out += f"#line {line} \""
            self.out += file
            self.out += "\"\n"
            self._phys += 1
        }

        self.out += self._line
        self.out += "\n"
        self._phys += 1
        self._map_file  = file
        self._map_line  = line + 1
        self._line      = ""
        self._line_file = ""
        self._line_no   = 0
    }

    /// Lays the recorded lines out (layout mode) into `out` and returns the
    /// PRELUDE, written beside the header and included from its first line.
    /// The prelude holds every line before the first one from the Kairo file
    /// (pragma, lowering helpers, includes) and every forward-declaration
    /// chunk: invented text, with `#ifndef` guards and `#include`s that need
    /// lines of their own, which inline they would take from declarations.
    ///
    /// Then, in emission order: a line from the Kairo file whose line is
    /// still ahead is padded down to that physical line (with one `#line`
    /// naming the file on the line before, the first time there is room, so
    /// presumed and physical lines agree from there on); a line that is
    /// behind, or names no line (a closing brace, glue), continues the
    /// current physical line, since C++ does not care; a directive takes a
    /// fresh line. A namespace-scope chunk of plain prototypes is the one
    /// thing moved: the emitter puts functions after every class, so a
    /// function declared above a struct would otherwise land below it. Each
    /// prototype becomes `namespace n { proto; }` on its own Kairo line when
    /// that line is at namespace scope and nothing it may need comes later
    /// (types are forward-declared in the prelude; a class whose nested name
    /// it spells, or any other namespace-scope declaration, is a barrier).
    pub fn finish_layout(self, const include_line: string) -> string {
        var n    = self._rec_text.size()
        var home = self._home_file_()

        // Chunks: records from namespace scope (depth 0) back to it. kind:
        // 0 plain, 1 forward declarations, 2 prototypes.
        var c_end:  [usize]
        var c_kind: [u8]
        var i: usize = 0
        while i < n {
            var j = i
            while (j < (n - 1)) && (self._rec_depth[j] != 0) {
                j += 1
            }

            var kind = self._chunk_kind_(i, j)
            for var q = i; q <= j; ++q {
                c_end.push_back(j)
                c_kind.push_back(kind)
            }

            i = j + 1
        }

        var first = n
        for var q: usize = 0; (q < n) && (first == n); ++q {
            if (!home.empty()) && (self._rec_file[q] == home) && (c_kind[q] != 1) {
                first = q
            }
        }

        var prelude: string = ""
        for var q: usize = 0; q < n; ++q {
            if (q < first) || (c_kind[q] == 1) {
                prelude += self._rec_text[q]
                prelude += "\n"
            }
        }

        self._pl_text.clear()
        self._pl_lock.clear()
        self._pl_depth.clear()
        self._pl_text.push_back(include_line)
        self._pl_lock.push_back(true)
        self._pl_depth.push_back(0)
        self._pl_text.push_back("_Pragma(\"once\")")
        self._pl_lock.push_back(false)
        self._pl_depth.push_back(0)
        self._cursor  = 2
        self._run_dep = 0
        self._mapped  = false
        self._home    = home
        var barrier: usize = 0
        var cls_names: [string]
        var cls_lines: [usize]

        var r = first
        while r < n {
            if c_kind[r] == 1 {
                r += 1
                continue
            }

            if c_kind[r] == 2 {
                var j    = c_end[r]
                var open = TextSink::_trim_(self._rec_text[r])
                for var q = r + 1; q < j; ++q {
                    var piece = open + " " + TextSink::_trim_(self._rec_text[q]) + " }"
                    var k: usize = 0
                    if self._rec_file[q] == home {
                        k = self._rec_line[q]
                    } else if self._rec_file[r] == home {
                        k = self._rec_line[r]
                    }

                    var hoist = (k >= 2) && (k <= self._cursor) && (!self._pl_lock[k - 1])
                             && (self._pl_depth[k - 1] == 0) && (k > barrier)
                    for var c: usize = 0; hoist && (c < cls_names.size()); ++c {
                        if (cls_lines[c] >= k) && TextSink::_has_(piece, cls_names[c] + "::") {
                            hoist = false
                        }
                    }

                    if k > self._cursor {
                        self._place_(k, piece, 0)
                    } else if hoist {
                        if self._pl_text[k - 1].empty() {
                            self._pl_text[k - 1] = piece
                        } else {
                            self._pl_text[k - 1] += " " + piece
                        }
                    } else {
                        self._join_(piece, 0)
                    }
                }

                r = j + 1
                continue
            }

            var text = self._rec_text[r]
            if self._rec_dir[r] {
                self._fresh_(self._cursor + 1, text, self._run_dep)
                self._pl_lock[self._cursor - 1] = true
            } else {
                var k: usize = 0
                if self._rec_file[r] == home {
                    k = self._rec_line[r]
                }

                if k > self._cursor {
                    self._place_(k, text, self._rec_depth[r])
                } else {
                    self._join_(text, self._rec_depth[r])
                }
            }

            // A chunk's end: what it declared bounds what may move above it.
            if (c_end[r] == r) && (self._run_dep == 0) {
                var j0 = r
                while (j0 > 0) && (c_end[j0 - 1] == r) {
                    j0 -= 1
                }

                var head: string = ""
                if (j0 + 1) <= r {
                    head = TextSink::_trim_(self._rec_text[j0 + 1])
                }

                var cls = TextSink::_class_name_(head)
                if !cls.empty() {
                    cls_names.push_back(cls)
                    cls_lines.push_back(self._cursor)
                } else if (!head.empty()) && (!TextSink::_has_(head, "(")) {
                    barrier = self._cursor
                }
            }

            r += 1
        }

        self.out = ""
        for var q: usize = 0; q < self._pl_text.size(); ++q {
            self.out += self._pl_text[q]
            self.out += "\n"
        }

        return prelude
    }

    /// The Kairo file most lines are attributed to: the module's own.
    priv fn _home_file_(self) -> string {
        var names:  [string]
        var counts: [usize]
        for var i: usize = 0; i < self._rec_file.size(); ++i {
            if self._rec_file[i].empty() {
                continue
            }

            var found = false
            for var k: usize = 0; k < names.size(); ++k {
                if names[k] == self._rec_file[i] {
                    counts[k] += 1
                    found = true
                }
            }

            if !found {
                names.push_back(self._rec_file[i])
                counts.push_back(1)
            }
        }

        var home: string = ""
        var best: usize  = 0
        for var k: usize = 0; k < names.size(); ++k {
            if counts[k] > best {
                best = counts[k]
                home = names[k]
            }
        }

        return home
    }

    /// 1: `namespace n {` + forward declarations + `}`; 2: the same with
    /// plain prototypes (no body, no default argument); else 0.
    priv fn _chunk_kind_(self, i: usize, j: usize) -> u8 {
        if (j < (i + 2)) || (!TextSink::_trim_(self._rec_text[i]).starts_with("namespace "))
            || (!TextSink::_trim_(self._rec_text[i]).ends_with("{")) || (TextSink::_trim_(self._rec_text[j]) != "}") {
            return 0
        }

        var fwd   = true
        var proto = true
        for var q = i; q <= j; ++q {
            if self._rec_dir[q] || ((q < j) && (self._rec_depth[q] > 1)) {
                return 0
            }

            if (q == i) || (q == j) {
                continue
            }

            var t = TextSink::_trim_(self._rec_text[q])
            var decl_end = t.ends_with(";") && (!TextSink::_has_(t, "="))
            var tag = t.starts_with("struct ") || t.starts_with("class ") || t.starts_with("union ")
                   || t.starts_with("enum ") || t.starts_with("template<")
            if (!decl_end) || (!tag) || TextSink::_has_(t, "(") {
                fwd = false
            }

            if (!decl_end) || (!TextSink::_has_(t, "(")) || t.starts_with("using ") || t.starts_with("static_assert") {
                proto = false
            }
        }

        if fwd {
            return 1
        }

        if proto {
            return 2
        }

        return 0
    }

    /// Text on physical line \p k (ahead of the cursor), with the first
    /// `#line` naming the Kairo file on the line before it when there is room.
    priv fn _place_(self, k: usize, const text: string, depth_after: usize) {
        if (!self._mapped) && (k >= (self._cursor + 2)) {
            self._fresh_(k - 1, f"#line {k} \"" + self._home + "\"", self._run_dep)
            self._pl_lock[k - 2] = true
            self._mapped = true
        }

        self._fresh_(k, text, depth_after)
    }

    /// Text on line \p k, the lines between padded with nothing.
    priv fn _fresh_(self, k: usize, const text: string, depth_after: usize) {
        while self._pl_text.size() < (k - 1) {
            self._pl_text.push_back("")
            self._pl_lock.push_back(false)
            self._pl_depth.push_back(self._run_dep)
        }

        self._pl_text.push_back(text)
        self._pl_lock.push_back(false)
        self._pl_depth.push_back(depth_after)
        self._cursor  = k
        self._run_dep = depth_after
    }

    /// Text continuing the current physical line (a fresh one after a directive).
    priv fn _join_(self, const text: string, depth_after: usize) {
        if self._pl_lock[self._cursor - 1] {
            self._fresh_(self._cursor + 1, text, depth_after)
            return
        }

        self._pl_text[self._cursor - 1] += " " + TextSink::_trim_(text)
        self._pl_depth[self._cursor - 1] = depth_after
        self._run_dep = depth_after
    }

    /// The record a namespace-scope chunk's first inner line defines
    /// (`struct Point {`, `enum class E : int {`), or "".
    priv static fn _class_name_(const t: string) -> string {
        var at: usize = 0
        if t.starts_with("struct ") {
            at = 7
        } else if t.starts_with("class ") {
            at = 6
        } else if t.starts_with("union ") {
            at = 6
        } else if t.starts_with("enum class ") {
            at = 11
        } else if t.starts_with("enum ") {
            at = 5
        } else {
            return ""
        }

        var e = at
        while (e < t.size()) && (((t[e] >= 97) && (t[e] <= 122)) || ((t[e] >= 65) && (t[e] <= 90))
                                 || ((t[e] >= 48) && (t[e] <= 57)) || (t[e] == 95)) {
            e += 1
        }

        return t.subslice(at, e - at)
    }

    priv static fn _trim_(const s: string) -> string {
        var a: usize = 0
        while (a < s.size()) && (s[a] == 32) {
            a += 1
        }

        return s.subslice(a, s.size() - a)
    }

    priv static fn _has_(const s: string, const needle: string) -> bool {
        if needle.size() > s.size() {
            return false
        }

        for var i: usize = 0; (i + needle.size()) <= s.size(); ++i {
            var same = true
            for var k: usize = 0; same && (k < needle.size()); ++k {
                if s[i + k] != needle[k] {
                    same = false
                }
            }

            if same {
                return true
            }
        }

        return false
    }

    priv fn _flush_pending(self) {
        if self._pending_brk {
            self._pending_brk = false
            self.brk()
        }
    }

    priv fn _word(self, s: string, tight: bool) {
        self._flush_pending()
        if self._at_line_start {
            for var i: usize = 0; i < self._depth; ++i {
                self._put("    ")
            }

            self._at_line_start = false
        } else if !(tight || self._glue_next) {
            self._put(" ")
        }

        self._glue_next   = false
        self._after_op_kw = false
        self._put(s)
    }
}
