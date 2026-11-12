/// --- The Kairo Project ------------------ Sema/Check/AttributeCheck.k --- ///
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
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ----------------------------------------------------------------- ///

ffi "c++" import "vector"

import AST::AttrFacts::AttrFacts
import AST::DeclFacts::decl_pattern
import AST::LangItems::LangAttrs
import AST::Mixin::Annotation::{
    AnnotationEntry,
    AnnotationKind,
}
import AST::Node::Base::{
    Decl,
    Expr,
    Stmt,
    Type,
}
import AST::Node::Casting::{
    cast,
    dyn_cast,
    isa,
}
import AST::Node::Declarations::{
    ClassDecl, FieldDecl, FunctionDecl, ProcedureMacroDecl, StructDecl, UnionDecl, VariableDecl,
}
import AST::Node::Expressions::{
    AssignOperatorExpr,
    BinaryOperatorExpr,
    CallExpr,
    UnaryOperatorExpr,
}
import AST::Node::PrimaryExpressions::{
    ChainExpr,
    NamedIdentExpr,
    StringLiteralExpr,
}
import AST::Node::Program::TopLevelKind
import AST::Node::Statements::ConditionalStmt
import AST::Node::Types::ChainType
import AST::Visitor::RecursiveASTVisitor::RecursiveASTVisitor
import Diagnostic::Code::{
    DiagCode,
    diag_from_code,
}
import Diagnostic::Engine::diag_policy_key
import Diagnostic::Registry::{
    DiagID,
    diag_explain,
}
import Diagnostic::Severity::DiagSeverity
import Lexer::Immediate::ImmediateTable
import Location::SourceLocation::SourceLocation
import Location::SourceRange::SourceRange
import Sema::Resolve::NameLookup::NameLookup
import Sema::SemaContext::SemaContext
import Sema::Type::TypeUtil::TypeUtil

pub class AttributeCheck derives RecursiveASTVisitor<AttributeCheck> {
    pub var  sc:  unsafe *SemaContext
    priv var _tu: TypeUtil
    /// 0 register_suppressions, 1 run, 2 run_uses.
    priv var _mode: u8 = 0
    /// The uses already reported (a type segment's name may be reached
    /// twice): one warning per location.
    priv var _seen: cxx::std::vector<SourceLocation>
    /// The decl _deprecation found the attribute on.
    priv var _carrier: unsafe *Decl = &null

    fn AttributeCheck(self, sc: unsafe *SemaContext) {
        self.sc  = sc
        self._tu = TypeUtil(sc)
    }

    fn register_suppressions(self) {
        self._mode = 0
        self._walk()
    }

    fn run(self) {
        self._mode = 1
        self._walk()
    }

    fn run_uses(self) {
        self._mode = 2
        self._walk()
    }

    priv fn _walk(self) {
        var unsafe *tu = self.sc->tu
        if tu == &null || tu->program == &null {
            return
        }

        var *items = &tu->program->items
        for var i: usize = 0; i < items->size(); i++ {
            if self.stop {
                break
            }

            var item = *items->get(i)
            match item.kind {
                case TopLevelKind::Decl {
                    self.dispatch_decl(item.as_decl())
                } case TopLevelKind::Stmt {
                    self.dispatch_stmt(item.as_stmt())
                } case TopLevelKind::Expr {
                    self.dispatch_expr(item.as_expr())
                }
            }
        }
    }

    /// # names

    priv fn _spell(self, e: unsafe *AnnotationEntry) -> string {
        return self.sc->imm_table()->get_ident(e->name)
    }

    priv fn _is_known(self, const nm: string) -> bool {
        for var i: usize = 0; i < 256; ++i {
            var k = LangAttrs::known(i)
            if k.size() == 0 {
                return false
            }

            if k == nm {
                return true
            }
        }

        return false
    }

    /// The known name closest to \p nm, when it is close enough to be a typo
    /// of it (at most a third of its letters off); "" otherwise.
    priv fn _closest(self, const nm: string) -> string {
        var best          = ""
        var best_d: usize = 0
        for var i: usize = 0; i < 256; ++i {
            var k = LangAttrs::known(i)
            if k.size() == 0 {
                break
            }

            var d = self._edit_distance(nm, k)
            if best.size() == 0 || d < best_d {
                best   = k
                best_d = d
            }
        }

        var lim = nm.size() / 3
        if lim < 1 {
            lim = 1
        }

        if best.size() == 0 || best_d > lim {
            return ""
        }

        return best
    }

    /// Two-row Levenshtein (Command::_edit_distance); runs only on a name
    /// that is already an error.
    priv fn _edit_distance(self, const a: string, const b: string) -> usize {
        var n = a.size()
        var m = b.size()
        if n == 0 {
            return m
        }

        if m == 0 {
            return n
        }

        var prev: cxx::std::vector<usize>
        var cur:  cxx::std::vector<usize>
        prev.resize(m + 1, 0 as usize)
        cur.resize(m + 1, 0 as usize)
        for var j: usize = 0; j <= m; ++j {
            prev[j] = j
        }

        for var i: usize = 1; i <= n; ++i {
            cur[0] = i
            for var j: usize = 1; j <= m; ++j {
                var cost: usize = if (a[i - 1] == b[j - 1]) => (0) else => (1)
                var best        = prev[j] + 1
                var ins         = cur[j - 1] + 1
                var sub         = prev[j - 1] + cost
                if ins < best {
                    best = ins
                }

                if sub < best {
                    best = sub
                }

                cur[j] = best
            }

            for var j: usize = 0; j <= m; ++j {
                prev[j] = cur[j]
            }
        }

        return prev[m]
    }

    /// A user attribute macro the attribute names: the decl N bound it to
    /// (decl annotations only), else a file-scope `macro @name` of this TU
    /// (a statement's or type's attribute is never bound by N).
    priv fn _macro_of(self, e: unsafe *AnnotationEntry) -> bool {
        if e->resolved_decl != &null {
            var unsafe *rd = e->resolved_decl
            if isa<ProcedureMacroDecl>(rd) {
                return true
            }
        }

        var unsafe *tu = self.sc->tu
        if tu == &null || tu->program == &null {
            return false
        }

        var *items = &tu->program->items
        for var i: usize = 0; i < items->size(); i++ {
            var item = *items->get(i)
            if item.kind != TopLevelKind::Decl {
                continue
            }

            var unsafe *d = item.as_decl()
            if d == &null || !isa<ProcedureMacroDecl>(d) {
                continue
            }

            if self.sc->ctx->get_ident_imm(cast<ProcedureMacroDecl>(d)->name) == e->name {
                return true
            }
        }

        return false
    }

    /// # diagnostics

    /// "'@x' <why>", at the attribute, a note at what carries it, and a
    /// fix-it that removes it.
    priv fn _misplaced(self,
                       e:          unsafe *AnnotationEntry,
                       const nm:   string,
                       const why:  string,
                       owner:      SourceRange,
                       const what: string) {
        var an = "'@" + nm + "'"
        var b = self.sc->diag->report(
            DiagID::SC143E,
            e->range.start,
            an + " " + why,
        )

        b.first(e->range)
        b.note(owner.start, "the attribute is on this " + what)
        b.remove(e->range, "remove " + an)
        b.emit()
    }

    priv fn _bad_arg(self, e: unsafe *AnnotationEntry, at: SourceRange, const msg: string) {
        var b = self.sc->diag->report(DiagID::SC144E, at.start, msg)
        b.first(at)
        b.emit()
    }

    priv fn _unsupported(self, e: unsafe *AnnotationEntry, const msg: string) {
        var b = self.sc->diag->report(DiagID::SC116E, e->range.start, msg)
        b.first(e->range)
        b.emit()
    }

    priv fn _unknown(self, e: unsafe *AnnotationEntry, const nm: string) {
        var an = "'@" + nm + "'"
        var b = self.sc->diag->report(
            DiagID::SC145E,
            e->range.start,
            "unknown attribute " + an,
        )

        b.first(e->range)
        var near = self._closest(nm)
        if near.size() > 0 {
            b.note(e->range.start, "did you mean '@" + near + "'?")
        }

        b.remove(e->range, "remove " + an)
        b.emit()
    }

    /// The common tail of every position: the two reserved forms and the
    /// names nothing knows. True when \p e was one of them (reported).
    priv fn _reserved_or_unknown(self, e: unsafe *AnnotationEntry, const nm: string) -> bool {
        if nm == LangAttrs::unreachable() {
            self._unsupported(
                e,
                LangAttrs::quoted(LangAttrs::unreachable()) + " is not yet supported",
            )

            return true
        }

        if self._is_known(nm) {
            return false
        }

        if self._macro_of(e) {
            self._unsupported(
                e,
                "the attribute macro '@" + nm + "' is not yet supported: attribute macros are not expanded yet",
            )

            return true
        }

        self._unknown(e, nm)
        return true
    }

    /// # arguments

    priv fn _arg(self, e: unsafe *AnnotationEntry, i: usize) -> unsafe *Expr {
        return e->args[i]
    }

    /// A `@no_warn` argument's code as written: an identifier (`SC031W`)
    /// or a string literal; "" for anything else.
    priv fn _code_text(self, a: unsafe *Expr) -> string {
        if a == &null {
            return ""
        }

        if isa<NamedIdentExpr>(a) {
            return self.sc->ctx->get_spelling(cast<NamedIdentExpr>(a)->name)
        }

        if isa<StringLiteralExpr>(a) {
            var unsafe *sl = cast<StringLiteralExpr>(a)
            if sl->is_format() {
                return ""
            }

            return self._string_text(sl)
        }

        return ""
    }

    priv fn _string_text(self, sl: unsafe *StringLiteralExpr) -> string {
        var out = ""
        if sl->imm != &null && sl->imm->has_owned_text() {
            for var i: usize = 0; i < (sl->imm->owned_len as usize); ++i {
                out.push_back(sl->imm->owned_ptr[i])
            }

            return out
        }

        // No decoded text: the spelling, less its quotes.
        var sp = self.sc->ctx->get_spelling(sl->token)
        var n  = sp.size()
        if n >= 2 && sp[0] == ('"' as u8) && sp[n - 1] == ('"' as u8) {
            var t: string = sp.subslice(1, n - 2)
            return t
        }

        return sp
    }

    /// The warning a `@no_warn` code names, or Invalid (\p why says why).
    priv fn _warning_code(self, const text: string, @inout why: string) -> DiagID {
        if text.size() == 0 {
            (why) = "expects a diagnostic code, such as SC031W"
            return DiagID::Invalid
        }

        var id = diag_from_code(text)
        if id == DiagID::Invalid || diag_explain(id).empty() {
            (why) = "'" + text + "' is not a diagnostic code"
            return DiagID::Invalid
        }

        var sev = DiagCode(id).severity()
        if sev == DiagSeverity::Error || sev == DiagSeverity::Fatal {
            (why) = "'" + text + "' is an error; only a warning can be suppressed"
            return DiagID::Invalid
        }

        if sev != DiagSeverity::Warning {
            (why) = "'" + text + "' is not a warning; only a warning can be suppressed"
            return DiagID::Invalid
        }

        return id
    }

    priv fn _check_no_warn(self, e: unsafe *AnnotationEntry, d: unsafe *Decl) {
        if e->args.size() == 0 {
            self._bad_arg(
                e,
                e->range,
                f"{LangAttrs::quoted(LangAttrs::no_warn())} expects one or more warning codes, such as '{LangAttrs::at(LangAttrs::no_warn())}(SC031W)'",
            )

            return
        }

        for var i: usize = 0; i < e->args.size(); ++i {
            var unsafe *a  = self._arg(e, i)
            var        why = ""
            var        id  = self._warning_code(self._code_text(a), &why)
            if id != DiagID::Invalid {
                continue
            }

            var at = if (a != &null) => (a->range) else => e->range
            self._bad_arg(
                e,
                at,
                LangAttrs::quoted(LangAttrs::no_warn()) + " " + why,
            )
        }
    }

    priv fn _check_align(self, e: unsafe *AnnotationEntry) {
        if AttrFacts::align_value(e) != 0 {
            return
        }

        var at = e->range
        if e->args.size() == 1 {
            var unsafe *a = self._arg(e, 0)
            if a != &null {
                at = a->range
            }
        }

        self._bad_arg(
            e,
            at,
            f"{LangAttrs::quoted(LangAttrs::align())} expects one integer literal that is a power of two, at most 268435456: '{LangAttrs::at(LangAttrs::align())}(16)'",
        )
    }

    priv fn _check_deprecated(self, e: unsafe *AnnotationEntry) {
        if e->args.size() == 0 {
            return
        }

        var unsafe *a = self._arg(e, 0)
        var ok = e->args.size() == 1
            && a != &null
            && isa<StringLiteralExpr>(a)
            && !cast<StringLiteralExpr>(a)->is_format()
        if ok {
            return
        }

        var at = if (a != &null) => (a->range) else => e->range
        self._bad_arg(
            e,
            at,
            LangAttrs::quoted(
                LangAttrs::deprecated(),
            ) + " takes no argument or one string literal, the message",
        )
    }

    /// # positions

    priv fn _is_record(self, d: unsafe *Decl) -> bool {
        return isa<ClassDecl>(d) || isa<StructDecl>(d) || isa<UnionDecl>(d)
    }

    priv fn _check_decl_attr(self, d: unsafe *Decl, e: unsafe *AnnotationEntry) {
        var nm = self._spell(e)
        if self._reserved_or_unknown(e, nm) {
            return
        }

        var fnd = isa<FunctionDecl>(d)
        // Reported where they are stamped (see the file header).
        if nm == LangAttrs::open_enum()
            || nm == LangAttrs::hot_path()
            || nm == LangAttrs::cold_path()
            || nm == LangAttrs::pure_fn()
            || nm == LangAttrs::preserve_most()
            || nm == LangAttrs::preserve_all()
            || nm == LangAttrs::preserve_none()
            || nm == LangAttrs::no_inline() {
            return
        }

        if nm == LangAttrs::implicit_conversion() {
            if !fnd {
                self._misplaced(
                    e,
                    nm,
                    "applies only to a conversion operator: 'fn op as (self) -> T' in a type's body",
                    d->range,
                    "declaration",
                )
            }

            return
        }

        if nm == LangAttrs::transfer_copy() || nm == LangAttrs::transfer_move() {
            if !fnd {
                self._misplaced(
                    e,
                    nm,
                    "applies only to a copy or move constructor",
                    d->range,
                    "declaration",
                )
            }

            return
        }

        if nm == LangAttrs::no_unwind() || nm == LangAttrs::unwind() {
            if !fnd {
                self._misplaced(
                    e,
                    nm,
                    "applies only to a function",
                    d->range,
                    "declaration",
                )
            }

            return
        }

        if nm == LangAttrs::likely() || nm == LangAttrs::unlikely() {
            self._misplaced(
                e,
                nm,
                "applies only to an 'if' statement",
                d->range,
                "declaration",
            )

            return
        }

        if nm == LangAttrs::param_inout() {
            self._misplaced(
                e,
                nm,
                "is a parameter passing mode; it is written on a function or closure parameter",
                d->range,
                "declaration",
            )

            return
        }

        if nm == LangAttrs::assume() {
            self._misplaced(
                e,
                nm,
                f"is a statement of its own: '{LangAttrs::at(LangAttrs::assume())}(cond)'",
                d->range,
                "declaration",
            )

            return
        }

        if nm == LangAttrs::packed() {
            if !self._is_record(d) {
                self._misplaced(
                    e,
                    nm,
                    "applies only to a class, struct or union",
                    d->range,
                    "declaration",
                )

                return
            }

            if e->args.size() != 0 {
                self._bad_arg(
                    e,
                    e->range,
                    LangAttrs::quoted(LangAttrs::packed()) + " takes no arguments",
                )
            }

            return
        }

        if nm == LangAttrs::align() {
            if !self._is_record(d) && (!isa<FieldDecl>(d)) && !isa<VariableDecl>(d) {
                self._misplaced(
                    e,
                    nm,
                    "applies only to a class, struct, union, field or variable",
                    d->range,
                    "declaration",
                )

                return
            }

            self._check_align(e)
            return
        }

        if nm == LangAttrs::deprecated() {
            self._check_deprecated(e)
            return
        }

        if nm == LangAttrs::no_warn() {
            self._check_no_warn(e, d)
            return
        }

        // A known name this pass has no rule for: its owner decides.
    }

    /// An attribute on a statement (not a declaration statement: those
    /// attributes are the declaration's), an expression or a type.
    priv fn _check_other_attr(self,
                              e:          unsafe *AnnotationEntry,
                              owner:      SourceRange,
                              const what: string,
                              is_if:      bool,
                              is_stmt:    bool) {
        var nm = self._spell(e)
        if self._reserved_or_unknown(e, nm) {
            return
        }

        if nm == LangAttrs::likely() || nm == LangAttrs::unlikely() {
            if !is_if {
                self._misplaced(
                    e,
                    nm,
                    "applies only to an 'if' statement",
                    owner,
                    what,
                )
            }

            return
        }

        // ASTParse reports the function attributes on a statement.
        if is_stmt
            && (nm == LangAttrs::hot_path()
                || nm == LangAttrs::cold_path()
                || nm == LangAttrs::pure_fn()
                || nm == LangAttrs::preserve_most()
                || nm == LangAttrs::preserve_all()
                || nm == LangAttrs::preserve_none()
                || nm == LangAttrs::no_inline()) {
            return
        }

        var place = "a type"
        if is_stmt {
            place = "a statement"
        } else if what == "expression" {
            place = "an expression"
        }

        self._misplaced(e, nm, "does not apply to " + place, owner, what)
    }

    /// # the walk

    fn visit_decl(self, n: unsafe *Decl) -> bool {
        if n == &null || !n->has_attribute() || self._mode == 2 {
            return true
        }

        for var i: usize = 0; i < n->annotations.size(); ++i {
            var unsafe *e = n->annotations.get(i)
            if e == &null || e->kind != AnnotationKind::Attribute || e->name == u32::MAX {
                continue
            }

            if self._mode == 1 {
                self._check_decl_attr(n, e)
                continue
            }

            // register_suppressions: the valid codes only; run() reports the rest.
            if self._spell(e) != LangAttrs::no_warn() {
                continue
            }

            for var j: usize = 0; j < e->args.size(); ++j {
                var why = ""
                var id = self._warning_code(
                    self._code_text(self._arg(e, j)),
                    &why,
                )

                if id == DiagID::Invalid {
                    continue
                }

                var c = DiagCode(id)
                self.sc->diag->quiet_in(
                    diag_policy_key(c.category(), c.number()),
                    n->range,
                )
            }
        }

        return true
    }

    fn visit_stmt(self, n: unsafe *Stmt) -> bool {
        if n == &null || self._mode != 1 || !n->has_attribute() {
            return true
        }

        var is_if = isa<ConditionalStmt>(n)
        for var i: usize = 0; i < n->annotations.size(); ++i {
            var unsafe *e = n->annotations.get(i)
            if e == &null || e->kind != AnnotationKind::Attribute || e->name == u32::MAX {
                continue
            }

            self._check_other_attr(e, n->range, "statement", is_if, true)
        }

        return true
    }

    fn visit_expr(self, n: unsafe *Expr) -> bool {
        if n == &null || self._mode != 1 || !n->has_attribute() {
            return true
        }

        for var i: usize = 0; i < n->annotations.size(); ++i {
            var unsafe *e = n->annotations.get(i)
            if e == &null || e->kind != AnnotationKind::Attribute || e->name == u32::MAX {
                continue
            }

            self._check_other_attr(e, n->range, "expression", false, false)
        }

        return true
    }

    fn visit_type(self, n: unsafe *Type) -> bool {
        if n == &null || self._mode != 1 || !n->has_attribute() {
            return true
        }

        for var i: usize = 0; i < n->annotations.size(); ++i {
            var unsafe *e = n->annotations.get(i)
            if e == &null || e->kind != AnnotationKind::Attribute || e->name == u32::MAX {
                continue
            }

            self._check_other_attr(e, n->range, "type", false, false)
        }

        return true
    }

    /// # @deprecated uses

    /// The imm table of the file \p d is written in, for a decl no scope
    /// reaches (a local: AttrFacts::find).
    priv fn _local_table(self, d: unsafe *Decl) -> unsafe *ImmediateTable {
        var unsafe *tcm = self.sc->ctx->tcm
        if tcm == &null {
            return self.sc->imm_table()
        }

        return tcm->get_imm_table_for_fid(self.sc->ctx->sm->get_fid(d->range))
    }

    /// \p d's `@deprecated`, read from whichever link carries it: the decl,
    /// its representative, its pattern (an instance), a function's
    /// canonical declaration. _carrier gets the decl that has it.
    priv fn _deprecation(self, d: unsafe *Decl) -> unsafe *AnnotationEntry {
        if d == &null {
            return &null
        }

        var        nm = LangAttrs::deprecated()
        var unsafe *e = AttrFacts::find(d, nm, self._local_table(d))
        if e != &null {
            self._carrier = d
            return e
        }

        var unsafe *r = NameLookup::representative(d)
        if r != &null && r != d {
            e = AttrFacts::find(r, nm)
            if e != &null {
                self._carrier = r
                return e
            }
        }

        var unsafe *p = decl_pattern(d)
        if p != &null && p != d {
            e = AttrFacts::find(p, nm)
            if e != &null {
                self._carrier = p
                return e
            }
        }

        var unsafe *f = dyn_cast<FunctionDecl>(d)
        if f != &null {
            var unsafe *c = f->canonical_decl()
            if c != &null && c != f {
                e = AttrFacts::find(c, nm)
                if e != &null {
                    self._carrier = c
                    return e
                }
            }
        }

        return &null
    }

    priv fn _use(self, d: unsafe *Decl, at: SourceRange) {
        if self._mode != 2 || d == &null || !at.is_valid() {
            return
        }

        var unsafe *e = self._deprecation(d)
        if e == &null {
            return
        }

        var unsafe *carrier = self._carrier
        // Inside the deprecated declaration itself (recursion, its own
        // members): not a use by anyone the warning is for.
        if carrier->range.contains(at.start) {
            return
        }

        for var i: usize = 0; i < self._seen.size(); ++i {
            if self._seen[i] == at.start {
                return
            }
        }

        self._seen.push_back(at.start)
        var name = self._tu.decl_name(carrier)
        var msg  = "'" + name + "' is deprecated"
        if e->args.size() == 1 {
            var unsafe *a = self._arg(e, 0)
            if a != &null && isa<StringLiteralExpr>(a) && !cast<StringLiteralExpr>(a)->is_format() {
                msg += ": " + self._string_text(cast<StringLiteralExpr>(a))
            }
        }

        var b = self.sc->diag->report(DiagID::SC146W, at.start, msg)
        b.first(at)
        b.note(e->range.start, "'" + name + "' was marked deprecated here")
        b.emit()
    }

    fn visit_named_ident_expr(self, n: *NamedIdentExpr) -> bool {
        if self._mode == 2 {
            self._use(n->resolved_decl, n->range)
        }

        return true
    }

    fn visit_chain_expr(self, n: *ChainExpr) -> bool {
        if self._mode != 2 {
            return true
        }

        for var i: usize = 0; i < n->steps.size(); ++i {
            var unsafe *st = n->steps.get(i)
            if st == &null {
                continue
            }

            self._use(st->resolved_decl, st->range)
        }

        return true
    }

    fn visit_call_expr(self, n: *CallExpr) -> bool {
        if self._mode == 2 && n->ctor_decl != &null {
            self._use(n->ctor_decl, n->range)
        }

        return true
    }

    fn visit_binary_operator_expr(self, n: *BinaryOperatorExpr) -> bool {
        if self._mode == 2 && n->resolved_op != &null {
            self._use(n->resolved_op, n->op_token.range)
        }

        return true
    }

    fn visit_assign_operator_expr(self, n: *AssignOperatorExpr) -> bool {
        if self._mode == 2 && n->resolved_op != &null {
            self._use(n->resolved_op, n->op_token.range)
        }

        return true
    }

    fn visit_unary_operator_expr(self, n: *UnaryOperatorExpr) -> bool {
        if self._mode == 2 && n->resolved_op != &null {
            self._use(n->resolved_op, n->op_token.range)
        }

        return true
    }

    fn visit_chain_type(self, n: *ChainType) -> bool {
        if self._mode != 2 {
            return true
        }

        for var i: usize = 0; i < n->segments.size(); ++i {
            var unsafe *seg = n->segments.get(i)
            if seg == &null {
                continue
            }

            self._use(seg->resolved_decl, seg->range)
        }

        return true
    }
}
