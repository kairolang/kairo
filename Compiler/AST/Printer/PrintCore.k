/// --- The Kairo Project ---------------------- AST/Printer/PrintCore.k --- ///
///
///   Shared printing infrastructure for the AST printers.
///
///   Two output modes, selected by PrintStyle:
///     Diagnostic / Canonical  source-faithful reproduction (sema diags)
///     Debug                   colored ASCII tree dump (--print-ast)
///
///   Color is orthogonal to style (PrintOptions.color). All escapes are plain
///   ANSI SGR over the base-8 palette plus bold, so output renders on dumb and
///   legacy terminals. No box-drawing glyphs: tree spines use '|', '`', '-'.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// --------------------------------------------------------------------- ///

/// Output flavor. Debug is the tree dump; the other two reproduce source.
enum PrintStyle derives u8 {
    Debug,       ///< --print-ast: colored ASCII tree with node kinds + attrs.
    Diagnostic,  ///< user-facing source reproduction, embedded in sema diags.
    Canonical,   ///< like Diagnostic but fully qualified; sema extends later.
}

/// Semantic color roles. Mapped to ANSI SGR in Painter::_sgr. Roles, not raw
/// colors, so the whole scheme retones in one place.
enum Color derives u8 {
    None,      ///< no styling / reset.
    Keyword,   ///< language keywords (fn, if, return, ...).
    Literal,   ///< numeric / string / char / bool / null literals.
    Ident,     ///< identifiers: variable, function, field names.
    TypeName,  ///< type spellings.
    Operator,  ///< operators (+, ==, ->, ...).
    Punct,     ///< structural punctuation ((), {}, ;, ,).
    NodeKind,  ///< AST node class names in the dump.
    Attr,      ///< annotation / attribute names.
    Error,     ///< recovery / error markers.
    Dim,       ///< low-salience detail (ranges, inferred ids).
    Tree,      ///< tree spine: connectors and continuations.
}

/// Knobs for a print run. `style` chooses the rendering; `color` toggles ANSI.
class PrintOptions {
    pub var style: PrintStyle = PrintStyle::Diagnostic;
    pub var color: bool       = false;

    static fn diag() -> PrintOptions {
        var o   = PrintOptions{};
        o.style = PrintStyle::Diagnostic;
        o.color = false;
        return o;
    }

    static fn diag_colored() -> PrintOptions {
        var o   = PrintOptions{};
        o.style = PrintStyle::Diagnostic;
        o.color = true;
        return o;
    }

    static fn canonical() -> PrintOptions {
        var o   = PrintOptions{};
        o.style = PrintStyle::Canonical;
        o.color = false;
        return o;
    }

    static fn dump() -> PrintOptions {
        var o   = PrintOptions{};
        o.style = PrintStyle::Debug;
        o.color = true;
        return o;
    }

    static fn dump_plain() -> PrintOptions {
        var o   = PrintOptions{};
        o.style = PrintStyle::Debug;
        o.color = false;
        return o;
    }

    fn is_debug(self)     -> bool { return self.style == PrintStyle::Debug; }
    fn is_canonical(self) -> bool { return self.style == PrintStyle::Canonical; }
}

/// Owns the output buffer and the tree-spine state. Knows nothing about AST
/// nodes the printers drive it. All color goes through `paint`, which is a
/// no-op when color is disabled, so callers never branch on color themselves.
class Painter {
    pub var out: string = "";

    pub var _opts:  PrintOptions;
    pub var _stack: vec::<bool>;   ///< per-ancestor: was that level a last child?

    default fn Painter(self);

    fn Painter(self, opts: PrintOptions) {
        self._opts = opts;
        self.out   = "";
    }

    fn opts(self)  -> PrintOptions { return self._opts; }
    fn style(self) -> PrintStyle   { return self._opts.style; }

    // -- raw output ---------------------------------------------------------

    /// Append text with no styling.
    fn put(self, s: string) { self.out += s; }

    /// Append `s` wrapped in the SGR for role `c`. Styling is skipped when
    /// color is off or the role is None; the text is always emitted.
    fn paint(self, c: Color, s: string) {
        if (!self._opts.color) || (c == Color::None) {
            self.out += s;
            return;
        }
        self.out += "\x1b[";
        self.out += Painter::_sgr(c);
        self.out += "m";
        self.out += s;
        self.out += "\x1b[0m";
    }

    fn newline(self) { self.out += "\n"; }

    // -- tree spine (used by the dump path) ---------------------------------

    /// Emit the prefix + connector for a child row. `is_last` picks '`-' over
    /// '|-'. Call once per node line in dump mode, before its head text.
    fn row(self, is_last: bool) {
        for var i: usize = 0; i < self._stack.size(); ++i {
            self.paint(Color::Tree, (("  ") if (self._stack[i]) else ("| ")));
        }
        self.paint(Color::Tree, (("`-") if (is_last) else ("|-")));
    }

    /// Descend one level. Pair with `leave`. `is_last` is this node's own
    /// last-child status, which sets the continuation glyph for its children.
    fn enter(self, is_last: bool) { self._stack.push_back(is_last); }

    fn leave(self) {
        if !self._stack.empty() { self._stack.pop_back(); }
    }

    // -- palette (base-8 + bold for legacy-terminal safety) -----------------

    priv static fn _sgr(c: Color) -> string {
        switch c {
            case Color::None     { return "0";    }
            case Color::Keyword  { return "1;34"; }
            case Color::Literal  { return "0;33"; }
            case Color::Ident    { return "1;37"; }
            case Color::TypeName { return "0;32"; }
            case Color::Operator { return "0;36"; }
            case Color::Punct    { return "0";    }
            case Color::NodeKind { return "1;32"; }
            case Color::Attr     { return "0;35"; }
            case Color::Error    { return "1;31"; }
            case Color::Dim      { return "90"; }
            case Color::Tree     { return "0;34"; }
        }
        return "0";
    }
}