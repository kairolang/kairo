/// --- The Kairo Project --------------------- Extras/Formatter/DocIR.k --- ///
///
///   The Doc tree the formatter builds and the renderer prints.
///
///   Besides the Wadler/prettier core (text, lines, groups, indent), two
///   kinds carry layouts the renderer has to decide with the column in hand:
///
///   - List: a parenthesized / bracketed / braced list (README 4.1). Flat, or
///     broken in the block, aligned or grid form, with the `name:` keys of
///     its rows padded to one column (11.3) and the trailing comma by form
///     (4.2). Which broken form it takes depends on where the opener lands,
///     which only the renderer knows.
///   - Table: an alignment run (section 11): rows of cells, each column
///     padded to its widest cell.
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

pub enum DocKind derives u8 {
    Text,
    Concat,
    Line,        ///< a space flat, a newline broken
    SoftLine,    ///< nothing flat, a newline broken
    HardLine,    ///< always a newline, at the current indent
    LiteralLine, ///< always a newline, at column 0 (multi-line strings)
    Group,       ///< `num` > 0: the flat form must also end by that column;
    ///< a second child is the broken form (Doc::choice)
    Indent,
    IfBreak,
    LineSuffix, ///< deferred to the end of the line (trailing comments)
    BreakParent,
    List,    ///< see the LIST_* bits
    Table,   ///< `num` columns; cells row-major; `seps[c]` goes before column c
    GapLine, ///< a HardLine that first adds a blank line when the line it
    ///< ends holds only closers (14.4)
    Align, ///< its child's broken lines start at the column it starts at
}

/// List layout bits (Doc::flags).
pub fn LIST_ALIGNED()  -> u32 { ///< broken: aligned form (parameters)
    return 1
}

pub fn LIST_GRID()     -> u32 { ///< broken: grid form when it applies
    return 2
}

pub fn LIST_FORCE()    -> u32 { ///< never flat (imports, 5.2)
    return 4
}

pub fn LIST_KEYS()     -> u32 { ///< broken: pad the keys to one column (11.3)
    return 8
}

pub fn LIST_FALLBACK() -> u32 { ///< aligned form falls back to block when too wide
    return 32
}

pub fn LIST_NOTRAIL()  -> u32 { ///< broken: never add a trailing `,`
    return 64
}

/// A `case`'s alternatives (8.4): always the grid, no opener
/// or closer, the first row on the current line, the others aligned under
/// it, no trailing `,`, no per-item width cap.
pub fn LIST_CASEGRID() -> u32 {
    return 128
}

pub class Doc {
    pub var kind:     DocKind = DocKind::Concat
    pub var txt:      string  = ""
    pub var children: [Doc]

    /// List: [open, close]. Table: the separator in front of each column
    /// (seps[0] is unused).
    pub var seps: [string]

    /// Group: column the flat form must end by (0: none). Table: columns.
    pub var num:   i32 = 0
    pub var flags: u32 = 0

    /// A hard break sits somewhere below: HardLine, LiteralLine, BreakParent,
    /// a Table, or a forced List. Set by the builders, so no subtree is ever
    /// rescanned for it. LineSuffix does not propagate it: a trailing comment
    /// never forces a break.
    pub var hard: bool = false

    fn Doc(self) = default

    static fn _any_hard(const xs: [Doc]) -> bool {
        for var i: usize = 0; i < xs.size(); ++i {
            if xs[i].hard {
                return true
            }
        }

        return false
    }

    static fn text(const s: string) -> Doc {
        var d = Doc()
        d.kind = DocKind::Text
        d.txt  = s.copy()
        return d
    }

    static fn concat(xs: [Doc]) -> Doc {
        var d = Doc()
        d.kind     = DocKind::Concat
        d.hard     = Doc::_any_hard(xs)
        d.children = xs
        return d
    }

    /// Fixed-arity concat helpers: there is no braced-init conversion to a
    /// vector of Docs.
    static fn concat2(a: Doc, b: Doc) -> Doc {
        var xs: [Doc]
        xs.push(a)
        xs.push(b)
        return Doc::concat(xs)
    }

    static fn concat3(a: Doc, b: Doc, c: Doc) -> Doc {
        var xs: [Doc]
        xs.push(a)
        xs.push(b)
        xs.push(c)
        return Doc::concat(xs)
    }

    static fn concat4(a: Doc, b: Doc, c: Doc, d: Doc) -> Doc {
        var xs: [Doc]
        xs.push(a)
        xs.push(b)
        xs.push(c)
        xs.push(d)
        return Doc::concat(xs)
    }

    static fn concat5(a: Doc, b: Doc, c: Doc, d: Doc, e: Doc) -> Doc {
        var xs: [Doc]
        xs.push(a)
        xs.push(b)
        xs.push(c)
        xs.push(d)
        xs.push(e)
        return Doc::concat(xs)
    }

    static fn line() -> Doc {
        var d = Doc()
        d.kind = DocKind::Line
        return d
    }

    static fn softline() -> Doc {
        var d = Doc()
        d.kind = DocKind::SoftLine
        return d
    }

    static fn hardline() -> Doc {
        var d = Doc()
        d.kind = DocKind::HardLine
        d.hard = true
        return d
    }

    /// Rule 14.4: a hard line, plus a blank one when the line it ends holds
    /// only closers. Decided by the renderer: only it sees whether a call
    /// broke into a `)` line.
    static fn gap_line() -> Doc {
        var d = Doc()
        d.kind = DocKind::GapLine
        d.hard = true
        return d
    }

    /// `child` with its broken lines at the column it starts at (rule 8.3's
    /// clause layouts: `catch` under `try`, `else` under `if`).
    static fn align(child: Doc) -> Doc {
        var d = Doc()
        d.kind = DocKind::Align
        d.hard = child.hard
        d.children.push(child)
        return d
    }

    static fn literal_line() -> Doc {
        var d = Doc()
        d.kind = DocKind::LiteralLine
        d.hard = true
        return d
    }

    static fn group(child: Doc) -> Doc {
        var d = Doc()
        d.kind = DocKind::Group
        d.hard = child.hard
        d.children.push(child)
        return d
    }

    /// `flat` when it fits on the rest of the line, else `broken` (rule
    /// 7.5's one-line type body). Unlike if_break, the broken form's hard
    /// lines do not force the choice.
    static fn choice(flat: Doc, broken: Doc) -> Doc {
        var d = Doc()
        d.kind = DocKind::Group
        d.hard = flat.hard
        d.children.push(flat)
        d.children.push(broken)
        return d
    }

    /// A group whose flat form must also end by column `cap` (rule 4.1's
    /// 80-column limit for calls).
    static fn group_cap(child: Doc, cap: i32) -> Doc {
        var d = Doc::group(child)
        d.num = cap
        return d
    }

    static fn indent(child: Doc) -> Doc {
        var d = Doc()
        d.kind = DocKind::Indent
        d.hard = child.hard
        d.children.push(child)
        return d
    }

    /// `when_broken` if the nearest enclosing Group broke, `when_flat` if not.
    static fn if_break(when_broken: Doc, when_flat: Doc) -> Doc {
        var d = Doc()
        d.kind = DocKind::IfBreak
        d.hard = when_broken.hard
        d.children.push(when_broken)
        d.children.push(when_flat)
        return d
    }

    static fn line_suffix(child: Doc) -> Doc {
        var d = Doc()
        d.kind = DocKind::LineSuffix
        d.children.push(child)
        return d
    }

    static fn break_parent() -> Doc {
        var d = Doc()
        d.kind = DocKind::BreakParent
        d.hard = true
        return d
    }

    /// Rule 4.1 list. `keys` / `vals`: one pair per item; an empty key is
    /// an item with no `name:` (its value is the whole item). `flat` is the
    /// one-line form, built by the caller so the renderer's fit test reads it.
    static fn list(const open:  string,
                   const close: string,
                   keys:        [Doc],
                   vals:        [Doc],
                   flat:        Doc,
                   flags:       u32) -> Doc {
        var d = Doc()
        d.kind  = DocKind::List
        d.flags = flags
        d.seps.push(open.copy())
        d.seps.push(close.copy())
        d.hard = (flags & LIST_FORCE()) != 0 || flat.hard
        d.children.push(flat)
        for var i: usize = 0; i < vals.size(); ++i {
            var *k = &keys[i]
            var *v = &vals[i]
            d.children.push(move(*k))
            d.children.push(move(*v))
        }

        return d
    }

    /// Section 11 run. `cells` is row-major, `cols` per row; `seps[c]` sits
    /// in front of column c. An empty cell pads to its column only when a
    /// later cell of the row is not empty.
    static fn table(cells: [Doc], cols: i32, seps: [string]) -> Doc {
        var d = Doc()
        d.kind     = DocKind::Table
        d.hard     = true
        d.num      = cols
        d.children = cells
        d.seps     = seps
        return d
    }

    static fn join(xs: [Doc], const sep: Doc) -> Doc {
        var out: [Doc]
        for var i: usize = 0; i < xs.size(); ++i {
            if i > 0 {
                out.push(sep.copy())
            }

            var *x = &xs[i]
            out.push(move(*x))
        }

        return Doc::concat(out)
    }

    /// For "did this produce nothing" checks.
    fn is_empty(self) -> bool {
        return self.kind == DocKind::Concat && self.children.is_empty()
    }

    static fn nothing() -> Doc {
        return Doc::concat([])
    }

    /// A copy of the whole subtree.
    fn copy(const self) -> Doc {
        var d = Doc()
        d.kind  = self.kind
        d.txt   = self.txt.copy()
        d.num   = self.num
        d.flags = self.flags
        d.hard  = self.hard
        d.children.reserve(self.children.size())
        for const *c in self.children {
            d.children.push(c->copy())
        }

        d.seps.reserve(self.seps.size())
        for const *s in self.seps {
            d.seps.push(s->copy())
        }

        return d
    }
}
