/// --- The Kairo Project --------------------- Sema/Check/AttributeCheck.k --- ///
///
///   \brief Every `@name` written on a declaration, statement, expression or
///          type either means something where it stands or is an error. No
///          attribute is accepted and silently ignored.
///
///   \detail
///     Three entry points, scheduled by Sema:
///
///       register_suppressions()   Expand, first. `@no_warn(CODE, ...)` on a
///                                 declaration registers one quiet scope per
///                                 valid code with the TU's sink
///                                 (BufferedDiagSink::quiet_in), so a warning
///                                 from any later pass located inside the
///                                 declaration is dropped. Silent: the codes
///                                 are validated by run().
///       run()                     Typed checks, first (before ExprTyper).
///                                 The attribute rules, below.
///       run_uses()                After ExprTyper: `@deprecated` -- one
///                                 warning at every use of the declaration
///                                 (a name, a member step, a constructor, an
///                                 operator, a type segment), with a note at
///                                 the attribute. A use inside the deprecated
///                                 declaration itself is not reported.
///
///     The rules. The name is read as written (LangAttrs is the list of
///     known names, LangAttrs::known):
///       - a known name in a position it applies to: accepted; in any other
///         position, an error naming where it applies, with a fix-it that
///         removes it. Positions another pass already reports are left to
///         it, so nothing is reported twice: `@open` (ASTParse),
///         `@hot_path` / `@cold_path` / `@pure` and the calling conventions
///         on a declaration or statement (ASTParse; CallConvCheck), `@implicit`
///         on a function (OperatorSignatureCheck).
///       - `@packed` (no arguments): a class, struct or union.
///         `@align(N)`: a class, struct, union, field or variable; N is an
///         integer literal, a power of two no larger than 2^28. AttrFacts
///         reads both for the layout and the C++ spelling.
///       - `@deprecated` / `@deprecated("msg")`, `@no_warn(CODE, ...)`: any
///         declaration. A `@no_warn` code must name a warning: an unknown
///         code, or one of an error, is an error.
///       - `@unreachable`: reserved, SC116E.
///       - a user attribute macro (`macro @name(...)`): SC116E -- macro
///         expansion (Sema::_stage_expand) is not implemented, so the
///         attribute would do nothing.
///       - anything else: "unknown attribute", with a did-you-mean among the
///         known names when one is close.
///
///     An expression attribute (`@create T()`, AttributedExpr) is not an
///     annotation and is FeatureGateCheck's (SC116E).
///
///   Phase: CHECKS
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ----------------------------------------------------------------- ///

import Sema::SemaContext::*;
import Sema::Resolve::NameLookup::*;
import Sema::Type::TypeUtil::*;
import AST::Context::ASTContext::*;
import AST::Context::TranslationUnit::*;
import AST::Context::DeclContext::*;
import AST::ASTSupport::*;
import AST::DeclFacts::*;
import AST::AttrFacts::*;
import AST::LangItems::*;
import AST::Mixin::Annotation::*;
import AST::Node::Base::*;
import AST::Node::Program::*;
import AST::Node::Statements::*;
import AST::Node::Expressions::*;
import AST::Node::PrimaryExpressions::*;
import AST::Node::Declarations::*;
import AST::Node::Casting::*;
import AST::Node::Types::*;
import AST::Visitor::RecursiveASTVisitor::*;
import Location::SourceRange::*;
import Diagnostic::Registry::*;
import Diagnostic::Meta::*;
import Diagnostic::Code::*;
import Diagnostic::Engine::*;
import Lexer::Immediate::*;

class AttributeCheck derives RecursiveASTVisitor::<AttributeCheck> {
    pub var sc: *SemaContext;
    priv var _tu: TypeUtil;
    /// 0 register_suppressions, 1 run, 2 run_uses.
    priv var _mode: u8 = 0;
    /// The uses already reported (a type segment's name may be reached
    /// twice): one warning per location.
    priv var _seen: vec::<SourceLocation>;
    /// The decl _deprecation found the attribute on.
    priv var _carrier: *Decl = &null;

    fn AttributeCheck(self, sc: *SemaContext) {
        self.sc  = sc;
        self._tu = TypeUtil(sc);
    }

    fn register_suppressions(self) { self._mode = 0; self._walk(); }
    fn run(self)                   { self._mode = 1; self._walk(); }
    fn run_uses(self)              { self._mode = 2; self._walk(); }

    priv fn _walk(self) {
        var tu = self.sc->tu;
        if (tu == &null) || (tu->program == &null) { return; }
        var items = &(tu->program->items);
        for var i: usize = 0; i < items->size(); i++ {
            if self.stop { break; }
            var item = *(items->get(i));
            switch item.kind {
                case TopLevelKind::Decl { self.dispatch_decl(item.as_decl()); }
                case TopLevelKind::Stmt { self.dispatch_stmt(item.as_stmt()); }
                case TopLevelKind::Expr { self.dispatch_expr(item.as_expr()); }
                default { 0; }
            }
        }
    }

    // === names ===================================================================

    priv fn _spell(self, e: *AnnotationEntry) -> string {
        return self.sc->imm_table()->get_ident(e->name);
    }

    priv fn _is_known(self, nm: string) -> bool {
        for var i: usize = 0; i < 256; ++i {
            var k = LangAttrs::known(i);
            if k.size() == 0 { return false; }
            if k == nm { return true; }
        }
        return false;
    }

    /// The known name closest to \p nm, when it is close enough to be a typo
    /// of it (at most a third of its letters off); "" otherwise.
    priv fn _closest(self, nm: string) -> string {
        var best = "";
        var best_d: usize = 0;
        for var i: usize = 0; i < 256; ++i {
            var k = LangAttrs::known(i);
            if k.size() == 0 { break; }
            var d = self._edit_distance(nm, k);
            if (best.size() == 0) || (d < best_d) { best = k; best_d = d; }
        }
        var lim = nm.size() / 3;
        if lim < 1 { lim = 1; }
        if (best.size() == 0) || (best_d > lim) { return ""; }
        return best;
    }

    /// Two-row Levenshtein (Command::_edit_distance); runs only on a name
    /// that is already an error.
    priv fn _edit_distance(self, a: string, b: string) -> usize {
        var n = a.size();
        var m = b.size();
        if n == 0 { return m; }
        if m == 0 { return n; }
        var prev: vec::<usize>;
        var cur:  vec::<usize>;
        prev.resize(m + 1, usize(0));
        cur.resize(m + 1, usize(0));
        for var j: usize = 0; j <= m; ++j { prev[j] = j; }
        for var i: usize = 1; i <= n; ++i {
            cur[0] = i;
            for var j: usize = 1; j <= m; ++j {
                var cost: usize = (usize(0)) if (a[i - 1] == b[j - 1]) else (usize(1));
                var best = prev[j] + 1;
                var ins  = cur[j - 1] + 1;
                var sub  = prev[j - 1] + cost;
                if ins < best { best = ins; }
                if sub < best { best = sub; }
                cur[j] = best;
            }
            for var j: usize = 0; j <= m; ++j { prev[j] = cur[j]; }
        }
        return prev[m];
    }

    /// A user attribute macro the attribute names: the decl N bound it to
    /// (decl annotations only), else a file-scope `macro @name` of this TU
    /// (a statement's or type's attribute is never bound by N).
    priv fn _macro_of(self, e: *AnnotationEntry) -> bool {
        if e->resolved_decl != &null {
            var rd = reinterpret_cast::<*Decl>(e->resolved_decl);
            if isa::<ProcedureMacroDecl>(rd) { return true; }
        }
        var tu = self.sc->tu;
        if (tu == &null) || (tu->program == &null) { return false; }
        var items = &(tu->program->items);
        for var i: usize = 0; i < items->size(); i++ {
            var item = *(items->get(i));
            if item.kind != TopLevelKind::Decl { continue; }
            var d = item.as_decl();
            if (d == &null) || (!isa::<ProcedureMacroDecl>(d)) { continue; }
            if self.sc->ctx->get_ident_imm(cast::<ProcedureMacroDecl>(d)->name) == e->name { return true; }
        }
        return false;
    }

    // === diagnostics ============================================================

    /// "'@x' <why>", at the attribute, a note at what carries it, and a
    /// fix-it that removes it.
    priv fn _misplaced(self, e: *AnnotationEntry, nm: string, why: string, owner: SourceRange, what: string) {
        var an = "\x27@" + nm + "\x27";
        var b = self.sc->diag->report(DiagID::SC001E, e->range.start, an + " " + why);
        b.first(e->range);
        b.note(owner.start, "the attribute is on this " + what);
        b.remove(e->range, "remove " + an);
        b.emit();
    }

    priv fn _bad_arg(self, e: *AnnotationEntry, at: SourceRange, msg: string) {
        var b = self.sc->diag->report(DiagID::SC001E, at.start, msg);
        b.first(at);
        b.emit();
    }

    priv fn _unsupported(self, e: *AnnotationEntry, msg: string) {
        var b = self.sc->diag->report(DiagID::SC116E, e->range.start, msg);
        b.first(e->range);
        b.emit();
    }

    priv fn _unknown(self, e: *AnnotationEntry, nm: string) {
        var an = "\x27@" + nm + "\x27";
        var b = self.sc->diag->report(DiagID::SC001E, e->range.start, "unknown attribute " + an);
        b.first(e->range);
        var near = self._closest(nm);
        if near.size() > 0 { b.note(e->range.start, "did you mean \x27@" + near + "\x27?"); }
        b.remove(e->range, "remove " + an);
        b.emit();
    }

    /// The common tail of every position: the two reserved forms and the
    /// names nothing knows. True when \p e was one of them (reported).
    priv fn _reserved_or_unknown(self, e: *AnnotationEntry, nm: string) -> bool {
        if nm == LangAttrs::unreachable() {
            self._unsupported(e, "\x27@unreachable\x27 is not yet supported");
            return true;
        }
        if self._is_known(nm) { return false; }
        if self._macro_of(e) {
            self._unsupported(e, "the attribute macro \x27@" + nm + "\x27 is not yet supported: attribute macros are not expanded yet");
            return true;
        }
        self._unknown(e, nm);
        return true;
    }

    // === arguments ===============================================================

    priv fn _arg(self, e: *AnnotationEntry, i: usize) -> *Expr {
        return reinterpret_cast::<*Expr>(e->args[i]);
    }

    /// A `@no_warn` argument's code as written: an identifier (`SC031W`)
    /// or a string literal; "" for anything else.
    priv fn _code_text(self, a: *Expr) -> string {
        if a == &null { return ""; }
        if isa::<NamedIdentExpr>(a) { return self.sc->ctx->get_spelling(cast::<NamedIdentExpr>(a)->name); }
        if isa::<StringLiteralExpr>(a) {
            var sl = cast::<StringLiteralExpr>(a);
            if sl->is_format() { return ""; }
            return self._string_text(sl);
        }
        return "";
    }

    priv fn _string_text(self, sl: *StringLiteralExpr) -> string {
        var out = "";
        if (sl->imm != &null) && sl->imm->has_owned_text() {
            for var i: usize = 0; i < static_cast::<usize>(sl->imm->owned_len); ++i { out += static_cast::<char>(sl->imm->owned_ptr[i]); }
            return out;
        }
        // No decoded text: the spelling, less its quotes.
        var sp = self.sc->ctx->get_spelling(sl->token);
        var n = sp.size();
        if (n >= 2) && (sp[0] == static_cast::<char>(34)) && (sp[n - 1] == static_cast::<char>(34)) {
            var t: string = sp.subslice(1, n - 2);
            return t;
        }
        return sp;
    }

    /// The warning a `@no_warn` code names, or Invalid (\p why says why).
    priv fn _warning_code(self, text: string, why: *string) -> DiagID {
        if text.size() == 0 { (*why) = "expects a diagnostic code, such as SC031W"; return DiagID::Invalid; }
        var id = diag_from_code(text);
        if (id == DiagID::Invalid) || diag_explain(id).empty() {
            (*why) = "\x27" + text + "\x27 is not a diagnostic code";
            return DiagID::Invalid;
        }
        var sev = DiagCode(id).severity();
        if (sev == DiagSeverity::Error) || (sev == DiagSeverity::Fatal) {
            (*why) = "\x27" + text + "\x27 is an error; only a warning can be suppressed";
            return DiagID::Invalid;
        }
        if sev != DiagSeverity::Warning {
            (*why) = "\x27" + text + "\x27 is not a warning; only a warning can be suppressed";
            return DiagID::Invalid;
        }
        return id;
    }

    priv fn _check_no_warn(self, e: *AnnotationEntry, d: *Decl) {
        if e->args.size() == 0 {
            self._bad_arg(e, e->range, "\x27@no_warn\x27 expects one or more warning codes, such as \x27@no_warn(SC031W)\x27");
            return;
        }
        for var i: usize = 0; i < e->args.size(); ++i {
            var a = self._arg(e, i);
            var why = "";
            var id = self._warning_code(self._code_text(a), &why);
            if id != DiagID::Invalid { continue; }
            var at = (a->range) if (a != &null) else (e->range);
            self._bad_arg(e, at, "\x27@no_warn\x27 " + why);
        }
    }

    priv fn _check_align(self, e: *AnnotationEntry) {
        if AttrFacts::align_value(e) != 0 { return; }
        var at = e->range;
        if e->args.size() == 1 {
            var a = self._arg(e, 0);
            if a != &null { at = a->range; }
        }
        self._bad_arg(e, at, "\x27@align\x27 expects one integer literal that is a power of two, at most 268435456: \x27@align(16)\x27");
    }

    priv fn _check_deprecated(self, e: *AnnotationEntry) {
        if e->args.size() == 0 { return; }
        var a = self._arg(e, 0);
        var ok = (e->args.size() == 1) && (a != &null) && isa::<StringLiteralExpr>(a) && (!cast::<StringLiteralExpr>(a)->is_format());
        if ok { return; }
        var at = (a->range) if (a != &null) else (e->range);
        self._bad_arg(e, at, "\x27@deprecated\x27 takes no argument or one string literal, the message");
    }

    // === positions ===============================================================

    priv fn _is_record(self, d: *Decl) -> bool {
        return isa::<ClassDecl>(d) || isa::<StructDecl>(d) || isa::<UnionDecl>(d);
    }

    priv fn _check_decl_attr(self, d: *Decl, e: *AnnotationEntry) {
        var nm = self._spell(e);
        if self._reserved_or_unknown(e, nm) { return; }
        var fnd = isa::<FunctionDecl>(d);
        // Reported where they are stamped (see the file header).
        if (nm == LangAttrs::open_enum()) || (nm == LangAttrs::hot_path()) || (nm == LangAttrs::cold_path())
        || (nm == LangAttrs::pure_fn()) || (nm == LangAttrs::preserve_most()) || (nm == LangAttrs::preserve_all())
        || (nm == LangAttrs::preserve_none()) || (nm == LangAttrs::no_inline()) {
            return;
        }
        if nm == LangAttrs::implicit_conversion() {
            if !fnd { self._misplaced(e, nm, "applies only to a conversion operator: \x27" + "fn op as (self) -> T\x27 in a type\x27s body", d->range, "declaration"); }
            return;
        }
        if (nm == LangAttrs::transfer_copy()) || (nm == LangAttrs::transfer_move()) {
            if !fnd { self._misplaced(e, nm, "applies only to a copy or move constructor", d->range, "declaration"); }
            return;
        }
        if (nm == LangAttrs::no_unwind()) || (nm == LangAttrs::unwind()) {
            if !fnd { self._misplaced(e, nm, "applies only to a function", d->range, "declaration"); }
            return;
        }
        if (nm == LangAttrs::likely()) || (nm == LangAttrs::unlikely()) {
            self._misplaced(e, nm, "applies only to an \x27if\x27 statement", d->range, "declaration");
            return;
        }
        if nm == LangAttrs::param_inout() {
            self._misplaced(e, nm, "is a parameter passing mode; it is written on a function or closure parameter", d->range, "declaration");
            return;
        }
        if nm == LangAttrs::assume() {
            self._misplaced(e, nm, "is a statement of its own: \x27@assume(cond)\x27", d->range, "declaration");
            return;
        }
        if nm == LangAttrs::packed() {
            if !self._is_record(d) { self._misplaced(e, nm, "applies only to a class, struct or union", d->range, "declaration"); return; }
            if e->args.size() != 0 { self._bad_arg(e, e->range, "\x27@packed\x27 takes no arguments"); }
            return;
        }
        if nm == LangAttrs::align() {
            if (!self._is_record(d)) && (!isa::<FieldDecl>(d)) && (!isa::<VariableDecl>(d)) {
                self._misplaced(e, nm, "applies only to a class, struct, union, field or variable", d->range, "declaration");
                return;
            }
            self._check_align(e);
            return;
        }
        if nm == LangAttrs::deprecated() { self._check_deprecated(e); return; }
        if nm == LangAttrs::no_warn()    { self._check_no_warn(e, d); return; }
        // A known name this pass has no rule for: its owner decides.
    }

    /// An attribute on a statement (not a declaration statement: those
    /// attributes are the declaration's), an expression or a type.
    priv fn _check_other_attr(self, e: *AnnotationEntry, owner: SourceRange, what: string, is_if: bool, is_stmt: bool) {
        var nm = self._spell(e);
        if self._reserved_or_unknown(e, nm) { return; }
        if (nm == LangAttrs::likely()) || (nm == LangAttrs::unlikely()) {
            if !is_if { self._misplaced(e, nm, "applies only to an \x27if\x27 statement", owner, what); }
            return;
        }
        // ASTParse reports the function attributes on a statement.
        if is_stmt && ((nm == LangAttrs::hot_path()) || (nm == LangAttrs::cold_path()) || (nm == LangAttrs::pure_fn())
        || (nm == LangAttrs::preserve_most()) || (nm == LangAttrs::preserve_all()) || (nm == LangAttrs::preserve_none())
        || (nm == LangAttrs::no_inline())) {
            return;
        }
        var place = "a type";
        if is_stmt { place = "a statement"; }
        else if what == "expression" { place = "an expression"; }
        self._misplaced(e, nm, "does not apply to " + place, owner, what);
    }

    // === the walk ================================================================

    fn visit_decl(self, n: *Decl) -> bool {
        if (n == &null) || (!n->has_attribute()) || (self._mode == 2) { return true; }
        for var i: usize = 0; i < n->annotations.size(); ++i {
            var e = n->annotations.get(i);
            if (e == &null) || (e->kind != AnnotationKind::Attribute) || (e->name == u32(-1)) { continue; }
            if self._mode == 1 { self._check_decl_attr(n, e); continue; }
            // register_suppressions: the valid codes only; run() reports the rest.
            if self._spell(e) != LangAttrs::no_warn() { continue; }
            for var j: usize = 0; j < e->args.size(); ++j {
                var why = "";
                var id = self._warning_code(self._code_text(self._arg(e, j)), &why);
                if id == DiagID::Invalid { continue; }
                var c = DiagCode(id);
                self.sc->diag->quiet_in(diag_policy_key(c.category(), c.number()), n->range);
            }
        }
        return true;
    }

    fn visit_stmt(self, n: *Stmt) -> bool {
        if (n == &null) || (self._mode != 1) || (!n->has_attribute()) { return true; }
        var is_if = isa::<ConditionalStmt>(n);
        for var i: usize = 0; i < n->annotations.size(); ++i {
            var e = n->annotations.get(i);
            if (e == &null) || (e->kind != AnnotationKind::Attribute) || (e->name == u32(-1)) { continue; }
            self._check_other_attr(e, n->range, "statement", is_if, true);
        }
        return true;
    }

    fn visit_expr(self, n: *Expr) -> bool {
        if (n == &null) || (self._mode != 1) || (!n->has_attribute()) { return true; }
        for var i: usize = 0; i < n->annotations.size(); ++i {
            var e = n->annotations.get(i);
            if (e == &null) || (e->kind != AnnotationKind::Attribute) || (e->name == u32(-1)) { continue; }
            self._check_other_attr(e, n->range, "expression", false, false);
        }
        return true;
    }

    fn visit_type(self, n: *Type) -> bool {
        if (n == &null) || (self._mode != 1) || (!n->has_attribute()) { return true; }
        for var i: usize = 0; i < n->annotations.size(); ++i {
            var e = n->annotations.get(i);
            if (e == &null) || (e->kind != AnnotationKind::Attribute) || (e->name == u32(-1)) { continue; }
            self._check_other_attr(e, n->range, "type", false, false);
        }
        return true;
    }

    // === @deprecated uses ========================================================

    /// The imm table of the file \p d is written in, for a decl no scope
    /// reaches (a local: AttrFacts::find).
    priv fn _local_table(self, d: *Decl) -> *ImmediateTable {
        var tcm = self.sc->ctx->tcm;
        if tcm == &null { return self.sc->imm_table(); }
        return tcm->get_imm_table_for_fid(self.sc->ctx->sm->get_fid(d->range));
    }

    /// \p d's `@deprecated`, read from whichever link carries it: the decl,
    /// its representative, its pattern (an instance), a function's
    /// canonical declaration. _carrier gets the decl that has it.
    priv fn _deprecation(self, d: *Decl) -> *AnnotationEntry {
        if d == &null { return &null; }
        var nm = LangAttrs::deprecated();
        var e = AttrFacts::find(d, nm, self._local_table(d));
        if e != &null { self._carrier = d; return e; }
        var r = NameLookup::representative(d);
        if (r != &null) && (r != d) {
            e = AttrFacts::find(r, nm);
            if e != &null { self._carrier = r; return e; }
        }
        var p = decl_pattern(d);
        if (p != &null) && (p != d) {
            e = AttrFacts::find(p, nm);
            if e != &null { self._carrier = p; return e; }
        }
        var f = dyn_cast::<FunctionDecl>(d);
        if f != &null {
            var c = f->canonical_decl();
            if (c != &null) && (c != f) {
                e = AttrFacts::find(static_cast::<*Decl>(c), nm);
                if e != &null { self._carrier = static_cast::<*Decl>(c); return e; }
            }
        }
        return &null;
    }

    priv fn _use(self, d: *Decl, at: SourceRange) {
        if (self._mode != 2) || (d == &null) || (!at.is_valid()) { return; }
        var e = self._deprecation(d);
        if e == &null { return; }
        var carrier = self._carrier;
        // Inside the deprecated declaration itself (recursion, its own
        // members): not a use by anyone the warning is for.
        if carrier->range.contains(at.start) { return; }
        for var i: usize = 0; i < self._seen.size(); ++i {
            if self._seen[i] == at.start { return; }
        }
        self._seen.push_back(at.start);
        var name = self._tu.decl_name(carrier);
        var msg = "\x27" + name + "\x27 is deprecated";
        if e->args.size() == 1 {
            var a = self._arg(e, 0);
            if (a != &null) && isa::<StringLiteralExpr>(a) && (!cast::<StringLiteralExpr>(a)->is_format()) {
                msg += ": " + self._string_text(cast::<StringLiteralExpr>(a));
            }
        }
        var b = self.sc->diag->report(DiagID::SC001W, at.start, msg);
        b.first(at);
        b.note(e->range.start, "\x27" + name + "\x27 was marked deprecated here");
        b.emit();
    }

    fn visit_named_ident_expr(self, n: *NamedIdentExpr) -> bool {
        if self._mode == 2 { self._use(n->resolved_decl, n->range); }
        return true;
    }

    fn visit_chain_expr(self, n: *ChainExpr) -> bool {
        if self._mode != 2 { return true; }
        for var i: usize = 0; i < n->steps.size(); ++i {
            var st = n->steps.get(i);
            if st == &null { continue; }
            self._use(st->resolved_decl, st->range);
        }
        return true;
    }

    fn visit_call_expr(self, n: *CallExpr) -> bool {
        if (self._mode == 2) && (n->ctor_decl != &null) { self._use(n->ctor_decl, n->range); }
        return true;
    }

    fn visit_binary_operator_expr(self, n: *BinaryOperatorExpr) -> bool {
        if (self._mode == 2) && (n->resolved_op != &null) { self._use(n->resolved_op, n->op_token.range); }
        return true;
    }

    fn visit_assign_operator_expr(self, n: *AssignOperatorExpr) -> bool {
        if (self._mode == 2) && (n->resolved_op != &null) { self._use(n->resolved_op, n->op_token.range); }
        return true;
    }

    fn visit_unary_operator_expr(self, n: *UnaryOperatorExpr) -> bool {
        if (self._mode == 2) && (n->resolved_op != &null) { self._use(n->resolved_op, n->op_token.range); }
        return true;
    }

    fn visit_chain_type(self, n: *ChainType) -> bool {
        if self._mode != 2 { return true; }
        for var i: usize = 0; i < n->segments.size(); ++i {
            var seg = n->segments.get(i);
            if seg == &null { continue; }
            self._use(seg->resolved_decl, seg->range);
        }
        return true;
    }
}
