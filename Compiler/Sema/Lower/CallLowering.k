/// --- The Kairo Project -------------------- Sema/Lower/CallLowering.k --- ///
///
///   \brief Every call becomes one positional argument list in parameter
///          order: named arguments placed, defaults filled, packs gathered.
///
///   \detail
///     X placed every argument (`CallExpr::arg_map`, parallel to the callee's
///     parameters, `self` in slot 0) and this pass makes the tree say so:
///
///       f(b: g(), a: h())      ({ var t0 = g(); var t1 = h(); f(t1, t0); })
///       f(1)                   f(1, __kairo_default_f_b())
///       print("a", "b", end: ' ')
///                              print(["a", "b"], ' ', __kairo_default_print_spacing())
///       v.push(x)              untouched (arg_map [self, 0])
///
///   \par Defaults are nullary thunks
///     A parameter's default becomes `fn __kairo_default_<fn>_<param>() -> P
///     { return <default> }`, carrying the callee's generic parameters
///     (dependent defaults are template bodies). Beside a free function it is
///     a free function; for a method, a static member of the same type, so a
///     private static is reachable; for an extension member, a member of the
///     same extension. A default cannot read a parameter or `self` (StmtTyping,
///     SC106E), which is what makes it nullary.
///
///     One thunk per ENTITY and parameter index, not per declaration: defaults
///     accumulate across a redecl chain (RedeclMerge admits one per index), so
///     the thunk is minted from whichever link wrote it and stamped on that
///     index's ParamDecl in every link. It is spliced beside the link that
///     wrote the default. A default is never written on an out-of-line
///     definition (RedeclMerge, R056E), so every method thunk splices beside
///     its in-class declaration. Minted on first need: a call above
///     its callee in the file mints it early, and the callee's own visit
///     splices it.
///
///     The default expression is MOVED into the thunk (`default_val` is null
///     afterwards) -- one node, one parent. Every later reader goes through
///     `default_thunk` or TypeUtil::param_default. Nothing re-types it per
///     instance (Compiler/Spec/Generics.md#decisions): a generic thunk is one C++ template like the
///     body it came from.
///
///     An imported C++ default (`has_default`, no expression) has no thunk:
///     the argument is omitted and clang applies it. The one headroom this
///     layer gives clang, on purpose; X rejects a call that would need a
///     non-trailing omission (SC107E).
///
///   \par Order
///     Explicit arguments evaluate left to right as written; defaults after
///     every explicit argument, in parameter order. SequenceLowering (next)
///     orders impure operands left to right as they sit in the rebuilt list,
///     so this pass binds explicit arguments to locals, in SOURCE order,
///     exactly when the rebuilt list would put an impure one after another
///     impure one written later, or after a thunk call. Bound, they are names
///     (pure), and what remains for SequenceLowering is the thunk calls, which
///     are already in parameter order. A call whose result is an lvalue or a
///     record is not wrapped (a statement expression is a prvalue and copies a
///     record out): those keep C++'s order, the same documented hole
///     SequenceLowering has.
///
///   \par Packs
///     A pack is a `Slice<E>` by value. Its contiguous run of arguments
///     becomes a ListLiteralExpr of that type, FullExpr storage, slice ctor
///     bound; ListLiteralLowering gives it its array. The array lives to the
///     end of the full-expression; a callee that retains the slice is AMT's
///     escape clause. A TYPE pack (`fn <...T> f(...xs: T)`) is a C++
///     parameter pack instead: its run stays in place, one argument per
///     element, and CallTyping's instance carries each element's type.
///
///   \par Postcondition
///     No NamedArgExpr; every call's arguments in parameter order, `self`
///     excluded when bound to a receiver; `arg_map` empty; every parameter
///     has an argument except trailing imported C++ defaults. A call a
///     lowering MINTED (empty arg_map) and left short is an ICE here; EmitIR
///     re-checks the count. A call typed as dependent has no arg_map and is
///     left as written until M2.
///
///   Phase: LOWER, after OperatorLowering and FStringLowering, before
///   SequenceLowering.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "Native/Types.hh"
ffi "c++" import "vector"
ffi "c++" import "cstring"

import AST::ASTSupport::create_empty_frozen_list
import AST::Context::DeclContext::{
    DeclContext,
    DeclContextKind,
}
import AST::Context::InstantiationRegistry::InstanceEntry
import AST::Context::SymbolTable::DeclName
import AST::DeclFacts::{
    decl_generic_params,
    decl_is_imported,
    param_is_type_pack,
}
import AST::Kind::DeclKind::DeclKind
import AST::Kind::TypeKind::TypeKind
import AST::LangItems::{
    LowerTargets,
    WellKnownType,
}
import AST::Mixin::Annotation::VisibilityKind
import AST::Node::Base::{
    Decl,
    Expr,
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
    AbiKind,   ClassDecl, FnBodyKind, FnModifier, FunctionDecl, ParamDecl, SpecKind, StructDecl,
    UnionDecl,
}
import AST::Node::Expressions::{
    CallExpr,
    ListLiteralExpr,
    ListStorage,
    NamedArgExpr,
    ParenExpr,
    StmtExpr,
}
import AST::Node::PrimaryExpressions::{
    ChainExpr,
    NamedIdentExpr,
}
import AST::Node::Statements::{
    CompoundStmt,
    DeclStmt,
    ExpressionStmt,
    ReturnStmt,
}
import AST::Node::Types::{
    CXXLValueRefType,
    CXXRValueRefType,
    GenericParamType,
}
import AST::Visitor::ASTWriter::{
    ASTWriter,
    ListBuilder,
}
import Location::FullSourceLocation::FullSourceLocation
import Location::SourceRange::SourceRange
import Sema::Lower::LowerSynth::LowerSynth
import Sema::Resolve::NameLookup::NameLookup
import Sema::SemaContext::{
    SemaContext,
    SemaPhase,
}
import Sema::Type::TypeUtil::TypeUtil
import Token::Token::Token

/// One default: minted once per (entity, parameter index).
pub class ThunkSlot {
    pub var entity:  unsafe *Decl         = &null ///< the callee's representative.
    pub var index:   usize                = 0     ///< into params, `self` included.
    pub var thunk:   unsafe *FunctionDecl = &null
    pub var carrier: unsafe *FunctionDecl = &null ///< the link that wrote the default.
    pub var home:    unsafe *ParamDecl    = &null ///< its parameter that wrote it.
    pub var spliced: bool                 = false
    fn ThunkSlot(self) { }
}

pub enum PlanKind derives u8 {
    Arg = 0, ///< an explicit argument, `index` into args.
    Thunk,   ///< a Kairo default, `index` into f->params.
    Omit,    ///< an imported C++ default: nothing emitted.
    Pack,    ///< args[index .. index + len) as one slice.
}

pub class PlanSlot {
    pub var kind:  PlanKind          = PlanKind::Arg
    pub var param: unsafe *ParamDecl = &null
    pub var index: usize             = 0
    pub var len:   usize             = 0
    fn PlanSlot(self) { }
}

pub class CallLowering derives ASTWriter<CallLowering> {
    pub var  sc:          unsafe *SemaContext
    priv var tu:          TypeUtil
    priv var synth:       LowerSynth
    priv var _slots:      cxx::std::vector<ThunkSlot>
    priv var _entered:    cxx::std::vector<unsafe *FunctionDecl> ///< every function whose own walk has begun.
    priv var _slice_ctor: unsafe *Decl                           = &null

    fn CallLowering(self, sc: unsafe *SemaContext) {
        self.sc    = sc
        self.ctx   = sc->ctx
        self.tu    = TypeUtil(sc)
        self.synth = LowerSynth(sc)
    }

    fn run(self) {
        self.sc->require_phase(SemaPhase::Checked)
        if self.sc->tu == &null {
            return
        }

        ASTWriter<CallLowering>::run(self, self.sc->tu)
        for var i: usize = 0; i < self._slots.size(); ++i {
            var *s = &self._slots[i]
            if s->spliced {
                continue
            }

            // Minted for a callee whose default is written in ANOTHER TU
            // that had not been lowered yet (whole-tree, cycle groups): that
            // TU's own walk places it (transform_function_decl, below).
            if NameLookup::ctx_of(s->carrier) != self.sc->ctx {
                continue
            }

            var full: FullSourceLocation = self.sc->ctx->sm->get_line_col(s->carrier->range.start)
            kairo::std::ice_fail(
                f"CallLowering: a default thunk was minted for '{self.tu.decl_name(s->entity)}' parameter {s->index}, but the declaration that wrote the default ({full.path.full_path()}:{full.line}:{full.column}) was never visited",
            )
        }
    }

    /// # declarations: mint and splice

    fn transform_function_decl(self, n: unsafe *FunctionDecl) -> cxx::std::vector<unsafe *Decl> {
        self._entered.push_back(n)
        // Params (their defaults), then the body: a call inside either is
        // lowered before this function's own thunks are minted from them.
        var out = ASTWriter<CallLowering>::transform_function_decl(self, n)
        if n->is_poisoned() {
            return out
        }

        for var i: usize = 0; i < n->params.size(); ++i {
            var unsafe *p = n->params[i]
            if p == &null {
                continue
            }

            if p->is_pack {
                self._pack_type(p)
            }

            if p->default_val != &null {
                self._thunk_for(n, i)
            }
        }

        for var i: usize = 0; i < self._slots.size(); ++i {
            var unsafe *s = unsafe &self._slots[i]
            if s->carrier != n || s->spliced {
                continue
            }

            s->spliced = true
            if s->home != &null {
                s->home->default_thunk_placed = true
            }

            if n->is_out_of_line() {
                self._append_member(n, s->thunk)
            } else {
                out.push_back(unsafe (s->thunk as unsafe *Decl))
            }
        }

        // A thunk another TU minted from this declaration's default, before
        // this TU was lowered (it moved the default out, so no slot here
        // names it): placed here, where the default is written.
        for var i: usize = 0; i < n->params.size(); ++i {
            var unsafe *p = n->params[i]
            if p == &null
                || p->default_thunk == &null
                || !p->default_thunk_home
                || p->default_thunk_placed {
                continue
            }

            p->default_thunk_placed = true
            var unsafe *th = cast<FunctionDecl>(p->default_thunk)
            if n->is_out_of_line() {
                self._append_member(n, th)
            } else {
                out.push_back(unsafe (th as unsafe *Decl))
            }
        }

        return out
    }

    /// The thunk for \p f's parameter \p i, minting it on first need.
    priv fn _thunk_for(self, f: unsafe *FunctionDecl, i: usize) -> unsafe *FunctionDecl {
        var unsafe *own = f->params[i]
        if own != &null && own->default_thunk != &null {
            return cast<FunctionDecl>(own->default_thunk)
        }

        var unsafe *p = self.tu.param_default(f, i)
        if p == &null {
            kairo::std::ice_fail(
                "CallLowering: arg_map says 'use the default' for a parameter with none; OverloadResolution invariant",
            )
        }

        if p->default_thunk != &null { // another TU minted it.
            return cast<FunctionDecl>(p->default_thunk)
        }

        if p->default_val == &null {
            kairo::std::ice_fail(
                "CallLowering: an imported C++ default reached thunk minting; it is omitted, never called",
            )
        }

        var unsafe *carrier = self._link_of(f, p)
        if carrier == &null {
            kairo::std::ice_fail(
                "CallLowering: the default's parameter is in no link of the callee's chain",
            )
        }

        // The shell first, stamped on every link, so a default that calls its
        // own function finds the thunk instead of minting a second one.
        var unsafe *th = self._mint(f, carrier, p, i)
        var        s   = ThunkSlot()
        s.entity  = NameLookup::representative(f)
        s.index   = i
        s.thunk   = th
        s.carrier = carrier
        s.home    = p
        self._slots.push_back(s)

        p->default_thunk_home = true
        var unsafe *v = p->default_val
        p->default_val = &null // moved: one node, one parent.
        if !self._was_entered(carrier) { // lower it now; the carrier's walk will find it moved.
            v = self.transform_expr(v)
        }

        self._fill(th, v)
        return th
    }

    priv fn _was_entered(self, f: unsafe *FunctionDecl) -> bool {
        for var i: usize = 0; i < self._entered.size(); ++i {
            if self._entered[i] == f {
                return true
            }
        }

        return false
    }

    priv fn _chain(self, f: unsafe *FunctionDecl) -> cxx::std::vector<unsafe *Decl> {
        var links = cxx::std::vector<unsafe *Decl>()
        NameLookup::collect_chain(unsafe (f as unsafe *Decl), &links)
        if links.size() == 0 {
            links.push_back(f)
        }

        return links
    }

    priv fn _link_of(self, f: unsafe *FunctionDecl, p: unsafe *ParamDecl) -> unsafe *FunctionDecl {
        var links = self._chain(f)
        for var k: usize = 0; k < links.size(); ++k {
            var unsafe *g = dyn_cast<FunctionDecl>(links[k])
            if g != &null && self.tu.param_index(g, p) != usize::MAX {
                return g
            }
        }

        return &null
    }

    /// The bodyless thunk, named, placed, stamped on every link.
    priv fn _mint(self,
                  f:       unsafe *FunctionDecl,
                  carrier: unsafe *FunctionDecl,
                  p:       unsafe *ParamDecl,
                  i:       usize) -> unsafe *FunctionDecl {
        if f->is_operator {
            kairo::std::ice_fail(
                "CallLowering: a default on an operator; OperatorSignatureCheck rejects it",
            )
        }

        var unsafe *rep = cast<FunctionDecl>(NameLookup::representative(unsafe (f as unsafe *Decl)))

        // Where it lives. Out of line: the owner type, never the file.
        var sem: unsafe *DeclContext = carrier->semantic_dc
        var lex: unsafe *DeclContext = carrier->lexical_dc
        if carrier->is_out_of_line() {
            lex = sem
        }

        var unsafe *ldc = lex
        if ldc != &null && ldc->dc_kind == DeclContextKind::Extension {
            if decl_generic_params(ldc->dc_owner).size() > 0 {
                kairo::std::ice_fail(
                    "CallLowering: a default on a member of a generic extension; its thunk would have no arguments to deduce the extension's parameters from",
                )
            }
        }

        var at = if (p->default_val != &null) => (p->default_val->range) else => p->range
        var name = LowerTargets::default_thunk(
            self.tu.decl_name(unsafe (f as unsafe *Decl)),
            self.tu.param_name(p),
        ) + self._ordinal(f)
        var nt = self.synth.ident(at, name)
        // A token's spelling is read through ITS file's table, and `at` is
        // in the carrier's file: minted from another TU of an import cycle,
        // the name must be interned there, or it spells nothing in C++.
        var unsafe *cctx = NameLookup::ctx_of(unsafe (carrier as unsafe *Decl))
        if cctx != &null && cctx != self.sc->ctx && cctx->get_imm_table() != &null {
            nt.imm = cctx->get_imm_table()->intern_ident_copy(name)
        }

        var unsafe *th = self._new_fn(at, nt, sem)
        th->semantic_dc    = sem
        th->lexical_dc     = lex
        th->visibility     = VisibilityKind::Public
        th->is_implicit    = true
        th->generic_params = rep->generic_params // the SAME list: its GenericParamDecls are the defaults' T.
        th->return_type    = p->type_

        var links = self._chain(f)
        for var k: usize = 0; k < links.size(); ++k {
            var unsafe *g = dyn_cast<FunctionDecl>(links[k])
            if g == &null || i >= g->params.size() || g->params[i] == &null {
                continue
            }

            g->params[i]->default_thunk = th
        }

        return th
    }

    /// A FunctionDecl with every field set: ASTContext::alloc runs no
    /// constructor, so the node is zeroed first (the registry's pattern).
    priv fn _new_fn(self,
                    at:     SourceRange,
                    name:   Token,
                    parent: unsafe *DeclContext) -> unsafe *FunctionDecl {
        var unsafe *n = self.ctx->alloc<FunctionDecl>()
        cxx::std::memset(unsafe (n as unsafe *void), 0, sizeof(FunctionDecl))
        n->kind  = DeclKind::FunctionDecl
        n->range = at
        n->name  = name
        n->init_annotations(unsafe &self.ctx->ast_alloc)
        n->init_dc(DeclContextKind::Function, self.ctx, parent, n)
        n->init_redecl()
        n->params          = create_empty_frozen_list<unsafe *ParamDecl>()
        n->op_token        = create_empty_frozen_list<Token>()
        n->spec_args       = create_empty_frozen_list<unsafe *Type>()
        n->abi             = AbiKind::None
        n->modifiers       = FnModifier::None
        n->body_kind       = FnBodyKind::Block
        n->spec_kind       = SpecKind::None
        n->requires_clause = &null
        n->where_clause    = &null
        n->qualifier       = &null
        return n
    }

    /// `{ return <v> }`.
    priv fn _fill(self, th: unsafe *FunctionDecl, v: unsafe *Expr) {
        var unsafe *ret  = ReturnStmt::create(self.ctx, v->range, v)
        var unsafe *body = CompoundStmt::create(self.ctx, v->range)
        var        b     = self.list_builder<unsafe *Stmt>()
        b.push(ret)
        b.freeze_into(&body->body)
        th->body_block = body
    }

    /// A default written on `fn C::g(...)`: its thunk would be a member of C.
    /// Unreachable: RedeclMerge rejects such a default (R056E) and clears it.
    /// The body stays so the guard names the cause if that ever changes.
    priv fn _append_member(self, carrier: unsafe *FunctionDecl, th: unsafe *FunctionDecl) {
        kairo::std::ice_fail(
            "CallLowering: a default on an out-of-line definition reached lowering; RedeclMerge (R056E) clears it",
        )

        var unsafe *dc = carrier->semantic_dc
        if dc == &null || !dc->is_type_scope() {
            kairo::std::ice_fail("CallLowering: out-of-line definition with no owning type")
        }

        var unsafe *owner = dc->dc_owner
        if decl_is_imported(owner) {
            kairo::std::ice_fail(
                "CallLowering: a default on an out-of-line definition of an imported C++ member; a C++ class cannot gain a member",
            )
        }

        if isa<ClassDecl>(owner) {
            var rw = self.rewriter<unsafe *FunctionDecl>(unsafe &cast<ClassDecl>(owner)->methods)
            rw.append(th)
            rw.apply()
            return
        }

        if isa<StructDecl>(owner) {
            var rw = self.rewriter<unsafe *FunctionDecl>(unsafe &cast<StructDecl>(owner)->methods)
            rw.append(th)
            rw.apply()
            return
        }

        if isa<UnionDecl>(owner) {
            var rw = self.rewriter<unsafe *FunctionDecl>(unsafe &cast<UnionDecl>(owner)->methods)
            rw.append(th)
            rw.apply()
            return
        }

        kairo::std::ice_fail(
            "CallLowering: out-of-line definition in a scope that holds no methods",
        )
    }

    /// `_<k>` when \p f's name cell holds more than one entity; "" otherwise.
    priv fn _ordinal(self, f: unsafe *FunctionDecl) -> string {
        var unsafe *dc  = f->semantic_dc
        var unsafe *lex = f->lexical_dc
        if lex != &null && lex->dc_kind == DeclContextKind::Extension {
            dc = lex
        }

        if dc == &null {
            return ""
        }

        var name = self.tu.decl_name(unsafe (f as unsafe *Decl))
        var ctor = self._is_ctor(f)
        var cell = if (ctor) => (self.sc->lookup.in_context(dc, DeclName::ctor()))
                   else => self.sc->lookup.in_context(
                       dc,
                       DeclName::ident(self.sc->imm_table()->intern_ident_copy(name)),
                       name,
                   )

        if !cell.found() {
            return ""
        }

        var unsafe *me  = NameLookup::representative(unsafe (f as unsafe *Decl))
        var        reps = cxx::std::vector<unsafe *Decl>()
        var        at   = (0 as usize)
        for var i: usize = 0; i < cell.cell->size(); ++i {
            var unsafe *r   = NameLookup::representative(cell.cell->get(i))
            var        seen = false
            for var k: usize = 0; k < reps.size(); ++k {
                if reps[k] == r {
                    seen = true
                    break
                }
            }

            if seen {
                continue
            }

            if r == me {
                at = reps.size()
            }

            reps.push_back(r)
        }

        if reps.size() <= 1 {
            return ""
        }

        return LowerTargets::default_thunk_ordinal(at + 1)
    }

    /// A pack parameter's C++ type, stamped once. Null for a dependent element.
    priv fn _pack_type(self, p: unsafe *ParamDecl) -> unsafe *Type {
        if p->pack_type == &null {
            p->pack_type = self.tu.param_value_type(p)
        }

        return p->pack_type
    }

    /// # calls

    fn transform_call_expr(self, n: unsafe *CallExpr) -> unsafe *Expr {
        var unsafe *out = ASTWriter<CallLowering>::transform_call_expr(self, n) // arguments first.
        if n->is_poisoned() {
            return out
        }

        var unsafe *f = self._callee(n)
        if n->arg_map.size() == 0 {
            if f != &null && !n->is_instantiation_dependent() {
                self._check_positional(n, f)
            }

            return out
        }

        if f == &null {
            kairo::std::ice_fail("CallLowering: arg_map on a call with no function callee")
        }

        return self._rewrite(n, f)
    }

    priv fn _callee(self, n: unsafe *CallExpr) -> unsafe *FunctionDecl {
        if n->ctor_decl != &null {
            return dyn_cast<FunctionDecl>(n->ctor_decl)
        }

        if n->functor_op != &null {
            return dyn_cast<FunctionDecl>(n->functor_op)
        }

        var unsafe *c = n->callee
        while c != &null && isa<ParenExpr>(c) {
            c = cast<ParenExpr>(c)->inner
        }

        if c != &null && isa<NamedIdentExpr>(c) {
            return dyn_cast<FunctionDecl>(cast<NamedIdentExpr>(c)->resolved_decl)
        }

        if c != &null && isa<ChainExpr>(c) {
            var unsafe *ch = cast<ChainExpr>(c)
            if ch->steps.size() == 0 {
                return &null
            }

            return dyn_cast<FunctionDecl>(ch->steps.get(ch->steps.size() - 1)->resolved_decl)
        }

        return &null
    }

    /// `x.m(...)` or a constructor: `self` is bound, not an argument. A
    /// constructor is recognised by the DECL, not by how the call names it:
    /// X's ctor calls carry ctor_decl, but every lowering that mints one
    /// (LowerSynth::ctor_call, ListLiteralLowering, OperatorLowering's
    /// _ctor_cast) names the ctor directly.
    priv fn _receiver_bound(self, n: unsafe *CallExpr) -> bool {
        if n->ctor_decl != &null || n->functor_op != &null {
            return true
        }

        var unsafe *f = self._callee(n)
        if f != &null && self._is_ctor(f) {
            return true
        }

        var unsafe *ch = dyn_cast<ChainExpr>(n->callee)
        if ch == &null || ch->steps.size() == 0 {
            return false
        }

        return ch->steps.get(ch->steps.size() - 1)->access_kind != ChainExpr::AccessKind::ColonColon
    }

    priv fn _is_ctor(self, f: unsafe *FunctionDecl) -> bool {
        if f->is_operator || !f->is_method() { // an operator has no name token to spell.
            return false
        }

        var unsafe *dc = f->semantic_dc
        if dc == &null || !dc->is_type_scope() || dc->dc_owner == &null {
            return false
        }

        return self.tu.decl_name(unsafe (f as unsafe *Decl)) == self.tu.decl_name(dc->dc_owner)
    }

    /// A call an earlier lowering minted is positional and must be whole.
    priv fn _check_positional(self, n: unsafe *CallExpr, f: unsafe *FunctionDecl) {
        if f->ffi_c_variadic {
            return
        }

        var bound       = self._receiver_bound(n)
        var need: usize = 0
        var tail: usize = 0
        for var i: usize = 0; i < f->params.size(); ++i {
            var unsafe *p = f->params[i]
            if p == &null {
                continue
            }

            if p->is_self && bound {
                continue
            }

            need += 1
            if p->has_default && p->default_thunk == &null {
                tail += 1
            } else {
                tail = 0
            }
        }

        // Not ICE_IF with the callee's name: its message is built whether or
        // not it fires, and an operator's `name` is the empty Token, which
        // asserts when spelled.
        if n->args.size() + tail < need {
            kairo::std::ice_fail(
                "CallLowering: a call minted by an earlier Lower/ pass is short of arguments; the pass that minted it must supply every one",
            )
        }
    }

    priv fn _rewrite(self, n: unsafe *CallExpr, f: unsafe *FunctionDecl) -> unsafe *Expr {
        var np = f->params.size()
        if n->arg_map.size() != np {
            kairo::std::ice_fail("CallLowering: arg_map is not parallel to the callee's parameters")
        }

        var vals  = cxx::std::vector<unsafe *Expr>()
        var used  = cxx::std::vector<u8>()
        var named = false
        for var i: usize = 0; i < n->args.size(); ++i {
            var unsafe *a = n->args[i]
            if isa<NamedArgExpr>(a) {
                a     = cast<NamedArgExpr>(a)->value
                named = true
            }

            vals.push_back(a)
            used.push_back(0)
        }

        // (a) the plan, and whether it is the identity.
        var plan         = cxx::std::vector<PlanSlot>()
        var identity     = !named
        var next:    i32 = 0
        var omitted      = false
        for var i: usize = 0; i < np; ++i {
            var unsafe *p = f->params[i]
            var        m  = n->arg_map[i]
            if m == (-2 as i32) {
                continue
            }

            var s = PlanSlot()
            s.param = p
            if p->is_pack {
                identity = false
                s.kind   = PlanKind::Pack
                if m != (-1 as i32) {
                    s.index = (m as usize)
                    s.len   = (n->pack_len as usize)
                    for var k: usize = 0; k < s.len; ++k {
                        used[s.index + k] = 1
                    }
                }
            } else if m == (-1 as i32) {
                identity = false
                s.kind = if (self._imported_default(f, i)) => (PlanKind::Omit)
                         else => PlanKind::Thunk
                s.index = i
            } else {
                if m != next {
                    identity = false
                }

                s.kind        = PlanKind::Arg
                s.index       = (m as usize)
                used[s.index] = 1
                next          = m + 1
            }

            if omitted && s.kind != PlanKind::Omit {
                kairo::std::ice_fail(
                    "CallLowering: an argument follows an omitted C++ default; OverloadResolution should have rejected it (SC107E)",
                )
            }

            if s.kind == PlanKind::Omit {
                omitted = true
            }

            plan.push_back(s)
        }

        if identity {
            self._clear(n)
            return unsafe (n as unsafe *Expr)
        }

        // (b) would the rebuilt order evaluate anything out of source order?
        var need_bind     = false
        var last:     i32 = -1
        var saw_thunk     = false
        for var i: usize = 0; i < plan.size(); ++i {
            var *s = &plan[i]
            if s->kind == PlanKind::Thunk {
                saw_thunk = true
                continue
            }

            if s->kind == PlanKind::Omit {
                continue
            }

            var len = if (s->kind == PlanKind::Pack) => (s->len) else => (1)
            for var k: usize = 0; k < len; ++k {
                var at = s->index + k
                if LowerSynth::pure(vals[at]) {
                    continue
                }

                if saw_thunk || (at as i32) < last {
                    need_bind = true
                }

                last = (at as i32)
            }
        }

        var stmts = self.list_builder<unsafe *Stmt>()
        var wrap  = need_bind && self._sequenceable(n)
        if wrap {
            // Operand zero is the receiver: it evaluates first as written, so it
            // is bound first if it has effects.
            var unsafe *ch = dyn_cast<ChainExpr>(n->callee)
            if ch != &null
                && ch->base != &null
                && self._receiver_bound(n)
                && ch->steps.size() > 0
                && !LowerSynth::pure(ch->base)
                && ch->base->type_ != &null {
                ch->base = self._bind(ch->base, &stmts)
            }

            for var k: usize = 0; k < vals.size(); ++k {
                if LowerSynth::pure(vals[k]) || vals[k]->type_ == &null {
                    continue
                }

                vals[k] = self._bind(vals[k], &stmts)
            }
        }

        // (c) rebuild in parameter order; (d) the C `...` tail after it.
        var out = self.list_builder<unsafe *Expr>()
        for var i: usize = 0; i < plan.size(); ++i {
            var *s = &plan[i]
            match s->kind {
                case PlanKind::Arg {
                    out.push(vals[s->index])
                } case PlanKind::Thunk {
                    out.push(self._thunk_call(n, f, s))
                } case PlanKind::Omit {
                    0
                } case PlanKind::Pack {
                    // A type pack is a C++ parameter pack: its run stays one
                    // argument per element, in place (param_is_type_pack).
                    if param_is_type_pack(s->param) {
                        for var k: usize = 0; k < s->len; ++k {
                            out.push(vals[s->index + k])
                        }
                    } else {
                        out.push(self._pack(n, s, vals))
                    }
                }
            }
        }

        for var k: usize = 0; k < vals.size(); ++k {
            if used[k] == 0 {
                out.push(vals[k])
            }
        }

        out.freeze_into(&n->args)
        self._clear(n)

        if !wrap {
            return unsafe (n as unsafe *Expr)
        }

        stmts.push(
            unsafe (ExpressionStmt::create(self.ctx, n->range, unsafe (n as unsafe *Expr)) as unsafe *Stmt),
        )

        var unsafe *body = CompoundStmt::create(self.ctx, n->range)
        stmts.freeze_into(&body->body)
        var unsafe *se = StmtExpr::create(self.ctx, n->range, body)
        se->type_          = n->type_
        se->value_category = Expr::ValueCategory::RValue
        se->expr_flags     = n->expr_flags
        return se
    }

    /// An imported C++ default: clang applies it, so the argument is omitted.
    priv fn _imported_default(self, f: unsafe *FunctionDecl, i: usize) -> bool {
        var unsafe *p = self.tu.param_default(f, i)
        return p != &null && p->has_default && p->default_val == &null && p->default_thunk == &null
    }

    /// `__kairo_default_f_x()`, resolved, typed, and for a generic callee
    /// registered as its own instance so EmitIR spells the arguments and
    /// EmitPlan homes it.
    priv fn _thunk_call(self,
                        n: unsafe *CallExpr,
                        f: unsafe *FunctionDecl,
                        s: *PlanSlot) -> unsafe *Expr {
        var unsafe *th   = self._thunk_for(f, s->index)
        var unsafe *tctx = NameLookup::ctx_of(th)
        if tctx == &null {
            tctx = self.ctx
        }

        var unsafe *head = NamedIdentExpr::create(
            self.ctx,
            n->range,
            self.synth.ident(n->range, tctx->get_spelling(th->name)),
        )

        head->resolved_decl = th

        var unsafe *call = CallExpr::create(self.ctx, n->range, unsafe (head as unsafe *Expr))
        var        none  = self.list_builder<unsafe *Expr>()
        none.freeze_into(&call->args)
        call->value_category = Expr::ValueCategory::RValue
        call->qualifier      = self._qualifier(n, f)

        var unsafe *ie = n->instance
        var unsafe *pt = canon_unqual(s->param->type_->canonical)
        if th->generic_params.size() > 0 {
            if ie == &null {
                kairo::std::ice_fail(
                    "CallLowering: a generic callee's default on a call with no instance; CallTyping registers one at Selected",
                )
            }

            call->instance = self.sc->instances->instance_for(
                th,
                unsafe &ie->args,
                self.sc->ctx->fid,
                tctx,
            )

            pt = self._subst(pt, ie)
        }

        // Null when still dependent: SequenceLowering then declines to hoist
        // it rather than declare a local of a type the call site cannot spell.
        call->type_ = pt
        return call
    }

    /// `T` -> the instance's argument for it; anything else dependent -> null.
    priv fn _subst(self, t: unsafe *Type, ie: unsafe *InstanceEntry) -> unsafe *Type {
        if t == &null || !t->is_dependent() {
            return t
        }

        if isa<GenericParamType>(t) {
            var unsafe *g = cast<GenericParamType>(t)
            if (g->param_index as usize) < ie->args.size() {
                return ie->args[g->param_index as usize]
            }
        }

        return &null
    }

    /// The receiver's record when the thunk's owner is generic: the thunk is a
    /// static member of a class template and needs `Box<i32>::` to be named.
    priv fn _qualifier(self, n: unsafe *CallExpr, f: unsafe *FunctionDecl) -> unsafe *Type {
        var unsafe *dc = f->semantic_dc
        if dc == &null || !dc->is_type_scope() || dc->dc_kind == DeclContextKind::Extension {
            return &null
        }

        var unsafe *owner = NameLookup::representative(dc->dc_owner)
        if decl_generic_params(owner).size() == 0 {
            return &null
        }

        if n->ctor_decl != &null {
            return canon_unqual(n->type_)
        }

        // `Box<i32>::make()`: CallTyping recorded the record it named.
        if n->qualifier != &null {
            return n->qualifier
        }

        var unsafe *ch = dyn_cast<ChainExpr>(n->callee)
        if ch == &null || !self._receiver_bound(n) {
            kairo::std::ice_fail(
                "CallLowering: a defaulted parameter of a generic type's method, called through `::`; the thunk's owner arguments cannot be named",
            )
        }

        var last = ch->steps.size() - 1
        var unsafe *rt = if (last == 0) => (ch->base->type_)
                         else => ch->steps.get(last - 1)->resolved_type
        rt = self.tu.strip_nullable(self.tu.as_value(rt))
        var unsafe *pe = self.tu.pointee(rt)
        if pe != &null {
            rt = pe
        }

        return canon_unqual(rt)
    }

    /// The pack run as a `Slice<E>` literal; ListLiteralLowering builds it.
    priv fn _pack(self,
                  n:          unsafe *CallExpr,
                  s:          *PlanSlot,
                  const vals: cxx::std::vector<unsafe *Expr>) -> unsafe *Expr {
        var unsafe *pt = self._pack_type(s->param)
        if pt == &null {
            kairo::std::ice_fail(
                "CallLowering: a one-type pack over a dependent element (`...xs: U`, U not a pack); not lowered yet",
            )
        }

        var unsafe *lit = ListLiteralExpr::create(self.ctx, n->range)
        var        b    = self.list_builder<unsafe *Expr>()
        for var k: usize = 0; k < s->len; ++k {
            b.push((vals)[s->index + k])
        }

        b.freeze_into(&lit->elements)
        lit->type_          = pt
        lit->value_category = Expr::ValueCategory::RValue
        lit->storage        = ListStorage::FullExpr
        lit->slice_ctor     = self._slice()
        lit->owner_ctor     = &null
        return lit
    }

    priv fn _slice(self) -> unsafe *Decl {
        if self._slice_ctor == &null {
            self._slice_ctor = self.tu.lang_ctor(WellKnownType::Slice, 2, false)
            if self._slice_ctor == &null {
                kairo::std::ice_fail(
                    "CallLowering: the Slice lang item has no (data, len) constructor",
                )
            }
        }

        return self._slice_ctor
    }

    priv fn _clear(self, n: unsafe *CallExpr) {
        n->arg_map  = create_empty_frozen_list<i32>()
        n->pack_len = 0
    }

    /// # binding (SequenceLowering's rules)

    priv fn _sequenceable(self, n: unsafe *CallExpr) -> bool {
        if n->value_category == Expr::ValueCategory::LValue {
            return false
        }

        var unsafe *t = n->type_
        if t == &null {
            return true
        }

        if isa<CXXLValueRefType>(t) || isa<CXXRValueRefType>(t) {
            return false
        }

        var unsafe *c = canon_unqual(t)
        if c != &null && c->kind == TypeKind::RecordType {
            return false
        }

        return true
    }

    priv fn _bind(self, e: unsafe *Expr, stmts: *ListBuilder<unsafe *Stmt>) -> unsafe *Expr {
        var unsafe *vd = self.synth.local(e->range, "carg", e->type_, e)
        self._mark_extended(e)
        stmts->push(
            unsafe (DeclStmt::create(self.ctx, e->range, unsafe (vd as unsafe *Decl)) as unsafe *Stmt),
        )

        return self.synth.use_of(vd, e->range, Expr::ValueCategory::LValue)
    }

    priv fn _mark_extended(self, e_in: unsafe *Expr) {
        var unsafe *e = self.tu.strip_parens(e_in)
        if e == &null || !isa<ListLiteralExpr>(e) {
            return
        }

        var unsafe *l = cast<ListLiteralExpr>(e)
        if l->type_ == &null || !self.tu.is_slice(l->type_) {
            return
        }

        l->storage = ListStorage::Extended
        for var i: usize = 0; i < l->elements.size(); ++i {
            self._mark_extended(l->elements[i])
        }
    }
}
