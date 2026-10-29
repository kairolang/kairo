/// --- The Kairo Project ----------------------------------- Extras/Formatter/DocIR.k --- ///
///
///   The Doc tree the formatter builds and the renderer prints.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

enum DocKind derives u8 {
    Text,
    Concat,
    Line,          ///< a space flat, a newline broken
    SoftLine,      ///< nothing flat, a newline broken
    HardLine,      ///< always a newline, at the current indent
    LiteralLine,   ///< always a newline, at column 0 (multi-line strings)
    Group,
    Indent,
    IfBreak,
    LineSuffix,    ///< deferred to the end of the line (trailing comments)
    BreakParent,
    Align,
}

class Doc {
    pub var kind:     DocKind       = DocKind::Concat;
    pub var txt:      string        = "";
    pub var children: vec::<Doc>    = vec::<Doc>();

    /// Align only: row i is children[2i] (key) and children[2i + 1] (value),
    /// joined by seps[i] after the key is padded to the widest key.
    pub var seps:     vec::<string> = vec::<string>();

    /// A hard break sits somewhere below: HardLine, LiteralLine, BreakParent,
    /// or an Align. Set by the builders, so no subtree is ever rescanned for it.
    /// LineSuffix does not propagate it: a trailing comment never forces a break.
    pub var hard:     bool          = false;

    default fn Doc(self);

    static fn _any_hard(xs: vec::<Doc>) -> bool {
        for var i: usize = 0; i < xs.size(); ++i {
            if xs[i].hard { return true; }
        }
        return false;
    }

    static fn text(s: string) -> Doc {
        var d = Doc{};
        d.kind = DocKind::Text;
        d.txt  = s;
        return d;
    }

    static fn concat(xs: vec::<Doc>) -> Doc {
        var d = Doc{};
        d.kind     = DocKind::Concat;
        d.hard     = Doc::_any_hard(xs);
        d.children = xs;
        return d;
    }

    /// Fixed-arity concat helpers. Kairo has no braced-init conversion to
    /// `vec::<Doc>`.
    static fn concat2(a: Doc, b: Doc) -> Doc {
        var xs = vec::<Doc>();
        xs.push_back(a);
        xs.push_back(b);
        return Doc::concat(xs);
    }

    static fn concat3(a: Doc, b: Doc, c: Doc) -> Doc {
        var xs = vec::<Doc>();
        xs.push_back(a);
        xs.push_back(b);
        xs.push_back(c);
        return Doc::concat(xs);
    }

    static fn concat4(a: Doc, b: Doc, c: Doc, d: Doc) -> Doc {
        var xs = vec::<Doc>();
        xs.push_back(a);
        xs.push_back(b);
        xs.push_back(c);
        xs.push_back(d);
        return Doc::concat(xs);
    }

    static fn concat5(a: Doc, b: Doc, c: Doc, d: Doc, e: Doc) -> Doc {
        var xs = vec::<Doc>();
        xs.push_back(a);
        xs.push_back(b);
        xs.push_back(c);
        xs.push_back(d);
        xs.push_back(e);
        return Doc::concat(xs);
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
        d.hard = true;
        return d;
    }

    static fn literal_line() -> Doc {
        var d = Doc{};
        d.kind = DocKind::LiteralLine;
        d.hard = true;
        return d;
    }

    static fn group(child: Doc) -> Doc {
        var d = Doc{};
        d.kind = DocKind::Group;
        d.hard = child.hard;
        d.children.push_back(child);
        return d;
    }

    static fn indent(child: Doc) -> Doc {
        var d = Doc{};
        d.kind = DocKind::Indent;
        d.hard = child.hard;
        d.children.push_back(child);
        return d;
    }

    /// `when_broken` if the nearest enclosing Group broke, `when_flat` if not.
    static fn if_break(when_broken: Doc, when_flat: Doc) -> Doc {
        var d = Doc{};
        d.kind = DocKind::IfBreak;
        d.hard = when_broken.hard;
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
        d.hard = true;
        return d;
    }

    /// Style rule 2. \p rows is key0, value0, key1, value1, ...; one sep per row.
    static fn align(rows: vec::<Doc>, seps: vec::<string>) -> Doc {
        var d = Doc{};
        d.kind     = DocKind::Align;
        d.hard     = true;
        d.children = rows;
        d.seps     = seps;
        return d;
    }

    static fn join(xs: vec::<Doc>, sep: Doc) -> Doc {
        var out = vec::<Doc>();
        for var i: usize = 0; i < xs.size(); ++i {
            if i > 0 { out.push_back(sep); }
            out.push_back(xs[i]);
        }
        return Doc::concat(out);
    }

    /// For "did this produce nothing" checks.
    fn is_empty(self) -> bool {
        return (self.kind == DocKind::Concat) && self.children.empty();
    }

    static fn nothing() -> Doc {
        return Doc::concat(vec::<Doc>());
    }
}