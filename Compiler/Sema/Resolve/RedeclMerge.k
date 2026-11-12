/// --- The Kairo Project ------------------- Sema/Resolve/RedeclMerge.k --- ///
///
///   \brief Phase R: merge FUNCTION redeclarations into a single canonical
///          decl, now that signatures exist.
///
///   \detail
///     N(a) merges the redeclarable NON-function kinds (class, struct,
///     union, interface, enum, module) in _link_group: same name, same
///     kind, same scope IS the same entity, and no types are needed to say
///     so. It stops at functions on purpose, and says why -- telling a
///     redeclaration from an overload needs SIGNATURES, and signatures need
///     canonical parameter types, which do not exist until T.
///
///     This pass is the other half:
///
///       R(a) in-scope chains -- per frozen table, group each all-function
///            cell by signature. Same signature = one entity: link it, make
///            the links agree, pick the canonical, diagnose the illegal
///            repeat. Different signature = a genuine overload, untouched.
///
///       R(b) out-of-line     -- match each `fn Class::method` against the
///            in-class overload set BY SIGNATURE and link it into that
///            decl's chain. N(a) attached these to their home scope
///            (semantic_dc) and left the link undone for the same reason.
///
///       R(c) inline bodies   -- once every chain is linked, an `inline`
///            function with no definition on its chain is an error.
///
///   \par What a SIGNATURE is
///     Arity, canonical parameter types in order, and generic-parameter
///     arity. Two decls agreeing on all of it are ONE ENTITY; anything else
///     is an overload.
///
///     The passing MODE of each parameter is in the signature (AST/ParamMode.k):
///     `f(x: T)` and `f(@inout x: T)` are two entities the call site tells
///     apart by the `&` marker. `f(x: T)` and `f(@move x: T)` are two
///     entities to C++ (`T` vs `T&&`) and ONE source text to a Kairo caller,
///     so that pair is an error at the second declaration
///     (_check_move_overload). Against a FOREIGN decl the C++ reference
///     kind is read as the mode it spells: `T&` is `@inout`, `const T&` is
///     by value, `T&&` is `@move` -- which is what lets a Kairo out-of-line
///     definition match an imported method. Foreign-vs-foreign pairs keep
///     the type-only comparison: their modes are all Value and the
///     reference kinds are already in their canonicals.
///
///     The TRANSFER MARKER is in the signature when both decls carry one:
///     `@copy fn X(self, const other: Self)` and `@move fn X(self, other:
///     Self)` are X(const X&) and X(X&&), two constructors. Their `other` is
///     written bare and only gets the mode its marker means when
///     ClassLifecycle stamps it, in the checks, after this pass -- so until
///     then the marker is the one thing telling the two apart, and without it
///     the NON_TRANSFER shape (both `= delete`) reads as one member declared
///     twice. This is what lets R(b) refuse to pair an out-of-line `@move`
///     definition with an in-class `@copy` declaration.
///
///     In a MEMBER TABLE, R(a) goes further and never merges two marked
///     constructors at all, same kind or not. How many transfer constructors
///     a class may have is ClassLifecycle's rule (SC057E), and it is the
///     accurate error for a second `@copy`: merged here, `@copy` with and
///     without `const` on `other` -- X(const X&) and X(X&), two constructors
///     to C++ -- would read as one member declared twice (R041E), since
///     top-level const is not in a signature. R(b) is untouched by this: an
///     out-of-line definition that repeats the marker must still find the
///     declaration it defines.
///
///     Everything else is EXCLUDED, and each exclusion is load-bearing:
///
///       return type       -- excluded, which is what makes a mismatch a
///                            CONFLICT rather than an overload.
///       method const-ness -- excluded FOR KAIRO-AUTHORED DECLS, included
///                            for foreign ones and for place operators.
///                            Kairo does not permit const overloading (it
///                            costs more than it buys), so `fn f(self)` and
///                            `fn f(const self)` in Kairo source are one
///                            entity that disagrees about const -- checked
///                            below, not compared here. C++ puts the
///                            cv-qualifier of the implicit object parameter
///                            IN the signature and the STL depends on it, so
///                            an extracted header's const/non-const pairs
///                            stay two entities; the gate is _foreign, the
///                            same predicate TypeResolution uses. The
///                            `[]` operator
///                            (OperatorFacts::is_subscript), and `->`
///                            with it, are the exception to the
///                            restriction: `-> *T` beside
///                            `-> *const T` is the pair a const receiver
///                            needs, and X ranks the two by receiver. Keyed
///                            on operator KIND, not on is_place: a value
///                            `op [] -> [T;]` beside its `-> [const T;]`
///                            pair is two entities too, and the exception
///                            takes no part in the place/value decision.
///
///     Fixity is INCLUDED: `op l++` and `op r++` share a name cell
///     (OperatorFacts::key) and X picks between them by is_postfix, so the
///     pair is two entities, not one declared twice.
///       default arguments -- excluded; a default is a property of a
///                            declaration, not of the function type.
///       parameter names   -- excluded; not part of any type.
///       top-level param
///         const           -- excluded, same as C++ ([dcl.fct]/5) -- both
///                            the `const` on the binding (ParamDecl::is_const)
///                            and a `const` written on the type at its top
///                            level (`x: const *i32` is a const pointer, and
///                            `f(x: const *i32)` / `f(x: *i32)` are one
///                            function). A qualifier UNDER the top level
///                            stays: `f(*const i32)` and `f(*i32)` are two.
///                            The receiver's is under the top level --
///                            `const self` is `const Foo*` -- and stays.
///
///     Identity is a POINTER comparison on canonicals, which is only sound
///     because CanonicalTypeStore uniques BUILD-wide, not per-TU: an
///     imported `fn f(x: i32)` and a local one must share the i32 canonical
///     or a cross-TU redefinition goes unseen. See CanonicalTypes.k.
///
///   \par What one entity must AGREE on
///     Return type, default arguments (specified once per parameter across
///     the whole chain), ABI / FFI linkage, and the semantic modifiers
///     (const, unsafe, async, eval, panic, noreturn). A disagreement is an
///     error at the later declaration; the chain still links, so a use site
///     resolves to the canonical instead of cascading.
///
///   \par Two scopes, two rules
///     At FILE scope, repeat declarations are legal and two DEFINITIONS are
///     the error. Inside a TYPE BODY they are not: a member-specification
///     may not declare the same member twice at all ([class.mem]), because
///     the out-of-line definition -- which never entered the member table --
///     is the only way to split a declaration from its definition. R(a)
///     therefore takes the scope kind as an argument; R(b) always uses the
///     file-scope rule, since an out-of-line def is not part of the
///     member-specification.
///
///   \par Dependent signatures are not ours
///     A parameter whose canonical is null is dependent or awaiting M2. Two
///     `fn f(x: T)` in one template are not a redefinition, and deciding
///     whether they collide after substitution is M2's. A null canonical
///     therefore reads as "not the same signature": conservative in the
///     right direction, since inventing a redefinition is worse than
///     missing one M2 will catch.
///
///   \par One error, one home
///     Function redefinition, member redeclaration, return-type conflict,
///     default-argument redefinition, linkage and modifier disagreement,
///     out-of-line signature mismatch: HERE. Non-function redefinition:
///     N(a). Specialization redefinition: T (_link_spec, keyed on spec
///     args). Overload SELECTION at a call: OverloadResolution, which
///     REQUIRES this pass to have run -- an unmerged set hands it a
///     declaration and its definition as two competing candidates for one
///     entity.
///
///   \par Explicitly NOT done here
///     - attribute merging across a chain. Annotations are arbitrary user
///       macros with no merge semantics defined yet; deciding which must
///       agree, which are first-wins, and which accumulate is an
///       attribute-system question, not a redecl one.
///     - `where` groups. Same-signature overloads where either one has a
///       `where` guard are a dispatch group (where.mdx), not one entity:
///       they are never linked, so none is a redefinition of another.
///       This pass only names the group, stamping `where_lead` (its
///       first-declared member) on every member; WhereGuardCheck judges
///       the group and WhereDispatchLowering folds it into one function.
///       An `unsafe` overload is never a member (where.mdx, "Where and
///       unsafe"). Two UNGUARDED same-signature definitions are still
///       linked, so a second fallback is R029E as before.
///     - block-scope redeclaration semantics. C++ discards a default added
///       in a block-scope declaration at the end of that block; Kairo has
///       block-scope `fn` (NameResolution::_stmt_decl_imm) but no rule yet.
///
///   Phase: RESOLVE (R), inside the T stage, after TypeResolution and
///          before ChainBinding -- an unmerged cell would hand ChainBinding
///          two candidates for one member.
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

import AST::ASTSupport::FrozenList
import AST::Context::DeclContext::DeclContext
import AST::Context::SymbolTable::{
    DeclName,
    OverloadCell,
    SymbolTable,
}
import AST::Context::TranslationUnit::TranslationUnit
import AST::DeclFacts::decl_name_tok
import AST::Kind::DeclKind::DeclKind
import AST::Kind::ExprKind::ExprKind
import AST::LangItems::LangAttrs
import AST::Node::Base::{
    Decl,
    Expr,
    Type,
}
import AST::Node::CanonicalNodes::{
    BuiltinKind,
    BuiltinType,
    builtin_info,
    canon_has_const,
    canon_quals,
    canon_unqual,
}
import AST::Node::Casting::{
    cast,
    dyn_cast,
    isa,
}
import AST::Node::Declarations
import AST::Node::Expressions::{
    BinaryOperatorExpr,
    ConstraintExpr,
}
import AST::Node::PrimaryExpressions::NamedIdentExpr
import AST::Node::Types::{
    CXXLValueRefType,
    CXXRValueRefType,
    PointerType,
}
import AST::OperatorFacts::OperatorFacts
import AST::ParamMode::ParamMode
import Diagnostic::Code::DiagCode
import Diagnostic::NoteText::previously_declared_here
import Diagnostic::Registry::DiagID
import Sema::Resolve::MemberLookup::MemberLookup
import Sema::Resolve::NameLookup::NameLookup
import Sema::SemaContext::{
    SemaContext,
    SemaPhase,
}
import Sema::Type::Substitution::Substitution
import Sema::Type::TypeUtil::TypeUtil
import Token::TokenKind::TokenKind

///
/// \class RedeclMerge
/// \brief The R pass. One instance per TU per run; no cursors, no stack.
///
///        Unlike N and T this pass keeps NO scope state: it reads canonical
///        slots off already-resolved nodes and writes decl-to-decl links.
///        It never resolves a name, never dispatches a type, never enters
///        an expression. That is why it is not a method on TypeResolution:
///        T's frames / _selfs / ltypes / cur_dc are irrelevant here, and
///        having them in scope invites a future edit to use them.
///
/// One parameter's contribution to signature identity: the type it is
/// judged on and the mode it is passed by, after the foreign mapping.
pub class SigShape {
    pub var mode: ParamMode    = ParamMode::Value
    pub var ty:   unsafe *Type = &null
    fn SigShape(self) { }
}

pub class RedeclMerge {
    pub var sc: unsafe *SemaContext

    fn RedeclMerge(self, sc: unsafe *SemaContext) {
        self.sc = sc
    }

    /// PRE: NamesResolved, and TypeResolution has run in this same stage
    /// (canonical param types exist). NOT TypesResolved -- the driver does
    /// not advance the phase until every pass in the T stage has returned,
    /// so asserting this stage's EXIT phase from inside it would fire.
    /// POST: function redecl chains linked; canonical points at the
    /// definition where there is one.
    fn run(self) {
        self.sc->require_phase(SemaPhase::NamesResolved)
        var unsafe *tu = self.sc->tu
        if tu == &null {
            return
        }

        self._merge_in(tu)
        self._merge_out_of_line(tu)
        // After both merges: an in-class declaration's body may be an
        // out-of-line definition, and only the linked chain knows.
        self._check_inline_defined_in(tu)
    }

    /// # R(a): in-scope chains

    /// Walk every frozen table, then recurse into child scopes. Same
    /// pass-through rule as N(a)::_validate_context: in a TYPE body a
    /// VisibilityGroupDecl's members were keyed into THIS table already, so
    /// descending through the wrapper would judge every cell twice and emit
    /// each diagnostic twice.
    priv fn _merge_in(self, dc: unsafe *DeclContext) {
        if dc == &null {
            return
        }

        var type_body = dc->is_type_scope()

        if dc->dc_symbols != &null {
            var rows = cxx::std::vector<SymbolTable::Entry>()
            dc->dc_symbols->collect_entries(&rows)
            for var i: usize = 0; i < rows.size(); ++i {
                self._merge_cell(rows[i], type_body)
            }
        }

        for var i: usize = 0; i < dc->dc_decls.size(); ++i {
            var unsafe *d = *dc->dc_decls.get(i)
            if d == &null {
                continue
            }

            if type_body && isa<Declarations::VisibilityGroupDecl>(d) {
                continue
            }

            self._descend(d)
        }
    }

    /// See through the table-less wrapper decls the parser parks in
    /// dc_decls. Mirrors NameResolution::_descend.
    priv fn _descend(self, d: unsafe *Decl) {
        if d == &null {
            return
        }

        if isa<Declarations::VisibilityGroupDecl>(d) {
            var unsafe *g = cast<Declarations::VisibilityGroupDecl>(d)
            for var i: usize = 0; i < g->members.count; ++i {
                self._descend(g->members[i])
            }

            return
        }

        if isa<Declarations::EvalBlockDecl>(d) {
            var unsafe *b = cast<Declarations::EvalBlockDecl>(d)
            for var i: usize = 0; i < b->body.count; ++i {
                self._descend(b->body[i])
            }

            return
        }

        if isa<Declarations::FFIBlockDecl>(d) {
            var unsafe *b = cast<Declarations::FFIBlockDecl>(d)
            for var i: usize = 0; i < b->body.count; ++i {
                self._descend(b->body[i])
            }

            return
        }

        self._merge_in(NameLookup::context_of(d))
    }

    /// One name in one scope. Size 1 needs nothing. A cell that is not
    /// all-function was already judged by N(a) -- a mixed-kind cell is a
    /// redefinition it diagnosed, and re-judging here would double the
    /// error.
    priv fn _merge_cell(self, e: SymbolTable::Entry, in_type_body: bool) {
        if e.cell == &null {
            return
        }

        if e.cell->size() <= 1 {
            return
        }

        var group = self._fn_group(e.cell)
        if group.size() <= 1 {
            return
        }

        var name = e.name.describe(self.sc->ctx)
        // An operator cell's name describes as the bare `op`; say which.
        if group[0]->is_operator {
            name = "op " + OperatorFacts::symbol(group[0])
        }

        // O(n^2) over one cell. Overload sets are single digits; hashing a
        // vector of canonical pointers costs more than the scan.
        //
        // A poisoned link is skipped on both sides: once a pair has been
        // diagnosed, comparing the loser again produces a second error for
        // one mistake. The cost is that a third genuinely distinct conflict
        // can go unreported until the first is fixed, which is the right
        // trade -- one error per compile beats a cascade.
        for var i: usize = 0; i < group.size(); ++i {
            var unsafe *a = group[i]
            if a->is_poisoned() {
                continue
            }

            for var j: usize = i + 1; j < group.size(); ++j {
                var unsafe *b = group[j]
                if b->is_poisoned() {
                    continue
                }

                // Sibling branches of one `eval if` that waits for a type
                // fact (Compiler/Spec/Eval.md#deferred-conditions): the late fold keeps one of the two, so
                // they are neither one entity nor an overload pair to vet.
                if self.sc->eval_branches.exclusive(a, b) {
                    continue
                }

                // Two marked constructors are never one member (header);
                // ClassLifecycle reports a pair that may not coexist. Not an
                // overload to vet either: their `other` modes are unstamped,
                // so _check_cxx_collision would read two identical `@copy`
                // ctors as one C++ signature and poison the second before
                // that rule sees it.
                if a->transfer != Declarations::TransferKind::NotTransfer
                    && b->transfer != Declarations::TransferKind::NotTransfer {
                    continue
                }

                if !self._one_entity(a, b) {
                    // Two generic overloads equal up to their parameters'
                    // names, one of them guarded: one generic `where` group
                    // (Compiler/Spec/Generics.md#where-groups-on-generic-functions), never linked.
                    if (a->has_where() || b->has_where()) && self._alpha_same(a, b) {
                        continue
                    }

                    // Two entities to Kairo -- but maybe one to the C++ it
                    // emits, and maybe unchoosable at a Kairo call site.
                    // Asked here, where the pair is already known to be an
                    // overload and nowhere else pairs them.
                    self._check_move_overload(name, a, b)
                    if !b->is_poisoned() {
                        self._check_cxx_collision(name, a, b)
                    }

                    continue
                }

                // A guard on either side: two members of one `where` group
                // (header), or an `unsafe` one beside a guard, which
                // WhereGuardCheck reports. Never one entity.
                if a->has_where() || b->has_where() {
                    continue
                }

                // Two bodiless generic MEMBERS that differ only in their
                // bounds are two overloads (C++ orders them by constraint);
                // a member list may not repeat a member, so only a file-scope
                // declaration and its definition are one entity with them,
                // and _link holds that pair to one set of bounds.
                if in_type_body && !self._bounds_differ(a, b).empty() {
                    continue
                }

                self._link(name, a, b, in_type_body)
            }
        }

        self._stamp_where_groups(group)
    }

    /// Stamp `where_lead` on every member of each `where` group in one cell.
    /// A group is the safe, unpoisoned functions sharing a guarded
    /// function's signature; its lead is the first of them in the cell,
    /// which holds a scope's declarations in source order. Runs after the
    /// pairwise loop, so a second fallback is already poisoned (R029E) and
    /// stays out, and so is anything else that loop rejected.
    priv fn _stamp_where_groups(self,
                                const group: cxx::std::vector<unsafe *Declarations::FunctionDecl>) {
        for var i: usize = 0; i < group.size(); ++i {
            var unsafe *g = (group)[i]
            if !g->has_where() || g->is_unsafe() || g->is_poisoned() {
                continue
            }

            if g->where_lead != &null {
                continue
            }

            var lead: unsafe *Declarations::FunctionDecl = &null
            for var j: usize = 0; j < group.size(); ++j {
                var unsafe *m = (group)[j]
                if m->is_unsafe() || m->is_poisoned() {
                    continue
                }

                if m != g && !self._one_entity(m, g) && !self._alpha_same(m, g) {
                    continue
                }

                if lead == &null {
                    lead = m
                }

                m->where_lead = lead
            }
        }
    }

    /// The distinct FunctionDecls in a cell, or empty if the cell is not
    /// all-function.
    ///
    /// The identity guard is NOT a name dedup: a cell legitimately holds
    /// many different decls under one name, but the SAME *Decl twice is a
    /// walk bug upstream, and judging it here would report a function as a
    /// redefinition of itself. Same guard, same reason, as N(a).
    priv fn _fn_group(self,
                      cell: unsafe *OverloadCell) -> cxx::std::vector<unsafe *Declarations::FunctionDecl> {
        var out = cxx::std::vector<unsafe *Declarations::FunctionDecl>()
        for var i: usize = 0; i < cell->size(); ++i {
            var unsafe *d = cell->get(i)
            if d == &null {
                continue
            }

            if d->kind == DeclKind::RecoveryDecl { // parse recovery; diagnosed.
                continue
            }

            var unsafe *f = dyn_cast<Declarations::FunctionDecl>(d)
            if f == &null { // not all-fn: N(a) owns it.
                return cxx::std::vector<unsafe *Declarations::FunctionDecl>()
            }

            // A function specialization is its own entity and never links
            // into the primary's chain; pairing it is OverloadResolution's.
            if NameLookup::is_specialization(d) {
                continue
            }

            var seen = false
            for var j: usize = 0; j < out.size(); ++j {
                if out[j] == f {
                    seen = true
                    break
                }
            }

            if seen {
                continue
            }

            out.push_back(f)
        }

        return out
    }

    /// # R(b): out-of-line definitions

    /// `fn Class::method` never entered a table. N(a) resolved the
    /// qualifier and set semantic_dc to the owning type, then stopped:
    /// picking WHICH overload the definition defines needs signatures.
    ///
    /// A definition matching no in-class signature is an error HERE. N(a)'s
    /// check was weaker on purpose -- it only asked whether the NAME exists
    /// in the type, which passes for `fn Foo::bump(x: i32)` against an
    /// in-class `fn bump()`.
    priv fn _merge_out_of_line(self, tu: unsafe *TranslationUnit) {
        for var i: usize = 0; i < tu->out_of_line.size(); ++i {
            var unsafe *d = *tu->out_of_line.get(i)
            if d == &null {
                continue
            }

            if d->is_poisoned() { // N(a) diagnosed the qualifier.
                continue
            }

            var unsafe *f = dyn_cast<Declarations::FunctionDecl>(d)
            if f == &null {
                continue
            }

            if f->semantic_dc == &null { // unattached; N(a) diagnosed.
                continue
            }

            var unsafe *home = f->semantic_dc
            // Same lazy-fill hazard as N(a): a partly filled imported table
            // hands back a cell missing the overload this def defines.
            var unsafe *owner = home->owner_decl()
            if owner != &null {
                MemberLookup::ensure_filled(self.sc, owner)
            }

            // Cross-TU safe (see NameResolution::_attach_out_of_line): a raw
            // lookup_symbol with this TU's imm probes an imported record's
            // table with the wrong key and returns ANOTHER member's cell.
            // An operator's name is its op_token (NameResolution::
            // _attach_out_of_line): its empty name token is never spelled.
            var ml = MemberLookup(self.sc)
            var nm = if (f->is_operator) => ("op " + OperatorFacts::symbol(f))
                     else => self.sc->ctx->get_spelling(f->name)
            var unsafe *cell = ml.in_scope(
                home,
                self._member_key(f, home),
                if (f->is_operator) => ("") else => nm,
            )

            if cell == &null { // N(a) diagnosed the missing name.
                continue
            }

            var group = self._fn_group(cell)
            // Generic overloads differing only in their bounds share a
            // shape: the one whose bounds agree is the declaration this
            // defines. Any other same-shape one is the fallback, and _link
            // then reports the bounds it disagrees about.
            var hit: unsafe *Declarations::FunctionDecl = &null
            for var j: usize = 0; j < group.size(); ++j {
                if group[j] == f {
                    continue
                }

                if !self._same_signature(group[j], f) {
                    continue
                }

                if hit == &null {
                    hit = group[j]
                }

                if self._bounds_differ(group[j], f).empty() {
                    hit = group[j]
                    break
                }
            }

            if hit == &null {
                var hm = self._dc_name(home)
                self.sc->diag->report(
                    DiagID::R031E,
                    f->range.start,
                    f"out-of-line definition of '{nm}' does not match any declaration in '{hm}'",
                ).first(f->range)->emit()
                f->poison()
                continue
            }

            // An out-of-line def is in no table, so `cell` holds only the
            // IN-CLASS declaration: two out-of-line definitions of one
            // member never meet through it. They meet on the CHAIN, because
            // the first one linked into it -- so ask the chain before
            // linking this one in, or the second links as happily as the
            // first and nothing collides.
            //
            // Checked here rather than in _link because _link's both-bodies
            // branch compares `cur` against `prev` only, and `prev` is the
            // bodyless in-class declaration in both passes.
            var unsafe *prior = hit->definition()
            if prior != &null && prior != f {
                self.sc->diag->report(
                    DiagID::R029E,
                    f->range.start,
                    f"redefinition of '{nm}'",
                ).first(f->range)->note(
                    DiagCode(DiagID::R029N),
                    prior->range.start,
                    f"previous definition of '{nm}' is here",
                )->child_first(prior->range)->emit()
                f->poison()
                continue
            }

            // A default belongs to the in-class declaration: the class is the
            // interface, and an out-of-line definition may sit in a file some
            // callers never import, so a default here would apply to some calls
            // and not others. Cleared once diagnosed, so _check_defaults_once
            // does not report the same default a second time and CallLowering
            // never mints a thunk for it. f is NOT poisoned: it still links, so
            // its body resolves and uses of the method do not cascade.
            for var j: usize = 0; j < f->params.size(); ++j {
                var unsafe *p = f->params[j]
                if p == &null || p->default_val == &null {
                    continue
                }

                // An unnamed parameter's name is the empty Token, which
                // asserts when spelled.
                var what = if (p->unname) => (f"parameter {j}")
                           else => f"'{self.sc->ctx->get_spelling(p->name)}'"
                self.sc->diag->report(
                    DiagID::R056E,
                    p->default_val->range.start,
                    f"a default argument for {what} cannot be written on an out-of-line definition; write it on the in-class declaration",
                ).first(p->default_val->range)->note(
                    DiagCode(DiagID::R056N),
                    hit->range.start,
                    "the in-class declaration, where defaults go",
                )->child_first(hit->range)->emit()
                p->default_val = &null
            }

            // File-scope rule, deliberately: the out-of-line definition is
            // not part of the member-specification, so it may legally pair
            // with the in-class declaration.
            self._link(nm, hit, f, false)
        }
    }

    /// The DeclName an out-of-line def is keyed under inside \p home.
    ///
    /// FIXME(dedup): this rule exists in three places --
    /// ASTParse::_index_symbol_decl (which writes the table),
    /// NameResolution::_member_key (which probes it), and here. Three copies
    /// of a keying rule that must agree exactly is how the probe and the
    /// table silently diverge; hoist to NameLookup as a static.
    priv fn _member_key(self,
                        f:    unsafe *Declarations::FunctionDecl,
                        home: unsafe *DeclContext) -> DeclName {
        if f->is_operator {
            var k0 = TokenKind::TkUnknown
            var k1 = TokenKind::TkUnknown
            var k2 = TokenKind::TkUnknown
            if f->op_token.count > 0 {
                k0 = f->op_token[0].kind
            }

            if f->op_token.count > 1 {
                k1 = f->op_token[1].kind
            }

            // `op []=` is three tokens (DeclName::op_name_of).
            if f->op_token.count > 2 {
                k2 = f->op_token[2].kind
            }

            return DeclName::op_name_of(k0, k1, k2)
        }

        var im = self.sc->ctx->get_ident_imm(f->name)
        if im != u32::MAX && home->is_type_scope() {
            var unsafe *owner = home->owner_decl()
            // By spelling, each through its own context (NameResolution::
            // _member_key): an imported owner's imm is the header TU's.
            if owner != &null {
                var unsafe *oc = NameLookup::ctx_of(owner)
                if oc == &null {
                    oc = self.sc->ctx
                }

                if oc->get_spelling(decl_name_tok(owner)) == self.sc->ctx->get_spelling(
                    f->name,
                ) {
                    return DeclName::ctor()
                }
            }
        }

        return DeclName::ident(im)
    }

    /// True when \p d's names live outside this TU: another TU's decl, or
    /// (post-extraction) a decl clang owns. Mirrors
    /// TypeResolution::_foreign -- same question, same answer.
    priv fn _foreign(self, d: unsafe *Decl) -> bool {
        var unsafe *c = NameLookup::ctx_of(d)
        return c != &null && c != self.sc->ctx
    }

    /// # signature identity

    /// Two GENERIC functions whose signatures are one up to the names of
    /// their generic parameters (`fn <T> f(x: T, n: i32)` twice): each
    /// parameter's canonical, read over \p a's parameters (Substitution::
    /// bind_alpha), is \p a's, mode for mode. Only a `where` group asks
    /// (Compiler/Spec/Generics.md#where-groups-on-generic-functions); _same_signature keeps saying no to dependent pairs.
    priv fn _alpha_same(self,
                        a: unsafe *Declarations::FunctionDecl,
                        b: unsafe *Declarations::FunctionDecl) -> bool {
        if a->generic_params.size() == 0 || a->generic_params.size() != b->generic_params.size() {
            return false
        }

        if a->is_variadic != b->is_variadic || a->params.size() != b->params.size() {
            return false
        }

        if a->is_operator || b->is_operator {
            return false
        }

        var sub = Substitution(self.sc)
        if !sub.bind_alpha(a, unsafe (b as unsafe *Decl)) {
            return false
        }

        for var i: usize = 0; i < a->params.size(); ++i {
            var unsafe *pa = a->params[i]
            var unsafe *pb = b->params[i]
            if pa == &null || pb == &null || pa->type_ == &null || pb->type_ == &null {
                return false
            }

            if pa->is_self != pb->is_self || pa->mode != pb->mode {
                return false
            }

            var unsafe *ca = pa->type_->canonical
            var unsafe *cb = pb->type_->canonical
            if ca == &null || cb == &null {
                return false
            }

            var unsafe *sb = sub.substitute(cb)
            if sb == &null || canon_unqual(sb) != canon_unqual(ca) {
                return false
            }
        }

        return true
    }

    /// See the header for what is in and what is out, and why each
    /// exclusion is load-bearing.
    priv fn _same_signature(self,
                            a: unsafe *Declarations::FunctionDecl,
                            b: unsafe *Declarations::FunctionDecl) -> bool {
        // Generic arity first: `fn <T> f(x: T)` and `fn f(x: i32)` are not
        // one entity however their parameters canonicalize. Cheap, and it
        // short-circuits the dependent cases below.
        if a->generic_params.size() != b->generic_params.size() {
            return false
        }

        // The trailing pack is part of the function type. In practice the
        // pack parameter is IN params with a VariadicPackType, so the loop
        // below would catch it -- this is a cheap guard against a shape
        // where the flag is set without a corresponding param node.
        if a->is_variadic != b->is_variadic {
            return false
        }

        if a->params.size() != b->params.size() {
            return false
        }

        // Prefix and postfix `++`/`--` are one name cell and two entities.
        if OperatorFacts::is_postfix(a) != OperatorFacts::is_postfix(b) {
            return false
        }

        // `op as` is overloaded on its TARGET (casting.mdx, User-Defined
        // Conversions): `-> i32` and `-> i64` take the same `self` and are
        // two conversions, as `operator int` and `operator long` are two to
        // C++. The return type is the identity here and nowhere else; an
        // inferred one (expression body) is not known yet and keeps the
        // old answer.
        if self._is_conversion(a) && self._is_conversion(b) {
            var unsafe *ra = self._return_canonical(a)
            var unsafe *rb = self._return_canonical(b)
            if a->body_kind != Declarations::FnBodyKind::Expr
                && b->body_kind != Declarations::FnBodyKind::Expr
                && ra != &null
                && rb != &null
                && canon_unqual(ra) != canon_unqual(self._alpha_ret(a, b, rb)) {
                return false
            }
        }

        // Two declarations of one GENERIC function name their parameters
        // independently: each `T` is a GenericParamType owned by its own
        // decl, so the canonicals never meet by pointer. Read \p b's
        // signature over \p a's parameters first (Substitution::
        // bind_redecl); a pair whose parameter lists cannot be aligned
        // (kinds, value types, packs) is two overloads, as before.
        var gen = a->generic_params.size() > 0
        var sub = Substitution(self.sc)
        if gen && !sub.bind_redecl(a, b) {
            return false
        }

        // `@copy` beside `@move` (see header). Both marked only: an unmarked
        // decl of the same shape is either an out-of-line definition that did
        // not repeat the marker, which must still find its declaration, or an
        // unmarked transfer shape, which ClassLifecycle reports (SC110E).
        // Only R(b) reaches here with two marked decls; R(a) keeps them apart
        // before asking.
        if a->transfer != Declarations::TransferKind::NotTransfer
            && b->transfer != Declarations::TransferKind::NotTransfer
            && a->transfer != b->transfer {
            return false
        }

        var fa = self._foreign(a)
        var fb = self._foreign(b)
        // Const-ness participates in signature identity for FOREIGN decls
        // and `[]` only. Kairo source may not declare const
        // overloads otherwise (see header), so for any other Kairo-authored
        // decl a const mismatch is one entity with two contracts and
        // _check_modifiers_agree reports it. C++ has no such rule and the
        // STL leans on it hard -- begin()/begin() const, the operator[]
        // pairs -- so an extracted header's pairs are two entities and must
        // not merge; a Kairo `op []` is the same pair by design. By KIND
        // (is_subscript), whatever the return: a value `op []` returning
        // `[T;]` and `[const T;]` is a const pair as much as a place is.
        // `op []=` has no const pair: it is the place form whatever
        // the receiver, so it is held to the named-method rule. `op ->` has
        // the same exemption as `op []` (operator-overloading.mdx: the two
        // place operators may overload on receiver const-ness).
        var const_is_identity = fa
            || fb
            || OperatorFacts::is_subscript(a)
            || OperatorFacts::is_subscript(b)
            || OperatorFacts::is_arrow(a)
            || OperatorFacts::is_arrow(b)
        if const_is_identity {
            if a->is_const() != b->is_const() {
                return false
            }
        }

        // Exactly one side owned by clang: its reference kinds are read as
        // modes. Keyed on _cxx_owned, NOT _foreign: an out-of-line Kairo def
        // of a method imported into THIS TU is the case the mapping exists
        // for, and _foreign (another TU) is false for it.
        var oa    = self._cxx_owned(a)
        var ob    = self._cxx_owned(b)
        var mixed = oa != ob

        for var i: usize = 0; i < a->params.size(); ++i {
            var unsafe *pa = a->params[i]
            var unsafe *pb = b->params[i]
            if pa == &null || pb == &null {
                return false
            }

            if pa->type_ == &null || pb->type_ == &null {
                return false
            }

            var unsafe *ca = pa->type_->canonical
            var unsafe *cb = pb->type_->canonical
            if ca == &null || cb == &null { // dependent: M2's.
                return false
            }

            if gen {
                cb = sub.substitute(cb)
                if cb == &null {
                    return false
                }
            }

            if pa->is_self || pb->is_self {
                if pa->is_self != pb->is_self {
                    return false
                }

                // A receiver's cv is in its canonical -- a const method's self
                // is `const Record` -- and for a FOREIGN pair or a place
                // operator it is identity: begin() / begin() const are two
                // entities. Kairo permits no other const overloads (header),
                // so a Kairo-authored pair differing only there is one entity
                // with two contracts, and _check_modifiers_agree reports it.
                var strip = !const_is_identity
                if strip {
                    ca = canon_unqual(ca)
                    cb = canon_unqual(cb)
                }

                if ca != cb {
                    return false
                }

                continue
            }

            var sa = self._param_shape(pa, ca, oa, mixed)
            var sb = self._param_shape(pb, cb, ob, mixed)
            if sa.mode != sb.mode {
                return false
            }

            if sa.ty != sb.ty {
                return false
            }
        }

        return true
    }

    /// R(a)'s question: \p a and \p b are declarations of ONE function. The
    /// signature agrees, and for a generic pair at most one has a body: a
    /// declaration and its definition, the shape generic chains exist for.
    /// Two generic DEFINITIONS of one shape keep their old identity, two
    /// overloads -- a `where` group's members (WhereGuardCheck judges them
    /// together, fallbacks included) or a constraint-ordered pair differing
    /// only in bounds; an unconstrained repeat stays the ambiguity it was
    /// at each call. R(b) asks _same_signature directly: an out-of-line
    /// definition always pairs with a bodiless in-class declaration.
    priv fn _one_entity(self,
                        a: unsafe *Declarations::FunctionDecl,
                        b: unsafe *Declarations::FunctionDecl) -> bool {
        if !self._same_signature(a, b) {
            return false
        }

        if a->generic_params.size() > 0 && a->has_body() && b->has_body() {
            return false
        }

        return true
    }

    /// `op as`: the one operator whose return type is part of its identity.
    priv fn _is_conversion(self, f: unsafe *Declarations::FunctionDecl) -> bool {
        return f->is_operator && OperatorFacts::op_kind(f) == TokenKind::KwAs
    }

    /// \p t, a type written over \p b's generic parameters, read over \p a's
    /// (Substitution::bind_redecl): what to compare against a type of \p a.
    /// \p t unchanged for a non-generic pair, or one that cannot be aligned
    /// (the comparison then fails on its own); null if a component does not
    /// substitute.
    priv fn _alpha_ret(self,
                       a: unsafe *Declarations::FunctionDecl,
                       b: unsafe *Declarations::FunctionDecl,
                       t: unsafe *Type) -> unsafe *Type {
        if t == &null || a->generic_params.size() == 0 || !t->is_dependent() {
            return t
        }

        var sub = Substitution(self.sc)
        if !sub.bind_redecl(
            unsafe (a as unsafe *Decl),
            unsafe (b as unsafe *Decl),
        ) {
            return t
        }

        return sub.substitute(t)
    }

    /// Two declarations of one generic function, already found one entity
    /// by _same_signature, that disagree about a parameter's bounds
    /// (`<T impl Graph>` against `<T impl Tree>`). functions-declarations.mdx:
    /// a definition and its forward declaration "must match exactly". The
    /// inline bounds are in the requires clause by now (RequiresDesugar
    /// hoisted them in E, clearing the lists), so each parameter's bounds are
    /// that clause's `impl` / `derives` conjuncts on it, compared as a set of
    /// (kind, canonical) with \p cur's read over \p prev's parameters. Any
    /// other conjunct is an expression, not compared. Empty when they agree;
    /// otherwise the first disagreeing parameter's name.
    priv fn _bounds_differ(self,
                           prev: unsafe *Declarations::FunctionDecl,
                           cur:  unsafe *Declarations::FunctionDecl) -> string {
        var n = prev->generic_params.size()
        if n == 0 || n != cur->generic_params.size() {
            return ""
        }

        var sub = Substitution(self.sc)
        if !sub.bind_redecl(
            unsafe (prev as unsafe *Decl),
            unsafe (cur as unsafe *Decl),
        ) {
            return ""
        }

        var ca = cxx::std::vector<unsafe *ConstraintExpr>()
        var cb = cxx::std::vector<unsafe *ConstraintExpr>()
        self._conjuncts(prev->requires_clause, unsafe &ca)
        self._conjuncts(cur->requires_clause, unsafe &cb)
        for var i: usize = 0; i < n; ++i {
            var ta = cxx::std::vector<unsafe *Type>()
            var ka = cxx::std::vector<u8>()
            var tb = cxx::std::vector<unsafe *Type>()
            var kb = cxx::std::vector<u8>()
            if !self._param_bounds(
                &ca,
                prev->generic_params[i],
                &null,
                &ta,
                &ka,
            ) {
                continue
            }

            if !self._param_bounds(
                &cb,
                cur->generic_params[i],
                unsafe &sub,
                &tb,
                &kb,
            ) {
                continue
            }

            if !self._bounds_within(ta, ka, tb, &kb) || !self._bounds_within(tb, kb, ta, &ka) {
                return self.sc->ctx->get_spelling(cur->generic_params[i]->name)
            }
        }

        return ""
    }

    /// Every `impl` / `derives` conjunct of \p e (an `&&` / `and` tree), in
    /// clause order.
    priv fn _conjuncts(self,
                       e:   unsafe *Expr,
                       out: unsafe *cxx::std::vector<unsafe *ConstraintExpr>) {
        if e == &null {
            return
        }

        if e->kind == ExprKind::BinaryOperatorExpr {
            var unsafe *b = cast<BinaryOperatorExpr>(e)
            if b->op_token.kind == TokenKind::OpAmpAmp || b->op_token.kind == TokenKind::KwAnd {
                self._conjuncts(b->lhs, out)
                self._conjuncts(b->rhs, out)
            }

            return
        }

        if e->kind == ExprKind::ConstraintExpr {
            out->push_back(cast<ConstraintExpr>(e))
        }
    }

    /// The bounds the conjuncts \p cs put on \p gp: each one's canonical
    /// (read through \p sub when given) into \p tys, and whether it is a
    /// `derives` bound into \p kinds. False when one did not resolve: it was
    /// diagnosed, and comparing around it would only add a second error.
    priv fn _param_bounds(self,
                          @inout cs:    cxx::std::vector<unsafe *ConstraintExpr>,
                          gp:           unsafe *Declarations::GenericParamDecl,
                          sub:          unsafe *Substitution,
                          @inout tys:   cxx::std::vector<unsafe *Type>,
                          @inout kinds: cxx::std::vector<u8>) -> bool {
        if gp == &null {
            return false
        }

        for var i: usize = 0; i < cs.size(); ++i {
            var unsafe *c  = (cs)[i]
            var unsafe *id = dyn_cast<NamedIdentExpr>(c->lhs)
            if id == &null || id->resolved_decl != gp {
                continue
            }

            if c->rhs == &null || c->rhs->canonical == &null {
                return false
            }

            var unsafe *t = c->rhs->canonical
            if sub != &null {
                t = sub->substitute(t)
                if t == &null {
                    return false
                }
            }

            tys.push_back(canon_unqual(t))
            kinds.push_back(c->is_derives() as u8)
        }

        return true
    }

    /// Every bound of (\p xt, \p xk) is one of (\p yt, \p yk).
    priv fn _bounds_within(self,
                           const xt:  cxx::std::vector<unsafe *Type>,
                           const xk:  cxx::std::vector<u8>,
                           const yt:  cxx::std::vector<unsafe *Type>,
                           @inout yk: cxx::std::vector<u8>) -> bool {
        for var i: usize = 0; i < xt.size(); ++i {
            var hit = false
            for var j: usize = 0; j < yt.size(); ++j {
                if (yt)[j] == (xt)[i] && (yk)[j] != 0 == ((xk)[i] != 0) {
                    hit = true
                    break
                }
            }

            if !hit {
                return false
            }
        }

        return true
    }

    /// One entity, one set of bounds (see _bounds_differ).
    priv fn _check_bounds_agree(self,
                                const name: string,
                                prev:       unsafe *Declarations::FunctionDecl,
                                cur:        unsafe *Declarations::FunctionDecl) {
        var p = self._bounds_differ(prev, cur)
        if p.empty() {
            return
        }

        self.sc->diag->report(
            DiagID::R061E,
            cur->range.start,
            f"'{name}' redeclared with different bounds on generic parameter '{p}'; " + "a declaration and its definition must name the same bounds",
        ).first(cur->range)->note(
            DiagCode(DiagID::R061N),
            prev->range.start,
            previously_declared_here(),
        )->child_first(prev->range)->emit()
        cur->poison()
    }

    /// True when clang owns \p d: an `ffi` import, from this TU or another
    /// (FFILinkage::is_imported -- it carries a USR). Distinct from _foreign,
    /// which asks only "another TU" and is false for a header imported here.
    priv fn _cxx_owned(self, d: unsafe *Declarations::FunctionDecl) -> bool {
        return d->is_imported()
    }

    /// The (mode, type) a value parameter is judged on. Top-level cv is
    /// stripped as in C++ ([dcl.fct]/5). A foreign decl's mode is always
    /// Value; against a KAIRO decl its C++ reference kind is read as the
    /// mode it spells, so `void f(int&)` in a header and `fn S::f(self,
    /// @inout x: i32)` are one entity. Foreign-vs-foreign keeps the
    /// reference in the type: `b(int&)` / `b(const int&)` stay two.
    priv fn _param_shape(self,
                         p:       unsafe *Declarations::ParamDecl,
                         c:       unsafe *Type,
                         foreign: bool,
                         mixed:   bool) -> SigShape {
        var out = SigShape()
        out.mode = p->mode
        out.ty   = canon_unqual(c)
        if !(foreign && mixed) {
            return out
        }

        if isa<CXXLValueRefType>(c) {
            var unsafe *r = cast<CXXLValueRefType>(c)->referee
            out.ty = canon_unqual(r)
            out.mode = if (canon_has_const(r)) => (ParamMode::Value) else => ParamMode::Inout
            return out
        }

        if isa<CXXRValueRefType>(c) {
            out.ty   = canon_unqual(cast<CXXRValueRefType>(c)->referee)
            out.mode = ParamMode::Move
            return out
        }

        return out
    }

    /// Two overloads whose ONLY difference is by-value vs `@move` on some
    /// parameter. C++ tells `f(T)` from `f(T&&)`; a Kairo call cannot --
    /// `@move` has no marker, so `f(x)` is the same text for both and
    /// nothing can choose. Error at the second declaration. Kairo-authored
    /// pairs only: an imported pair is clang's and legal there.
    ///
    /// A pair that ALSO differs in `@inout`-ness at some position is a
    /// genuine overload: `f(&a, b)` and `f(a, b)` choose.
    priv fn _check_move_overload(self,
                                 const name: string,
                                 a:          unsafe *Declarations::FunctionDecl,
                                 b:          unsafe *Declarations::FunctionDecl) {
        if self._foreign(a) || self._foreign(b) {
            return
        }

        if a->generic_params.size() != b->generic_params.size() {
            return
        }

        if a->is_variadic != b->is_variadic {
            return
        }

        if a->params.size() != b->params.size() {
            return
        }

        var differs       = false
        var pos:    usize = 0
        for var i: usize = 0; i < a->params.size(); ++i {
            var unsafe *pa = a->params[i]
            var unsafe *pb = b->params[i]
            if pa == &null || pb == &null {
                return
            }

            if pa->is_self != pb->is_self {
                return
            }

            var unsafe *ca = self._param_canonical(pa)
            var unsafe *cb = self._param_canonical(pb)
            if ca == &null || cb == &null {
                return
            }

            if ca != cb {
                return
            }

            if pa->is_self {
                continue
            }

            var ia = pa->mode == ParamMode::Inout
            var ib = pb->mode == ParamMode::Inout
            if ia != ib { // distinguishable at the call.
                return
            }

            if pa->mode != pb->mode {
                differs = true
                pos     = i
            }
        }

        if !differs {
            return
        }

        var pn = self.sc->ctx->get_spelling(b->params[pos]->name)
        // Adjacent f-strings do not concatenate: explicit `+`.
        self.sc->diag->report(
            DiagID::R054E,
            b->range.start,
            f"'{name}' cannot be overloaded on {LangAttrs::quoted(LangAttrs::param_move())}: a {LangAttrs::quoted(LangAttrs::param_move())} argument is written " + "with no marker, so a call could not choose between these declarations",
        ).first(b->range)->note(
            DiagCode(DiagID::R054N),
            a->range.start,
            f"the other declaration is here; they differ only in the passing mode of '{pn}'",
        )->child_first(a->range)->emit()
        b->poison()
    }

    /// # C++ signature collision

    /// Two overloads Kairo tells apart but the emitted C++ cannot: every
    /// parameter lowers to the same C++ type, so the generated file would
    /// declare one C++ function twice -- a redefinition clang reports
    /// against code nobody wrote. Reported here, against the source, at the
    /// second decl.
    ///
    /// The lowering compared is the BUILTIN table only: `usize` and
    /// `isize` are distinct Kairo types that lower to `size_t` / `ptrdiff_t`,
    /// which are the fixed-width integers of the target's pointer width.
    /// Records, pointers and references compare by canonical pointer, as
    /// signature identity does; dependent signatures are M2's, as above.
    ///
    /// Kairo-authored pairs only: two imported decls are distinct C++
    /// already (clang said so), and an imported decl is never emitted.
    priv fn _check_cxx_collision(self,
                                 const name: string,
                                 a:          unsafe *Declarations::FunctionDecl,
                                 b:          unsafe *Declarations::FunctionDecl) {
        if self._foreign(a) || self._foreign(b) {
            return
        }

        if a->generic_params.size() != b->generic_params.size() {
            return
        }

        if a->is_variadic != b->is_variadic {
            return
        }

        if a->params.size() != b->params.size() {
            return
        }

        // Postfix `++`/`--` gets C++'s `int` dummy, prefix does not: two
        // different C++ parameter lists however the Kairo ones compare.
        if OperatorFacts::is_postfix(a) != OperatorFacts::is_postfix(b) {
            return
        }

        // Two `op as`: `operator int()` and `operator long()` -- the target
        // type IS the C++ name, so they never share a signature.
        if self._is_conversion(a) && self._is_conversion(b) {
            return
        }

        // `@copy` beside `@move`: `const X&` / `X&` against `X&&` in C++,
        // though both `other`s still read as by-value here (the stamp that
        // says so comes after this pass). Two marked ctors never get here
        // (_merge_cell); this keeps a marked one apart from an unmarked one.
        if a->transfer != b->transfer {
            return
        }

        // A mode difference is a C++ difference (`T` vs `T&` vs `T&&`): no
        // collision possible, whatever the types lower to.
        for var i: usize = 0; i < a->params.size(); ++i {
            if a->params[i] != &null
                && b->params[i] != &null
                && a->params[i]->mode != b->params[i]->mode {
                return
            }
        }

        var pw = self._pointer_width()
        for var i: usize = 0; i < a->params.size(); ++i {
            var unsafe *ca = self._param_canonical(a->params[i])
            var unsafe *cb = self._param_canonical(b->params[i])
            if ca == &null || cb == &null {
                return
            }

            if !self._cxx_same(ca, cb, pw) {
                return
            }
        }

        var ka = self._kairo_sig(name, a)
        var kb = self._kairo_sig(name, b)
        var cx = self._cxx_sig(name, a, pw)
        self.sc->diag->report(
            DiagID::R052E,
            b->range.start,
            f"'{ka}' and '{kb}' have the same C++ signature '{cx}' on this target",
        ).first(b->range)->note(
            DiagCode(DiagID::R052N),
            a->range.start,
            f"'{ka}' declared here",
        )->child_first(a->range)->emit()
        b->poison()
    }

    priv fn _param_canonical(self, p: unsafe *Declarations::ParamDecl) -> unsafe *Type {
        if p == &null || p->type_ == &null {
            return &null
        }

        var unsafe *c = p->type_->canonical
        return if (p->is_self) => (c) else => canon_unqual(c)
    }

    /// The canonical \p t is identical to once lowered: `usize` / `isize`
    /// become the fixed-width integer of the pointer width, anything else
    /// is itself. Only where the target says size_t / ptrdiff_t IS that
    /// integer (target.usize_is_fixed): `usize` emits as `decltype(sizeof(0))`,
    /// and on Darwin that is `unsigned long` beside a `long long` u64 -- two
    /// C++ types, two overloads, no collision.
    priv fn _cxx_lowered(self, t: unsafe *Type, pw: usize) -> unsafe *Type {
        if !isa<BuiltinType>(t) {
            return t
        }

        var k = cast<BuiltinType>(t)->builtin
        if k != BuiltinKind::USize && k != BuiltinKind::ISize {
            return t
        }

        var sgn = k == BuiltinKind::ISize
        if !self._size_is_fixed(sgn) {
            return t
        }

        var fixed = BuiltinKind::COUNT
        if pw == 16 {
            fixed = if (sgn) => (BuiltinKind::I16) else => BuiltinKind::U16
        }

        if pw == 32 {
            fixed = if (sgn) => (BuiltinKind::I32) else => BuiltinKind::U32
        }

        if pw == 64 {
            fixed = if (sgn) => (BuiltinKind::I64) else => BuiltinKind::U64
        }

        if fixed == BuiltinKind::COUNT {
            return t
        }

        var unsafe *ft = self.sc->builtin(fixed)
        return if (ft != &null) => (ft) else => t
    }

    /// \p a and \p b are one C++ type once lowered: _cxx_lowered's
    /// integers, and pointers that differ only in safety. C++ spells `*T`
    /// and `unsafe *T` alike as `T*` (safety is a Kairo-only fact), so
    /// `f(p: *B)` beside `f(p: unsafe *B)` is one C++ function twice.
    /// The pointee is compared the same way, level by level, with
    /// its qualifiers: `*const B` is `const B*`, a different type. A `*T?`
    /// is a Nullable in C++, never a `T*`, so it stays apart.
    priv fn _cxx_same(self, a: unsafe *Type, b: unsafe *Type, pw: usize) -> bool {
        if a == &null || b == &null {
            return false
        }

        if self._cxx_lowered(a, pw) == self._cxx_lowered(b, pw) {
            return true
        }

        if canon_quals(a) != canon_quals(b) {
            return false
        }

        var unsafe *pa = dyn_cast<PointerType>(canon_unqual(a))
        var unsafe *pb = dyn_cast<PointerType>(canon_unqual(b))
        if pa == &null || pb == &null || pa->pointee == &null || pb->pointee == &null {
            return false
        }

        var unsafe *ea = if (pa->pointee->canonical != &null) => (pa->pointee->canonical)
                         else => pa->pointee
        var unsafe *eb = if (pb->pointee->canonical != &null) => (pb->pointee->canonical)
                         else => pb->pointee
        return self._cxx_same(ea, eb, pw)
    }

    /// target.usize_is_fixed / isize_is_fixed. A hand-built invocation never
    /// filled them and keeps the default (true), matching _pointer_width's
    /// "treat unfilled as the 64-bit host".
    priv fn _size_is_fixed(self, sgn: bool) -> bool {
        var unsafe *ci = self.sc->ctx->ci
        if ci == &null {
            return true
        }

        return if (sgn) => (ci->target.isize_is_fixed) else => ci->target.usize_is_fixed
    }

    /// target.pointer_width, never a literal. 0 (a hand-built invocation)
    /// reads as 64: the fallback SemaContext gives the store, so the two
    /// cannot disagree about what `usize` is.
    priv fn _pointer_width(self) -> usize {
        var unsafe *ci = self.sc->ctx->ci
        if ci == &null || ci->target.pointer_width == 0 {
            return 64
        }

        return ci->target.pointer_width
    }

    /// `f(u64, i32)`: value parameters only, the receiver is implied.
    priv fn _kairo_sig(self, const name: string, f: unsafe *Declarations::FunctionDecl) -> string {
        var tu    = TypeUtil(self.sc)
        var s     = name + "("
        var first = true
        for var i: usize = 0; i < f->params.size(); ++i {
            var unsafe *p = f->params[i]
            if p == &null || p->is_self {
                continue
            }

            if !first {
                s += ", "
            }

            first = false
            s += tu.str(self._param_canonical(p))
        }

        return s + ")"
    }

    /// The same, as the lowering spells it: EmitIR's builtin spellings.
    priv fn _cxx_sig(self,
                     const name: string,
                     f:          unsafe *Declarations::FunctionDecl,
                     pw:         usize) -> string {
        var tu    = TypeUtil(self.sc)
        var s     = name + "("
        var first = true
        for var i: usize = 0; i < f->params.size(); ++i {
            var unsafe *p = f->params[i]
            if p == &null || p->is_self {
                continue
            }

            if !first {
                s += ", "
            }

            first = false
            var unsafe *c = self._cxx_lowered(self._param_canonical(p), pw)
            if isa<BuiltinType>(c) {
                s += builtin_info(cast<BuiltinType>(c)->builtin)->cxx
            } else {
                s += tu.str(c)
            }
        }

        return s + ")"
    }

    /// # agreement across a linked chain

    /// Return type is not in the signature, which is exactly why it must be
    /// checked here: two decls that matched on parameters are ONE entity,
    /// so a differing return type is a conflict, not an overload.
    priv fn _check_return_agrees(self,
                                 const name: string,
                                 prev:       unsafe *Declarations::FunctionDecl,
                                 cur:        unsafe *Declarations::FunctionDecl) {
        // An expr-bodied function's return type is INFERRED and does not
        // exist until TypeInference, which runs after R. Its null means
        // "not yet knowable", not "void", so there is nothing to compare.
        if prev->body_kind == Declarations::FnBodyKind::Expr {
            return
        }

        if cur->body_kind == Declarations::FnBodyKind::Expr {
            return
        }

        // FIXME(noreturn): `-> !` may be encoded as is_noreturn with a null
        // return_type, in which case it canonicalizes to void here and a
        // `-> !` / `-> void` pair merges silently. _check_modifiers_agree
        // catches it as a modifier disagreement; if `!` becomes
        // a real return type, delete that half and let this one report it. See Tests/Sema/RedeclMerge/kairo-only/.
        var unsafe *rp = self._return_canonical(prev)
        var unsafe *rc = self._return_canonical(cur)
        if rp == &null || rc == &null { // dependent or diagnosed.
            return
        }

        if rp == rc {
            return
        }

        // `-> *T` defining an imported member declared `T&` (CXX-REF): C++
        // keeps its reference, the Kairo body returns the pointer.
        if prev->is_imported() && OperatorFacts::ptr_implements_lref(rc, rp) {
            cur->cxx_ref_return = true
            return
        }

        // `-> T` on both links of a generic chain: two decls' own `T`s.
        if self._alpha_ret(prev, cur, rc) == rp {
            return
        }

        var at = if (cur->return_type != &null) => (cur->return_type->range) else => cur->range
        var prev_at = if (prev->return_type != &null) => (prev->return_type->range)
                      else => prev->range

        // A definition of an imported function where either side is a C++
        // reference: the one spelling that matches is the fix-it.
        if prev->is_imported() && (Self::_is_cxx_ref(rp) || Self::_is_cxx_ref(rc)) {
            var tu   = TypeUtil(self.sc)
            var want = tu.return_fix(cur->return_type, rp)
            var have = tu.return_str(rc)
            if cur->return_type != &null && cur->return_type->range.is_valid() {
                have = self.sc->ctx->get_spelling(cur->return_type->range)
            }

            var b = self.sc->diag->report(
                DiagID::SC294E,
                at.start,
                f"'{name}' returns '{have}', but its C++ declaration returns '{want}'",
            )

            b.first(at)
            if cur->return_type != &null {
                b.fix(at, want, f"return '{want}', as the C++ declaration does")
            }

            // An imported declaration's return type has no range of its own.
            var decl_at = if (prev_at.is_valid()) => (prev_at) else => prev->range
            b.note(
                DiagCode(DiagID::SC294N),
                decl_at.start,
                "the C++ declaration, whose return it must match",
            )

            b.child_first(decl_at)
            b.emit()
            cur->poison()
            return
        }

        self.sc->diag->report(
            DiagID::R037E,
            at.start,
            f"'{name}' declared with a different return type; the parameter types "
            "are identical, so this is a redeclaration, not an overload",
        ).first(at)->note(
            DiagCode(DiagID::R037N),
            prev_at.start,
            "previously declared with this return type",
        )->child_first(prev_at)->emit()
        cur->poison()
    }

    /// The canonical a non-expr-bodied function returns: the declared
    /// type's canonical, or void when the return type was omitted, so an
    /// omitted `-> void` and an explicit one compare equal.
    priv static fn _is_cxx_ref(c: unsafe *Type) -> bool {
        var unsafe *u = canon_unqual(c)
        return u != &null && (isa<CXXLValueRefType>(u) || isa<CXXRValueRefType>(u))
    }

    priv fn _return_canonical(self, f: unsafe *Declarations::FunctionDecl) -> unsafe *Type {
        if f->return_type == &null {
            return self.sc->builtin(BuiltinKind::Void)
        }

        return f->return_type->canonical
    }

    /// Each parameter's default may be SPECIFIED exactly once across the
    /// whole chain. NOT a comparison of the expressions: two textually
    /// identical defaults are still an error, and comparing arbitrary
    /// default expressions for equivalence is not decidable anyway. A later
    /// declaration MAY add a default to a parameter that lacks one, which is
    /// why this tests for BOTH being present rather than for disagreement.
    ///
    /// Defaults ACCUMULATE left to right across a chain, so the check must
    /// reach every earlier link, not just the immediately previous one.
    /// _merge_cell's pairwise loop already compares every pair, which is
    /// what makes that work.
    ///
    /// Arity already matches (the caller only reaches here when
    /// _same_signature returned true), so the parallel index is safe.
    priv fn _check_defaults_once(self,
                                 prev: unsafe *Declarations::FunctionDecl,
                                 cur:  unsafe *Declarations::FunctionDecl) {
        for var i: usize = 0; i < cur->params.size(); ++i {
            var unsafe *pp = prev->params[i]
            var unsafe *pc = cur->params[i]
            if pp == &null || pc == &null {
                continue
            }

            if pp->default_val == &null || pc->default_val == &null {
                continue
            }

            var pn = self.sc->ctx->get_spelling(pc->name)
            self.sc->diag->report(
                DiagID::R040E,
                pc->default_val->range.start,
                f"redefinition of default argument for '{pn}'",
            ).first(pc->default_val->range)->note(
                DiagCode(DiagID::R040N),
                pp->default_val->range.start,
                "previous default argument is here",
            )->child_first(pp->default_val->range)->emit()
            cur->poison()
        }
    }

    /// One entity, one linkage. A chain that disagrees would emit two
    /// different symbols for one function, which the linker resolves by
    /// accident or not at all.
    priv fn _check_linkage_agrees(self,
                                  const name: string,
                                  prev:       unsafe *Declarations::FunctionDecl,
                                  cur:        unsafe *Declarations::FunctionDecl) {
        if prev->abi == cur->abi {
            return
        }

        self.sc->diag->report(
            DiagID::R038E,
            cur->range.start,
            f"'{name}' redeclared with a different ABI",
        ).first(cur->range)->note(
            DiagCode(DiagID::R038N),
            prev->range.start,
            previously_declared_here(),
        )->child_first(prev->range)->emit()
        cur->poison()
    }

    /// Modifiers that change what the function MEANS must agree across a
    /// chain. `final` is excluded: it does not change the contract.
    ///
    /// `inline` is in, though C++ permits adding it on a later declaration,
    /// because in Kairo it decides where the body is EMITTED: an importer
    /// reads it off the in-class declaration (the member list), the home TU
    /// off the definition. Disagreeing, the importer skips the body while
    /// the home object holds a definition only if it happened to use it --
    /// an undefined reference, or not, by accident. Only Kairo links are
    /// held to it; a C++ declaration's inline is clang's business.
    ///
    /// `const` is here rather than in _same_signature because Kairo does
    /// not permit const overloading -- see the header. Two links
    /// disagreeing about const are one entity with two contracts. An
    /// `[]` or `->` pair never reaches here: const is its identity,
    /// keyed on operator kind (is_subscript, is_arrow), place or value alike.
    ///
    /// A `where` guard never reaches here: a guarded pair is a dispatch
    /// group, not a chain (_merge_cell), and WhereGuardCheck holds its
    /// members to the agreement this function holds a chain to.
    priv fn _check_modifiers_agree(self,
                                   const name: string,
                                   prev:       unsafe *Declarations::FunctionDecl,
                                   cur:        unsafe *Declarations::FunctionDecl) {
        var what = ""
        if !self._foreign(prev) && !self._foreign(cur) && prev->is_const() != cur->is_const() {
            what = "const"
        } else if prev->is_unsafe() != cur->is_unsafe() {
            what = "unsafe"
        } else if prev->is_async() != cur->is_async() {
            what = "async"
        } else if prev->is_eval() != cur->is_eval() {
            what = "eval"
        } else if prev->is_panic() != cur->is_panic() {
            what = "panic"
        } else if prev->is_noreturn != cur->is_noreturn {
            what = "noreturn"
        } else if !self._cxx_owned(prev)
            && !self._cxx_owned(cur)
            && prev->is_inline() != cur->is_inline() {
            what = "inline"
        }

        if what.size() == 0 {
            return
        }

        self.sc->diag->report(
            DiagID::R039E,
            cur->range.start,
            f"'{name}' redeclared with a different '{what}' qualifier; the "
            "parameter types are identical, so this is one function",
        ).first(cur->range)->note(
            DiagCode(DiagID::R039N),
            prev->range.start,
            previously_declared_here(),
        )->child_first(prev->range)->emit()
        cur->poison()
    }

    /// The calling convention is part of what a call through any of the
    /// chain's declarations does: a caller that saw one declaration saves
    /// the registers ITS convention says the callee clobbers, so a chain
    /// that disagrees miscompiles every call made through the other one.
    /// Not part of _same_signature: a convention alone never makes two
    /// declarations distinct overloads (C++ cannot overload on it either),
    /// so a same-signature pair that differs only here lands in this check.
    priv fn _check_conv_agrees(self,
                               const name: string,
                               prev:       unsafe *Declarations::FunctionDecl,
                               cur:        unsafe *Declarations::FunctionDecl) {
        if prev->call_conv == cur->call_conv {
            return
        }

        var now    = self._conv_phrase(cur->call_conv)
        var before = self._conv_phrase(prev->call_conv)
        self.sc->diag->report(
            DiagID::R039E,
            cur->range.start,
            f"'{name}' redeclared with {now}; the " + "parameter types are identical, so this is one function",
        ).first(cur->range)->note(
            DiagCode(DiagID::R039N),
            prev->range.start,
            f"previously declared here with {before}",
        )->child_first(prev->range)->emit()
        cur->poison()
    }

    /// `'@preserve_most'`, or the default convention, for a message.
    priv fn _conv_phrase(self, cc: u8) -> string {
        if cc == 0 {
            return "the default calling convention"
        }

        return "'@" + LangAttrs::call_conv_name(cc) + "'"
    }

    /// # linking

    /// Two same-signature declarations of one function: link them, make
    /// them agree, and apply the scope's repeat rule.
    ///
    /// At FILE scope the agreement checks run BEFORE the repeat rule and
    /// none of them return early, because they are independent facts about
    /// the same pair: a chain with both a return-type conflict and two
    /// bodies should report both. Putting them after would skip them in
    /// exactly the case with the most to say.
    ///
    /// In a TYPE BODY the member rule runs FIRST and returns, because it
    /// subsumes them: any same-signature repeat in a member list is already
    /// an error, so also reporting that the two disagree about const or
    /// return type is a second diagnostic for one mistake with the same fix.
    ///
    /// A diagnosed loser is POISONED but keeps its `is_this_definition`
    /// flag, matching clang (Sema marks a redefinition invalid via
    /// setInvalidDecl and never clears isThisDeclarationADefinition). The
    /// chain therefore holds two flagged links after a redefinition, and
    /// `definition()` stays unambiguous only because the ring is in
    /// insertion order and returns the earlier one. Read a chain through
    /// `definition()`; a consumer that tests `is_this_definition` directly
    /// must check `is_poisoned()` first, exactly as clang's CodeGen skips
    /// invalid decls.
    ///
    /// Idempotent by construction: linking is skipped when the two already
    /// share a chain, and retarget_canonical recomputes the same target on
    /// a second run (LSP contract, same as N(a)::_link_group).
    priv fn _link(self,
                  const name:   string,
                  prev:         unsafe *Declarations::FunctionDecl,
                  cur:          unsafe *Declarations::FunctionDecl,
                  in_type_body: bool) {
        if cur->canonical_decl() != prev->canonical_decl() {
            cur->set_prev(prev)
        }

        // [class.mem]: a member-specification may not declare the same
        // member twice, with or without a body. The out-of-line definition
        // is the only legal way to split declaration from definition, and
        // it is not in this table.
        //
        // This SUBSUMES the agreement checks below: any same-signature
        // repeat in a member list is already an error, so also reporting
        // that the two disagree about const or return type is a second
        // diagnostic for one mistake, with the same fix.
        if in_type_body {
            self.sc->diag->report(
                DiagID::R041E,
                cur->range.start,
                f"class member '{name}' cannot be redeclared",
            ).first(cur->range)->note(
                DiagCode(DiagID::R041N),
                prev->range.start,
                "previous declaration is here",
            )->child_first(prev->range)->emit()
            cur->poison()
            return
        }

        self._check_return_agrees(name, prev, cur)
        self._check_bounds_agree(name, prev, cur)
        self._check_defaults_once(prev, cur)
        self._check_linkage_agrees(name, prev, cur)
        self._check_modifiers_agree(name, prev, cur)
        self._check_conv_agrees(name, prev, cur)

        if prev->has_body() && cur->has_body() {
            self.sc->diag->report(
                DiagID::R029E,
                cur->range.start,
                f"redefinition of '{name}'",
            ).first(cur->range)->note(
                DiagCode(DiagID::R029N),
                prev->range.start,
                f"previous definition of '{name}' is here",
            )->child_first(prev->range)->emit()
            cur->poison()
            return
        }

        // canonical = the definition if the chain has one, else the first
        // link (which retarget_canonical leaves as-is via first_decl).
        var unsafe *def = prev->definition()
        prev->retarget_canonical(
            if (def != &null) => (def) else => prev->first_decl(),
        )
    }

    /// # inline needs a body

    /// `inline` puts the body in the interface: every TU that declares the
    /// function defines it. One with no definition on its chain is declared
    /// `inline` in C++ with a definition nowhere, so every call is an
    /// undefined reference. Run per TU after the merges, so the definition
    /// has to be in the declaring file -- which it must anyway: an importer
    /// of that file is exactly who compiles the body, and it never sees a
    /// definition written in some other file that imports the class.
    ///
    /// `= default` / `= delete` / `= virtual` are definitions as far as C++
    /// is concerned (or need none), so only a missing body is reported.
    priv fn _check_inline_defined_in(self, dc: unsafe *DeclContext) {
        if dc == &null {
            return
        }

        for var i: usize = 0; i < dc->dc_decls.size(); ++i {
            self._check_inline_defined(*dc->dc_decls.get(i))
        }
    }

    priv fn _check_inline_defined(self, d: unsafe *Decl) {
        if d == &null || d->is_poisoned() {
            return
        }

        if isa<Declarations::VisibilityGroupDecl>(d) {
            var unsafe *g = cast<Declarations::VisibilityGroupDecl>(d)
            for var i: usize = 0; i < g->members.count; ++i {
                self._check_inline_defined(g->members[i])
            }

            return
        }

        if isa<Declarations::ModuleDecl>(d) {
            self._check_inline_defined_in(
                unsafe (cast<Declarations::ModuleDecl>(d) as unsafe *DeclContext),
            )

            return
        }

        if isa<Declarations::ExtensionDecl>(d) {
            var unsafe *x = cast<Declarations::ExtensionDecl>(d)
            for var i: usize = 0; i < x->methods.size(); ++i {
                self._check_inline_fn(x->methods[i])
            }

            return
        }

        if isa<Declarations::ClassDecl>(d)
            || isa<Declarations::StructDecl>(d)
            || isa<Declarations::UnionDecl>(d) {
            var methods: unsafe *FrozenList<unsafe *Declarations::FunctionDecl> = &null
            if isa<Declarations::ClassDecl>(d) {
                methods = unsafe &cast<Declarations::ClassDecl>(d)->methods
            } else if isa<Declarations::StructDecl>(d) {
                methods = unsafe &cast<Declarations::StructDecl>(d)->methods
            } else {
                methods = unsafe &cast<Declarations::UnionDecl>(d)->methods
            }

            for var i: usize = 0; i < methods->size(); ++i {
                self._check_inline_fn((*methods)[i])
            }

            // Nested records only: the methods were just checked off the list.
            var unsafe *inner = NameLookup::context_of(d)
            if inner == &null {
                return
            }

            for var i: usize = 0; i < inner->dc_decls.size(); ++i {
                var unsafe *nd = *inner->dc_decls.get(i)
                if nd == &null {
                    continue
                }

                if isa<Declarations::FunctionDecl>(nd) {
                    continue
                }

                self._check_inline_defined(nd)
            }

            return
        }

        var unsafe *f = dyn_cast<Declarations::FunctionDecl>(d)
        if f != &null {
            self._check_inline_fn(f)
        }
    }

    priv fn _check_inline_fn(self, f: unsafe *Declarations::FunctionDecl) {
        if f == &null || f->is_poisoned() {
            return
        }

        if !f->is_inline() || f->has_body() {
            return
        }

        if self._cxx_owned(f) { // the body is on clang's side.
            return
        }

        // A poisoned definition still counts: it was diagnosed already (an
        // inline mismatch poisons the out-of-line def), and this would be a
        // second error for the same mistake.
        if f->definition() != &null {
            return
        }

        var nm = self.sc->ctx->get_spelling(f->name)
        self.sc->diag->report(
            DiagID::R062E,
            f->range.start,
            f"'{nm}' is declared inline but has no body; inline puts the body in the interface, so it must be defined in this file",
        ).first(f->range)->emit()
    }

    /// # helpers

    priv fn _dc_name(self, dc: unsafe *DeclContext) -> string {
        if dc == &null {
            return "<null scope>"
        }

        if dc->is_translation_unit() {
            return "<tu>"
        }

        var unsafe *owner = dc->owner_decl()
        if owner == &null {
            return "<anon scope>"
        }

        var tok = decl_name_tok(owner)
        if tok.kind == TokenKind::TkUnknown {
            return "<anon scope>"
        }

        return self.sc->ctx->get_spelling(tok)
    }
}
