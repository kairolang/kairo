/// --- The Kairo Project ----------------------------------- Extras/Formatter/DocIR.k --- ///
///
///   Contains the Doc data structure implemetation and its helpers for the formatter.
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