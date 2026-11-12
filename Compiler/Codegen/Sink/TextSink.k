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
    pub var home_path: string = "" ///< the module's own .k file, as the source manager names it
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
    priv var _pl_decl:  [usize]      ///< the Kairo line placed on this physical one (its own), else 0
    priv var _line_at:  usize  = 0   ///< the physical line of the one `#line` _place_ wrote, else 0
    priv var _fnames:   [string]     ///< the Kairo files lines are attributed to, and their ids
    priv var _fids:     [u32]
    priv var _home_fid: u32    = u32::MAX
    priv var _doc_done: [usize]      ///< Kairo lines whose doc comment is in the header
    priv var _last_word: string = "" ///< the token _word wrote last (layout: `public :` breaks)
    priv var _enum_at:  usize  = 0   ///< layout: the depth of the enum body being written, else 0
    priv var _c_end:    [usize]      ///< finish_layout: the last record of each record's chunk
    priv var _c_kind:   [u8]         ///< and the chunk's kind (_chunk_kind_)
    priv var _skip_fwd: [bool]       ///< a forward declaration that claims no line (_lay_)
    priv var _pl_rec:   [usize]      ///< the record whose text claimed this physical line, else usize::MAX
    priv var _drop:     [bool]       ///< a record of a definition the header leaves out (_mark_drops_)

    /// Out-of-line function definitions (P882): left out because their
    /// declaration holds their line, or kept because C++ in the including
    /// file may need the body (constexpr, consteval, a deduced type, an
    /// explicit specialization, internal linkage).
    pub var bodies_dropped: usize = 0
    pub var bodies_needed:  usize = 0

    /// Doc comments carried into a layout header (P876): above their
    /// declaration on the .k file's own lines, on the forward declaration in
    /// the prelude when those lines are taken (classes only), or dropped.
    pub var docs_placed:  usize = 0
    pub var docs_prelude: usize = 0
    pub var docs_dropped: usize = 0

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

            if self._depth < self._enum_at {
                self._enum_at = 0
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

        var access = (k == clang::tok::colon)
            && ((self._last_word == "public") || (self._last_word == "private") || (self._last_word == "protected"))
        self._note(at)
        self._word(s, tight_before)
        if tight_after {
            self._glue_next = true
        }

        if k == clang::tok::semi {
            self.brk()
        }

        // Layout mode: lines a declaration's own tokens would otherwise
        // share with text anchored on an earlier Kairo line, which takes the
        // line's attribution (the lowest) and so the declaration's physical
        // line. An enum's `};` is anchored at the enum, so its variants join
        // the enum's line unless each one breaks after its comma; an access
        // specifier is anchored at the class, so the field after it joins
        // the class's line unless the specifier ends its line. C++ does not
        // care where a line breaks.
        if self.layout && (k == clang::tok::comma) && (self._enum_at != 0) && (self._depth == self._enum_at) {
            self.brk()
        }

        if self.layout && access {
            self.brk()
        }

        if k == clang::tok::l_brace {
            // Not an enum the compiler mints (an ADT's `__kairo_Tag`): its
            // variants share the Kairo lines of the factories C++ calls.
            var head    = TextSink::_trim_(self._line)
            var is_enum = self.layout && head.starts_with("enum class ") && (!head.starts_with("enum class __kairo"))
            self._depth += 1
            if is_enum {
                self._enum_at = self._depth
            }

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
            if self.layout {
                self._remember_fid_(name, fl.file_id as u32)
            }

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
    /// it spells, a specialization, alias or variable whose name it spells,
    /// or any other namespace-scope declaration, is a barrier). Text that
    /// claims no line: forward declarations whose definition then has it,
    /// and what declares a name the compiler mints (P882). Text left out:
    /// an out-of-line function definition whose declaration holds its line,
    /// when C++ cannot need its body (_mark_drops_).
    pub fn finish_layout(self, const include_line: string) -> string {
        var n    = self._rec_text.size()
        var home = self._home_file_()
        // The module's own file when the emitter names it and any line is
        // attributed to it: a small module that instantiates an imported
        // template (a `Panic<T, E>`) has more lines from that template's
        // file than from its own.
        for var q: usize = 0; (q < n) && (!self.home_path.empty()); ++q {
            if self._rec_file[q] == self.home_path {
                home = self.home_path
            }
        }

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

        // The prelude ends outside every conditional it opens: a guard
        // split across the two files compiles in neither.
        var open: usize = 0
        for var q: usize = 0; q < first; ++q {
            open = TextSink::_cond_depth_(self._rec_text[q], self._rec_dir[q], open)
        }

        while (open != 0) && (first < n) {
            open = TextSink::_cond_depth_(self._rec_text[first], self._rec_dir[first], open)
            first += 1
        }

        // A forward declaration standing alone in its chunk's text names
        // its record's Kairo line, which the definition clangd jumps to
        // wants. First every such one claims no line; one whose line no
        // declaration then takes (its definition is placed out of order)
        // claims it again, as before, until that settles.
        self._c_end  = c_end
        self._c_kind = c_kind
        self._home   = home
        self._skip_fwd.clear()
        for var q: usize = 0; q < n; ++q {
            self._skip_fwd.push_back((c_kind[q] == 0) && (q >= first) && (self._rec_file[q] == home)
                && (self._rec_line[q] > 1) && (!self._rec_dir[q]) && TextSink::_is_fwd_(TextSink::_trim_(self._rec_text[q])))
        }

        self._drop.clear()
        for var q: usize = 0; q < n; ++q {
            self._drop.push_back(false)
        }

        self._lay_(first, include_line)
        if self._mark_drops_(first) {
            self._lay_(first, include_line)
        }

        for var pass: usize = 0; pass < 8; ++pass {
            var changed = false
            for var q: usize = 0; q < n; ++q {
                var at = self._rec_line[q]
                // A record the compiler names (`__kairo_ext_T`, an extend
                // block's) is never what clangd is asked about: its line
                // stays free even then, for whatever the block declares.
                var minted = TextSink::_has_(self._rec_text[q], " __kairo")
                if self._skip_fwd[q] && (!minted) && ((at > self._pl_decl.size()) || (self._pl_decl[at - 1] != at)) {
                    self._skip_fwd[q] = false
                    changed = true
                }
            }

            if !changed {
                break
            }

            self._lay_(first, include_line)
        }

        // Last, once nothing else is placed or joined: text joined after a
        // `///` line would be commented out.
        self._docs_()

        // A class whose doc found no room above it in the header keeps it on
        // its forward declaration here: clangd shows the doc of any
        // redeclaration, and the prelude has no line numbers to keep.
        var prelude: string = ""
        var missed:  [usize]
        for var q: usize = 0; q < n; ++q {
            if (q < first) || (c_kind[q] == 1) {
                var at = self._rec_line[q]
                var fwd = TextSink::_class_name_(TextSink::_untemplate_(TextSink::_trim_(self._rec_text[q])))
                if (c_kind[q] == 1) && (!fwd.empty()) && (self._rec_file[q] == home) && (at > 0)
                    && (!TextSink::_has_line_(self._doc_done, at)) {
                    var top: usize = 0
                    var doc = self._doc_above_(at, &top)
                    if !doc.empty() {
                        var pad = self._rec_text[q].subslice(0, self._rec_text[q].size() - TextSink::_trim_(self._rec_text[q]).size())
                        for var d: usize = 0; d < doc.size(); ++d {
                            prelude += pad + TextSink::_trim_ws_(doc[d])
                            prelude += "\n"
                        }

                        self._doc_done.push_back(at)
                        self.docs_prelude += 1
                    }
                }

                prelude += self._rec_text[q]
                prelude += "\n"
            }
        }

        // What is left: a declaration with a doc that is in neither place.
        for var q: usize = 0; q < n; ++q {
            var at = self._rec_line[q]
            if (self._rec_file[q] != home) || (at == 0) || self._rec_dir[q] || TextSink::_has_line_(self._doc_done, at)
                || TextSink::_has_line_(missed, at) {
                continue
            }

            var top: usize = 0
            if !self._doc_above_(at, &top).empty() {
                missed.push_back(at)
                self.docs_dropped += 1
            }
        }

        self.out = ""
        for var q: usize = 0; q < self._pl_text.size(); ++q {
            self.out += self._pl_text[q]
            self.out += "\n"
        }

        return prelude
    }

    /// finish_layout's placement, from nothing: every record from \p first
    /// on, onto `_pl_text` (_skip_fwd says which forward declarations
    /// claim no line).
    priv fn _lay_(self, first: usize, const include_line: string) {
        var n    = self._rec_text.size()
        var home = self._home
        var c_end  = self._c_end
        var c_kind = self._c_kind
        self._pl_text.clear()
        self._pl_lock.clear()
        self._pl_depth.clear()
        self._pl_decl.clear()
        self._doc_done.clear()
        self._pl_rec.clear()
        self._pl_text.push_back(include_line)
        self._pl_lock.push_back(true)
        self._pl_depth.push_back(0)
        self._pl_decl.push_back(0)
        self._pl_rec.push_back(usize::MAX)
        self._pl_text.push_back("_Pragma(\"once\")")
        self._pl_lock.push_back(false)
        self._pl_depth.push_back(0)
        self._pl_decl.push_back(0)
        self._pl_rec.push_back(usize::MAX)
        self._cursor  = 2
        self._run_dep = 0
        self._mapped  = false
        self._line_at = 0
        self._home    = home
        self._home_fid = u32::MAX
        for var f: usize = 0; f < self._fnames.size(); ++f {
            if self._fnames[f] == home {
                self._home_fid = self._fids[f]
            }
        }
        var barrier: usize = 0
        var cls_names: [string]
        var cls_lines: [usize]
        // A namespace-scope declaration that is not a record (an explicit
        // specialization, an alias, a variable) bounds only the prototypes
        // that spell its name; nb_max is the highest of their lines, which
        // bounds a prototype whose text C++ evaluates (noexcept(), requires,
        // decltype() other than the size_t spelling): fail closed there.
        var nb_names: [string]
        var nb_lines: [usize]
        var nb_max: usize = 0

        // Text the compiler names (an ADT's payload structs, tag and union)
        // is never what clangd is asked about, but it carries its variant's
        // Kairo line, which the factory C++ calls wants: it, and all of its
        // body, claims no line. inv_depth: the depth inside such a body.
        var inv_depth: usize = 0
        var r = first
        while r < n {
            var starts_at: usize = 0
            if r > 0 {
                starts_at = self._rec_depth[r - 1]
            }

            if (inv_depth != 0) && (starts_at < inv_depth) {
                inv_depth = 0
            }

            var minted = (inv_depth != 0)
            if (!minted) && (!self._rec_dir[r]) && (c_kind[r] == 0) && TextSink::_invented_(TextSink::_trim_(self._rec_text[r])) {
                minted = true
                // An extend block's struct holds the block's own functions.
                var ext = TextSink::_has_(self._rec_text[r], "__kairo_ext_")
                if (!ext) && TextSink::_trim_(self._rec_text[r]).ends_with("{") && (self._rec_depth[r] > starts_at) {
                    inv_depth = self._rec_depth[r]
                }
            }

            if (c_kind[r] == 1) || self._drop[r] {
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

                    for var c: usize = 0; hoist && (c < nb_names.size()); ++c {
                        if (nb_lines[c] >= k) && TextSink::_has_word_(piece, nb_names[c]) {
                            hoist = false
                        }
                    }

                    if hoist && (nb_max >= k) && TextSink::_evaluates_(piece) {
                        hoist = false
                    }

                    var landed = self._cursor

                    if k > self._cursor {
                        self._place_(k, piece, 0)
                        self._pl_rec[k - 1] = q
                        landed = k
                    } else if hoist {
                        if self._pl_text[k - 1].empty() {
                            self._pl_text[k - 1] = piece
                            self._pl_decl[k - 1] = k
                            self._pl_rec[k - 1]  = q
                        } else {
                            self._pl_text[k - 1] += " " + piece
                        }

                        landed = k
                    } else {
                        self._join_(piece, 0)
                        landed = self._cursor
                    }

                    // An extern variable is a name a later prototype may spell.
                    var t = TextSink::_trim_(self._rec_text[q])
                    if t.starts_with("extern ") {
                        var vn = TextSink::_var_name_(t)
                        if !vn.empty() {
                            nb_names.push_back(vn)
                            nb_lines.push_back(landed)
                            if landed > nb_max {
                                nb_max = landed
                            }
                        }
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
                // A forward declaration finish_layout skips claims no line.
                var k: usize = 0
                if (self._rec_file[r] == home) && (!self._skip_fwd[r]) && (!minted) {
                    k = self._rec_line[r]
                }

                if k > self._cursor {
                    self._place_(k, text, self._rec_depth[r])
                    self._pl_rec[k - 1] = r
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

                // The chunk's declaration: after its namespace opener, or
                // its first line when it has none (a specialization at
                // global scope).
                var head: string = ""
                var h0 = TextSink::_trim_(self._rec_text[j0])
                var opener = h0.starts_with("namespace ") && h0.ends_with("{")
                if opener && ((j0 + 1) <= r) {
                    head = TextSink::_trim_(self._rec_text[j0 + 1])
                } else if (!opener) && (!self._rec_dir[j0]) {
                    head = h0
                }

                var spec = head.starts_with("template<>") || head.starts_with("template <>")
                var cls = TextSink::_class_name_(TextSink::_untemplate_(head))
                if spec {
                    var sn = TextSink::_spec_name_(head)
                    if sn.empty() {
                        barrier = self._cursor
                    } else {
                        nb_names.push_back(sn)
                        nb_lines.push_back(self._cursor)
                        nb_max = self._cursor
                    }
                } else if !cls.empty() {
                    cls_names.push_back(cls)
                    cls_lines.push_back(self._cursor)
                } else if (!head.empty()) && (!TextSink::_has_(head, "(")) {
                    var vn = TextSink::_var_name_(head)
                    if !vn.empty() {
                        nb_names.push_back(vn)
                        nb_lines.push_back(self._cursor)
                        nb_max = self._cursor
                    } else if opener || (j0 < r) {
                        barrier = self._cursor
                    }
                }
            }

            r += 1
        }
    }

    /// Out-of-line function definitions the header leaves out, from the
    /// placement just made; true if any (P882). The emitter writes inline
    /// and template bodies after every class, where clangd's go-to-definition
    /// then lands, though their declarations hold their Kairo lines. A body
    /// clangd does not need goes, so the jump falls back to the declaration.
    /// What C++ in the including file can need a body for, it keeps:
    /// constant evaluation (constexpr, consteval), a deduced type (`auto`),
    /// an explicit specialization (without it the primary template would be
    /// used), internal linkage (an undefined `static` is a warning at every
    /// use). A body is dropped only when every check passes, so a definition
    /// is never the only declaration left out:
    /// - its chunk is `namespace n {`, the head ending in `{`, the body, `}`, `}`;
    /// - its head claimed no line, and its Kairo line is claimed by its
    ///   declaration: for a member, a line inside a class spelling its name
    ///   (never a friend, never the class head); for a free function, a
    ///   prototype with the same text but `inline`.
    /// A definition whose declaration is elsewhere keeps its body: dropping
    /// it would gain nothing, and the definition may be what clangd finds.
    priv fn _mark_drops_(self, first: usize) -> bool {
        var n   = self._rec_text.size()
        var any = false
        var j0  = first
        while j0 < n {
            var j = self._c_end[j0]
            var h = j0 + 1
            if (self._c_kind[j0] != 0) || (h >= j) || (self._rec_file[h] != self._home) {
                j0 = j + 1
                continue
            }

            // The shape: one function definition and nothing else.
            var opener = TextSink::_trim_(self._rec_text[j0])
            var head   = TextSink::_trim_(self._rec_text[h])
            var shape  = opener.starts_with("namespace ") && opener.ends_with("{") && (opener != "namespace {")
                      && (TextSink::_openers_(opener) == opener) && (self._rec_depth[j0] == 1)
                      && head.ends_with("{") && (self._rec_depth[h] == 2)
                      && (TextSink::_trim_(self._rec_text[j]) == "}") && (self._rec_depth[j] == 0)
                      && (TextSink::_trim_(self._rec_text[j - 1]) == "}") && (self._rec_depth[j - 1] == 1)
            for var q = j0; shape && (q <= j); ++q {
                if self._rec_dir[q] || ((q > h) && (q < (j - 1)) && (self._rec_depth[q] < 2)) {
                    shape = false
                }
            }

            var u = TextSink::_untemplate_all_(head)
            if shape && ((!TextSink::_class_name_(u).empty()) || u.starts_with("namespace ") || u.starts_with("using ")
                         || (!TextSink::_has_(u, "("))) {
                shape = false
            }

            if !shape {
                j0 = j + 1
                continue
            }

            // What C++ beyond the header can need the body for.
            if TextSink::_has_word_(head, "constexpr") || TextSink::_has_word_(head, "consteval")
                || TextSink::_has_word_(head, "auto") || TextSink::_has_word_(head, "static")
                || TextSink::_has_word_(head, "extern") || TextSink::_has_(head, "template<>")
                || TextSink::_has_(head, "template <>") {
                self.bodies_needed += 1
                j0 = j + 1
                continue
            }

            var qual = false
            var name = TextSink::_fn_name_(u, &qual)
            var k    = self._rec_line[h]
            var c    = usize::MAX
            if (!name.empty()) && (k >= 2) && (k <= self._pl_text.size()) && (self._pl_decl[k - 1] == k) {
                c = self._pl_rec[k - 1]
            }

            var held = (c != usize::MAX) && (c != h) && (self._rec_file[c] == self._home) && (!self._rec_dir[c])
            if held {
                var t = TextSink::_trim_(self._rec_text[c])
                if qual {
                    held = (self._c_kind[c] == 0) && (self._rec_depth[c] >= 2) && TextSink::_has_word_(t, name)
                        && (!TextSink::_has_word_(t, "friend")) && TextSink::_class_name_(TextSink::_untemplate_all_(t)).empty()
                } else {
                    held = (self._c_kind[c] == 2) && (TextSink::_proto_key_(t) == TextSink::_proto_key_(head))
                }
            }

            if held {
                for var q = j0; q <= j; ++q {
                    self._drop[q] = true
                }

                self.bodies_dropped += 1
                any = true
            }

            j0 = j + 1
        }

        return any
    }

    /// The preprocessor conditional depth after record \p t (a directive
    /// when \p dir), from \p d.
    priv static fn _cond_depth_(const t: string, dir: bool, d: usize) -> usize {
        if !dir {
            return d
        }

        var s = TextSink::_trim_ws_(t)
        if s.starts_with("#if") {
            return d + 1
        }

        if s.starts_with("#endif") && (d > 0) {
            return d - 1
        }

        return d
    }

    /// \p t without every leading `template<...>` head (a member template
    /// of a class template has two); `template<>` is kept.
    priv static fn _untemplate_all_(const t: string) -> string {
        var u = t
        while u.starts_with("template<") && (!u.starts_with("template<>")) {
            var v = TextSink::_untemplate_(u)
            if v.size() == u.size() {
                break
            }

            u = v
        }

        return u
    }

    /// The name a function head (no template head) declares, and in \p qual
    /// whether it is qualified (`X<T>::f`, `X::~X`, `X::operator[]`): an
    /// operator is `operator`; else the identifier before the first `(`
    /// that is not a type or attribute spelling (`decltype(sizeof(0))`).
    priv static fn _fn_name_(const u: string, qual: *bool) -> string {
        *qual = false
        if TextSink::_has_word_(u, "operator") {
            *qual = TextSink::_has_(u, "::operator")
            return "operator"
        }

        for var i: usize = 0; i < u.size(); ++i {
            if u[i] != 40 {
                continue
            }

            var e = i
            while (e > 0) && (u[e - 1] == 32) {
                e -= 1
            }

            var b = e
            while (b > 0) && TextSink::_ident_char_(u[b - 1]) {
                b -= 1
            }

            var id = u.subslice(b, e - b)
            if id.empty() || (id == "decltype") || (id == "sizeof") || (id == "alignof") || (id == "__attribute__")
                || (id == "noexcept") || (id == "alignas") || (id == "requires") {
                continue
            }

            var p = b
            if (p > 0) && (u[p - 1] == 126) { // `~X`
                p -= 1
            }

            *qual = (p >= 2) && (u[p - 1] == 58) && (u[p - 2] == 58)
            return id
        }

        return ""
    }

    /// A free function's prototype or definition head as one key: its
    /// tokens without `inline`, attributes (`[[noreturn]]` and
    /// `__attribute__((...))` sit on the prototype only) and the trailing
    /// `;` or `{`, with a space kept only between two identifier characters
    /// (`inline::T` and `>::T` spell the same tokens). What is left is the
    /// signature: two heads with one key declare one function. The
    /// prototype is the emitter's spelling of the same declaration, so they
    /// agree unless one carries something the other does not, and then
    /// nothing is dropped.
    priv static fn _proto_key_(const t: string) -> string {
        var s = TextSink::_trim_(t)
        if s.ends_with(";") || s.ends_with("{") {
            s = s.subslice(0, s.size() - 1)
        }

        var bare: string = ""
        var i: usize = 0
        while i < s.size() {
            var rest = s.subslice(i, s.size() - i)
            var before = (i > 0) && TextSink::_ident_char_(s[i - 1])
            if (!before) && rest.starts_with("inline") && ((rest.size() == 6) || (!TextSink::_ident_char_(rest[6]))) {
                bare += " "
                i += 6
                continue
            }

            // An attribute: through its balanced brackets or parentheses.
            var open: u8 = 0
            if rest.starts_with("[[") {
                open = 91
            } else if (!before) && rest.starts_with("__attribute__") {
                open = 40
            }

            if open != 0 {
                var close: u8 = 93
                if open == 40 {
                    close = 41
                }

                var d: usize = 0
                var e = i
                var seen = false
                while e < s.size() {
                    if s[e] == open {
                        d += 1
                        seen = true
                    } else if s[e] == close {
                        d -= 1
                        if seen && (d == 0) {
                            break
                        }
                    }

                    e += 1
                }

                if e >= s.size() {
                    return s // unbalanced: a key nothing else has
                }

                bare += " "
                i = e + 1
                continue
            }

            bare += s.subslice(i, 1)
            i += 1
        }

        var out: string = ""
        for var p: usize = 0; p < bare.size(); ++p {
            if bare[p] != 32 {
                out += bare.subslice(p, 1)
                continue
            }

            var q = p
            while (q < bare.size()) && (bare[q] == 32) {
                q += 1
            }

            if (out.size() > 0) && (q < bare.size()) && TextSink::_ident_char_(out[out.size() - 1])
                && TextSink::_ident_char_(bare[q]) {
                out += " "
            }

            p = q - 1
        }

        return out
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

            var ext_var = t.starts_with("extern ") && (!t.starts_with("extern template")) && (!t.starts_with("extern \""))
            if (!decl_end) || ((!TextSink::_has_(t, "(")) && (!ext_var)) || t.starts_with("using ")
                || t.starts_with("static_assert") || t.starts_with("extern template") {
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
            self._mapped  = true
            self._line_at = k - 1
        }

        self._fresh_(k, text, depth_after)
        self._pl_decl[k - 1] = k
    }

    /// Text on line \p k, the lines between padded with nothing.
    priv fn _fresh_(self, k: usize, const text: string, depth_after: usize) {
        while self._pl_text.size() < (k - 1) {
            self._pl_text.push_back("")
            self._pl_lock.push_back(false)
            self._pl_depth.push_back(self._run_dep)
            self._pl_decl.push_back(0)
            self._pl_rec.push_back(usize::MAX)
        }

        self._pl_text.push_back(text)
        self._pl_lock.push_back(false)
        self._pl_depth.push_back(depth_after)
        self._pl_decl.push_back(0)
        self._pl_rec.push_back(usize::MAX)
        self._cursor  = k
        self._run_dep = depth_after
    }

    priv fn _remember_fid_(self, const name: string, fid: u32) {
        for var f: usize = 0; f < self._fnames.size(); ++f {
            if self._fnames[f] == name {
                return
            }
        }

        self._fnames.push_back(name)
        self._fids.push_back(fid)
    }

    priv static fn _has_line_(const set: [usize], k: usize) -> bool {
        for var i: usize = 0; i < set.size(); ++i {
            if set[i] == k {
                return true
            }
        }

        return false
    }

    /// The `///` block directly above line \p k of the home .k file, top
    /// line first, as written (\p top: its first line). The block kals'
    /// hover shows (Hovers.k doc_): attribute lines between it and the
    /// declaration are passed over, a bare `//` ends it, and a block opening
    /// with a `/// ---` rule is the file's license banner, not a doc.
    priv fn _doc_above_(self, k: usize, top: *usize) -> [string] {
        var rev: [string]
        var none: [string]
        if (self._home_fid == u32::MAX) || (self._sm == &null) {
            return none
        }

        var j = k
        while j > 1 {
            var s = TextSink::_trim_ws_(self._sm->get_line_text(self._home_fid, (j - 1) as u32))
            if s.starts_with("///") {
                rev.push_back(self._sm->get_line_text(self._home_fid, (j - 1) as u32))
                j -= 1
                continue
            }

            if s.starts_with("@") && rev.empty() {
                j -= 1
                continue
            }

            break
        }

        if rev.empty() || TextSink::_trim_ws_(rev[rev.size() - 1]).starts_with("/// ---") {
            return none
        }

        var out: [string]
        for var i: usize = rev.size(); i > 0; --i {
            out.push_back(TextSink::_doc_line_(rev[i - 1]))
        }

        *top = j
        return out
    }

    /// A doc line as C++ text: as written, but never ending in `\`, which
    /// would splice the next line (the declaration) into the comment.
    priv static fn _doc_line_(const s: string) -> string {
        var e = s.size()
        while (e > 0) && ((s[e - 1] == 32) || (s[e - 1] == 9) || (s[e - 1] == 13) || (s[e - 1] == 92)) {
            e -= 1
        }

        return s.subslice(0, e)
    }

    /// The leading `namespace n {` openers of a header line ("" if none).
    priv static fn _openers_(const t: string) -> string {
        var p: usize = 0
        while (p < t.size()) && (t[p] == 32) {
            p += 1
        }

        var end: usize = 0
        while t.subslice(p, t.size() - p).starts_with("namespace ") {
            var q = p + 10
            while (q < t.size()) && (t[q] != 123) && (t[q] != 59) && (t[q] != 40) && (t[q] != 125) {
                q += 1
            }

            if (q >= t.size()) || (t[q] != 123) {
                break
            }

            p = q + 1
            end = p
            while (p < t.size()) && (t[p] == 32) {
                p += 1
            }
        }

        return t.subslice(0, end)
    }

    /// Puts each placed declaration's doc comment on the lines it has in
    /// the .k file, directly above the declaration (P876). Only where every
    /// one of those lines is empty in the header: nothing is ever moved to
    /// make room. clangd attaches a comment to the next declaration only
    /// across whitespace (no `;{}#`), so a declaration line that opens with
    /// its namespace (`namespace n { class C {`) has the opener moved to the
    /// line above the comment, across nothing but those empty lines; and the
    /// one `#line` _place_ wrote, if it is among them, moves above it too
    /// (or goes: under the overlay the header is named by its .k path
    /// already, so it only restates that).
    priv fn _docs_(self) {
        if self._home_fid == u32::MAX {
            return
        }

        for var k: usize = 2; k <= self._pl_text.size(); ++k {
            if self._pl_decl[k - 1] != k {
                continue
            }

            var top: usize = 0
            var doc = self._doc_above_(k, &top)
            if doc.empty() || (top < 2) {
                continue
            }

            var fits    = true
            var has_dir = false
            for var j = top; j < k; ++j {
                if j == self._line_at {
                    has_dir = true
                } else if self._pl_lock[j - 1] || (!TextSink::_trim_(self._pl_text[j - 1]).empty()) {
                    fits = false
                }
            }

            var open = TextSink::_openers_(self._pl_text[k - 1])
            var above = top - 1 // the opener's line, and the `#line`'s
            if (!open.empty()) && ((above < 1) || self._pl_lock[above - 1] || (above == self._line_at)) {
                fits = false
            }

            if !fits {
                continue
            }

            if has_dir {
                var to = above
                if !open.empty() {
                    to = above - 1
                }

                var old = self._line_at
                self._pl_text[old - 1] = ""
                self._pl_lock[old - 1] = false
                self._line_at = 0
                if (to >= 3) && (!self._pl_lock[to - 1])
                    && TextSink::_trim_(self._pl_text[to - 1]).empty() {
                    self._pl_text[to - 1] = f"#line {to + 1} \"" + self._home + "\""
                    self._pl_lock[to - 1] = true
                    self._line_at = to
                }
            }

            if !open.empty() {
                var rest = self._pl_text[k - 1].subslice(open.size(), self._pl_text[k - 1].size() - open.size())
                self._pl_text[k - 1] = TextSink::_trim_(rest)
                if TextSink::_trim_(self._pl_text[above - 1]).empty() {
                    self._pl_text[above - 1] = TextSink::_trim_(open)
                } else {
                    self._pl_text[above - 1] += " " + TextSink::_trim_(open)
                }
            }

            for var d: usize = 0; d < doc.size(); ++d {
                self._pl_text[top + d - 1] = doc[d]
                self._pl_lock[top + d - 1] = true
            }

            self._doc_done.push_back(k)
            self.docs_placed += 1
        }
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

    /// A line that declares a name the compiler mints (`struct __kairo_V_t {`,
    /// `__kairo_Tag __kairo_tag;`, an anonymous `union {`), by the name it
    /// declares: before its first `(` for a function, else as _var_name_.
    priv static fn _invented_(const t: string) -> bool {
        var u = TextSink::_untemplate_(t)
        if u.starts_with("union {") || u.starts_with("struct {") {
            return true
        }

        var at: usize = 0
        if u.starts_with("struct ") {
            at = 7
        } else if u.starts_with("class ") || u.starts_with("union ") {
            at = 6
        } else if u.starts_with("enum class ") {
            at = 11
        } else if u.starts_with("enum ") {
            at = 5
        }

        if at != 0 {
            return u.subslice(at, u.size() - at).starts_with("__kairo")
        }

        if u.starts_with("__kairo") {
            return true
        }

        // `T x = __kairo_init_x();` declares x: an `=` before the first `(`
        // is a variable's.
        var p: usize = 0
        while (p < u.size()) && (u[p] != 40) && (u[p] != 61) {
            p += 1
        }

        if (p < u.size()) && (u[p] == 40) {
            var e = p
            while (e > 0) && (u[e - 1] == 32) {
                e -= 1
            }

            var b = e
            while (b > 0) && TextSink::_ident_char_(u[b - 1]) {
                b -= 1
            }

            return u.subslice(b, e - b).starts_with("__kairo")
        }

        return TextSink::_var_name_(u).starts_with("__kairo")
    }

    /// A forward declaration (`struct S;`, `enum class E : int;`,
    /// `template<class T> struct B;`): a tag, no body, no initializer.
    priv static fn _is_fwd_(const t: string) -> bool {
        var u = TextSink::_untemplate_(t)
        var tag = u.starts_with("struct ") || u.starts_with("class ") || u.starts_with("union ") || u.starts_with("enum ")
        return tag && t.ends_with(";") && (!TextSink::_has_(t, "(")) && (!TextSink::_has_(t, "{")) && (!TextSink::_has_(t, "="))
    }

    /// \p t without a leading `template<...> ` head (balanced), else \p t;
    /// an explicit specialization's `template<>` is kept.
    priv static fn _untemplate_(const t: string) -> string {
        if (!t.starts_with("template<")) || t.starts_with("template<>") {
            return t
        }

        var d: usize = 0
        for var i: usize = 8; i < t.size(); ++i {
            if t[i] == 60 {
                d += 1
            } else if t[i] == 62 {
                d -= 1
                if d == 0 {
                    return TextSink::_trim_(t.subslice(i + 1, t.size() - i - 1))
                }
            }
        }

        return t
    }

    /// The template an explicit specialization head specializes
    /// (`template<> struct __kairo_niche<E> {` is `__kairo_niche`), or "".
    priv static fn _spec_name_(const t: string) -> string {
        var u = t
        if u.starts_with("template<>") {
            u = TextSink::_trim_(u.subslice(10, u.size() - 10))
        } else if u.starts_with("template <>") {
            u = TextSink::_trim_(u.subslice(11, u.size() - 11))
        }

        var at: usize = 0
        if u.starts_with("struct ") {
            at = 7
        } else if u.starts_with("class ") {
            at = 6
        } else if u.starts_with("union ") {
            at = 6
        } else {
            return ""
        }

        var e = at
        while (e < u.size()) && TextSink::_ident_char_(u[e]) {
            e += 1
        }

        if (e == at) || (e >= u.size()) || (u[e] != 60) {
            return ""
        }

        return u.subslice(at, e - at)
    }

    /// The name a namespace-scope variable or alias line declares
    /// (`using A = B;`, `inline constexpr T N = v;`, `extern T const N;`):
    /// the identifier before its first `=`, `{`, `[` or `;`; else "".
    priv static fn _var_name_(const t: string) -> string {
        if t.starts_with("using ") {
            var e: usize = 6
            while (e < t.size()) && TextSink::_ident_char_(t[e]) {
                e += 1
            }

            return t.subslice(6, e - 6)
        }

        var stop: usize = 0
        while (stop < t.size()) && (t[stop] != 61) && (t[stop] != 123) && (t[stop] != 91) && (t[stop] != 59) {
            stop += 1
        }

        var e = stop
        while (e > 0) && (t[e - 1] == 32) {
            e -= 1
        }

        var b = e
        while (b > 0) && TextSink::_ident_char_(t[b - 1]) {
            b -= 1
        }

        if (b == e) || ((t[b] >= 48) && (t[b] <= 57)) {
            return ""
        }

        return t.subslice(b, e - b)
    }

    /// A prototype whose text C++ evaluates where it is declared: a
    /// noexcept(), a requires clause, a decltype() other than the size_t
    /// spelling. It may need any earlier declaration, so it moves above none.
    priv static fn _evaluates_(const piece: string) -> bool {
        if TextSink::_has_(piece, "noexcept(") || TextSink::_has_(piece, "requires") {
            return true
        }

        var n: usize = 0
        var z: usize = 0
        for var i: usize = 0; (i + 9) <= piece.size(); ++i {
            if piece.subslice(i, 9) == "decltype(" {
                n += 1
                if piece.subslice(i, piece.size() - i).starts_with("decltype(sizeof(0))") {
                    z += 1
                }
            }
        }

        return n != z
    }

    /// \p name in \p s as a whole identifier.
    priv static fn _has_word_(const s: string, const name: string) -> bool {
        if name.empty() || (name.size() > s.size()) {
            return false
        }

        for var i: usize = 0; (i + name.size()) <= s.size(); ++i {
            if s.subslice(i, name.size()) != name {
                continue
            }

            var before = (i > 0) && TextSink::_ident_char_(s[i - 1])
            var after  = ((i + name.size()) < s.size()) && TextSink::_ident_char_(s[i + name.size()])
            if (!before) && (!after) {
                return true
            }
        }

        return false
    }

    priv static fn _ident_char_(c: u8) -> bool {
        return ((c >= 97) && (c <= 122)) || ((c >= 65) && (c <= 90)) || ((c >= 48) && (c <= 57)) || (c == 95)
    }

    priv static fn _trim_(const s: string) -> string {
        var a: usize = 0
        while (a < s.size()) && (s[a] == 32) {
            a += 1
        }

        return s.subslice(a, s.size() - a)
    }

    /// \p s without its leading spaces and tabs.
    priv static fn _trim_ws_(const s: string) -> string {
        var a: usize = 0
        while (a < s.size()) && ((s[a] == 32) || (s[a] == 9)) {
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
        self._last_word   = s
        self._put(s)
    }
}
