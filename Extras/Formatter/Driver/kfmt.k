/// --- The Kairo Project ----------------------------------- Extras/Formatter/Driver/kfmt.k --- ///
///
///   <short description>
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import AST::Printer::PrintCore::*;
import AST::Context::ASTContext::*;
import AST::Mixin::TypeQual::*;
import AST::Kind::PatternKind::*;
import Token::TokenKind::*;
import AST::Node::Types::*;
import AST::Kind::TypeKind::*;
import AST::Node::Declarations::*;

enum DocKind derives u8 {
    Text,
    Concat,
    Line,
    SoftLine,
    HardLine,
    Group,
    Indent,
    IfBreak,
    LineSuffix,
    BreakParent,
    Align,
}



/// One row of an Align block: `key <sep> value`, e.g. `item1 = 67` or
/// `var item1 : u32`. `key` is padded to the widest sibling key's flat
/// width before `sep` is printed.
class AlignRow {
    pub var key:   Doc;
    pub var sep:   string;
    pub var value: Doc;

    fn AlignRow(self, key: Doc, sep: string, value: Doc) {
        self.key   = key;
        self.sep   = sep;
        self.value = value;
    }
}

class Doc {
    pub var kind:     DocKind;
    pub var text:     string        = "";
    pub var children: vec::<Doc>    = vec::<Doc>();
    pub var rows:      vec::<AlignRow> = vec::<AlignRow>();

    default fn Doc(self);

    /// ----------------------------------------------------------------------
    /// Methods created for the purpose of construction docs
    /// ----------------------------------------------------------------------

    static fn text(s: string) -> Doc {
        var d = Doc{};
        d.kind = DocKind::Text;
        d.text = s;
        return d;
    }

    static fn concat(xs: vec::<Doc>) -> Doc {
        var d = Doc{};
        d.kind     = DocKind::Concat;
        d.children = xs;
        return d;
    }

    static fn line() -> Doc {
        var d = Doc{};
        d.kind = DocKind::Line;
        return d;
    }

    static fn softline() -> Doc {
        var d = Doc{};
        d.kind = DocKind::SoftLine;
        return d;
    }

    static fn hardline() -> Doc {
        var d = Doc{};
        d.kind = DocKind::HardLine;
        return d;
    }

    static fn group(child: Doc) -> Doc {
        var d = Doc{};
        d.kind = DocKind::Group;
        d.children.push_back(child);
        return d;
    }

    static fn indent(child: Doc) -> Doc {
        var d = Doc{};
        d.kind = DocKind::Indent;
        d.children.push_back(child);
        return d;
    }

    /// `when_broken` is used if the nearest enclosing Group broke;
    /// `when_flat` is used if it stayed flat.
    static fn if_break(when_broken: Doc, when_flat: Doc) -> Doc {
        var d = Doc{};
        d.kind = DocKind::IfBreak;
        d.children.push_back(when_broken);
        d.children.push_back(when_flat);
        return d;
    }

    static fn line_suffix(child: Doc) -> Doc {
        var d = Doc{};
        d.kind = DocKind::LineSuffix;
        d.children.push_back(child);
        return d;
    }

    static fn break_parent() -> Doc {
        var d = Doc{};
        d.kind = DocKind::BreakParent;
        return d;
    }

    static fn align(rows: vec::<AlignRow>) -> Doc {
        var d = Doc{};
        d.kind = DocKind::Align;
        d.rows = rows;
        return d;
    }

    // ----------------------------------------------------------------------
    //  Convenience helpers
    // ----------------------------------------------------------------------

    /// for "did this sub-piece produce nothing" checks (e.g. fmt_quals with no flags set) without every caller having to special-case an empty vec.
    fn is_empty(self) -> bool {
        return (self.kind == DocKind::Concat) && self.children.is_empty();
    }

    static fn nothing() -> Doc {
        return Doc::concat(vec::<Doc>());
    }
}


/// ----------------------------------------------------------------------
/// Format Classifiers
/// ----------------------------------------------------------------------

fn fmt_quals(self, ty: *Type) -> Doc {
    type TQ = TypeQual::<Type>;
    var f = static_cast::<u8>(ty->flags);
    var parts = vec::<Doc>();
    if (f & static_cast::<u8>(TQ::Flags::IsConst))    != 0 { parts.push_back(Doc::text("const "));    }
    if (f & static_cast::<u8>(TQ::Flags::IsVolatile)) != 0 { parts.push_back(Doc::text("volatile ")); }
    if (f & static_cast::<u8>(TQ::Flags::IsAtomic))   != 0 { parts.push_back(Doc::text("atomic "));   }
    if (f & static_cast::<u8>(TQ::Flags::IsUnsafe))   != 0 { parts.push_back(Doc::text("unsafe "));   }
    if (f & static_cast::<u8>(TQ::Flags::IsEval))     != 0 { parts.push_back(Doc::text("eval "));     }
    if (f & static_cast::<u8>(TQ::Flags::IsAsync))    != 0 { parts.push_back(Doc::text("async "));    }
    if (f & static_cast::<u8>(TQ::Flags::IsYield))    != 0 { parts.push_back(Doc::text("yield "));    }
    if (f & static_cast::<u8>(TQ::Flags::IsPanic))    != 0 { parts.push_back(Doc::text("panic "));    }
    return Doc::concat(parts);
}

fn fmt_type(self, ty: *Type) -> Doc {
    if ty == &null    { return Doc::text("<error>"); }
    if ty->is_error() { return Doc::text("<error>"); }

    if isa::<ChainType>(ty)             { return self._ft_chain(cast::<ChainType>(ty)); }
    if isa::<GenericParamType>(ty)      { return self._ft_generic_param(cast::<GenericParamType>(ty)); }
    if isa::<SubstGenericParamType>(ty) { return self.fmt_type(cast::<SubstGenericParamType>(ty)->replacement); }
    if isa::<TypeOfType>(ty) {
        return Doc::concat([ self.fmt_quals(ty), Doc::text("typeof"), Doc::text("(...)") ]);
    }
    if isa::<VariadicPackType>(ty) {
        return Doc::concat([ Doc::text("..."), self.fmt_type(cast::<VariadicPackType>(ty)->param) ]);
    }
    if isa::<PackExpansionType>(ty) {
        return Doc::concat([ self.fmt_type(cast::<PackExpansionType>(ty)->pattern), Doc::text("...") ]);
    }
    if isa::<PointerType>(ty) {
        return Doc::concat([ self.fmt_quals(ty), Doc::text("*"), self.fmt_type(cast::<PointerType>(ty)->pointee) ]);
    }
    if isa::<NullableType>(ty) {
        return Doc::concat([ self.fmt_quals(ty), self.fmt_type(cast::<NullableType>(ty)->inner), Doc::text("?") ]);
    }
    if isa::<TupleType>(ty)      { return self._ft_tuple(cast::<TupleType>(ty)); }
    if isa::<FixedArrayType>(ty) { return self._ft_fixed_array(cast::<FixedArrayType>(ty)); }
    if isa::<VectorType>(ty) {
        return Doc::concat([ self.fmt_quals(ty), Doc::text("["), self.fmt_type(cast::<VectorType>(ty)->element), Doc::text("]") ]);
    }
    if isa::<MapType>(ty) { return self._ft_map(cast::<MapType>(ty)); }
    if isa::<SetType>(ty) {
        return Doc::concat([ self.fmt_quals(ty), Doc::text("{"), self.fmt_type(cast::<SetType>(ty)->element), Doc::text("}") ]);
    }
    if isa::<SelfType>(ty) { return Doc::concat([ self.fmt_quals(ty), Doc::text("Self") ]); }
    if isa::<FunctionPointerType>(ty) { return self._ft_fn_ptr(cast::<FunctionPointerType>(ty)); }
    if isa::<InferredType>(ty)  { return Doc::text("_"); }
    if isa::<CXXLValueRefType>(ty) {
        return Doc::concat([ self.fmt_quals(ty), self.fmt_type(cast::<CXXLValueRefType>(ty)->referee), Doc::text("&") ]);
    }
    if isa::<CXXRValueRefType>(ty) {
        return Doc::concat([ self.fmt_quals(ty), self.fmt_type(cast::<CXXRValueRefType>(ty)->referee), Doc::text("&&") ]);
    }
    if isa::<OpaqueFFIType>(ty) { return Doc::text(self.istr(cast::<OpaqueFFIType>(ty)->name)); }
    if isa::<TypeExpr>(ty) {
        return Doc::concat([ self.fmt_quals(ty), self.fmt_expr(cast::<TypeExpr>(ty)->expr) ]);
    }

    return Doc::text("<error>");
}


fn _ft_chain(self, ty: *ChainType) -> Doc {
    var parts = vec::<Doc>();
    parts.push_back(self.fmt_quals(ty));
    if ty->segments.is_empty() { return Doc::text("<error>"); }
    for var i: usize = 0; i < ty->segments.size(); ++i {
        var seg = ty->segments.get(i);
        if seg->sep == ChainType::SegmentSeparator::ColonColon {
            parts.push_back(Doc::text("::"));
        }
        if seg->name == &null { parts.push_back(Doc::text("<error>")); continue; }
        parts.push_back(Doc::text(self.tok(seg->name->name)));
        parts.push_back(self.fmt_generic_args(seg->generic_args));
    }
    return Doc::concat(parts);
}


fn _ft_generic_param(self, ty: *GenericParamType) -> Doc {
    var parts = vec::<Doc>();
    parts.push_back(self.fmt_quals(ty));
    if ty->is_pack { parts.push_back(Doc::text("...")); }
    if ty->param_name == &null { return Doc::text("<error>"); }
    parts.push_back(Doc::text(self.tok(ty->param_name->name)));
    return Doc::concat(parts);
}


fn _ft_tuple(self, ty: *TupleType) -> Doc {
    var items = vec::<Doc>();
    for (var i: usize = 0; i < ty->elements.size(); ++i) {
        if i > 0 { items.push_back(Doc::text(",")); items.push_back(Doc::line()); }
        items.push_back(self.fmt_type(ty->elements[i]));
    }
    return Doc::concat([
        self.fmt_quals(ty),
        Doc::text("("),
        Doc::group(Doc::concat(items)),
        Doc::text(")"),
    ]);
}


fn fmt_program(self, prog: *TranslationUnit) -> Doc {
    var items = vec::<Doc>();
    var n = prog->items.size();

    var prev_end_line: i32 = -1;

    for var i: usize = 0; i < n; ++i {
        var item = prog->items.get(i);
        if item == &null { continue; }

        // Rule 3: blank-line preservation, capped at 4
        if prev_end_line >= 0 {
            var gap = self._blank_lines_before(prev_end_line, item->range.start.line);
            for var b: usize = 0; b < gap; ++b { items.push_back(Doc::hardline()); }
        }

        switch item->get_kind() {
            case TopLevelKind::Decl { items.push_back(self.fmt_decl(item->as_decl())); }
            case TopLevelKind::Stmt { items.push_back(self.fmt_stmt(item->as_stmt())); }
            case TopLevelKind::Expr { items.push_back(self.fmt_expr(item->as_expr())); }
            default { items.push_back(Doc::text("<unknown-top-level>")); }
        }

        items.push_back(Doc::hardline());
        prev_end_line = item->range.end.line;
    }

    return Doc::concat(items);
}



/// ----------------------------------------------------------------------
/// RENDERER 
/// ----------------------------------------------------------------------

 
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
            })
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



/// ----------------------------------------------------------------------
/// DRIVER
/// ----------------------------------------------------------------------

fn format_one_file(path: libcxx::filesystem::path) -> bool {
    var tu: *TranslationUnit = parse_file(path);

    if tu == &null {
        return false;
    }

    var doc: Doc = fmt_program(tu->program);
    var output: string = render(doc, 100);

    var out = libcxx::ofstream(path, libcxx::ios::binary);
    out << output;
    out.flush();

    return true;
}

fn main(argc: i32, argv: *(*kairo::std::Legacy::char)) -> i32 {
    if argc != 2 {
        std::print("Usage: kfmt <input_folder>/<input_file>");
        return 1;
    }

    var target_path = argv[1];
    var path = libcxx::filesystem::path(target_path);

    if !libcxx::filesystem::exists(path) {
        std::print(f"Error: path does not exist: {target_path}");
        return 1;
    }

    var files_formatted: usize = 0;

    if libcxx::filesystem::is_directory(path) {
        for entry in libcxx::filesystem::recursive_directory_iterator(path) {
            if entry.is_regular_file() && (entry.path().extension() == ".k") {
                if !format_one_file(entry.path()) {
                    std::print(f"Error: failed to format {entry.path().generic_string()}");
                    return 1;
                }
                files_formatted += 1;
            }
        }
    } else {
        if path.extension() != ".k" {
            std::print(f"Error: not a .k file: {target_path}");
            return 1;
        }
        if !format_one_file(path) {
            std::print(f"Error: failed to format {target_path}");
            return 1;
        }
        files_formatted += 1;
    }

    std::print(f"Formatted {files_formatted} file(s)");
    return 0;
}