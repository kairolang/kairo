/// --- The Kairo Project ------------------- Sema/Check/BaseInitCheck.k --- ///
///
///   \brief A derived class builds each base exactly once, before anything
///          else, by calling the base's constructor by qualified name:
///          `Animal::Animal(self, legs)` (classes-inheritance.md).
///
///   \detail
///     C++ builds a base before the derived constructor's body runs, and
///     the call becomes the constructor's mem-initializer (EmitIR,
///     _mem_inits). So what Kairo admits is exactly what that form can
///     say:
///
///       - a constructor is called by name only as a base initializer: a
///         statement of its own, among the FIRST statements of a
///         constructor of a class the constructor's record is a direct
///         base of, or a virtual base anywhere above ([class.base.init]/2);
///       - its first argument is `self`, and no other argument names
///         `self` (the object does not exist yet: a mem-initializer reading
///         a member reads it uninitialized);
///       - each base at most once.
///
///     And a base must be built somehow: one whose constructors all take
///     arguments (or whose default constructor is deleted) has to be
///     initialized by EVERY constructor of a class deriving it -- an
///     implicit one included, which is then no constructor at all. Left to
///     clang, each was CL001E "constructor for 'Dog' must explicitly
///     initialize the base class 'Animal'" in the generated C++.
///
///     A transfer constructor that is `= default` copies or moves its bases
///     itself, and one with a body builds them like any other constructor.
///     Imported C++ bases are clang's to judge: their constructors are not
///     visible to this question (TypeUtil::default_record).
///
///     SC180E (the call rules) and SC181E (a base left uninitialized).
///
///   Phase: CHECKS, after InitCheck, before CtorInitCheck (which skips the
///          statements this pass admits: they run before S_pre does).
///          Reads X's callee bindings.
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

import AST::DeclFacts::{
    decl_is_imported,
    decl_is_instance,
    decl_name_tok,
    decl_only_forward,
    decl_pattern,
}
import AST::Node::Base::{
    Decl,
    Stmt,
    Type,
}
import AST::Node::CanonicalNodes::canon_unqual
import AST::Node::Casting::{
    cast,
    dyn_cast,
    isa,
}
import AST::Node::Declarations::{
    AdtRole,
    ClassDecl,
    FnBodyKind,
    FunctionDecl,
    ParamDecl,
    TransferKind,
}
import AST::Node::Expressions::CallExpr
import AST::Node::PrimaryExpressions::{
    ChainExpr,
    NamedIdentExpr,
}
import AST::Node::Program::TopLevelKind
import AST::Node::Statements::ExpressionStmt
import AST::Visitor::RecursiveASTVisitor::RecursiveASTVisitor
import Diagnostic::Code::DiagCode
import Diagnostic::Registry::DiagID
import Location::SourceRange::SourceRange
import Sema::Resolve::NameLookup::NameLookup
import Sema::SemaContext::{
    SemaContext,
    SemaPhase,
}
import Sema::Type::TypeUtil::TypeUtil

/// A method named after the record it is declared in.
pub fn base_init_is_ctor(f: unsafe *FunctionDecl) -> bool {
    if f == &null || f->is_operator || !f->is_method() || f->adt_role != AdtRole::None {
        return false
    }

    var unsafe *dc = f->semantic_dc
    if dc == &null
        || !dc->is_type_scope()
        || dc->dc_owner == &null
        || !isa<ClassDecl>(dc->dc_owner) {
        return false
    }

    var unsafe *fc = NameLookup::ctx_of(f)
    var unsafe *oc = NameLookup::ctx_of(dc->dc_owner)
    if fc == &null || oc == &null {
        return false
    }

    return fc->get_spelling(f->name) == oc->get_spelling(decl_name_tok(dc->dc_owner))
}

/// The constructor \p n calls BY NAME (`Animal::Animal(self, 4)`), or null.
/// A construction (`Animal(4)`) names the type and carries ctor_decl.
pub fn base_init_ctor_of(n: unsafe *CallExpr) -> unsafe *FunctionDecl {
    if n == &null || n->ctor_decl != &null {
        return &null
    }

    var unsafe *ch = dyn_cast<ChainExpr>(n->callee)
    if ch == &null || ch->steps.size() == 0 {
        return &null
    }

    var unsafe *st = ch->steps.get(ch->steps.size() - 1)
    if st->access_kind != ChainExpr::AccessKind::ColonColon {
        return &null
    }

    var unsafe *f = dyn_cast<FunctionDecl>(st->resolved_decl)
    if !base_init_is_ctor(f) {
        return &null
    }

    return f
}

/// The call when \p s is a statement that is only a constructor called by
/// name, else null.
pub fn base_init_stmt(s: unsafe *Stmt) -> unsafe *CallExpr {
    var unsafe *es = dyn_cast<ExpressionStmt>(s)
    if es == &null || es->expr == &null {
        return &null
    }

    var unsafe *n = dyn_cast<CallExpr>(es->expr)
    if base_init_ctor_of(n) == &null {
        return &null
    }

    return n
}

/// The record a constructor builds, as its pattern's representative.
pub fn base_init_owner(f: unsafe *FunctionDecl) -> unsafe *Decl {
    var unsafe *dc = f->semantic_dc
    return NameLookup::representative(decl_pattern(dc->dc_owner))
}

/// Any `self` under an expression.
pub class BaseInitSelfFind derives RecursiveASTVisitor<BaseInitSelfFind> {
    pub var at:    SourceRange
    pub var found: bool        = false

    fn visit_named_ident_expr(self, n: *NamedIdentExpr) -> bool {
        var unsafe *p = dyn_cast<ParamDecl>(n->resolved_decl)
        if p != &null && p->is_self {
            self.found = true
            self.at    = n->range
            self.stop  = true
        }

        return true
    }
}

pub class BaseInitCheck derives RecursiveASTVisitor<BaseInitCheck> {
    pub var  sc:  unsafe *SemaContext
    priv var _tu: TypeUtil
    /// The base initializers the constructor being walked admitted; any
    /// other call of a constructor by name is an error (visit_call_expr).
    priv var _ok: cxx::std::vector<unsafe *CallExpr>

    fn BaseInitCheck(self, sc: unsafe *SemaContext) {
        self.sc  = sc
        self._tu = TypeUtil(sc)
    }

    fn run(self) {
        self.sc->require_phase(SemaPhase::TypesResolved)
        var unsafe *tu = self.sc->tu
        if tu == &null || tu->program == &null {
            return
        }

        var *items = &tu->program->items
        for var i: usize = 0; i < items->size(); ++i {
            if self.stop {
                break
            }

            var item = *items->get(i)
            match item.get_kind() {
                case TopLevelKind::Decl {
                    self.dyn()->dispatch_decl(item.as_decl())
                } case TopLevelKind::Stmt {
                    self.dyn()->dispatch_stmt(item.as_stmt())
                } case TopLevelKind::Expr {
                    self.dyn()->dispatch_expr(item.as_expr())
                }
            }
        }
    }

    /// # the class: every base that needs it is built

    fn visit_class_decl(self, n: *ClassDecl) -> bool {
        if n->is_poisoned()
            || decl_is_instance(unsafe (n as unsafe *Decl))
            || decl_is_imported(unsafe (n as unsafe *Decl)) {
            return true
        }

        var cname    = self._tu.decl_name(unsafe (n as unsafe *Decl))
        var any_ctor = false
        for var i: usize = 0; i < n->methods.size(); ++i {
            var unsafe *m = n->methods[i]
            if m == &null || m->is_poisoned() || !base_init_is_ctor(m) {
                continue
            }

            any_ctor = true
            var unsafe *def = m
            if !m->has_body() {
                def = m->definition()
            }

            if def == &null || def->is_poisoned() {
                continue
            }

            if def->body_kind == FnBodyKind::Delete || def->body_kind == FnBodyKind::Virtual {
                continue
            }

            // A defaulted transfer constructor copies or moves the bases.
            if def->body_kind == FnBodyKind::Default && def->transfer != TransferKind::NotTransfer {
                continue
            }

            for var j: usize = 0; j < n->derives_list.size(); ++j {
                var unsafe *e = n->derives_list.get(j)
                if e == &null || e->base == &null {
                    continue
                }

                var why = self._needs_init(e->base, false)
                if why.size() == 0 {
                    continue
                }

                if self._inits(def, e->base) {
                    continue
                }

                var bname = self._tu.str(canon_unqual(e->base->canonical))
                var b = self.sc->diag->report(
                    DiagID::SC181E,
                    def->name.range.start,
                    f"constructor of '{cname}' does not initialize its base '{bname}', and {why}",
                )

                b.first(def->name.range, "base not initialized")
                var hint = f"'{bname}' is a base here; call one of its constructors first in the body: '{bname}::{self._leaf(e->base)}(self, ...)'"
                var unsafe *brd = self._tu.default_record(canon_unqual(e->base->canonical))
                if brd != &null && !self._tu.declares_ctor(brd) {
                    hint = f"'{bname}' is a base here and declares no constructor to call; give it one, or make its implicit one possible"
                }

                b.note(DiagCode(DiagID::SC181N), e->range.start, hint)->first(e->range)
                b.emit()
            }
        }

        if any_ctor {
            return true
        }

        // No constructor at all: the implicit one can only default-build a base.
        for var j: usize = 0; j < n->derives_list.size(); ++j {
            var unsafe *e = n->derives_list.get(j)
            if e == &null || e->base == &null {
                continue
            }

            var why = self._needs_init(e->base, true)
            if why.size() == 0 {
                continue
            }

            var bname = self._tu.str(canon_unqual(e->base->canonical))
            var b = self.sc->diag->report(
                DiagID::SC181E,
                n->name.range.start,
                f"'{cname}' has no constructor, so nothing initializes its base '{bname}', and {why}",
            )

            b.first(n->name.range)
            b.note(
                DiagCode(DiagID::SC181N),
                e->range.start,
                f"'{bname}' is a base here; declare a constructor whose first statement calls one of its own: '{bname}::{self._leaf(e->base)}(self, ...)'",
            )->first(e->range)
            b.emit()
        }

        return true
    }

    /// Why base \p t cannot be built from nothing, "" when it can (or when
    /// clang decides: an imported or dependent base).
    ///
    /// \p implicit: the derived class declares no constructor. Its implicit
    /// one is then judged where it is used (TypeUtil::why_no_default covers
    /// the base too), so only a base that declares constructors -- and so
    /// visibly has none to default to -- is reported at the class. A base
    /// that is only forward-declared is the by-value check's error.
    priv fn _needs_init(self, t: unsafe *Type, implicit: bool) -> string {
        if t == &null || t->canonical == &null {
            return ""
        }

        var unsafe *c = canon_unqual(t->canonical)
        if c == &null || c->is_dependent() {
            return ""
        }

        var unsafe *rd = self._tu.default_record(c)
        if rd == &null || !isa<ClassDecl>(rd) || decl_only_forward(rd) {
            return ""
        }

        if implicit && !self._tu.declares_ctor(rd) {
            return ""
        }

        var        nm  = self._tu.decl_name(rd)
        var unsafe *dc = self._tu.default_ctor_of(rd)
        if dc != &null {
            if dc->body_kind == FnBodyKind::Delete {
                return f"the default constructor of '{nm}' is deleted"
            }

            return ""
        }

        // No default constructor: only a record that declares constructors
        // lost the implicit one. A declared transfer constructor -- even a
        // deleted `@copy` -- counts, in Kairo as in C++: `X()` is refused
        // for it (CallTyping), and clang would refuse the derived class.
        var unsafe *cd           = cast<ClassDecl>(rd)
        var        transfer_only = false
        for var i: usize = 0; i < cd->methods.size(); ++i {
            var unsafe *m = cd->methods[i]
            if m == &null || !base_init_is_ctor(m) {
                continue
            }

            if m->transfer == TransferKind::NotTransfer {
                return f"'{nm}' has no default constructor"
            }

            transfer_only = true
        }

        if transfer_only {
            return f"'{nm}' has no default constructor: declaring its transfer constructor removed the implicit one (declare 'fn {nm}(self) = default' to keep it)"
        }

        // No constructor declared: the implicit one exists only when it can
        // build every base and field of its own (TypeUtil's rule, the one
        // `X()` and a field of type X are judged by).
        return self._tu.why_no_default(c)
    }

    /// The base's own name, the constructor's spelling after `::`.
    priv fn _leaf(self, t: unsafe *Type) -> string {
        var unsafe *rd = self._tu.record_decl(canon_unqual(t->canonical))
        if rd == &null {
            return "?"
        }

        return self._tu.decl_name(decl_pattern(rd))
    }

    /// Constructor \p f has a leading base initializer for base \p t.
    priv fn _inits(self, f: unsafe *FunctionDecl, t: unsafe *Type) -> bool {
        if f->body_kind != FnBodyKind::Block || f->body_block == &null {
            return false
        }

        var unsafe *want = self._base_rep(t)
        var        stmts = f->body_block->body
        for var i: usize = 0; i < stmts.size(); ++i {
            var unsafe *n = base_init_stmt(stmts[i])
            if n == &null {
                break
            }

            if base_init_owner(base_init_ctor_of(n)) == want {
                return true
            }
        }

        return false
    }

    priv fn _base_rep(self, t: unsafe *Type) -> unsafe *Decl {
        if t == &null || t->canonical == &null {
            return &null
        }

        var unsafe *rd = self._tu.record_decl(canon_unqual(t->canonical))
        if rd == &null {
            return &null
        }

        return NameLookup::representative(decl_pattern(rd))
    }

    /// # one constructor: its leading base initializers

    fn traverse_function_decl(self, n: unsafe *FunctionDecl) -> unsafe *FunctionDecl {
        var saved = self._ok
        self._ok = cxx::std::vector<unsafe *CallExpr>()
        if !n->is_poisoned()
            && base_init_is_ctor(n)
            && n->body_kind == FnBodyKind::Block
            && n->body_block != &null {
            self._lead(n)
        }

        var unsafe *r = RecursiveASTVisitor<BaseInitCheck>::traverse_function_decl(self, n)
        self._ok = saved
        return r
    }

    /// Judge the leading run of constructor-by-name statements of \p f and
    /// admit the good ones into _ok.
    priv fn _lead(self, f: unsafe *FunctionDecl) {
        var unsafe *owner = base_init_owner(f)
        var        stmts  = f->body_block->body
        var        done   = cxx::std::vector<unsafe *Decl>()
        for var i: usize = 0; i < stmts.size(); ++i {
            var unsafe *n = base_init_stmt(stmts[i])
            if n == &null {
                break
            }

            var unsafe *ctor = base_init_ctor_of(n)
            var unsafe *base = base_init_owner(ctor)
            var        bname = self._tu.decl_name(base)
            var        cname = self._tu.decl_name(owner)
            if n->is_poisoned() {
                self._ok.push_back(n)
                continue
            }

            if base == owner {
                var b = self.sc->diag->report(
                    DiagID::SC180E,
                    n->range.start,
                    f"a constructor of '{cname}' cannot call another of its own constructors; only a base constructor is called by name",
                )

                b.first(n->range)
                b.note(
                    DiagCode(DiagID::SC180N),
                    f->name.range.start,
                    "this constructor builds the object itself",
                )->first(f->name.range)
                b.emit()
                self._ok.push_back(n)
                continue
            }

            if !self._is_base(owner, base, false, 0) {
                var b = self.sc->diag->report(
                    DiagID::SC180E,
                    n->range.start,
                    f"'{bname}' is not a direct or virtual base of '{cname}'; a constructor initializes only those",
                )

                b.first(n->range)
                b.note(
                    DiagCode(DiagID::SC180N),
                    decl_name_tok(base).range.start,
                    f"'{bname}' is declared here",
                )->first(decl_name_tok(base).range)
                b.emit()
                self._ok.push_back(n)
                continue
            }

            var dup = false
            for var k: usize = 0; k < done.size(); ++k {
                if done[k] == base {
                    dup = true
                    break
                }
            }

            if dup {
                var b = self.sc->diag->report(
                    DiagID::SC180E,
                    n->range.start,
                    f"base '{bname}' is initialized twice",
                )

                b.first(n->range)
                b.remove(stmts[i]->range, "remove the second initialization")
                b.emit()
                self._ok.push_back(n)
                continue
            }

            done.push_back(base)
            self._args(n, bname)
            self._ok.push_back(n)
        }
    }

    /// The object is argument zero and nowhere else.
    priv fn _args(self, n: unsafe *CallExpr, const bname: string) {
        if n->args.size() == 0 {
            return
        }

        var unsafe *a0   = n->args[0]
        var unsafe *p0   = dyn_cast<NamedIdentExpr>(a0)
        var        self0 = false
        if p0 != &null {
            var unsafe *pd = dyn_cast<ParamDecl>(p0->resolved_decl)
            self0 = pd != &null && pd->is_self
        }

        if !self0 {
            var b = self.sc->diag->report(
                DiagID::SC180E,
                a0->range.start,
                f"a base initializer builds the base part of 'self'; its first argument must be 'self'",
            )

            b.first(a0->range)
            b.fix(a0->range, "self", "pass 'self'")
            b.note(
                DiagCode(DiagID::SC180N),
                n->range.start,
                f"this initializes base '{bname}'",
            )->first(n->callee->range)
            b.emit()
            return
        }

        for var i: usize = 1; i < n->args.size(); ++i {
            var s = BaseInitSelfFind()
            s.dispatch_expr(n->args[i])
            if !s.found {
                continue
            }

            var b = self.sc->diag->report(
                DiagID::SC180E,
                s.at.start,
                f"'self' cannot be used in the arguments of the initializer of base '{bname}': the object is built only after its bases",
            )

            b.first(s.at)
            b.note(
                DiagCode(DiagID::SC180N),
                n->range.start,
                "base initializers run before any field is initialized",
            )->first(n->callee->range)
            b.emit()
            return
        }
    }

    /// \p base is a direct base of \p d, or (\p virt) a virtual base above.
    priv fn _is_base(self, d: unsafe *Decl, base: unsafe *Decl, virt: bool, depth: u32) -> bool {
        if d == &null || depth > 64 || !isa<ClassDecl>(d) {
            return false
        }

        var unsafe *cd = cast<ClassDecl>(d)
        for var i: usize = 0; i < cd->derives_list.size(); ++i {
            var unsafe *e = cd->derives_list.get(i)
            if e == &null || e->base == &null {
                continue
            }

            var unsafe *bd = self._base_rep(e->base)
            if bd == &null {
                continue
            }

            if bd == base && (depth == 0 || e->is_virtual) {
                return true
            }

            if self._is_base(bd, base, true, depth + 1) {
                return true
            }
        }

        return false
    }

    /// A constructor called by name anywhere it is not an admitted base
    /// initializer.
    fn visit_call_expr(self, n: unsafe *CallExpr) -> bool {
        if n->is_poisoned() {
            return true
        }

        var unsafe *ctor = base_init_ctor_of(n)
        if ctor == &null {
            return true
        }

        for var i: usize = 0; i < self._ok.size(); ++i {
            if self._ok[i] == n {
                return true
            }
        }

        var bname = self._tu.decl_name(base_init_owner(ctor))
        var b = self.sc->diag->report(
            DiagID::SC180E,
            n->range.start,
            f"a constructor is called by name only to initialize a base, as one of the first statements of a constructor of a derived class",
        )

        b.first(n->range)
        b.note(
            DiagCode(DiagID::SC180N),
            ctor->name.range.start,
            f"to build an object of '{bname}', call the type by name instead",
        )->first(ctor->name.range)
        b.emit()
        return true
    }
}
