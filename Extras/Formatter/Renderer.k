/// --- The Kairo Project ----------------------------------- Extras/Formatter/Renderer.k --- ///
///
///   Wadler/prettier renderer for the Doc IR. Iterative over an explicit
///   command stack: a Group goes flat only when it AND the rest of its line fit
///   in the remaining columns, which is what a measure of the group alone
///   cannot tell.
///
///   Indentation and flat-Line spaces are owed, not written: they go out with
///   the next text on the line, so blank lines and line ends carry no
///   whitespace.
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

/// One indent level, in columns.
fn indent_width() -> i32 { return 4; }

fn spaces(n: i32) -> string {
    var s: string = "";
    for var i: i32 = 0; i < n; ++i { s += " "; }
    return s;
}

/// Pending work: print `doc` at indent level `ind`, broken or flat. A null
/// `doc` is the literal `lit`; a `lit` of "\n" is a row break inside an Align.
struct Cmd {
    var ind: i32    = 0;
    var brk: bool   = true;
    var doc: *Doc   = &null;
    var lit: string = "";
}

/// The output and where it stands.
class Pen {
    pub var out:  string = "";
    pub var col:  i32    = 0;
    pub var owed: i32    = 0;     ///< indent owed before the next text on this line
    pub var sp:   i32    = 0;     ///< spaces owed by flat Lines; a newline drops them
    pub var bol:  bool   = true;  ///< nothing printed on this line yet

    default fn Pen(self);

    /// The column the next text would start at.
    fn at(self) -> i32 {
        return (self.owed) if (self.bol) else (self.col + self.sp);
    }

    fn put(self, s: string) {
        if s.length() == 0 { return; }
        if self.bol {
            self.out += spaces(self.owed);
            self.col  = self.owed;
            self.bol  = false;
        } else if self.sp > 0 {
            self.out += spaces(self.sp);
            self.col += self.sp;
        }
        self.sp   = 0;
        self.out += s;
        self.col += static_cast::<i32>(s.length());
    }

    fn newline(self, ind: i32) {
        self.out += "\n";
        self.col  = 0;
        self.sp   = 0;
        self.owed = ind * indent_width();
        self.bol  = true;
    }
}

class Renderer {
    /// Flat width of a node that can never be flat. Large enough to lose every
    /// comparison, small enough not to overflow when summed.
    static fn unfittable() -> i32 { return 1000000; }

    /// Width of \p doc printed flat; unfittable when it holds a hard break.
    static fn flat_width(doc: *Doc) -> i32 {
        if doc->hard { return Renderer::unfittable(); }

        var k = doc->kind;
        if k == DocKind::Text { return static_cast::<i32>(doc->txt.length()); }
        if k == DocKind::Line { return 1; }
        if (k == DocKind::SoftLine) || (k == DocKind::LineSuffix) || (k == DocKind::BreakParent) { return 0; }
        if k == DocKind::IfBreak {
            if doc->children.size() < 2 { return 0; }
            return Renderer::flat_width(&(doc->children[1]));
        }

        var w: i32 = 0;
        for var i: usize = 0; i < doc->children.size(); ++i {
            w += Renderer::flat_width(&(doc->children[i]));
            if w >= Renderer::unfittable() { return Renderer::unfittable(); }
        }
        return w;
    }

    static fn render(doc: *Doc, width: i32) -> string {
        var pen   = Pen();
        var stack = vec::<Cmd>();
        var sfx   = vec::<Cmd>();

        stack.push_back(Cmd { ind: 0, brk: true, doc: doc, lit: "" });

        while true {
            while !stack.empty() {
                var c = stack.back();
                stack.pop_back();

                if Renderer::_is_newline(c) {
                    // line suffixes go out before the break that ends their line
                    if !sfx.empty() {
                        stack.push_back(c);
                        Renderer::_drain(&stack, &sfx);
                        continue;
                    }
                    var ind = c.ind;
                    if (c.doc != &null) && (c.doc->kind == DocKind::LiteralLine) { ind = 0; }
                    pen.newline(ind);
                    continue;
                }

                if c.doc == &null { pen.put(c.lit); continue; }

                var d = c.doc;
                var k = d->kind;

                if k == DocKind::Text { pen.put(d->txt); continue; }

                if k == DocKind::Concat {
                    var i = d->children.size();
                    while i > 0 {
                        i -= 1;
                        stack.push_back(Cmd { ind: c.ind, brk: c.brk, doc: &(d->children[i]), lit: "" });
                    }
                    continue;
                }

                if k == DocKind::Indent {
                    if d->children.empty() { continue; }
                    stack.push_back(Cmd { ind: c.ind + 1, brk: c.brk, doc: &(d->children[0]), lit: "" });
                    continue;
                }

                if k == DocKind::Group {
                    if d->children.empty() { continue; }
                    var flat = Cmd { ind: c.ind, brk: false, doc: &(d->children[0]), lit: "" };
                    if (!c.brk) || ((!d->hard) && Renderer::_fits(flat, &stack, width - pen.at())) {
                        stack.push_back(flat);
                    } else {
                        stack.push_back(Cmd { ind: c.ind, brk: true, doc: &(d->children[0]), lit: "" });
                    }
                    continue;
                }

                // only flat Lines reach here; broken ones were newlines above
                if k == DocKind::Line { pen.sp += 1; continue; }

                if k == DocKind::IfBreak {
                    if d->children.size() < 2 { continue; }
                    var arm: usize = (0) if (c.brk) else (1);
                    stack.push_back(Cmd { ind: c.ind, brk: c.brk, doc: &(d->children[arm]), lit: "" });
                    continue;
                }

                if k == DocKind::LineSuffix {
                    if d->children.empty() { continue; }
                    sfx.push_back(Cmd { ind: c.ind, brk: false, doc: &(d->children[0]), lit: "" });
                    continue;
                }

                if k == DocKind::Align { Renderer::_push_align(&stack, d, c.ind); continue; }

                // SoftLine flat, BreakParent: nothing to print
            }

            if sfx.empty() { break; }
            Renderer::_drain(&stack, &sfx);
        }

        if !pen.bol { pen.out += "\n"; }
        return pen.out;
    }

    priv static fn _is_newline(c: Cmd) -> bool {
        if c.doc == &null { return c.lit == "\n"; }
        var k = c.doc->kind;
        if (k == DocKind::HardLine) || (k == DocKind::LiteralLine) { return true; }
        if (k == DocKind::Line) || (k == DocKind::SoftLine) { return c.brk; }
        return false;
    }

    priv static fn _drain(stack: *vec::<Cmd>, sfx: *vec::<Cmd>) {
        var i = sfx->size();
        while i > 0 {
            i -= 1;
            stack->push_back((*sfx)[i]);
        }
        sfx->clear();
    }

    /// Rule 2: one row per line, every sep pinned just past the widest flat key.
    priv static fn _push_align(stack: *vec::<Cmd>, d: *Doc, ind: i32) {
        var rows = d->seps.size();
        if rows == 0 { return; }

        var kw: i32 = 0;
        for var r: usize = 0; r < rows; ++r {
            var w = Renderer::flat_width(&(d->children[2 * r]));
            if w > kw { kw = w; }
        }

        // pushed in reverse: per row the print order is [break], key, pad+sep, value
        var r = rows;
        while r > 0 {
            r -= 1;
            var key = &(d->children[2 * r]);
            var pad = kw - Renderer::flat_width(key);
            stack->push_back(Cmd { ind: ind, brk: false, doc: &(d->children[2 * r + 1]), lit: "" });
            stack->push_back(Cmd { ind: ind, brk: false, doc: &null, lit: spaces(pad) + d->seps[r] });
            stack->push_back(Cmd { ind: ind, brk: false, doc: key, lit: "" });
            if r > 0 { stack->push_back(Cmd { ind: ind, brk: true, doc: &null, lit: "\n" }); }
        }
    }

    /// Does \p next fit in \p rem0 columns, followed by the rest of its line?
    /// The rest is the pending stack, read from the top down in its own modes.
    priv static fn _fits(next: Cmd, stack: *vec::<Cmd>, rem0: i32) -> bool {
        var rem  = rem0;
        var rest = stack->size();
        var work = vec::<Cmd>();
        work.push_back(next);

        while true {
            if rem < 0 { return false; }

            if work.empty() {
                if rest == 0 { return true; }
                rest -= 1;
                work.push_back((*stack)[rest]);
                continue;
            }

            var c = work.back();
            work.pop_back();

            if c.doc == &null {
                if c.lit == "\n" { return true; }
                rem -= static_cast::<i32>(c.lit.length());
                continue;
            }

            var d = c.doc;
            var k = d->kind;

            if k == DocKind::Text { rem -= static_cast::<i32>(d->txt.length()); continue; }

            if k == DocKind::Concat {
                var i = d->children.size();
                while i > 0 {
                    i -= 1;
                    work.push_back(Cmd { ind: c.ind, brk: c.brk, doc: &(d->children[i]), lit: "" });
                }
                continue;
            }

            if (k == DocKind::Group) || (k == DocKind::Indent) {
                if d->children.empty() { continue; }
                var b = c.brk || ((k == DocKind::Group) && d->hard);
                work.push_back(Cmd { ind: c.ind, brk: b, doc: &(d->children[0]), lit: "" });
                continue;
            }

            if k == DocKind::Line {
                if c.brk { return true; }
                rem -= 1;
                continue;
            }

            if k == DocKind::SoftLine {
                if c.brk { return true; }
                continue;
            }

            if (k == DocKind::HardLine) || (k == DocKind::LiteralLine) || (k == DocKind::Align) {
                return true;
            }

            if k == DocKind::IfBreak {
                if d->children.size() < 2 { continue; }
                var arm: usize = (0) if (c.brk) else (1);
                work.push_back(Cmd { ind: c.ind, brk: c.brk, doc: &(d->children[arm]), lit: "" });
                continue;
            }

            // LineSuffix, BreakParent: zero width
        }

        return true;
    }
}