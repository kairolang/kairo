/// --- The Kairo Project ------------------ Extras/Formatter/Renderer.k --- ///
///
///   Wadler/prettier renderer for the Doc IR. Iterative over an explicit
///   command stack: a Group goes flat only when it AND the rest of its line fit
///   in the remaining columns, which is what a measure of the group alone
///   cannot tell.
///
///   A command carries its position as a structural level plus extra
///   spaces (`pad`). Levels are written in the indent kind of README 2.3
///   (spaces, or tabs); the pad is always spaces, so an aligned column (rule
///   4.1's aligned form, the keys of 11.3) survives any tab width in an
///   editor. For the width limit a tab counts as `--tab-size` columns (2.3).
///
///   Indentation and flat-Line spaces are owed, not written: they go out with
///   the next text on the line, so blank lines and line ends carry no
///   whitespace.
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

import DocIR::*
import Options::*

pub fn spaces(n: i32) -> string {
    var s: string = ""
    for var i: i32 = 0; i < n; ++i {
        s += " "
    }

    return s
}

/// Display width of \p s: code points, not bytes, so a `é` in a comment or a
/// string does not push its line over the limit early.
pub fn width_of(s: string) -> i32 {
    return s.codepoints() as i32
}

/// Rule 14.4: the last line of \p out holds only closers (`}`, `)`, `]`),
/// then at most one `;` or `,`, then at most a comment.
pub fn closer_only_line(out: string) -> bool {
    var i = out.size()
    while i > 0 && out[i - 1] != ('\n' as u8) {
        i -= 1
    }

    var n = out.size()
    while i < n && (out[i] == (' ' as u8) || out[i] == ('\t' as u8)) {
        i += 1
    }

    var closers: usize = 0
    while i < n && (out[i] == ('}' as u8) || out[i] == (')' as u8) || out[i] == (']' as u8)) {
        closers += 1
        i += 1
    }

    if closers == 0 {
        return false
    }

    if i < n && (out[i] == (';' as u8) || out[i] == (',' as u8)) {
        i += 1
    }

    while i < n && (out[i] == (' ' as u8) || out[i] == ('\t' as u8)) {
        i += 1
    }

    if i >= n {
        return true
    }

    // a trailing comment does not change what the line is
    return i + 1 < n
        && out[i] == ('/' as u8)
        && (out[i + 1] == ('/' as u8) || out[i + 1] == ('*' as u8))
}

/// Pending work: print `doc` at level `ind` plus `pad` spaces, broken or
/// flat. A null `doc` is the literal `lit`; a `lit` of "\n" is a line break
/// the renderer itself decided (a List or Table row).
pub struct Cmd {
    var ind: i32         = 0
    var pad: i32         = 0
    var brk: bool        = true
    var doc: unsafe *Doc = &null
    var lit: string      = ""
}

/// The output and where it stands.
pub class Pen {
    pub var out:  string   = ""
    pub var col:  i32      = 0
    pub var oind: i32      = 0    ///< indent level owed before the next text on this line
    pub var opad: i32      = 0    ///< alignment spaces owed after it
    pub var sp:   i32      = 0    ///< spaces owed by flat Lines; a newline drops them
    pub var bol:  bool     = true ///< nothing printed on this line yet
    pub var set:  Settings

    fn Pen(self) = default

    /// Columns one indent level takes.
    fn level_cols(self) -> i32 {
        if self.set.use_tabs {
            return self.set.tab_size * self.set.tab_size
        }

        return self.set.tab_size
    }

    fn indent_text(self, ind: i32, pad: i32) -> string {
        var s: string = ""
        if self.set.use_tabs {
            for var i: i32 = 0; i < ind * self.set.tab_size; ++i {
                s += "\t"
            }
        } else {
            s += spaces(ind * self.set.tab_size)
        }

        s += spaces(pad)
        return s
    }

    /// The column the next text would start at.
    fn at(self) -> i32 {
        if self.bol {
            return self.oind * self.level_cols() + self.opad
        }

        return self.col + self.sp
    }

    fn put(self, s: string) {
        if s.length() == 0 {
            return
        }

        if self.bol {
            self.out += self.indent_text(self.oind, self.opad)
            self.col = self.oind * self.level_cols() + self.opad
            self.bol = false
        } else if self.sp > 0 {
            self.out += spaces(self.sp)
            self.col += self.sp
        }

        self.sp = 0
        self.out += s
        self.col += width_of(s)
    }

    fn newline(self, ind: i32, pad: i32) {
        self.out += "\n"
        self.col  = 0
        self.sp   = 0
        self.oind = ind
        self.opad = pad
        self.bol  = true
    }
}

pub class Renderer {
    /// Flat width of a node that can never be flat. Large enough to lose every
    /// comparison, small enough not to overflow when summed.
    static fn unfittable() -> i32 {
        return 1000000
    }

    /// Width of \p doc printed flat; unfittable when it holds a hard break.
    static fn flat_width(doc: unsafe *Doc) -> i32 {
        if doc->hard {
            return Renderer::unfittable()
        }

        var k = doc->kind
        if k == DocKind::Text {
            return width_of(doc->txt)
        }

        if k == DocKind::Line {
            return 1
        }

        if k == DocKind::SoftLine || k == DocKind::LineSuffix || k == DocKind::BreakParent {
            return 0
        }

        if k == DocKind::IfBreak {
            if doc->children.size() < 2 {
                return 0
            }

            return Renderer::flat_width(unsafe &doc->children[1])
        }

        if k == DocKind::List || k == DocKind::Group {
            if doc->children.empty() {
                return 0
            }

            return Renderer::flat_width(unsafe &doc->children[0])
        }

        var w: i32 = 0
        for var i: usize = 0; i < doc->children.size(); ++i {
            w += Renderer::flat_width(unsafe &doc->children[i])
            if w >= Renderer::unfittable() {
                return Renderer::unfittable()
            }
        }

        return w
    }

    static fn render(doc: unsafe *Doc, set: Settings) -> string {
        var pen = Pen()
        pen.set = set
        var width = line_width()
        var stack = cxx::std::vector<Cmd>()
        var sfx   = cxx::std::vector<Cmd>()

        stack.push_back(Cmd { ind: 0, pad: 0, brk: true, doc: doc, lit: "" })

        while true {
            while !stack.empty() {
                var c = stack.back()
                stack.pop_back()

                if Renderer::_is_newline(c) {
                    // line suffixes go out before the break that ends their line
                    if !sfx.empty() {
                        stack.push_back(c)
                        Renderer::_drain(unsafe &stack, unsafe &sfx)
                        continue
                    }

                    // rule 14.4: a blank line after a line of closers only
                    if c.doc != &null
                        && c.doc->kind == DocKind::GapLine
                        && !pen.bol
                        && closer_only_line(pen.out) {
                        pen.out += "\n"
                    }

                    // a literal line's text is the literal's own: no indent of ours
                    if c.doc != &null && c.doc->kind == DocKind::LiteralLine {
                        pen.newline(0, 0)
                    } else {
                        pen.newline(c.ind, c.pad)
                    }

                    continue
                }

                if c.doc == &null {
                    pen.put(c.lit)
                    continue
                }

                var unsafe *d = c.doc
                var        k  = d->kind

                if k == DocKind::Text {
                    pen.put(d->txt)
                    continue
                }

                if k == DocKind::Concat {
                    var i = d->children.size()
                    while i > 0 {
                        i -= 1
                        stack.push_back(
                            Cmd {
                                ind: c.ind,
                                pad: c.pad,
                                brk: c.brk,
                                doc: unsafe &d->children[i],
                                lit: "",
                            },
                        )
                    }

                    continue
                }

                if k == DocKind::Indent {
                    if d->children.empty() {
                        continue
                    }

                    stack.push_back(
                        Cmd {
                            ind: c.ind + 1,
                            pad: c.pad,
                            brk: c.brk,
                            doc: unsafe &d->children[0],
                            lit: "",
                        },
                    )

                    continue
                }

                if k == DocKind::Align {
                    if d->children.empty() {
                        continue
                    }

                    var pad = pen.at() - c.ind * pen.level_cols()
                    stack.push_back(
                        Cmd {
                            ind: c.ind,
                            pad: pad,
                            brk: c.brk,
                            doc: unsafe &d->children[0],
                            lit: "",
                        },
                    )

                    continue
                }

                if k == DocKind::Group {
                    if d->children.empty() {
                        continue
                    }

                    var unsafe *child = unsafe &d->children[0]
                    var flat = Cmd { ind: c.ind, pad: c.pad, brk: false, doc: child, lit: "" }
                    var ok   = !c.brk
                    if !ok && !d->hard && Renderer::_fits(flat, unsafe &stack, width - pen.at()) {
                        ok = d->num <= 0 || pen.at() + Renderer::flat_width(child) <= d->num
                    }

                    if ok {
                        stack.push_back(flat)
                    } else {
                        // a choice breaks into its second child
                        var unsafe *bd = if d->children.size() > 1 => unsafe &d->children[1]
                                         else => child
                        stack.push_back(Cmd { ind: c.ind, pad: c.pad, brk: true, doc: bd, lit: "" })
                    }

                    continue
                }

                // only flat Lines reach here; broken ones were newlines above
                if k == DocKind::Line {
                    pen.sp += 1
                    continue
                }

                if k == DocKind::IfBreak {
                    if d->children.size() < 2 {
                        continue
                    }

                    var arm: usize = if c.brk => 0 else => 1
                    stack.push_back(
                        Cmd {
                            ind: c.ind,
                            pad: c.pad,
                            brk: c.brk,
                            doc: unsafe &d->children[arm],
                            lit: "",
                        },
                    )

                    continue
                }

                if k == DocKind::LineSuffix {
                    if d->children.empty() {
                        continue
                    }

                    sfx.push_back(
                        Cmd {
                            ind: c.ind,
                            pad: c.pad,
                            brk: false,
                            doc: unsafe &d->children[0],
                            lit: "",
                        },
                    )

                    continue
                }

                if k == DocKind::List {
                    Renderer::_list(unsafe &stack, d, c, unsafe &pen, width)
                    continue
                }

                if k == DocKind::Table {
                    Renderer::_table(unsafe &stack, d, c)
                    continue
                }

                // SoftLine flat, BreakParent: nothing to print
            }

            if sfx.empty() {
                break
            }

            Renderer::_drain(unsafe &stack, unsafe &sfx)
        }

        if !pen.bol {
            pen.out += "\n"
        }

        return pen.out
    }

    priv static fn _is_newline(c: Cmd) -> bool {
        if c.doc == &null {
            return c.lit == "\n"
        }

        var k = c.doc->kind
        if k == DocKind::HardLine || k == DocKind::LiteralLine || k == DocKind::GapLine {
            return true
        }

        if k == DocKind::Line || k == DocKind::SoftLine {
            return c.brk
        }

        return false
    }

    priv static fn _drain(stack: unsafe *cxx::std::vector<Cmd>,
                          sfx:   unsafe *cxx::std::vector<Cmd>) {
        var i = sfx->size()
        while i > 0 {
            i -= 1
            stack->push_back((*sfx)[i])
        }

        sfx->clear()
    }

    /// \p seq, in print order, onto the stack (which pops from the back).
    priv static fn _push_seq(stack: unsafe *cxx::std::vector<Cmd>,
                             seq:   unsafe *cxx::std::vector<Cmd>) {
        var i = seq->size()
        while i > 0 {
            i -= 1
            stack->push_back((*seq)[i])
        }
    }

    priv static fn _lit(ind: i32, pad: i32, s: string) -> Cmd {
        return Cmd { ind: ind, pad: pad, brk: false, doc: &null, lit: s }
    }

    priv static fn _nl(ind: i32, pad: i32) -> Cmd {
        return Cmd { ind: ind, pad: pad, brk: true, doc: &null, lit: "\n" }
    }

    /// Rule 4.1. Flat when it fits (and, for a call, ends by its cap);
    /// otherwise the grid, aligned or block form, where the list allows it.
    priv static fn _list(stack: unsafe *cxx::std::vector<Cmd>,
                         d:     unsafe *Doc,
                         c:     Cmd,
                         pen:   unsafe *Pen,
                         width: i32) {
        var        open  = d->seps[0]
        var        close = d->seps[1]
        var        n     = (d->children.size() - 1) / 2
        var unsafe *flat = unsafe &d->children[0]
        var        set   = pen->set

        if n == 0 {
            stack->push_back(Renderer::_lit(c.ind, c.pad, open + close))
            return
        }

        if (d->flags & LIST_CASEGRID()) != 0 {
            Renderer::_case_grid(stack, d, c, pen, width, n)
            return
        }

        var force = (d->flags & LIST_FORCE()) != 0
        if !force {
            var fc = Cmd { ind: c.ind, pad: c.pad, brk: false, doc: flat, lit: "" }
            var ok = !c.brk
            if !ok && !d->hard && Renderer::_fits(fc, stack, width - pen->at()) {
                ok = d->num <= 0 || pen->at() + Renderer::flat_width(flat) <= d->num
            }

            if ok {
                stack->push_back(fc)
                return
            }
        }

        // widest key and value, and whether every item is a short keyless cell
        var kw:         i32 = 0
        var vw:         i32 = 0
        var short_cells     = true
        for var i: usize = 0; i < n; ++i {
            var unsafe *key = unsafe &d->children[1 + 2 * i]
            var unsafe *val = unsafe &d->children[2 + 2 * i]
            var        k    = Renderer::flat_width(key)
            var        v    = Renderer::flat_width(val)
            if k > kw {
                kw = k
            }

            if v > vw {
                vw = v
            }

            if !key->is_empty() || v > grid_max_item() {
                short_cells = false
            }
        }

        var keys = set.align && (d->flags & LIST_KEYS()) != 0 && kw > 0

        var grid_ok = (d->flags & LIST_GRID()) != 0 && n > grid_min_items() && short_cells
        if !set.align && rules().grid_off_without_align {
            grid_ok = false
        }

        if grid_ok {
            Renderer::_grid(stack, d, c, pen, width, n)
            return
        }

        var aligned = set.align && (d->flags & LIST_ALIGNED()) != 0
        if aligned && (d->flags & LIST_FALLBACK()) != 0 {
            // the widest row at the opener's column, plus its `,` or `)`
            var row = vw + 1
            if keys {
                row += kw + 1
            }

            if pen->at() + width_of(open) + row > width {
                aligned = false
            }
        }

        var seq = cxx::std::vector<Cmd>()
        seq.push_back(Renderer::_lit(c.ind, c.pad, open))

        if aligned {
            var col = pen->at() + width_of(open)
            var pad = col - c.ind * pen->level_cols()
            for var i: usize = 0; i < n; ++i {
                if i > 0 {
                    seq.push_back(Renderer::_lit(c.ind, pad, ","))
                    seq.push_back(Renderer::_nl(c.ind, pad))
                }

                Renderer::_item(unsafe &seq, d, i, c.ind, pad, keys, kw)
            }

            seq.push_back(Renderer::_lit(c.ind, pad, close))
            Renderer::_push_seq(stack, unsafe &seq)
            return
        }

        var trail = (d->flags & LIST_NOTRAIL()) == 0
        for var i: usize = 0; i < n; ++i {
            seq.push_back(Renderer::_nl(c.ind + 1, c.pad))
            Renderer::_item(unsafe &seq, d, i, c.ind + 1, c.pad, keys, kw)
            if i + 1 < n || trail {
                seq.push_back(Renderer::_lit(c.ind + 1, c.pad, ","))
            }
        }

        seq.push_back(Renderer::_nl(c.ind, c.pad))
        seq.push_back(Renderer::_lit(c.ind, c.pad, close))
        Renderer::_push_seq(stack, unsafe &seq)
    }

    /// One list item: its key padded to \p kw (when \p keys), then its value.
    priv static fn _item(seq:  unsafe *cxx::std::vector<Cmd>,
                         d:    unsafe *Doc,
                         i:    usize,
                         ind:  i32,
                         pad:  i32,
                         keys: bool,
                         kw:   i32) {
        var unsafe *key = unsafe &d->children[1 + 2 * i]
        var unsafe *val = unsafe &d->children[2 + 2 * i]
        if !key->is_empty() {
            seq->push_back(Cmd { ind: ind, pad: pad, brk: false, doc: key, lit: "" })
            var gap: i32 = 1
            if keys {
                gap += kw - Renderer::flat_width(key)
            }

            seq->push_back(Renderer::_lit(ind, pad, spaces(gap)))
        }

        seq->push_back(Cmd { ind: ind, pad: pad, brk: true, doc: val, lit: "" })
    }

    /// Rule 4.1's grid: row-major, each column padded to its widest `item,`,
    /// as many columns (at most grid_max_cols) as fit at the list's indent;
    /// the last cell of a row is not padded. Scripts/import_lint.py's
    /// grid_rows is the same layout.
    priv static fn _grid(stack: unsafe *cxx::std::vector<Cmd>,
                         d:     unsafe *Doc,
                         c:     Cmd,
                         pen:   unsafe *Pen,
                         width: i32,
                         n:     usize) {
        var cw = cxx::std::vector<i32>()
        for var i: usize = 0; i < n; ++i {
            cw.push_back(Renderer::flat_width(unsafe &d->children[2 + 2 * i]) + 1)
        }

        var lead = (c.ind + 1) * pen->level_cols() + c.pad

        var ncol: usize = grid_max_cols()
        if ncol > n {
            ncol = n
        }

        var widths = cxx::std::vector<i32>()
        while ncol >= 1 {
            widths.clear()
            for var k: usize = 0; k < ncol; ++k {
                widths.push_back(0)
            }

            for var i: usize = 0; i < n; ++i {
                if cw[i] > widths[i % ncol] {
                    widths[i % ncol] = cw[i]
                }
            }

            var widest: i32   = 0
            var i:      usize = 0
            while i < n {
                var w: i32   = 0
                var k: usize = 0
                while k < ncol && i + k < n {
                    var last = k + 1 == ncol || i + k + 1 == n
                    w += if last => cw[i + k] else => widths[k] + 1
                    k += 1
                }

                if w > widest {
                    widest = w
                }

                i += ncol
            }

            if ncol == 1 || lead + widest <= width {
                break
            }

            ncol -= 1
        }

        var seq = cxx::std::vector<Cmd>()
        seq.push_back(Renderer::_lit(c.ind, c.pad, d->seps[0]))
        for var i: usize = 0; i < n; ++i {
            var k = i % ncol
            if k == 0 {
                seq.push_back(Renderer::_nl(c.ind + 1, c.pad))
            }

            seq.push_back(
                Cmd {
                    ind: c.ind + 1,
                    pad: c.pad,
                    brk: false,
                    doc: unsafe &d->children[2 + 2 * i],
                    lit: "",
                },
            )

            var last = k + 1 == ncol || i + 1 == n
            if last {
                seq.push_back(Renderer::_lit(c.ind + 1, c.pad, ","))
            } else {
                seq.push_back(Renderer::_lit(c.ind + 1, c.pad, "," + spaces(widths[k] - cw[i] + 1)))
            }
        }

        seq.push_back(Renderer::_nl(c.ind, c.pad))
        seq.push_back(Renderer::_lit(c.ind, c.pad, d->seps[1]))
        Renderer::_push_seq(stack, unsafe &seq)
    }

    /// Rule 8.4's `case` grid: the first row continues the
    /// current line, the others start at its column; each column padded to
    /// its widest `item,`; as many columns (at most grid_max_cols) as fit;
    /// row-major, only the last row short; no `,` after the last item. The
    /// last row also leaves room for the ` {` / ` =>` that follows it.
    priv static fn _case_grid(stack: unsafe *cxx::std::vector<Cmd>,
                              d:     unsafe *Doc,
                              c:     Cmd,
                              pen:   unsafe *Pen,
                              width: i32,
                              n:     usize) {
        var cw = cxx::std::vector<i32>()
        for var i: usize = 0; i < n; ++i {
            var w = Renderer::flat_width(unsafe &d->children[2 + 2 * i]) + 1
            if i + 1 == n {
                w += 2
            }

            cw.push_back(w)
        }

        var lead = pen->at()

        var ncol: usize = grid_max_cols()
        if ncol > n {
            ncol = n
        }

        var widths = cxx::std::vector<i32>()
        while ncol >= 1 {
            widths.clear()
            for var k: usize = 0; k < ncol; ++k {
                widths.push_back(0)
            }

            for var i: usize = 0; i < n; ++i {
                if cw[i] > widths[i % ncol] {
                    widths[i % ncol] = cw[i]
                }
            }

            var widest: i32   = 0
            var i:      usize = 0
            while i < n {
                var w: i32   = 0
                var k: usize = 0
                while k < ncol && i + k < n {
                    var last = k + 1 == ncol || i + k + 1 == n
                    w += if last => cw[i + k] else => widths[k] + 1
                    k += 1
                }

                if w > widest {
                    widest = w
                }

                i += ncol
            }

            if ncol == 1 || lead + widest <= width {
                break
            }

            ncol -= 1
        }

        // the widths were measured with the last item's ` {`; a column it
        // alone widened is padded only as wide as its `item,` needs
        widths.clear()
        for var k: usize = 0; k < ncol; ++k {
            widths.push_back(0)
        }

        for var i: usize = 0; i < n; ++i {
            var w = if i + 1 == n => cw[i] - 2 else => cw[i]
            if w > widths[i % ncol] {
                widths[i % ncol] = w
            }
        }

        var pad = lead - c.ind * pen->level_cols()
        var seq = cxx::std::vector<Cmd>()
        for var i: usize = 0; i < n; ++i {
            var k = i % ncol
            if k == 0 && i > 0 {
                seq.push_back(Renderer::_nl(c.ind, pad))
            }

            seq.push_back(
                Cmd {
                    ind: c.ind,
                    pad: pad,
                    brk: false,
                    doc: unsafe &d->children[2 + 2 * i],
                    lit: "",
                },
            )

            if i + 1 == n {
                break
            }

            var last = k + 1 == ncol
            if last {
                seq.push_back(Renderer::_lit(c.ind, pad, ","))
            } else {
                var iw = Renderer::flat_width(unsafe &d->children[2 + 2 * i]) + 1
                seq.push_back(Renderer::_lit(c.ind, pad, "," + spaces(widths[k] - iw + 1)))
            }
        }

        Renderer::_push_seq(stack, unsafe &seq)
    }

    /// Section 11: one row per line, each column padded to its widest cell.
    /// A row stops at its last non-empty cell, so nothing trails it.
    priv static fn _table(stack: unsafe *cxx::std::vector<Cmd>, d: unsafe *Doc, c: Cmd) {
        var cols = d->num as usize
        if cols == 0 {
            return
        }

        var rows = d->children.size() / cols

        var w = cxx::std::vector<i32>()
        for var k: usize = 0; k < cols; ++k {
            w.push_back(0)
        }

        for var r: usize = 0; r < rows; ++r {
            for var k: usize = 0; k < cols; ++k {
                var cw = Renderer::flat_width(unsafe &d->children[r * cols + k])
                if cw > w[k] {
                    w[k] = cw
                }
            }
        }

        var seq = cxx::std::vector<Cmd>()
        for var r: usize = 0; r < rows; ++r {
            if r > 0 {
                seq.push_back(Renderer::_nl(c.ind, c.pad))
            }

            var last: usize = 0
            for var k: usize = 0; k < cols; ++k {
                if !d->children[r * cols + k].is_empty() {
                    last = k
                }
            }

            for var k: usize = 0; k <= last; ++k {
                var unsafe *cell        = unsafe &d->children[r * cols + k]
                var        sep:  string = ""
                if k > 0 && w[k] > 0 {
                    sep = d->seps[k]
                }

                if cell->is_empty() {
                    // an empty cell under a later one: pad past it, separator included
                    if w[k] > 0 {
                        seq.push_back(Renderer::_lit(c.ind, c.pad, spaces(width_of(sep) + w[k])))
                    }

                    continue
                }

                if sep.length() > 0 {
                    seq.push_back(Renderer::_lit(c.ind, c.pad, sep))
                }

                seq.push_back(Cmd { ind: c.ind, pad: c.pad, brk: false, doc: cell, lit: "" })
                if k < last {
                    var gap = w[k] - Renderer::flat_width(cell)
                    if gap > 0 {
                        seq.push_back(Renderer::_lit(c.ind, c.pad, spaces(gap)))
                    }
                }
            }
        }

        Renderer::_push_seq(stack, unsafe &seq)
    }

    /// Does \p next fit in \p rem0 columns, followed by the rest of its line?
    /// The rest is the pending stack, read from the top down in its own modes.
    priv static fn _fits(next: Cmd, stack: unsafe *cxx::std::vector<Cmd>, rem0: i32) -> bool {
        var rem  = rem0
        var rest = stack->size()
        var work = cxx::std::vector<Cmd>()
        work.push_back(next)

        while true {
            if rem < 0 {
                return false
            }

            if work.empty() {
                if rest == 0 {
                    return true
                }

                rest -= 1
                work.push_back((*stack)[rest])
                continue
            }

            var c = work.back()
            work.pop_back()

            if c.doc == &null {
                if c.lit == "\n" {
                    return true
                }

                rem -= width_of(c.lit)
                continue
            }

            var unsafe *d = c.doc
            var        k  = d->kind

            if k == DocKind::Text {
                rem -= width_of(d->txt)
                continue
            }

            if k == DocKind::Concat {
                var i = d->children.size()
                while i > 0 {
                    i -= 1
                    work.push_back(
                        Cmd {
                            ind: c.ind,
                            pad: c.pad,
                            brk: c.brk,
                            doc: unsafe &d->children[i],
                            lit: "",
                        },
                    )
                }

                continue
            }

            if k == DocKind::Group || k == DocKind::Indent {
                if d->children.empty() {
                    continue
                }

                var b          = c.brk || k == DocKind::Group && d->hard
                var arm: usize = if b && d->children.size() > 1 => 1 else => 0
                work.push_back(
                    Cmd { ind: c.ind, pad: c.pad, brk: b, doc: unsafe &d->children[arm], lit: "" },
                )

                continue
            }

            if k == DocKind::List {
                // flat inside a flat parent; otherwise it may break right after its opener
                if c.brk || d->hard {
                    rem -= width_of(d->seps[0])
                    return rem >= 0
                }

                work.push_back(
                    Cmd {
                        ind: c.ind,
                        pad: c.pad,
                        brk: false,
                        doc: unsafe &d->children[0],
                        lit: "",
                    },
                )

                continue
            }

            if k == DocKind::Line {
                if c.brk {
                    return true
                }

                rem -= 1
                continue
            }

            if k == DocKind::SoftLine {
                if c.brk {
                    return true
                }

                continue
            }

            if k == DocKind::HardLine
                || k == DocKind::LiteralLine
                || k == DocKind::Table
                || k == DocKind::GapLine {
                return true
            }

            if k == DocKind::Align {
                if d->children.empty() {
                    continue
                }

                work.push_back(
                    Cmd {
                        ind: c.ind,
                        pad: c.pad,
                        brk: c.brk,
                        doc: unsafe &d->children[0],
                        lit: "",
                    },
                )

                continue
            }

            if k == DocKind::IfBreak {
                if d->children.size() < 2 {
                    continue
                }

                var arm: usize = if c.brk => 0 else => 1
                work.push_back(
                    Cmd {
                        ind: c.ind,
                        pad: c.pad,
                        brk: c.brk,
                        doc: unsafe &d->children[arm],
                        lit: "",
                    },
                )

                continue
            }

            // LineSuffix, BreakParent: zero width
        }

        return true
    }
}
