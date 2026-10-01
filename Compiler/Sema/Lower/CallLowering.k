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
///     wrote the default; a default written on an out-of-line definition goes
///     into the owner's method list, since a namespace-scope sibling of
///     `fn C::g` cannot be a member of C. Minted on first need: a call above
///     its callee in the file mints it early, and the callee's own visit
///     splices it.
///
///     The default expression is MOVED into the thunk (`default_val` is null
///     afterwards) -- one node, one parent. Every later reader goes through
///     `default_thunk` or TypeUtil::param_default. M2's re-typing meets the
///     thunk body as it meets any lowered body.
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
///     escape clause. A pack over a dependent element is not lowered yet.
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
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import Sema::SemaContext::*;
import Sema::Resolve::NameLookup::*;
import Sema::Type::TypeUtil::*;
import Sema::Lower::LowerSynth::*;
import AST::Visitor::ASTWriter::*;
import AST::ASTSupport::*;
import AST::DeclFacts::*;
import AST::LangItems::*;
import AST::Mixin::Annotation::*;
import AST::Context::DeclContext::*;
import AST::Context::SymbolTable::*;
import AST::Context::InstantiationRegistry::*;
import AST::Node::Base::*;
import AST::Node::Types::*;
import AST::Node::Expressions::*;
import AST::Node::PrimaryExpressions::*;
import AST::Node::Statements::*;
import AST::Node::Declarations::*;
import AST::Node::CanonicalNodes::*;
import AST::Node::Casting::*;
import AST::Kind::DeclKind::*;
import AST::Kind::ExprKind::*;
import AST::Kind::TypeKind::*;
import Token::Token::*;
import Location::SourceRange::*;

__inline_cpp("
#define ASTWriter_CallLowering ASTWriter<CallLowering>
");

/// One default: minted once per (entity, parameter index).
class ThunkSlot {
    pub var entity:  *Decl         = &null;   ///< the callee's representative.
    pub var index:   usize         = 0;       ///< into params, `self` included.
    pub var thunk:   *FunctionDecl = &null;
    pub var carrier: *FunctionDecl = &null;   ///< the link that wrote the default.
    pub var spliced: bool          = false;
    fn ThunkSlot(self) { }
}

enum PlanKind derives u8 {
    Arg = 0,   ///< an explicit argument, `index` into args.
    Thunk,     ///< a Kairo default, `index` into f->params.
    Omit,      ///< an imported C++ default: nothing emitted.
    Pack,      ///< args[index .. index + len) as one slice.
}

class PlanSlot {
    pub var kind:  PlanKind   = PlanKind::Arg;
    pub var param: *ParamDecl = &null;
    pub var index: usize      = 0;
    pub var len:   usize      = 0;
    fn PlanSlot(self) { }
}

class CallLowering derives ASTWriter::<CallLowering> {
    pub var sc: *SemaContext;
    priv var tu:    TypeUtil;
    priv var synth: LowerSynth;
    priv var _slots:      vec::<ThunkSlot>;
    priv var _entered:    vec::<*FunctionDecl>;   ///< every function whose own walk has begun.
    priv var _slice_ctor: *Decl = &null;

    fn CallLowering(self, sc: *SemaContext) {
        self.sc    = sc;
        self.ctx   = sc->ctx;
        self.tu    = TypeUtil(sc);
        self.synth = LowerSynth(sc);
    }

    fn run(self) {
        self.sc->require_phase(SemaPhase::Checked);
        if self.sc->tu == &null { return; }
        ASTWriter_CallLowering::run(self.sc->tu);
        for var i: usize = 0; i < self._slots.size(); ++i {
            ICE_IF(!self._slots[i].spliced,
                "CallLowering: a default thunk was minted but the declaration that wrote the default was never visited");
        }
    }

    // --- declarations: mint and splice ------------------------------------------

    fn transform_function_decl(self, n: *FunctionDecl) -> vec::<*Decl> {
        self._entered.push_back(n);
        // Params (their defaults), then the body: a call inside either is
        // lowered before this function's own thunks are minted from them.
        var out = ASTWriter_CallLowering::transform_function_decl(n);
        if n->is_poisoned() { return out; }

        for var i: usize = 0; i < n->params.size(); ++i {
            var p = n->params[i];
            if p == &null { continue; }
            if p->is_pack { self._pack_type(p); }
            if p->default_val != &null { self._thunk_for(n, i); }
        }
        for var i: usize = 0; i < self._slots.size(); ++i {
            var s = &(self._slots[i]);
            if (s->carrier != n) || s->spliced { continue; }
            s->spliced = true;
            if n->is_out_of_line() { self._append_member(n, s->thunk); }
            else { out.push_back(static_cast::<*Decl>(s->thunk)); }
        }
        return out;
    }

    /// The thunk for \p f's parameter \p i, minting it on first need.
    priv fn _thunk_for(self, f: *FunctionDecl, i: usize) -> *FunctionDecl {
        var own = f->params[i];
        if (own != &null) && (own->default_thunk != &null) { return cast::<FunctionDecl>(own->default_thunk); }

        var p = self.tu.param_default(f, i);
        ICE_IF(p == &null, "CallLowering: arg_map says 'use the default' for a parameter with none; OverloadResolution invariant");
        if p->default_thunk != &null { return cast::<FunctionDecl>(p->default_thunk); }   // another TU minted it.
        ICE_IF(p->default_val == &null, "CallLowering: an imported C++ default reached thunk minting; it is omitted, never called");

        var carrier = self._link_of(f, p);
        ICE_IF(carrier == &null, "CallLowering: the default's parameter is in no link of the callee's chain");

        // The shell first, stamped on every link, so a default that calls its
        // own function finds the thunk instead of minting a second one.
        var th = self._mint(f, carrier, p, i);
        var s = ThunkSlot{};
        s.entity  = NameLookup::representative(static_cast::<*Decl>(f));
        s.index   = i;
        s.thunk   = th;
        s.carrier = carrier;
        self._slots.push_back(s);

        var v = p->default_val;
        p->default_val = &null;                                   // moved: one node, one parent.
        if !self._was_entered(carrier) { v = self.transform_expr(v); }   // lower it now; the carrier's walk will find it moved.
        self._fill(th, v);
        return th;
    }

    priv fn _was_entered(self, f: *FunctionDecl) -> bool {
        for var i: usize = 0; i < self._entered.size(); ++i { if self._entered[i] == f { return true; } }
        return false;
    }

    priv fn _chain(self, f: *FunctionDecl) -> vec::<*Decl> {
        var links = vec::<*Decl>();
        NameLookup::collect_chain(static_cast::<*Decl>(f), links);
        if links.size() == 0 { links.push_back(static_cast::<*Decl>(f)); }
        return links;
    }

    priv fn _link_of(self, f: *FunctionDecl, p: *ParamDecl) -> *FunctionDecl {
        var links = self._chain(f);
        for var k: usize = 0; k < links.size(); ++k {
            var g = dyn_cast::<FunctionDecl>(links[k]);
            if (g != &null) && (self.tu.param_index(g, p) != usize(-1)) { return g; }
        }
        return &null;
    }

    /// The bodyless thunk, named, placed, stamped on every link.
    priv fn _mint(self, f: *FunctionDecl, carrier: *FunctionDecl, p: *ParamDecl, i: usize) -> *FunctionDecl {
        ICE_IF(f->is_operator, "CallLowering: a default on an operator; OperatorSignatureCheck rejects it");
        var rep = cast::<FunctionDecl>(NameLookup::representative(static_cast::<*Decl>(f)));

        // Where it lives. Out of line: the owner type, never the file.
        var sem: *void = carrier->semantic_dc;
        var lex: *void = carrier->lexical_dc;
        if carrier->is_out_of_line() { lex = sem; }
        var ldc = reinterpret_cast::<*DeclContext>(lex);
        if (ldc != &null) && (ldc->dc_kind == DeclContextKind::Extension) {
            ICE_IF(decl_generic_params(ldc->dc_owner).size() > 0,
                "CallLowering: a default on a member of a generic extension; its thunk would have no arguments to deduce the extension's parameters from");
        }

        var at   = (p->default_val->range) if (p->default_val != &null) else (p->range);
        var name = LowerTargets::default_thunk(self.tu.decl_name(static_cast::<*Decl>(f)), self.tu.param_name(p)) + self._ordinal(f);
        var th   = self._new_fn(at, self.synth.ident(at, name), reinterpret_cast::<*DeclContext>(sem));
        th->semantic_dc    = sem;
        th->lexical_dc     = lex;
        th->visibility     = VisibilityKind::Public;
        th->is_implicit    = true;
        th->generic_params = rep->generic_params;   // the SAME list: its GenericParamDecls are the defaults' T.
        th->return_type    = p->type_;

        var links = self._chain(f);
        for var k: usize = 0; k < links.size(); ++k {
            var g = dyn_cast::<FunctionDecl>(links[k]);
            if (g == &null) || (i >= g->params.size()) || (g->params[i] == &null) { continue; }
            g->params[i]->default_thunk = static_cast::<*Decl>(th);
        }
        return th;
    }

    /// A FunctionDecl with every field set: ASTContext::alloc runs no
    /// constructor, so the node is zeroed first (the registry's pattern).
    priv fn _new_fn(self, at: SourceRange, name: Token, parent: *DeclContext) -> *FunctionDecl {
        var n = self.ctx->alloc::<FunctionDecl>();
        libcxx::memset(static_cast::<*void>(n), 0, sizeof(FunctionDecl));
        n->kind  = DeclKind::FunctionDecl;
        n->range = at;
        n->name  = name;
        n->init_annotations(&(self.ctx->ast_alloc));
        n->init_dc(DeclContextKind::Function, self.ctx, parent, static_cast::<*Decl>(n));
        n->init_redecl();
        n->params          = create_empty_frozen_list::<*ParamDecl>();
        n->op_token        = create_empty_frozen_list::<Token>();
        n->spec_args       = create_empty_frozen_list::<*Type>();
        n->abi             = AbiKind::None;
        n->modifiers       = FnModifier::None;
        n->body_kind       = FnBodyKind::Block;
        n->spec_kind       = SpecKind::None;
        n->requires_clause = &null;
        n->where_clause    = &null;
        n->qualifier       = &null;
        return n;
    }

    /// `{ return <v> }`.
    priv fn _fill(self, th: *FunctionDecl, v: *Expr) {
        var ret  = ReturnStmt::create(self.ctx, v->range, v);
        var body = CompoundStmt::create(self.ctx, v->range);
        var b = self.list_builder::<*Stmt>();
        b.push(static_cast::<*Stmt>(ret));
        b.freeze_into(&(body->body));
        th->body_block = body;
    }

    /// A default written on `fn C::g(...)`: its thunk is a member of C.
    priv fn _append_member(self, carrier: *FunctionDecl, th: *FunctionDecl) {
        var dc = reinterpret_cast::<*DeclContext>(carrier->semantic_dc);
        ICE_IF((dc == &null) || (!dc->is_type_scope()), "CallLowering: out-of-line definition with no owning type");
        var owner = dc->dc_owner;
        ICE_IF(decl_is_imported(owner),
            "CallLowering: a default on an out-of-line definition of an imported C++ member; a C++ class cannot gain a member");
        if isa::<ClassDecl>(owner)  { var rw = self.rewriter::<*FunctionDecl>(&(cast::<ClassDecl>(owner)->methods));  rw.append(th); rw.apply(); return; }
        if isa::<StructDecl>(owner) { var rw = self.rewriter::<*FunctionDecl>(&(cast::<StructDecl>(owner)->methods)); rw.append(th); rw.apply(); return; }
        if isa::<UnionDecl>(owner)  { var rw = self.rewriter::<*FunctionDecl>(&(cast::<UnionDecl>(owner)->methods));  rw.append(th); rw.apply(); return; }
        ICE_FAIL("CallLowering: out-of-line definition in a scope that holds no methods");
    }

    /// `_<k>` when \p f's name cell holds more than one entity; "" otherwise.
    priv fn _ordinal(self, f: *FunctionDecl) -> string {
        var dc = reinterpret_cast::<*DeclContext>(f->semantic_dc);
        var lex = reinterpret_cast::<*DeclContext>(f->lexical_dc);
        if (lex != &null) && (lex->dc_kind == DeclContextKind::Extension) { dc = lex; }
        if dc == &null { return ""; }
        var name = self.tu.decl_name(static_cast::<*Decl>(f));
        var ctor = self._is_ctor(f);
        var cell = (self.sc->lookup.in_context(dc, DeclName::ctor())) if (ctor)
              else (self.sc->lookup.in_context(dc, DeclName::ident(self.sc->imm_table()->intern_ident_copy(name)), name));
        if !cell.found() { return ""; }
        var me   = NameLookup::representative(static_cast::<*Decl>(f));
        var reps = vec::<*Decl>();
        var at   = usize(0);
        for var i: usize = 0; i < cell.cell->size(); ++i {
            var r = NameLookup::representative(cell.cell->get(i));
            var seen = false;
            for var k: usize = 0; k < reps.size(); ++k { if reps[k] == r { seen = true; break; } }
            if seen { continue; }
            if r == me { at = reps.size(); }
            reps.push_back(r);
        }
        if reps.size() <= 1 { return ""; }
        return f"_{at + 1}";
    }

    /// A pack parameter's C++ type, stamped once. Null for a dependent element.
    priv fn _pack_type(self, p: *ParamDecl) -> *Type {
        if p->pack_type == &null { p->pack_type = self.tu.param_value_type(p); }
        return p->pack_type;
    }

    // --- calls ------------------------------------------------------------------------

    fn transform_call_expr(self, n: *CallExpr) -> *Expr {
        var out = ASTWriter_CallLowering::transform_call_expr(n);   // arguments first.
        if n->is_poisoned() { return out; }
        var f = self._callee(n);
        if n->arg_map.size() == 0 {
            if (f != &null) && (!n->is_instantiation_dependent()) { self._check_positional(n, f); }
            return out;
        }
        ICE_IF(f == &null, "CallLowering: arg_map on a call with no function callee");
        return self._rewrite(n, f);
    }

    priv fn _callee(self, n: *CallExpr) -> *FunctionDecl {
        if n->ctor_decl != &null { return dyn_cast::<FunctionDecl>(n->ctor_decl); }
        var c = n->callee;
        while (c != &null) && isa::<ParenExpr>(c) { c = cast::<ParenExpr>(c)->inner; }
        if (c != &null) && isa::<NamedIdentExpr>(c) { return dyn_cast::<FunctionDecl>(cast::<NamedIdentExpr>(c)->resolved_decl); }
        if (c != &null) && isa::<ChainExpr>(c) {
            var ch = cast::<ChainExpr>(c);
            if ch->steps.size() == 0 { return &null; }
            return dyn_cast::<FunctionDecl>(ch->steps.get(ch->steps.size() - 1)->resolved_decl);
        }
        return &null;
    }

    /// `x.m(...)` or a constructor: `self` is bound, not an argument. A
    /// constructor is recognised by the DECL, not by how the call names it:
    /// X's ctor calls carry ctor_decl, but every lowering that mints one
    /// (LowerSynth::ctor_call, ListLiteralLowering, OperatorLowering's
    /// _ctor_cast) names the ctor directly.
    priv fn _receiver_bound(self, n: *CallExpr) -> bool {
        if n->ctor_decl != &null { return true; }
        var f = self._callee(n);
        if (f != &null) && self._is_ctor(f) { return true; }
        var ch = dyn_cast::<ChainExpr>(n->callee);
        if (ch == &null) || (ch->steps.size() == 0) { return false; }
        return ch->steps.get(ch->steps.size() - 1)->access_kind != ChainExpr::AccessKind::ColonColon;
    }

    priv fn _is_ctor(self, f: *FunctionDecl) -> bool {
        if f->is_operator || (!f->is_method()) { return false; }   // an operator has no name token to spell.
        var dc = reinterpret_cast::<*DeclContext>(f->semantic_dc);
        if (dc == &null) || (!dc->is_type_scope()) || (dc->dc_owner == &null) { return false; }
        return self.tu.decl_name(static_cast::<*Decl>(f)) == self.tu.decl_name(dc->dc_owner);
    }

    /// A call an earlier lowering minted is positional and must be whole.
    priv fn _check_positional(self, n: *CallExpr, f: *FunctionDecl) {
        if f->ffi_c_variadic { return; }
        var bound = self._receiver_bound(n);
        var need: usize = 0;
        var tail: usize = 0;
        for var i: usize = 0; i < f->params.size(); ++i {
            var p = f->params[i];
            if p == &null { continue; }
            if p->is_self && bound { continue; }
            need += 1;
            if p->has_default && (p->default_thunk == &null) { tail += 1; } else { tail = 0; }
        }
        // Not ICE_IF with the callee's name: its message is built whether or
        // not it fires, and an operator's `name` is the empty Token, which
        // asserts when spelled.
        if n->args.size() + tail < need {
            ICE_FAIL("CallLowering: a call minted by an earlier Lower/ pass is short of arguments; the pass that minted it must supply every one");
        }
    }

    priv fn _rewrite(self, n: *CallExpr, f: *FunctionDecl) -> *Expr {
        var np = f->params.size();
        ICE_IF(n->arg_map.size() != np, "CallLowering: arg_map is not parallel to the callee's parameters");

        var vals = vec::<*Expr>();
        var used = vec::<bool>();
        var named = false;
        for var i: usize = 0; i < n->args.size(); ++i {
            var a = n->args[i];
            if isa::<NamedArgExpr>(a) { a = cast::<NamedArgExpr>(a)->value; named = true; }
            vals.push_back(a);
            used.push_back(false);
        }

        // (a) the plan, and whether it is the identity.
        var plan = vec::<PlanSlot>();
        var identity = !named;
        var next: i32 = 0;
        var omitted = false;
        for var i: usize = 0; i < np; ++i {
            var p = f->params[i];
            var m = n->arg_map[i];
            if m == i32(-2) { continue; }
            var s = PlanSlot{};
            s.param = p;
            if p->is_pack {
                identity = false;
                s.kind = PlanKind::Pack;
                if m != i32(-1) {
                    s.index = static_cast::<usize>(m);
                    s.len   = static_cast::<usize>(n->pack_len);
                    for var k: usize = 0; k < s.len; ++k { used[s.index + k] = true; }
                }
            } else if m == i32(-1) {
                identity = false;
                s.kind  = (PlanKind::Omit) if (self._imported_default(f, i)) else (PlanKind::Thunk);
                s.index = i;
            } else {
                if m != next { identity = false; }
                s.kind  = PlanKind::Arg;
                s.index = static_cast::<usize>(m);
                used[s.index] = true;
                next = m + 1;
            }
            ICE_IF(omitted && (s.kind != PlanKind::Omit),
                "CallLowering: an argument follows an omitted C++ default; OverloadResolution should have rejected it (SC107E)");
            if s.kind == PlanKind::Omit { omitted = true; }
            plan.push_back(s);
        }
        if identity { self._clear(n); return static_cast::<*Expr>(n); }

        // (b) would the rebuilt order evaluate anything out of source order?
        var need_bind = false;
        var last: i32 = -1;
        var saw_thunk = false;
        for var i: usize = 0; i < plan.size(); ++i {
            var s = &(plan[i]);
            if s->kind == PlanKind::Thunk { saw_thunk = true; continue; }
            if s->kind == PlanKind::Omit { continue; }
            var len = (s->len) if (s->kind == PlanKind::Pack) else (usize(1));
            for var k: usize = 0; k < len; ++k {
                var at = s->index + k;
                if LowerSynth::pure(vals[at]) { continue; }
                if saw_thunk || (i32(at) < last) { need_bind = true; }
                last = i32(at);
            }
        }

        var stmts = self.list_builder::<*Stmt>();
        var wrap  = need_bind && self._sequenceable(n);
        if wrap {
            // Operand zero is the receiver: it evaluates first as written, so it
            // is bound first if it has effects.
            var ch = dyn_cast::<ChainExpr>(n->callee);
            if (ch != &null) && (ch->base != &null) && self._receiver_bound(n) && (ch->steps.size() > 0)
            && (!LowerSynth::pure(ch->base)) && (ch->base->type_ != &null) {
                ch->base = self._bind(ch->base, &stmts);
            }
            for var k: usize = 0; k < vals.size(); ++k {
                if LowerSynth::pure(vals[k]) || (vals[k]->type_ == &null) { continue; }
                vals[k] = self._bind(vals[k], &stmts);
            }
        }

        // (c) rebuild in parameter order; (d) the C `...` tail after it.
        var out = self.list_builder::<*Expr>();
        for var i: usize = 0; i < plan.size(); ++i {
            var s = &(plan[i]);
            switch s->kind {
                case PlanKind::Arg   { out.push(vals[s->index]); }
                case PlanKind::Thunk { out.push(self._thunk_call(n, f, s)); }
                case PlanKind::Omit  { 0; }
                case PlanKind::Pack  { out.push(self._pack(n, s, &vals)); }
            }
        }
        for var k: usize = 0; k < vals.size(); ++k { if !used[k] { out.push(vals[k]); } }
        out.freeze_into(&(n->args));
        self._clear(n);

        if !wrap { return static_cast::<*Expr>(n); }
        stmts.push(static_cast::<*Stmt>(ExpressionStmt::create(self.ctx, n->range, static_cast::<*Expr>(n))));
        var body = CompoundStmt::create(self.ctx, n->range);
        stmts.freeze_into(&(body->body));
        var se = StmtExpr::create(self.ctx, n->range, body);
        se->type_          = n->type_;
        se->value_category = Expr::ValueCategory::RValue;
        se->expr_flags     = n->expr_flags;
        return static_cast::<*Expr>(se);
    }

    /// An imported C++ default: clang applies it, so the argument is omitted.
    priv fn _imported_default(self, f: *FunctionDecl, i: usize) -> bool {
        var p = self.tu.param_default(f, i);
        return (p != &null) && p->has_default && (p->default_val == &null) && (p->default_thunk == &null);
    }

    /// `__kairo_default_f_x()`, resolved, typed, and for a generic callee
    /// registered as its own instance so EmitIR spells the arguments and
    /// EmitPlan homes it.
    priv fn _thunk_call(self, n: *CallExpr, f: *FunctionDecl, s: *PlanSlot) -> *Expr {
        var th   = self._thunk_for(f, s->index);
        var tctx = NameLookup::ctx_of(static_cast::<*Decl>(th));
        if tctx == &null { tctx = self.ctx; }
        var head = NamedIdentExpr::create(self.ctx, n->range, self.synth.ident(n->range, tctx->get_spelling(th->name)));
        head->resolved_decl = static_cast::<*Decl>(th);

        var call = CallExpr::create(self.ctx, n->range, static_cast::<*Expr>(head));
        var none = self.list_builder::<*Expr>();
        none.freeze_into(&(call->args));
        call->value_category = Expr::ValueCategory::RValue;
        call->qualifier      = self._qualifier(n, f);

        var ie = reinterpret_cast::<*InstanceEntry>(n->instance);
        var pt = canon_unqual(s->param->type_->canonical);
        if th->generic_params.size() > 0 {
            ICE_IF(ie == &null, "CallLowering: a generic callee's default on a call with no instance; CallTyping registers one at Selected");
            call->instance = reinterpret_cast::<*void>(
                self.sc->instances->instance_for(static_cast::<*Decl>(th), &(ie->args), self.sc->ctx->fid, tctx));
            pt = self._subst(pt, ie);
        }
        // Null when still dependent: SequenceLowering then declines to hoist
        // it rather than declare a local of a type the call site cannot spell.
        call->type_ = pt;
        return static_cast::<*Expr>(call);
    }

    /// `T` -> the instance's argument for it; anything else dependent -> null.
    priv fn _subst(self, t: *Type, ie: *InstanceEntry) -> *Type {
        if (t == &null) || (!t->is_dependent()) { return t; }
        if isa::<GenericParamType>(t) {
            var g = cast::<GenericParamType>(t);
            if static_cast::<usize>(g->param_index) < ie->args.size() { return ie->args[static_cast::<usize>(g->param_index)]; }
        }
        return &null;
    }

    /// The receiver's record when the thunk's owner is generic: the thunk is a
    /// static member of a class template and needs `Box<i32>::` to be named.
    priv fn _qualifier(self, n: *CallExpr, f: *FunctionDecl) -> *Type {
        var dc = reinterpret_cast::<*DeclContext>(f->semantic_dc);
        if (dc == &null) || (!dc->is_type_scope()) || (dc->dc_kind == DeclContextKind::Extension) { return &null; }
        var owner = NameLookup::representative(dc->dc_owner);
        if decl_generic_params(owner).size() == 0 { return &null; }
        if n->ctor_decl != &null { return canon_unqual(n->type_); }
        var ch = dyn_cast::<ChainExpr>(n->callee);
        ICE_IF((ch == &null) || (!self._receiver_bound(n)),
            "CallLowering: a defaulted parameter of a generic type's method, called through `::`; the thunk's owner arguments cannot be named");
        var last = ch->steps.size() - 1;
        var rt = (ch->base->type_) if (last == 0) else (ch->steps.get(last - 1)->resolved_type);
        rt = self.tu.strip_nullable(self.tu.as_value(rt));
        var pe = self.tu.pointee(rt);
        if pe != &null { rt = pe; }
        return canon_unqual(rt);
    }

    /// The pack run as a `Slice<E>` literal; ListLiteralLowering builds it.
    priv fn _pack(self, n: *CallExpr, s: *PlanSlot, vals: *vec::<*Expr>) -> *Expr {
        var pt = self._pack_type(s->param);
        ICE_IF(pt == &null, "CallLowering: a pack over a dependent element type; generic packs are not lowered yet");
        var lit = ListLiteralExpr::create(self.ctx, n->range);
        var b = self.list_builder::<*Expr>();
        for var k: usize = 0; k < s->len; ++k { b.push((*vals)[s->index + k]); }
        b.freeze_into(&(lit->elements));
        lit->type_          = pt;
        lit->value_category = Expr::ValueCategory::RValue;
        lit->storage        = ListStorage::FullExpr;
        lit->slice_ctor     = self._slice();
        lit->owner_ctor     = &null;
        return static_cast::<*Expr>(lit);
    }

    priv fn _slice(self) -> *Decl {
        if self._slice_ctor == &null {
            self._slice_ctor = self.tu.lang_ctor(WellKnownType::Slice, 2, false);
            ICE_IF(self._slice_ctor == &null, "CallLowering: the Slice lang item has no (data, len) constructor");
        }
        return self._slice_ctor;
    }

    priv fn _clear(self, n: *CallExpr) {
        n->arg_map  = create_empty_frozen_list::<i32>();
        n->pack_len = 0;
    }

    // --- binding (SequenceLowering's rules) -------------------------------------------

    priv fn _sequenceable(self, n: *CallExpr) -> bool {
        if n->value_category == Expr::ValueCategory::LValue { return false; }
        var t = n->type_;
        if t == &null { return true; }
        if isa::<CXXLValueRefType>(t) || isa::<CXXRValueRefType>(t) { return false; }
        var c = canon_unqual(t);
        if (c != &null) && (c->kind == TypeKind::RecordType) { return false; }
        return true;
    }

    priv fn _bind(self, e: *Expr, stmts: *ListBuilder::<*Stmt>) -> *Expr {
        var vd = self.synth.local(e->range, "carg", e->type_, e);
        self._mark_extended(e);
        stmts->push(static_cast::<*Stmt>(DeclStmt::create(self.ctx, e->range, static_cast::<*Decl>(vd))));
        return self.synth.use_of(vd, e->range, Expr::ValueCategory::LValue);
    }

    priv fn _mark_extended(self, e_in: *Expr) {
        var e = self.tu.strip_parens(e_in);
        if (e == &null) || (!isa::<ListLiteralExpr>(e)) { return; }
        var l = cast::<ListLiteralExpr>(e);
        if (l->type_ == &null) || (!self.tu.is_slice(l->type_)) { return; }
        l->storage = ListStorage::Extended;
        for var i: usize = 0; i < l->elements.size(); ++i { self._mark_extended(l->elements[i]); }
    }
}

__inline_cpp("
#undef ASTWriter_CallLowering
");