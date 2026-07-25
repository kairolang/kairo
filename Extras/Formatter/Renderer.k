/// --- The Kairo Project ----------------------------------- Extras/Formatter/Renderer.k --- ///
///
///   
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

fn render_doc(self, doc: Doc, width: i32) -> string {
    var out: string = "";
    var col: i32 = 0;
    self._render_node(doc, width, /*indent*/ 0, /*broken*/ false, &out, &col);
    return out;
}

fn _render_node(self, doc: Doc, width: i32, indent: i32, broken: bool, out: *string, col: *i32, suffixes: *vec::<Doc> ){

    switch doc.kind{
        case DocKind::Text {
            *out += doc.text;
            *col += doc.text.length();
        }
        case DocKind::Concat {
            for (var i : usize = 0; i< doc.children.size(); ++i){
                self.render_node(doc.children[i], width, indent, broken, out, col, suffixes);
            }
        }
        case DocKind::Line {
            if broken { self._flush_and_newline(indent, out, col, suffixes); }
            else      { *out += " "; *col += 1; }
        }
        case DocKind::SoftLine {
            if broken { self._flush_and_newline(indent, out, col, suffixes); }
        }
        case DocKind::HardLine {
            self._flush_and_newline(indent, out, col, suffixes);
        }
        case DocKind::Indent {
            self._render_node(doc.children[0], width, indent + 1, broken, out, col, suffixes);
        }
        case DocKind::Group {
            var child = doc.children[0];
            var forced = self._contains_break_parent(child);
            var will_break = forced || ((*col + self._measure_flat(child)) > width);
            self._render_node(child, width, indent, will_break, out, col, suffixes);
        }
        case DocKind::IfBreak{
            if broken { self._render_node(doc.children[0], width, indent, broken, out, col, suffixes); }
            else      { self._render_node(doc.children[1], width, indent, broken, out, col, suffixes); }
        }
        case DocKind::LineSuffix {
            suffixes->push_back(doc.children[0]);
        }
        case DocKind::BreakParent {
            // no-op at render time; only matters to _contains_break_parent's scan
        }
        case DocKind::Align {
            self._render_align(doc.rows, width, indent, out, col, suffixes);
        }
    }
}