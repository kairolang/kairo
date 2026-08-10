/// --- The Kairo Project ----------------------------------- Extras/Formatter/Renderer.k --- ///
///
///   Wadler-style renderer for the Doc IR: walks a Doc tree and produces the
///   final formatted text. Groups decide flat-vs-broken by measuring their
///   flattened width against the remaining columns.
///
///   The walk is mutually recursive (_render_node <-> _flush_and_newline <->
///   _render_align) and carries no state beyond the explicit out/col/suffixes
///   accumulators. Free functions would need forward declarations to close
///   that cycle, so these are statics on `Renderer`   member lookup inside a
///   class body is order-independent.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import DocIR::*;

class Renderer {
    /// One indent level, in columns.
    static fn indent_width() -> i32 { return 4; }

    /// Flat width for a node that can never fit on one line. Large enough to
    /// lose every `<= width` comparison, small enough not to overflow when
    /// summed across a Concat.
    static fn unfittable() -> i32 { return 1000000; }

    static fn _spaces(n: i32) -> string {
        var s: string = "";
        for var i: i32 = 0; i < n; ++i { s += " "; }
        return s;
    }

    static fn render(doc: Doc, width: i32) -> string {
        var out: string = "";
        var col: i32    = 0;
        var suffixes    = vec::<Doc>();

        Renderer::_render_node(doc, width, /*indent*/ 0, /*broken*/ false, &out, &col, &suffixes);
        Renderer::_flush_suffixes(&out, &col, &suffixes);

        return out;
    }

    /// True if `doc` contains a hardline or an explicit BreakParent, which
    /// forces every enclosing Group to break regardless of measured width.
    static fn _contains_break_parent(doc: Doc) -> bool {
        if (doc.kind == DocKind::HardLine) || (doc.kind == DocKind::BreakParent) {
            return true;
        }

        for var i: usize = 0; i < doc.children.size(); ++i {
            if Renderer::_contains_break_parent(doc.children[i]) { return true; }
        }

        for var i: usize = 0; i < doc.rows.size(); ++i {
            if (doc.rows[i].key != &null) && Renderer::_contains_break_parent(*(doc.rows[i].key)) {
                return true;
            }
            if (doc.rows[i].value != &null) && Renderer::_contains_break_parent(*(doc.rows[i].value)) {
                return true;
            }
        }

        return false;
    }

    /// Width `doc` would occupy printed entirely flat. Line -> one space,
    /// SoftLine -> nothing, HardLine -> unfittable.
    static fn _measure_flat(doc: Doc) -> i32 {
        switch doc.kind {
            case DocKind::Text {
                return static_cast::<i32>(doc.txt.length());
            }
            case DocKind::Concat {
                var w: i32 = 0;
                for var i: usize = 0; i < doc.children.size(); ++i {
                    w += Renderer::_measure_flat(doc.children[i]);
                }
                return w;
            }
            case DocKind::Line     { return 1; }
            case DocKind::SoftLine { return 0; }
            case DocKind::HardLine { return Renderer::unfittable(); }
            case DocKind::Group {
                if doc.children.empty() { return 0; }
                return Renderer::_measure_flat(doc.children[0]);
            }
            case DocKind::Indent {
                if doc.children.empty() { return 0; }
                return Renderer::_measure_flat(doc.children[0]);
            }
            case DocKind::IfBreak {
                // measuring flat means taking the flat arm
                if doc.children.size() < 2 { return 0; }
                return Renderer::_measure_flat(doc.children[1]);
            }
            case DocKind::LineSuffix  { return 0; }
            case DocKind::BreakParent { return 0; }
            case DocKind::Align {
                // an Align block is always one row per line
                return Renderer::unfittable();
            }
        }

        return 0;
    }

    /// Emit pending line suffixes (trailing comments) at the current column.
    /// Suffixes are drained into a local first: rendering one may legally
    /// queue another, and re-entering the live vector while iterating it is a
    /// dangling read.
    static fn _flush_suffixes(out: *string, col: *i32, suffixes: *vec::<Doc>) -> void {
        if suffixes->empty() { return; }

        var pending = *suffixes;
        suffixes->clear();

        var drain = vec::<Doc>();
        for var i: usize = 0; i < pending.size(); ++i {
            Renderer::_render_node(
                pending[i], Renderer::unfittable(),
                /*indent*/ 0, /*broken*/ false, out, col, &drain
            );
        }
    }

    static fn _flush_and_newline(indent: i32, out: *string, col: *i32, suffixes: *vec::<Doc>) -> void {
        Renderer::_flush_suffixes(out, col, suffixes);

        var pad = indent * Renderer::indent_width();
        (*out) += "\n";
        (*out) += Renderer::_spaces(pad);
        (*col)  = pad;
    }

    static fn _render_node(
        doc:      Doc,
        width:    i32,
        indent:   i32,
        broken:   bool,
        out:      *string,
        col:      *i32,
        suffixes: *vec::<Doc>
    ) -> void {

        switch doc.kind {
            case DocKind::Text {
                (*out) += doc.txt;
                (*col) += static_cast::<i32>(doc.txt.length());
            }
            case DocKind::Concat {
                for var i: usize = 0; i < doc.children.size(); ++i {
                    Renderer::_render_node(doc.children[i], width, indent, broken, out, col, suffixes);
                }
            }
            case DocKind::Line {
                if broken { Renderer::_flush_and_newline(indent, out, col, suffixes); }
                else      { (*out) += " "; (*col) += 1; }
            }
            case DocKind::SoftLine {
                if broken { Renderer::_flush_and_newline(indent, out, col, suffixes); }
            }
            case DocKind::HardLine {
                Renderer::_flush_and_newline(indent, out, col, suffixes);
            }
            case DocKind::Indent {
                if doc.children.empty() { return; }
                Renderer::_render_node(doc.children[0], width, indent + 1, broken, out, col, suffixes);
            }
            case DocKind::Group {
                if doc.children.empty() { return; }
                var forced     = Renderer::_contains_break_parent(doc.children[0]);
                var will_break = forced || (((*col) + Renderer::_measure_flat(doc.children[0])) > width);
                Renderer::_render_node(doc.children[0], width, indent, will_break, out, col, suffixes);
            }
            case DocKind::IfBreak {
                if doc.children.size() < 2 { return; }
                if broken { Renderer::_render_node(doc.children[0], width, indent, broken, out, col, suffixes); }
                else      { Renderer::_render_node(doc.children[1], width, indent, broken, out, col, suffixes); }
            }
            case DocKind::LineSuffix {
                if doc.children.empty() { return; }
                suffixes->push_back(doc.children[0]);
            }
            case DocKind::BreakParent {
                return;
            }
            case DocKind::Align {
                Renderer::_render_align(doc.rows, width, indent, out, col, suffixes);
            }
        }
    }

    /// Style rule 2: `key <sep> value`, one row per line, every `sep` in the
    /// block pinned to the column just past the widest flat key.
    static fn _render_align(
        rows:     vec::<AlignRow>,
        width:    i32,
        indent:   i32,
        out:      *string,
        col:      *i32,
        suffixes: *vec::<Doc>
    ) -> void {
        if rows.empty() { return; }

        var key_width: i32 = 0;
        for var i: usize = 0; i < rows.size(); ++i {
            if rows[i].key == &null { continue; }
            var w = Renderer::_measure_flat(*(rows[i].key));
            if w > key_width { key_width = w; }
        }

        for var i: usize = 0; i < rows.size(); ++i {
            if i > 0 { Renderer::_flush_and_newline(indent, out, col, suffixes); }

            var key_start = *col;

            if rows[i].key != &null {
                Renderer::_render_node(*(rows[i].key), width, indent, /*broken*/ false, out, col, suffixes);
            }

            var written = (*col) - key_start;
            if written < key_width {
                (*out) += Renderer::_spaces(key_width - written);
                (*col) += (key_width - written);
            }

            (*out) += rows[i].sep;
            (*col) += static_cast::<i32>(rows[i].sep.length());

            if rows[i].value != &null {
                Renderer::_render_node(*(rows[i].value), width, indent, /*broken*/ false, out, col, suffixes);
            }
        }
    }
}
