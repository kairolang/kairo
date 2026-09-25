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
///                            same predicate TypeResolution uses. A place
///                            operator (`[]`, `.*`, `->*`;
///                            OperatorFacts::is_place) is the one exception
///                            to the restriction: `-> *T` beside
///                            `-> *const T` is the pair a const receiver
///                            needs, and X ranks the two by receiver.
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
///     - `where` clause agreement. A runtime-dispatch guard on one link and
///       not another is either a conflict or a third dispatch axis, and
///       WhereDispatchLowering owns that call. FIXME marks the site.
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
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import Sema::SemaContext::*;
import Sema::Resolve::NameLookup::*;
import Sema::Resolve::MemberLookup::*;
import Sema::Type::TypeUtil::*;
import Config::Invocation::*;
import AST::Context::ASTContext::*;
import AST::Context::DeclContext::*;
import AST::Context::TranslationUnit::*;
import AST::Context::SymbolTable::*;
import AST::ASTSupport::*;
import AST::Node::Base::*;
import AST::Node::CanonicalNodes::*;
import AST::Node::Declarations::*;
import AST::DeclFacts::*;
import AST::OperatorFacts::*;
import AST::Node::Types::*;
import AST::Node::Casting::*;
import AST::Kind::DeclKind::*;
import Token::Token::*;
import Token::TokenKind::*;
import Diagnostic::Registry::*;
import AST::ParamMode::*;

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
class SigShape {
    pub var mode: ParamMode = ParamMode::Value;
    pub var ty:   *Type     = &null;
    fn SigShape(self) { }
}

class RedeclMerge {
    pub var sc: *SemaContext;

    fn RedeclMerge(self, sc: *SemaContext) {
        self.sc = sc;
    }

    /// PRE: NamesResolved, and TypeResolution has run in this same stage
    /// (canonical param types exist). NOT TypesResolved -- the driver does
    /// not advance the phase until every pass in the T stage has returned,
    /// so asserting this stage's EXIT phase from inside it would fire.
    /// POST: function redecl chains linked; canonical points at the
    /// definition where there is one.
    fn run(self) {
        self.sc->require_phase(SemaPhase::NamesResolved);
        var tu = self.sc->tu;
        if tu == &null { return; }

        self._merge_in(static_cast::<*DeclContext>(tu));
        self._merge_out_of_line(tu);
    }

    // === R(a): in-scope chains ============================================

    /// Walk every frozen table, then recurse into child scopes. Same
    /// pass-through rule as N(a)::_validate_context: in a TYPE body a
    /// VisibilityGroupDecl's members were keyed into THIS table already, so
    /// descending through the wrapper would judge every cell twice and emit
    /// each diagnostic twice.
    priv fn _merge_in(self, dc: *DeclContext) {
        if dc == &null { return; }
        var type_body = dc->is_type_scope();

        if dc->dc_symbols != &null {
            var rows = vec::<SymbolTable::Entry>();
            dc->dc_symbols->collect_entries(rows);
            for var i: usize = 0; i < rows.size(); ++i {
                self._merge_cell(rows[i], type_body);
            }
        }

        for var i: usize = 0; i < dc->dc_decls.size(); ++i {
            var d = *(dc->dc_decls.get(i));
            if d == &null { continue; }
            if type_body && isa::<VisibilityGroupDecl>(d) { continue; }
            self._descend(d);
        }
    }

    /// See through the table-less wrapper decls the parser parks in
    /// dc_decls. Mirrors NameResolution::_descend.
    priv fn _descend(self, d: *Decl) {
        if d == &null { return; }

        if isa::<VisibilityGroupDecl>(d) {
            var g = cast::<VisibilityGroupDecl>(d);
            for var i: usize = 0; i < g->members.count; ++i { self._descend(g->members[i]); }
            return;
        }
        if isa::<EvalBlockDecl>(d) {
            var b = cast::<EvalBlockDecl>(d);
            for var i: usize = 0; i < b->body.count; ++i { self._descend(b->body[i]); }
            return;
        }
        if isa::<FFIBlockDecl>(d) {
            var b = cast::<FFIBlockDecl>(d);
            for var i: usize = 0; i < b->body.count; ++i { self._descend(b->body[i]); }
            return;
        }

        self._merge_in(NameLookup::context_of(d));
    }

    /// One name in one scope. Size 1 needs nothing. A cell that is not
    /// all-function was already judged by N(a) -- a mixed-kind cell is a
    /// redefinition it diagnosed, and re-judging here would double the
    /// error.
    priv fn _merge_cell(self, e: SymbolTable::Entry, in_type_body: bool) {
        if e.cell == &null { return; }
        if e.cell->size() <= 1 { return; }

        var group = self._fn_group(e.cell);
        if group.size() <= 1 { return; }

        var name = e.name.describe(self.sc->ctx);

        // O(n^2) over one cell. Overload sets are single digits; hashing a
        // vector of canonical pointers costs more than the scan.
        //
        // A poisoned link is skipped on both sides: once a pair has been
        // diagnosed, comparing the loser again produces a second error for
        // one mistake. The cost is that a third genuinely distinct conflict
        // can go unreported until the first is fixed, which is the right
        // trade -- one error per compile beats a cascade.
        for var i: usize = 0; i < group.size(); ++i {
            var a = group[i];
            if a->is_poisoned() { continue; }
            for var j: usize = i + 1; j < group.size(); ++j {
                var b = group[j];
                if b->is_poisoned() { continue; }
                if !self._same_signature(a, b) {
                    // Two entities to Kairo -- but maybe one to the C++ it
                    // emits, and maybe unchoosable at a Kairo call site.
                    // Asked here, where the pair is already known to be an
                    // overload and nowhere else pairs them.
                    self._check_move_overload(name, a, b);
                    if !b->is_poisoned() { self._check_cxx_collision(name, a, b); }
                    continue;
                }
                self._link(name, a, b, in_type_body);
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
    priv fn _fn_group(self, cell: *OverloadCell) -> vec::<*FunctionDecl> {
        var out = vec::<*FunctionDecl>();
        for var i: usize = 0; i < cell->size(); ++i {
            var d = cell->get(i);
            if d == &null { continue; }
            if d->kind == DeclKind::RecoveryDecl { continue; }   // parse recovery; diagnosed.
            var f = dyn_cast::<FunctionDecl>(d);
            if f == &null { return vec::<*FunctionDecl>(); }      // not all-fn: N(a) owns it.
            // A function specialization is its own entity and never links
            // into the primary's chain; pairing it is OverloadResolution's.
            if NameLookup::is_specialization(d) { continue; }
            var seen = false;
            for var j: usize = 0; j < out.size(); ++j {
                if out[j] == f { seen = true; break; }
            }
            if seen { continue; }
            out.push_back(f);
        }
        return out;
    }

    // === R(b): out-of-line definitions ====================================

    /// `fn Class::method` never entered a table. N(a) resolved the
    /// qualifier and set semantic_dc to the owning type, then stopped:
    /// picking WHICH overload the definition defines needs signatures.
    ///
    /// A definition matching no in-class signature is an error HERE. N(a)'s
    /// check was weaker on purpose -- it only asked whether the NAME exists
    /// in the type, which passes for `fn Foo::bump(x: i32)` against an
    /// in-class `fn bump()`.
    priv fn _merge_out_of_line(self, tu: *TranslationUnit) {
        for var i: usize = 0; i < tu->out_of_line.size(); ++i {
            var d = *(tu->out_of_line.get(i));
            if d == &null { continue; }
            if d->is_poisoned() { continue; }          // N(a) diagnosed the qualifier.
            var f = dyn_cast::<FunctionDecl>(d);
            if f == &null { continue; }
            if f->semantic_dc == &null { continue; }   // unattached; N(a) diagnosed.

            var home = reinterpret_cast::<*DeclContext>(f->semantic_dc);
            // Same lazy-fill hazard as N(a): a partly filled imported table
            // hands back a cell missing the overload this def defines.
            var owner = home->owner_decl();
            if owner != &null { MemberLookup::ensure_filled(self.sc, owner); }
            // Cross-TU safe (see NameResolution::_attach_out_of_line): a raw
            // lookup_symbol with this TU's imm probes an imported record's
            // table with the wrong key and returns ANOTHER member's cell.
            var ml   = MemberLookup(self.sc);
            var cell = ml.in_scope(home, self._member_key(f, home), self.sc->ctx->get_spelling(f->name));
            if cell == &null { continue; }             // N(a) diagnosed the missing name.

            var group = self._fn_group(cell);
            var hit: *FunctionDecl = &null;
            for var j: usize = 0; j < group.size(); ++j {
                if group[j] == f { continue; }
                if !self._same_signature(group[j], f) { continue; }
                hit = group[j];
                break;
            }

            if hit == &null {
                var nm = self.sc->ctx->get_spelling(f->name);
                var hm = self._dc_name(home);
                self.sc->diag->report(DiagID::R031E, f->range.start,
                    f"out-of-line definition of '{nm}' does not match any declaration in '{hm}\x27"
                ).first(f->range).emit();
                f->poison();
                continue;
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
            var prior = hit->definition();
            if (prior != &null) && (prior != f) {
                var nm = self.sc->ctx->get_spelling(f->name);
                self.sc->diag->report(DiagID::R029E, f->range.start,
                    f"redefinition of '{nm}\x27"
                ).first(f->range)
                 .note(DiagID::R029N, prior->range.start,
                    f"previous definition of '{nm}' is here"
                ).first(prior->range).emit();
                f->poison();
                continue;
            }

            // File-scope rule, deliberately: the out-of-line definition is
            // not part of the member-specification, so it may legally pair
            // with the in-class declaration.
            self._link(self.sc->ctx->get_spelling(f->name), hit, f, false);
        }
    }

    /// The DeclName an out-of-line def is keyed under inside \p home.
    ///
    /// FIXME(dedup): this rule now exists in three places --
    /// ASTParse::_index_symbol_decl (which writes the table),
    /// NameResolution::_member_key (which probes it), and here. Three copies
    /// of a keying rule that must agree exactly is how the probe and the
    /// table silently diverge; hoist to NameLookup as a static.
    priv fn _member_key(self, f: *FunctionDecl, home: *DeclContext) -> DeclName {
        if f->is_operator {
            var k0 = TokenKind::TkUnknown;
            var k1 = TokenKind::TkUnknown;
            if f->op_token.count > 0 { k0 = f->op_token[0].kind; }
            if f->op_token.count > 1 { k1 = f->op_token[1].kind; }
            return DeclName::op_name(k0, k1);
        }
        var im = self.sc->ctx->get_ident_imm(f->name);
        if (im != u32(-1)) && home->is_type_scope() {
            var owner = home->owner_decl();
            // By spelling, each through its own context (NameResolution::
            // _member_key): an imported owner's imm is the header TU's.
            if owner != &null {
                var oc = NameLookup::ctx_of(owner);
                if oc == &null { oc = self.sc->ctx; }
                if oc->get_spelling(decl_name_tok(owner)) == self.sc->ctx->get_spelling(f->name) {
                    return DeclName::ctor();
                }
            }
        }
        return DeclName::ident(im);
    }

    /// True when \p d's names live outside this TU: another TU's decl, or
    /// (post-extraction) a decl clang owns. Mirrors
    /// TypeResolution::_foreign -- same question, same answer.
    priv fn _foreign(self, d: *Decl) -> bool {
        var c = NameLookup::ctx_of(d);
        return (c != &null) && (c != self.sc->ctx);
    }

    // === signature identity ===============================================

    /// See the header for what is in and what is out, and why each
    /// exclusion is load-bearing.
    priv fn _same_signature(self, a: *FunctionDecl, b: *FunctionDecl) -> bool {
        // Generic arity first: `fn <T> f(x: T)` and `fn f(x: i32)` are not
        // one entity however their parameters canonicalize. Cheap, and it
        // short-circuits the dependent cases below.
        if a->generic_params.size() != b->generic_params.size() { return false; }

        // The trailing pack is part of the function type. In practice the
        // pack parameter is IN params with a VariadicPackType, so the loop
        // below would catch it -- this is a cheap guard against a shape
        // where the flag is set without a corresponding param node.
        if a->is_variadic != b->is_variadic { return false; }

        if a->params.size() != b->params.size() { return false; }

        // Prefix and postfix `++`/`--` are one name cell and two entities.
        if OperatorFacts::is_postfix(a) != OperatorFacts::is_postfix(b) { return false; }

        var fa = self._foreign(a);
        var fb = self._foreign(b);
        // Const-ness participates in signature identity for FOREIGN decls
        // and PLACE OPERATORS only. Kairo source may not declare const
        // overloads otherwise (see header), so for any other Kairo-authored
        // decl a const mismatch is one entity with two contracts and
        // _check_modifiers_agree reports it. C++ has no such rule and the
        // STL leans on it hard -- begin()/begin() const, the operator[]
        // pairs -- so an extracted header's pairs are two entities and must
        // not merge; a Kairo place operator is the same pair by design.
        var const_is_identity = fa || fb || OperatorFacts::is_place(a) || OperatorFacts::is_place(b);
        if const_is_identity {
            if a->is_const() != b->is_const() { return false; }
        }

        // Exactly one side owned by clang: its reference kinds are read as
        // modes. Keyed on _cxx_owned, NOT _foreign: an out-of-line Kairo def
        // of a method imported into THIS TU is the case the mapping exists
        // for, and _foreign (another TU) is false for it.
        var oa    = self._cxx_owned(a);
        var ob    = self._cxx_owned(b);
        var mixed = oa != ob;

        for var i: usize = 0; i < a->params.size(); ++i {
            var pa = a->params[i];
            var pb = b->params[i];
            if (pa == &null) || (pb == &null) { return false; }
            if (pa->type_ == &null) || (pb->type_ == &null) { return false; }
            var ca = pa->type_->canonical;
            var cb = pb->type_->canonical;
            if (ca == &null) || (cb == &null) { return false; }   // dependent: M2's.

            if pa->is_self || pb->is_self {
                if pa->is_self != pb->is_self { return false; }
                // A receiver's cv is in its canonical -- a const method's self
                // is `const Record` -- and for a FOREIGN pair or a place
                // operator it is identity: begin() / begin() const are two
                // entities. Kairo permits no other const overloads (header),
                // so a Kairo-authored pair differing only there is one entity
                // with two contracts, and _check_modifiers_agree reports it.
                var strip = !const_is_identity;
                if strip { ca = canon_unqual(ca); cb = canon_unqual(cb); }
                if ca != cb { return false; }
                continue;
            }

            var sa = self._param_shape(pa, ca, oa, mixed);
            var sb = self._param_shape(pb, cb, ob, mixed);
            if sa.mode != sb.mode { return false; }
            if sa.ty   != sb.ty   { return false; }
        }
        return true;
    }

    /// True when clang owns \p d: an `ffi` import, from this TU or another
    /// (FFILinkage::is_imported -- it carries a USR). Distinct from _foreign,
    /// which asks only "another TU" and is false for a header imported here.
    priv fn _cxx_owned(self, d: *FunctionDecl) -> bool {
        return d->is_imported();
    }

    /// The (mode, type) a value parameter is judged on. Top-level cv is
    /// stripped as in C++ ([dcl.fct]/5). A foreign decl's mode is always
    /// Value; against a KAIRO decl its C++ reference kind is read as the
    /// mode it spells, so `void f(int&)` in a header and `fn S::f(self,
    /// @inout x: i32)` are one entity. Foreign-vs-foreign keeps the
    /// reference in the type: `b(int&)` / `b(const int&)` stay two.
    priv fn _param_shape(self, p: *ParamDecl, c: *Type, foreign: bool, mixed: bool) -> SigShape {
        var out = SigShape{};
        out.mode = p->mode;
        out.ty   = canon_unqual(c);
        if !(foreign && mixed) { return out; }
        if isa::<CXXLValueRefType>(c) {
            var r = cast::<CXXLValueRefType>(c)->referee;
            out.ty   = canon_unqual(r);
            out.mode = (ParamMode::Value) if (canon_has_const(r)) else (ParamMode::Inout);
            return out;
        }
        if isa::<CXXRValueRefType>(c) {
            out.ty   = canon_unqual(cast::<CXXRValueRefType>(c)->referee);
            out.mode = ParamMode::Move;
            return out;
        }
        return out;
    }

    /// Two overloads whose ONLY difference is by-value vs `@move` on some
    /// parameter. C++ tells `f(T)` from `f(T&&)`; a Kairo call cannot --
    /// `@move` has no marker, so `f(x)` is the same text for both and
    /// nothing can choose. Error at the second declaration. Kairo-authored
    /// pairs only: an imported pair is clang's and legal there.
    ///
    /// A pair that ALSO differs in `@inout`-ness at some position is a
    /// genuine overload: `f(&a, b)` and `f(a, b)` choose.
    priv fn _check_move_overload(self, name: string, a: *FunctionDecl, b: *FunctionDecl) {
        if self._foreign(a) || self._foreign(b) { return; }
        if a->generic_params.size() != b->generic_params.size() { return; }
        if a->is_variadic != b->is_variadic { return; }
        if a->params.size() != b->params.size() { return; }
        var differs = false;
        var pos: usize = 0;
        for var i: usize = 0; i < a->params.size(); ++i {
            var pa = a->params[i];
            var pb = b->params[i];
            if (pa == &null) || (pb == &null) { return; }
            if pa->is_self != pb->is_self { return; }
            var ca = self._param_canonical(pa);
            var cb = self._param_canonical(pb);
            if (ca == &null) || (cb == &null) { return; }
            if ca != cb { return; }
            if pa->is_self { continue; }
            var ia = pa->mode == ParamMode::Inout;
            var ib = pb->mode == ParamMode::Inout;
            if ia != ib { return; }                       // distinguishable at the call.
            if pa->mode != pb->mode { differs = true; pos = i; }
        }
        if !differs { return; }

        var pn = self.sc->ctx->get_spelling(b->params[pos]->name);
        // f-strings do not adjacent-concatenate under Stage 0: explicit `+`.
        self.sc->diag->report(DiagID::R001E, b->range.start,
            f"'{name}' cannot be overloaded on '@move': a '@move' argument is written "
            + "with no marker, so a call could not choose between these declarations"
        ).first(b->range)
         .note(DiagID::R001N, a->range.start,
            f"the other declaration is here; they differ only in the passing mode of '{pn}\x27"
        ).first(a->range).emit();
        b->poison();
    }

    // === C++ signature collision ==========================================

    /// Two overloads Kairo tells apart but the emitted C++ cannot: every
    /// parameter lowers to the same C++ type, so the generated file would
    /// declare one C++ function twice -- a redefinition clang reports
    /// against code nobody wrote. Reported here, against the source, at the
    /// second decl.
    ///
    /// The lowering compared is the BUILTIN table only, for now: `usize` and
    /// `isize` are distinct Kairo types that lower to `size_t` / `ptrdiff_t`,
    /// which are the fixed-width integers of the target's pointer width.
    /// Records, pointers and references compare by canonical pointer, as
    /// signature identity does; dependent signatures are M2's, as above.
    ///
    /// Kairo-authored pairs only: two imported decls are distinct C++
    /// already (clang said so), and an imported decl is never emitted.
    priv fn _check_cxx_collision(self, name: string, a: *FunctionDecl, b: *FunctionDecl) {
        if self._foreign(a) || self._foreign(b) { return; }
        if a->generic_params.size() != b->generic_params.size() { return; }
        if a->is_variadic != b->is_variadic { return; }
        if a->params.size() != b->params.size() { return; }
        // Postfix `++`/`--` gets C++'s `int` dummy, prefix does not: two
        // different C++ parameter lists however the Kairo ones compare.
        if OperatorFacts::is_postfix(a) != OperatorFacts::is_postfix(b) { return; }
        // A mode difference is a C++ difference (`T` vs `T&` vs `T&&`): no
        // collision possible, whatever the types lower to.
        for var i: usize = 0; i < a->params.size(); ++i {
            if (a->params[i] != &null) && (b->params[i] != &null)
            && (a->params[i]->mode != b->params[i]->mode) { return; }
        }
        var pw = self._pointer_width();
        for var i: usize = 0; i < a->params.size(); ++i {
            var ca = self._param_canonical(a->params[i]);
            var cb = self._param_canonical(b->params[i]);
            if (ca == &null) || (cb == &null) { return; }
            if self._cxx_lowered(ca, pw) != self._cxx_lowered(cb, pw) { return; }
        }
        var ka = self._kairo_sig(name, a);
        var kb = self._kairo_sig(name, b);
        var cx = self._cxx_sig(name, a, pw);
        self.sc->diag->report(DiagID::R052E, b->range.start,
            f"'{ka}' and '{kb}' have the same C++ signature '{cx}' on this target"
        ).first(b->range)
         .note(DiagID::R052N, a->range.start, f"'{ka}' declared here")
         .first(a->range).emit();
        b->poison();
    }

    priv fn _param_canonical(self, p: *ParamDecl) -> *Type {
        if (p == &null) || (p->type_ == &null) { return &null; }
        var c = p->type_->canonical;
        return (c) if (p->is_self) else (canon_unqual(c));
    }

    /// The canonical \p t is identical to once lowered: `usize` / `isize`
    /// become the fixed-width integer of the pointer width, anything else
    /// is itself.
    priv fn _cxx_lowered(self, t: *Type, pw: usize) -> *Type {
        if !isa::<BuiltinType>(t) { return t; }
        var k = cast::<BuiltinType>(t)->builtin;
        if (k != BuiltinKind::USize) && (k != BuiltinKind::ISize) { return t; }
        var sgn   = k == BuiltinKind::ISize;
        var fixed = BuiltinKind::COUNT;
        if pw == 16 { fixed = (BuiltinKind::I16) if (sgn) else (BuiltinKind::U16); }
        if pw == 32 { fixed = (BuiltinKind::I32) if (sgn) else (BuiltinKind::U32); }
        if pw == 64 { fixed = (BuiltinKind::I64) if (sgn) else (BuiltinKind::U64); }
        if fixed == BuiltinKind::COUNT { return t; }
        var ft = self.sc->builtin(fixed);
        return (ft) if (ft != &null) else (t);
    }

    /// target.pointer_width, never a literal. 0 (a hand-built invocation)
    /// reads as 64: the fallback SemaContext gives the store, so the two
    /// cannot disagree about what `usize` is.
    priv fn _pointer_width(self) -> usize {
        var ci = self.sc->ctx->ci;
        if (ci == &null) || (ci->target.pointer_width == 0) { return 64; }
        return ci->target.pointer_width;
    }

    /// `f(u64, i32)`: value parameters only, the receiver is implied.
    priv fn _kairo_sig(self, name: string, f: *FunctionDecl) -> string {
        var tu = TypeUtil(self.sc);
        var s = name + "(";
        var first = true;
        for var i: usize = 0; i < f->params.size(); ++i {
            var p = f->params[i];
            if (p == &null) || p->is_self { continue; }
            if !first { s += ", "; }
            first = false;
            s += tu.str(self._param_canonical(p));
        }
        return s + ")";
    }

    /// The same, as the lowering spells it: EmitIR's builtin spellings.
    priv fn _cxx_sig(self, name: string, f: *FunctionDecl, pw: usize) -> string {
        var tu = TypeUtil(self.sc);
        var s = name + "(";
        var first = true;
        for var i: usize = 0; i < f->params.size(); ++i {
            var p = f->params[i];
            if (p == &null) || p->is_self { continue; }
            if !first { s += ", "; }
            first = false;
            var c = self._cxx_lowered(self._param_canonical(p), pw);
            if isa::<BuiltinType>(c) { s += builtin_info(cast::<BuiltinType>(c)->builtin)->cxx; }
            else { s += tu.str(c); }
        }
        return s + ")";
    }

    // === agreement across a linked chain ==================================

    /// Return type is not in the signature, which is exactly why it must be
    /// checked here: two decls that matched on parameters are ONE entity,
    /// so a differing return type is a conflict, not an overload.
    priv fn _check_return_agrees(self, name: string, prev: *FunctionDecl,
                                 cur: *FunctionDecl) {
        // An expr-bodied function's return type is INFERRED and does not
        // exist until TypeInference, which runs after R. Its null means
        // "not yet knowable", not "void", so there is nothing to compare.
        if prev->body_kind == FnBodyKind::Expr { return; }
        if cur->body_kind  == FnBodyKind::Expr { return; }

        // FIXME(noreturn): `-> !` may be encoded as is_noreturn with a null
        // return_type, in which case it canonicalizes to void here and a
        // `-> !` / `-> void` pair merges silently. _check_modifiers_agree
        // catches it as a modifier disagreement for now; if OVERLOAD.md
        // makes `!` a real return type, delete that half and let this one
        // report it. See Tests/Sema/RedeclMerge/kairo-only/.
        var rp = self._return_canonical(prev);
        var rc = self._return_canonical(cur);
        if (rp == &null) || (rc == &null) { return; }   // dependent or diagnosed.
        if rp == rc { return; }

        var at      = (cur->return_type->range)  if (cur->return_type  != &null) else (cur->range);
        var prev_at = (prev->return_type->range) if (prev->return_type != &null) else (prev->range);

        self.sc->diag->report(DiagID::R037E, at.start,
            f"'{name}' declared with a different return type; the parameter types "
            "are identical, so this is a redeclaration, not an overload"
        ).first(at)
         .note(DiagID::R037N, prev_at.start,
            "previously declared with this return type"
        ).first(prev_at).emit();
        cur->poison();
    }

    /// The canonical a non-expr-bodied function returns: the declared
    /// type's canonical, or void when the return type was omitted, so an
    /// omitted `-> void` and an explicit one compare equal.
    priv fn _return_canonical(self, f: *FunctionDecl) -> *Type {
        if f->return_type == &null { return self.sc->builtin(BuiltinKind::Void); }
        return f->return_type->canonical;
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
    priv fn _check_defaults_once(self, prev: *FunctionDecl, cur: *FunctionDecl) {
        for var i: usize = 0; i < cur->params.size(); ++i {
            var pp = prev->params[i];
            var pc = cur->params[i];
            if (pp == &null) || (pc == &null) { continue; }
            if (pp->default_val == &null) || (pc->default_val == &null) { continue; }

            var pn = self.sc->ctx->get_spelling(pc->name);
            self.sc->diag->report(DiagID::R040E, pc->default_val->range.start,
                f"redefinition of default argument for '{pn}\x27"
            ).first(pc->default_val->range)
             .note(DiagID::R040N, pp->default_val->range.start,
                "previous default argument is here"
            ).first(pp->default_val->range).emit();
            cur->poison();
        }
    }

    /// One entity, one linkage. A chain that disagrees would emit two
    /// different symbols for one function, which the linker resolves by
    /// accident or not at all.
    priv fn _check_linkage_agrees(self, name: string, prev: *FunctionDecl,
                                  cur: *FunctionDecl) {
        if prev->abi == cur->abi { return; }
        self.sc->diag->report(DiagID::R038E, cur->range.start,
            f"'{name}' redeclared with a different ABI"
        ).first(cur->range)
         .note(DiagID::R038N, prev->range.start, "previously declared here")
         .first(prev->range).emit();
        cur->poison();
    }

    /// Modifiers that change what the function MEANS must agree across a
    /// chain. `inline` and `final` are excluded: neither changes the
    /// contract, and C++ explicitly permits adding `inline` on a later
    /// declaration.
    ///
    /// `const` is here rather than in _same_signature because Kairo does
    /// not permit const overloading -- see the header. Two links
    /// disagreeing about const are one entity with two contracts. A place
    /// operator's pair never reaches here: const is its identity.
    ///
    /// FIXME(where): a `where` guard on one link and not another is either
    /// this same kind of conflict or a third dispatch axis;
    /// WhereDispatchLowering owns that decision. Not checked yet.
    priv fn _check_modifiers_agree(self, name: string, prev: *FunctionDecl,
                                   cur: *FunctionDecl) {
        var what = "";
        if (!self._foreign(prev)) && (!self._foreign(cur)) && (prev->is_const() != cur->is_const()) { what = "const"; }
        else if prev->is_unsafe()  != cur->is_unsafe()  { what = "unsafe";   }
        else if prev->is_async()   != cur->is_async()   { what = "async";    }
        else if prev->is_eval()    != cur->is_eval()    { what = "eval";     }
        else if prev->is_panic()   != cur->is_panic()   { what = "panic";    }
        else if prev->is_noreturn  != cur->is_noreturn  { what = "noreturn"; }
        if what.size() == 0 { return; }

        self.sc->diag->report(DiagID::R039E, cur->range.start,
            f"'{name}' redeclared with a different '{what}' qualifier; the "
            "parameter types are identical, so this is one function"
        ).first(cur->range)
         .note(DiagID::R039N, prev->range.start, "previously declared here")
         .first(prev->range).emit();
        cur->poison();
    }

    // === linking ==========================================================

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
    priv fn _link(self, name: string, prev: *FunctionDecl, cur: *FunctionDecl,
                  in_type_body: bool) {
        if cur->canonical_decl() != prev->canonical_decl() { cur->set_prev(prev); }

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
            self.sc->diag->report(DiagID::R041E, cur->range.start,
                f"class member '{name}' cannot be redeclared"
            ).first(cur->range)
             .note(DiagID::R041N, prev->range.start, "previous declaration is here")
             .first(prev->range).emit();
            cur->poison();
            return;
        }

        self._check_return_agrees(name, prev, cur);
        self._check_defaults_once(prev, cur);
        self._check_linkage_agrees(name, prev, cur);
        self._check_modifiers_agree(name, prev, cur);

        if prev->has_body() && cur->has_body() {
            self.sc->diag->report(DiagID::R029E, cur->range.start,
                f"redefinition of '{name}\x27"
            ).first(cur->range)
             .note(DiagID::R029N, prev->range.start,
                f"previous definition of '{name}' is here"
            ).first(prev->range).emit();
            cur->poison();
            return;
        }

        // canonical = the definition if the chain has one, else the first
        // link (which retarget_canonical leaves as-is via first_decl).
        var def = prev->definition();
        prev->retarget_canonical((def) if (def != &null) else (prev->first_decl()));
    }

    // === helpers ==========================================================

    priv fn _dc_name(self, dc: *DeclContext) -> string {
        if dc == &null { return "<null scope>"; }
        if dc->is_translation_unit() { return "<tu>"; }
        var owner = dc->owner_decl();
        if owner == &null { return "<anon scope>"; }
        var tok = decl_name_tok(owner);
        if tok.kind == TokenKind::TkUnknown { return "<anon scope>"; }
        return self.sc->ctx->get_spelling(tok);
    }
}