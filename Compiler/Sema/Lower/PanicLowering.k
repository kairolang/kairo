/// --- The Kairo Project -------------------- Sema/Lower/PanicLowering.k --- ///
///
///   \brief A panic is a returned value: signatures, `return`, `panic`,
///          propagation at a call, and `try` / `catch` as tag compares.
///
///   \detail
///     A function whose final set (EffectPropagation) is not empty returns
///     `Panic<T, E...>` (PANIC.md §4.1), formed here with PanicSets::form
///     and recorded on the decl as `panic_result`; `return_type` stays T,
///     because an importer's typing reads it after this TU lowered. Every
///     Kairo function stays noexcept: nothing here throws.
///
///       return x          ->  return Panic<T, E...>::Ok { value: x }
///       panic X           ->  return Err<X> with this site's id (§1.4)
///       f(a)  (may panic) ->  ({ var __kairo_p = f(a);
///                                if !ok(__kairo_p) { <deliver __kairo_p> }
///                                (__kairo_p.value as T&&) })
///       return g()        ->  return fwd_all<R>(g())   (tail: g's value
///                             type is ours and no `try` is open)
///
///     The statement expression sits where the call sat, so evaluation
///     order is the tree's and a call under `&&`, `||` or an `if` arm runs
///     only on its branch (§4.5): nothing is hoisted across one.
///
///   \par Delivering an error
///     Where an error goes is the innermost TARGET: the function's return
///     (`return fwd<R>(p)`, or `p` moved when it already is an R), or the
///     innermost `try`'s raw slot (`slot <- fwd<S>(p); goto __kairo_catchK`).
///     A `panic X` builds its Err straight into the target. `fwd` copies the
///     tag and site word and moves the payload (InterfaceEmitter writes it:
///     the bytes when the layouts agree, else one case per type), so a
///     re-panic `panic e` forwards the result the error came in, keeping
///     its ORIGINAL site (§3.4).
///
///   \par try / catch (§4.4)
///     Direct form, when the body is one statement that is, or assigns,
///     returns or binds, the one call that can panic in it: the call's own
///     result is held and tested, and the arms read it in place.
///
///       { var p = f(); if ok(p) { <stmt with p.value> } else { <dispatch p> } }
///
///     Slot form, everywhere else: a raw-storage slot `Panic<void, reach>`
///     that nothing builds unless a site fails; each failing site fills it
///     and jumps to the dispatch, which first moves the error out into an
///     ordinary local and destroys the slot, so every arm exit -- a fall
///     through, `return`, `break`, a re-panic -- is a plain scope exit that
///     destroys the error.
///
///       { raw __kairo_s;  { body }  goto done;
///         catch: { var __kairo_e = take(__kairo_s); <dispatch e> }  done:; }
///
///     The dispatch is an `if` chain: `catch e: E` is `tag == type_id<E>`
///     with `e` a reference to the payload; a bare `catch e` is the final
///     `else`, `e` the error as `Panic<void, L...>` over what is left; with
///     no bare arm, what is left is delivered to the next target. A dead arm
///     (PanicEffectChecking) gets no compare. The expression form is the
///     same inside a statement expression, its value in a raw slot of its
///     type that the operand or the arm that ran fills; an arm that leaves
///     (`=> return v`) is its statement.
///
///   \par What it reads
///     PanicEffectChecking's facts: each `try`'s reach, each dead arm, each
///     re-panic's arm (PanicStmt::repanic), the bare binder's type. Every
///     tag, site and payload goes through EnumLayoutQuery; every name it
///     spells in C++ goes through LowerTargets (PanicOpExpr, EmitIR).
///
///   Phase: LOWER, after ScriptLowering (a script's main is an ordinary
///   function by then) and CopyMoveLowering; before FinallyLowering (a
///   `finally` then sees each jump and return this pass makes as an
///   ordinary exit), LabelLowering (an arm's `break L` is lowered with
///   everything else's) and every pass that orders or rewrites calls
///   (CallLowering, SequenceLowering), which meet the held call as an
///   ordinary one.
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
import Sema::Type::TypeUtil::*;
import Sema::Type::PanicSets::*;
import Sema::Resolve::NameLookup::*;
import Sema::Resolve::MemberLookup::*;
import Sema::Check::EffectPropagation::*;
import Sema::Lower::LowerSynth::*;
import Sema::Lower::EnumLayoutLowering::*;
import AST::Visitor::ASTWriter::*;
import AST::ASTSupport::*;
import AST::DeclFacts::*;
import AST::LangItems::*;
import AST::Context::DeclContext::*;
import AST::Context::InstantiationRegistry::*;
import AST::Node::Base::*;
import AST::Node::Types::*;
import AST::Node::Expressions::*;
import AST::Node::PrimaryExpressions::*;
import AST::Node::Statements::*;
import AST::Node::Declarations::*;
import AST::Node::CanonicalNodes::*;
import AST::Node::Casting::*;
import AST::Kind::ExprKind::*;
import AST::Kind::StmtKind::*;
import AST::Kind::DeclKind::*;
import AST::Kind::TypeKind::*;
import AST::ParamMode::*;
import Token::Token::*;
import Token::TokenKind::*;
import Location::SourceRange::*;

/// Where an error from a site goes: the function's return (`slot` null),
/// or a `try`'s raw slot, filled before a jump to its dispatch.
struct PanicTarget {
    var slot:  *VariableDecl = &null;
    var type_: *Type = &null;          ///< the slot's type, or the function's result.
    var label: Token;                  ///< the `try`'s dispatch.
}

/// A catch arm's binding, and the panic result its error is held in: what
/// a re-panic `panic e` forwards.
struct PanicHolder {
    var decl:   *Decl = &null;
    var holder: *VariableDecl = &null;
}

/// A call that may panic: the call, its result type, and whether its set
/// is non-empty (an override of a panicking base, or a conformer of a
/// panicking requirement, returns the base's or requirement's result even
/// when its own body cannot panic: nothing to test then).
struct PanicCall {
    var call:  *CallExpr = &null;
    var rc:    *Type = &null;
    var fails: bool = false;
}

/// One catch arm, of either form.
struct PanicArm {
    var filter:   *Type = &null;
    var decl:     *Decl = &null;
    var is_const: bool = false;
    var is_dead:  bool = false;
    var sbody:    *CompoundStmt = &null;   ///< the statement form's body.
    var ebody:    *Expr = &null;           ///< the expression form's value (or jump).
    var range:    SourceRange;
    var is_cxx:   bool = false;            ///< a C++ exception arm (§3.5).
}

class PanicLowering derives ASTWriter::<PanicLowering> {
    pub var sc: *SemaContext;
    priv var tu:    TypeUtil;
    priv var synth: LowerSynth;
    priv var q:     EnumLayoutQuery;

    priv var _targets: vec::<PanicTarget>;   ///< innermost last; empty in a body that cannot panic, outside a `try`.
    priv var _holders: vec::<PanicHolder>;
    /// The bindings of C++ exception arms: `panic e` of one panics a copy of
    /// the caught object (its arm's type, what the set holds), from here.
    priv var _cxx_binders: vec::<*Decl>;
    /// Inside the body of a `try` with a C++ arm: a value that can throw is
    /// computed first too (_leaves).
    priv var _cxx_depth: i32 = 0;
    priv var _fn_r: *Type = &null;           ///< the current body's result, or null when it does not panic.
    priv var _fn_t: *Type = &null;           ///< its value type T.
    /// The extension index, built on the first conforming-method question
    /// (_requirement_of): most TUs never ask it.
    priv var _ml: MemberLookup;
    priv var _ml_ready: bool = false;

    fn PanicLowering(self, sc: *SemaContext) {
        self.sc    = sc;
        self.ctx   = sc->ctx;
        self.tu    = TypeUtil(sc);
        self.synth = LowerSynth(sc);
        self.q     = EnumLayoutQuery(sc);
    }

    fn run(self) {
        self.sc->require_phase(SemaPhase::Checked);
        if self.sc->tu == &null { return; }
        if PanicSets(self.sc).panic_enum() == &null { return; }   // no builtin root: nothing can panic.
        ASTWriter::<PanicLowering>::run(self.sc->tu);
    }

    // === signatures (§4.1) =====================================================

    /// The value type of \p f: its return type, `void` when it has none.
    priv fn _value_type(self, rt: *Type) -> *Type {
        if (rt == &null) || (rt->canonical == &null) { return self.sc->builtin(BuiltinKind::Void); }
        return canon_unqual(rt->canonical);
    }

    /// What C++ sees \p f return: `Panic<T, E...>` over its final set, or
    /// null when it does not panic. An override returns its base method's
    /// (C++ requires the same return type through the vtable; its own set is
    /// a subset, §2.10), a conforming method its requirement's (the
    /// witness). Recorded on the decl when it is this TU's.
    priv fn _result_of(self, f: *FunctionDecl) -> *Type {
        if f == &null { return &null; }
        if f->panic_result != &null { return f->panic_result; }
        if f->is_poisoned() || f->is_noreturn { return &null; }
        if panic_in_generic(static_cast::<*Decl>(f)) { return &null; }   // gated (§2.6).
        if f->abi == AbiKind::Override {
            var dc = reinterpret_cast::<*DeclContext>(f->semantic_dc);
            var cd: *ClassDecl = &null;
            if (dc != &null) && (dc->owner_decl() != &null) { cd = dyn_cast::<ClassDecl>(dc->owner_decl()); }
            if cd != &null {
                var base = panic_overridden(&(self.tu), cd, f);
                if base != &null {
                    var br = self._result_of(base);
                    if br != &null { return self._store(f, br); }
                }
            }
        }
        // A conforming method returns its requirement's result, for the
        // override's reason: the witness forwards `self->m(...)` as the
        // requirement's type, and its `requires` test names that exact
        // member pointer type, so a smaller set (even none) cannot change it.
        var req = self._requirement_of(f);
        if req != &null {
            var qr = self._result_of(req);
            if qr != &null { return self._store(f, qr); }
        }
        var set = vec::<*Type>();
        if panic_set_of_fn(&(self.tu), f, &set) != PanicKnown::Set { return &null; }
        var at = (f->name.range) if (f->name.range.is_valid()) else (f->range);
        var r = PanicSets(self.sc).form(at, self._value_type(f->return_type), &set);
        if r == &null { return &null; }
        return self._store(f, r);
    }

    /// The interface requirement \p f implements, from the conformance rows
    /// ConformanceChecking recorded: those declared by \p f's owner (`class
    /// X impl I`, `extend X impl I` holding it) and, for a record's own
    /// method, by its extensions (`extend X impl I` met by X's member).
    /// Null for a method that implements none. The first row wins; one
    /// method meeting two requirements with different sets is ticketed.
    priv fn _requirement_of(self, f: *FunctionDecl) -> *FunctionDecl {
        if self.sc->instances == &null { return &null; }
        var dc = reinterpret_cast::<*DeclContext>(f->semantic_dc);
        if (dc == &null) || (dc->owner_decl() == &null) { return &null; }
        var owner = NameLookup::representative(dc->owner_decl());
        var by = vec::<*Decl>();
        if isa::<ExtensionDecl>(owner) {
            by.push_back(owner);
        } else if isa::<ClassDecl>(owner) || isa::<StructDecl>(owner) {
            by.push_back(owner);
            if !self._ml_ready { self._ml = MemberLookup(self.sc); self._ml.index_extensions(); self._ml_ready = true; }
            var exts = self._ml.extensions_of_decl(owner);
            if exts != &null { for var i: usize = 0; i < exts->size(); ++i { by.push_back(static_cast::<*Decl>((*exts)[i])); } }
        } else {
            return &null;
        }
        var me = NameLookup::representative(static_cast::<*Decl>(f));
        var rows = vec::<*ConformanceRow>();
        for var i: usize = 0; i < by.size(); ++i { self.sc->instances->declared_rows(by[i], &rows); }
        for var r: usize = 0; r < rows.size(); ++r {
            var row = rows[r];
            if row == &null { continue; }
            for var i: usize = 0; (i < row->witnesses.size()) && (i < row->reqs.size()); ++i {
                var w = row->witnesses[i];
                if (w == &null) || (NameLookup::representative(w) != me) { continue; }
                var q = dyn_cast::<FunctionDecl>(row->reqs[i]);
                if (q != &null) && (static_cast::<*Decl>(q) != me) { return q; }
            }
        }
        return &null;
    }

    /// \p r as \p f's result, on every link of its chain in this TU (a
    /// `where` group's links are distinct bodies: only \p f). Another TU's
    /// decl wrote its own when that TU lowered.
    priv fn _store(self, f: *FunctionDecl, r: *Type) -> *Type {
        var fid = self.sc->ctx->fid;
        if f->where_lead != &null {
            if self.tu.fid_of(static_cast::<*Decl>(f)) == fid { f->panic_result = r; }
            return r;
        }
        var cur = f;
        for var guard: u32 = 0; guard < 4096; ++guard {
            if self.tu.fid_of(static_cast::<*Decl>(cur)) == fid { cur->panic_result = r; }
            cur = cur->next_in_chain();
            if (cur == f) || (cur == &null) { break; }
        }
        return r;
    }

    /// A closure's result: its final set (declared, §2.2) over its value type.
    priv fn _closure_result(self, c: *ClosureExpr) -> *Type {
        if c->panic_result != &null { return c->panic_result; }
        var panics = (static_cast::<u16>(c->modifiers) & static_cast::<u16>(FnModifier::IsPanic)) != 0;
        if (!panics) || c->is_noreturn { return &null; }
        var set = vec::<*Type>();
        if c->panic_set.size() > 0 {
            if !canonical_set(&(self.tu), &(c->panic_set), &set) { return &null; }
        } else if c->panic_state == PanicSetState::Final {
            for var i: usize = 0; i < c->panic_eff.size(); ++i { set.push_back(c->panic_eff[i]); }
        }
        if set.size() == 0 { return &null; }
        var r = PanicSets(self.sc).form(c->range, self._value_type(c->return_type), &set);
        c->panic_result = r;
        return r;
    }

    /// A panicking `fn` type's C++ result, formed and recorded on the
    /// canonical node the first time any TU meets it (CXXSpell spells the
    /// value type from it); its parameters' and result's `fn` types too.
    priv fn _fn_type_result(self, fp_in: *FunctionPointerType) -> *Type {
        if fp_in == &null { return &null; }
        var fp = fp_in;
        if (fp->canonical != &null) && isa::<FunctionPointerType>(canon_unqual(fp->canonical)) { fp = cast::<FunctionPointerType>(canon_unqual(fp->canonical)); }
        if fp->panic_result != &null { return fp->panic_result; }
        if fp->is_dependent() || fp->is_instantiation_dependent() { return &null; }
        for var i: usize = 0; i < fp->params.size(); ++i { self._note_type(fp->params[i]); }
        self._note_type(fp->return_type);
        if (!fp->canon_panics) || (fp->panic_set.size() == 0) { return &null; }
        var set = vec::<*Type>();
        for var i: usize = 0; i < fp->panic_set.size(); ++i { set.push_back(fp->panic_set[i]); }
        var r = PanicSets(self.sc).form(fp->range, self._value_type(fp->return_type), &set);
        fp->panic_result = r;
        return r;
    }

    /// Every `fn` type a lowered value has gets its result before codegen
    /// spells it.
    priv fn _note_type(self, t: *Type) {
        if (t == &null) || (t->canonical == &null) { return; }
        var c = canon_unqual(t->canonical);
        if c == &null { return; }
        if isa::<NullableType>(c) { self._note_type(cast::<NullableType>(c)->inner); return; }
        if isa::<PointerType>(c) { self._note_type(cast::<PointerType>(c)->pointee); return; }
        if isa::<FunctionPointerType>(c) { self._fn_type_result(cast::<FunctionPointerType>(c)); }
    }

    fn transform_expr(self, e: *Expr) -> *Expr {
        var out = ASTWriter::<PanicLowering>::transform_expr(e);
        if (out != &null) && (out->type_ != &null) { self._note_type(out->type_); }
        return out;
    }

    fn transform_type(self, t: *Type) -> *Type {
        var out = ASTWriter::<PanicLowering>::transform_type(t);
        self._note_type(out);
        return out;
    }

    // === bodies =================================================================

    fn transform_function_decl(self, n: *FunctionDecl) -> vec::<*Decl> {
        var r = self._result_of(n);
        if (n->body_block == &null) && (n->body_expr == &null) { return ASTWriter::<PanicLowering>::transform_function_decl(n); }
        var st = self._targets;
        var sh = self._holders;
        var sr = self._fn_r;
        var sv = self._fn_t;
        self._enter(r, self._value_type(n->return_type));
        var out = ASTWriter::<PanicLowering>::transform_function_decl(n);
        if r != &null { self._end_void(n->body_block); }
        self._targets = st;
        self._holders = sh;
        self._fn_r = sr;
        self._fn_t = sv;
        return out;
    }

    fn transform_closure_expr(self, n: *ClosureExpr) -> *Expr {
        var r = self._closure_result(n);
        var st = self._targets;
        var sh = self._holders;
        var sr = self._fn_r;
        var sv = self._fn_t;
        self._enter(r, self._value_type(n->return_type));
        var out = ASTWriter::<PanicLowering>::transform_closure_expr(n);
        if r != &null { self._end_void(n->body_block); }
        self._targets = st;
        self._holders = sh;
        self._fn_r = sr;
        self._fn_t = sv;
        return out;
    }

    priv fn _enter(self, r: *Type, t: *Type) {
        self._targets.clear();
        self._holders.clear();
        self._fn_r = r;
        self._fn_t = t;
        if r != &null {
            var tg = PanicTarget();
            tg.type_ = r;
            self._targets.push_back(tg);
        }
    }

    /// A `void` panicking body that can fall off its end returns Ok there
    /// (§4.2). A body whose last statement is a `return` cannot.
    priv fn _end_void(self, body: *CompoundStmt) {
        if (body == &null) || (!self.tu.is_void(self._fn_t)) { return; }
        var n = body->body.size();
        if (n > 0) && isa::<ReturnStmt>(body->body[n - 1]) { return; }
        var lb = self.list_builder::<*Stmt>();
        for var i: usize = 0; i < n; ++i { lb.push(body->body[i]); }
        lb.push(static_cast::<*Stmt>(ReturnStmt::create(self.ctx, body->range, self.q.panic_ok(body->range, self._fn_r, &null))));
        lb.freeze_into(&(body->body));
    }

    // === return and panic (§4.2) =================================================

    fn transform_return_stmt(self, n: *ReturnStmt) -> vec::<*Stmt> {
        if self._fn_r == &null { return ASTWriter::<PanicLowering>::transform_return_stmt(n); }
        var at = n->range;
        // Tail position: `return g()` straight out of the function, g's
        // value type ours. No test: the result is forwarded whole.
        if (n->value != &null) && (self._targets.size() == 1) {
            var pc = self._as_call(n->value);
            if (pc.call != &null) && (canon_unqual(self._value_of(pc.rc)) == canon_unqual(self._fn_t)) && (!self.tu.is_void(self._fn_t)) {
                ASTWriter::<PanicLowering>::transform_call_expr(pc.call);
                self._retype(pc);
                var c = static_cast::<*Expr>(pc.call);
                n->value = (c) if (pc.rc == self._fn_r) else (self._fwd(at, PanicOp::FwdAll, self._fn_r, c));
                return self._one_stmt(n);
            }
        }
        var leaves = (n->value != &null) && self._leaves(n->value);
        if n->value != &null { n->value = self.transform_expr(n->value); }
        var out = vec::<*Stmt>();
        // A value that can leave the function (a held call's `return`, an
        // arm's jump) is computed first: codegen builds the Ok payload in a
        // lambda, where a `return` would leave the lambda instead.
        if leaves && (!self.tu.is_void(self._fn_t)) { n->value = self._bound(at, n->value, &out); }
        if self.tu.is_void(self._fn_t) {
            // `return f()` of a void f: run it, then return Ok.
            if n->value != &null { out.push_back(static_cast::<*Stmt>(ExpressionStmt::create(self.ctx, at, n->value))); }
            n->value = self.q.panic_ok(at, self._fn_r, &null);
            out.push_back(static_cast::<*Stmt>(n));
            return out;
        }
        n->value = self.q.panic_ok(at, self._fn_r, self._conv(self._moved_local(n->value), self._fn_t));
        out.push_back(static_cast::<*Stmt>(n));
        return out;
    }

    fn transform_panic_stmt(self, n: *PanicStmt) -> vec::<*Stmt> {
        var out = vec::<*Stmt>();
        var at = n->range;
        // A re-panic forwards the result the error is held in, word 0 as
        // it is: the original site (§3.4).
        if (n->repanic != &null) && (!self._is_cxx_binder(n->repanic)) {
            var h = self._holder_of(n->repanic);
            ICE_IF(h == &null, "PanicLowering: a re-panic of a binding no lowered arm holds; PanicEffectChecking stamps only an arm's");
            self._deliver(at, h, &out);
            return out;
        }
        ICE_IF(self._targets.size() == 0, "PanicLowering: a 'panic' with nowhere to go; PanicEffectChecking gate failure");
        var leaves = self._leaves(n->payload);
        var payload = self.transform_expr(n->payload);
        if leaves { payload = self._bound(at, payload, &out); }   // as a returned value is.
        var x = canon_unqual(payload->type_);
        var site = PanicSets(self.sc).site_id(at.start);
        var tg = self._targets[self._targets.size() - 1];
        // Into the function's return the payload is the local's last use
        // (C++'s implicit move); into a `try`'s slot control goes on, and
        // the local with it: copied.
        var pv = (self._moved_local(payload)) if (tg.slot == &null) else (payload);
        var v = self.q.panic_err(at, tg.type_, x, site, pv);
        if tg.slot == &null {
            out.push_back(static_cast::<*Stmt>(ReturnStmt::create(self.ctx, at, v)));
            return out;
        }
        out.push_back(static_cast::<*Stmt>(ExpressionStmt::create(self.ctx, at, self._slot_put(at, tg.slot, v))));
        out.push_back(static_cast::<*Stmt>(JumpIntrinsicStmt::create(self.ctx, at, tg.label)));
        return out;
    }

    /// An ADT construction whose payload can leave the function: its fields
    /// are computed first, in the order written, into locals the payload
    /// then moves from. Codegen builds a payload in a lambda, where a
    /// held call's `return` would leave the lambda instead.
    fn transform_variant_init_expr(self, n: *VariantInitExpr) -> *Expr {
        var leaves = false;
        for var i: usize = 0; i < n->fields.size(); ++i { if self._leaves(n->fields[i]) { leaves = true; } }
        var out = ASTWriter::<PanicLowering>::transform_variant_init_expr(n);
        if (!leaves) || (n->type_ == &null) { return out; }
        var count = n->fields.size();
        var lb = self.list_builder::<*Stmt>();
        var stmts = vec::<*Stmt>();
        var bound = vec::<*Expr>();
        for var i: usize = 0; i < count; ++i { bound.push_back(&null); }
        for var k: usize = 0; k < count; ++k {
            for var i: usize = 0; i < count; ++i {
                if usize(n->source_order[i]) != k { continue; }
                bound[i] = self._bound(n->fields[i]->range, n->fields[i], &stmts);
            }
        }
        var fields = self.list_builder::<*Expr>();
        var order  = self.list_builder::<u32>();
        for var i: usize = 0; i < count; ++i {
            fields.push(bound[i]);
            order.push(u32(i));
        }
        fields.freeze_into(&(n->fields));
        order.freeze_into(&(n->source_order));
        for var i: usize = 0; i < stmts.size(); ++i { lb.push(stmts[i]); }
        lb.push(static_cast::<*Stmt>(ExpressionStmt::create(self.ctx, n->range, static_cast::<*Expr>(n))));
        return self.synth.stmt_expr(static_cast::<*Expr>(n), &lb, n->type_);
    }

    /// \p e can leave the function or jump: it holds a call that may panic,
    /// or a `try`. Or, in the body of a `try` with a C++ arm, it can throw
    /// (anything not pure): codegen builds a payload in a noexcept lambda
    /// and a noexcept constructor, which would stop the exception short of
    /// the C++ `try` and terminate.
    priv fn _leaves(self, e: *Expr) -> bool {
        if e == &null { return false; }
        if (self._cxx_depth > 0) && (!LowerSynth::pure(e)) { return true; }
        var w = PanicWalk(self.sc);
        w.keep_sites = true;
        w.walk_expr(e);
        return (w.sites.size() > 0) || (w.tries.size() > 0);
    }

    /// `var __kairo_vK = e;` onto \p out, and its value moved out (a record)
    /// or read (anything else).
    priv fn _bound(self, at: SourceRange, e: *Expr, out: *vec::<*Stmt>) -> *Expr {
        var vd = self.synth.local(at, "v", e->type_, e);
        out->push_back(static_cast::<*Stmt>(DeclStmt::create(self.ctx, at, static_cast::<*Decl>(vd))));
        var use = self.synth.use_of(vd, at, Expr::ValueCategory::LValue);
        var c = canon_unqual(e->type_);
        if (c != &null) && (c->kind == TypeKind::RecordType) { return self._rref(at, use, c); }
        return use;
    }

    // === propagation at a call (§4.3, §4.5) ======================================

    fn transform_call_expr(self, n: *CallExpr) -> *Expr {
        var out = ASTWriter::<PanicLowering>::transform_call_expr(n);
        if out != static_cast::<*Expr>(n) { return out; }
        var pc = self._as_call(static_cast::<*Expr>(n));
        if pc.call == &null { return out; }
        return self._held(pc);
    }

    /// A statement that IS a panicking call: the held result is tested and
    /// dropped, with no statement expression around it.
    fn transform_expression_stmt(self, n: *ExpressionStmt) -> vec::<*Stmt> {
        var pc = self._as_call(n->expr);
        if pc.call == &null { return ASTWriter::<PanicLowering>::transform_expression_stmt(n); }
        ASTWriter::<PanicLowering>::transform_call_expr(pc.call);
        self._retype(pc);
        var lb = self.list_builder::<*Stmt>();
        var h = self.synth.bind(n->range, "p", pc.rc, static_cast::<*Expr>(pc.call), &lb);
        if pc.fails { lb.push(self._test_deliver(n->range, h)); }
        var out = vec::<*Stmt>();
        var blk = CompoundStmt::create(self.ctx, n->range);
        lb.freeze_into(&(blk->body));
        out.push_back(static_cast::<*Stmt>(blk));
        return out;
    }

    /// `({ var p = call; if !ok(p) { deliver } (p.value as T&&) })`.
    priv fn _held(self, pc: PanicCall) -> *Expr {
        var at = pc.call->range;
        var orig = static_cast::<*Expr>(pc.call);
        self._retype(pc);
        var lb = self.list_builder::<*Stmt>();
        var h = self.synth.bind(at, "p", pc.rc, orig, &lb);
        if pc.fails { lb.push(self._test_deliver(at, h)); }
        var vt = self._value_of(pc.rc);
        if self.tu.is_void(vt) { return self.synth.stmt_expr(orig, &lb, vt); }
        lb.push(static_cast::<*Stmt>(ExpressionStmt::create(self.ctx, at, self._read_value(at, h, vt))));
        return self.synth.stmt_expr(orig, &lb, vt);
    }

    /// `if !ok(h) { <deliver h> }`.
    priv fn _test_deliver(self, at: SourceRange, h: *VariableDecl) -> *Stmt {
        var stmts = vec::<*Stmt>();
        self._deliver(at, h, &stmts);
        return static_cast::<*Stmt>(ConditionalStmt::create(self.ctx, at, self._not(at, self._ok(at, h)), self._block(at, &stmts), &null));
    }

    /// The call \p e is (parentheses aside), when it may panic: its callee
    /// returns a panic result.
    priv fn _as_call(self, e_in: *Expr) -> PanicCall {
        var r = PanicCall();
        var e = self.tu.strip_parens(e_in);
        if (e == &null) || (!isa::<CallExpr>(e)) || e->is_poisoned() { return r; }
        var c = cast::<CallExpr>(e);
        var f = self._callee_fn(c);
        if f == &null {
            // Through a `fn` value: its type carries the set (§2.10).
            var ce = self.tu.strip_parens(c->callee);
            if (ce == &null) || (ce->type_ == &null) { return r; }
            var fp = dyn_cast::<FunctionPointerType>(canon_unqual(ce->type_));
            if fp == &null { return r; }
            var frc = self._fn_type_result(fp);
            if frc == &null { return r; }
            r.call  = c;
            r.rc    = frc;
            r.fails = true;
            return r;
        }
        var rc = self._result_of(f);
        if rc == &null { return r; }
        var set = vec::<*Type>();
        r.call  = c;
        r.rc    = rc;
        r.fails = panic_set_of_fn(&(self.tu), f, &set) == PanicKnown::Set;
        return r;
    }

    /// The function a call selected, or null (PanicWalk's rule).
    priv fn _callee_fn(self, c: *CallExpr) -> *FunctionDecl {
        if (c->ctor_decl != &null) && isa::<FunctionDecl>(c->ctor_decl) { return cast::<FunctionDecl>(c->ctor_decl); }
        var e = self.tu.strip_parens(c->callee);
        if e == &null { return &null; }
        var d: *Decl = &null;
        if isa::<NamedIdentExpr>(e) { d = cast::<NamedIdentExpr>(e)->resolved_decl; }
        else if isa::<ChainExpr>(e) {
            var ch = cast::<ChainExpr>(e);
            if ch->steps.size() > 0 {
                var st = ch->steps.get(ch->steps.size() - 1);
                d = st->resolved_decl;
                if (d == &null) && (st->name != &null) { d = st->name->resolved_decl; }
            }
        }
        return dyn_cast::<FunctionDecl>(d);
    }

    /// The call now yields its panic result.
    priv fn _retype(self, pc: PanicCall) {
        pc.call->type_          = pc.rc;
        pc.call->value_category = Expr::ValueCategory::RValue;
    }

    // === delivering an error =========================================================

    /// The error held in \p h, to the innermost target: returned (moved, or
    /// forwarded into the result), or put into the `try`'s slot before a
    /// jump to its dispatch.
    priv fn _deliver(self, at: SourceRange, h: *VariableDecl, out: *vec::<*Stmt>) {
        ICE_IF(self._targets.size() == 0, "PanicLowering: an error with nowhere to go; PanicEffectChecking gate failure");
        var tg = self._targets[self._targets.size() - 1];
        var use = self.synth.use_of(h, at, Expr::ValueCategory::LValue);
        var v: *Expr = &null;
        if canon_unqual(h->type_) == canon_unqual(tg.type_) { v = self._rref(at, use, tg.type_); }
        else { v = self._fwd(at, PanicOp::Fwd, tg.type_, use); }
        if tg.slot == &null {
            out->push_back(static_cast::<*Stmt>(ReturnStmt::create(self.ctx, at, v)));
            return;
        }
        out->push_back(static_cast::<*Stmt>(ExpressionStmt::create(self.ctx, at, self._slot_put(at, tg.slot, v))));
        out->push_back(static_cast::<*Stmt>(JumpIntrinsicStmt::create(self.ctx, at, tg.label)));
    }

    priv fn _holder_of(self, d: *Decl) -> *VariableDecl {
        var k = self._holders.size();
        while k > 0 {
            k -= 1;
            if self._holders[k].decl == d { return self._holders[k].holder; }
        }
        return &null;
    }

    // === try / catch (§4.4) ==========================================================

    fn transform_try_catch_stmt(self, n: *TryCatchStmt) -> vec::<*Stmt> {
        var at = n->range;
        var arms = vec::<PanicArm>();
        var cxx  = vec::<PanicArm>();
        for var i: usize = 0; i < n->arms.size(); ++i {
            var a = n->arms.get(i);
            var pa = PanicArm();
            pa.filter  = a->filter;
            pa.decl    = a->decl;
            pa.is_dead = a->is_dead;
            pa.sbody   = a->body;
            pa.range   = a->range;
            if (a->decl != &null) && isa::<VariableDecl>(a->decl) { pa.is_const = cast::<VariableDecl>(a->decl)->storage == StorageClass::Const; }
            pa.is_cxx  = a->is_cxx;
            if pa.is_cxx { cxx.push_back(pa); } else { arms.push_back(pa); }
        }
        var out = vec::<*Stmt>();
        // Nothing reaches it: the body alone; no panic arm runs (a C++ one
        // may: the body is its C++ `try`).
        if n->reach.size() == 0 {
            if cxx.size() > 0 { self._cxx_depth += 1; }
            var only = self.transform_stmt_scalar(static_cast::<*Stmt>(n->try_body));
            if cxx.size() > 0 { self._cxx_depth -= 1; }
            if cxx.size() > 0 { only = self._cxx_try(at, only, &cxx, &null); }
            out.push_back(only);
            return out;
        }

        // Direct: one statement, the one call that can panic, first. Not
        // with a C++ arm: the dispatch would sit inside the C++ `try`, and
        // a panic arm is outside its `try`.
        var shape = (-1) if (cxx.size() > 0) else (self._direct_shape(n));
        if shape >= 0 {
            var s  = n->try_body->body[0];
            var pc = self._as_call(self._direct_call(s, shape));
            ASTWriter::<PanicLowering>::transform_call_expr(pc.call);
            self._retype(pc);
            var lb = self.list_builder::<*Stmt>();
            var h = self.synth.bind(at, "p", pc.rc, static_cast::<*Expr>(pc.call), &lb);
            var okv = vec::<*Stmt>();
            if shape > 0 {
                var vt = self._value_of(pc.rc);
                self._replace_call(s, shape, self._read_value(at, h, vt));
                var done = self.transform_stmt(s);
                for var i: usize = 0; i < done.size(); ++i { okv.push_back(done[i]); }
            }
            var errv = vec::<*Stmt>();
            errv.push_back(self._dispatch(at, h, &arms, &null, &(n->reach)));
            lb.push(static_cast::<*Stmt>(ConditionalStmt::create(self.ctx, at, self._ok(at, h), self._block(at, &okv), self._block(at, &errv))));
            var blk = CompoundStmt::create(self.ctx, at);
            lb.freeze_into(&(blk->body));
            out.push_back(static_cast::<*Stmt>(blk));
            return out;
        }

        // The slot form.
        var st = self._slot_type(at, &(n->reach));
        var lb = self.list_builder::<*Stmt>();
        var slot = self._raw(at, "s", st, &lb);
        var tg = PanicTarget();
        tg.slot  = slot;
        tg.type_ = st;
        tg.label = self.synth.fresh(at, "catch");
        var done = self.synth.fresh(at, "done");
        self._targets.push_back(tg);
        if cxx.size() > 0 { self._cxx_depth += 1; }
        var body = self.transform_stmt_scalar(static_cast::<*Stmt>(n->try_body));
        if cxx.size() > 0 { self._cxx_depth -= 1; }
        self._targets.pop_back();
        // The C++ `try` holds the body only; a failing site's jump to the
        // dispatch leaves it (a goto out of a C++ try block is legal).
        if cxx.size() > 0 { body = self._cxx_try(at, body, &cxx, &null); }
        lb.push(body);
        lb.push(static_cast::<*Stmt>(JumpIntrinsicStmt::create(self.ctx, at, done)));
        lb.push(static_cast::<*Stmt>(LabelIntrinsicStmt::create(self.ctx, at, tg.label)));
        lb.push(self._catch_block(at, slot, st, &arms, &null));
        lb.push(static_cast::<*Stmt>(LabelIntrinsicStmt::create(self.ctx, at, done)));
        var blk = CompoundStmt::create(self.ctx, at);
        lb.freeze_into(&(blk->body));
        out.push_back(static_cast::<*Stmt>(blk));
        return out;
    }

    fn transform_try_catch_expr(self, n: *TryCatchExpr) -> *Expr {
        var at = n->range;
        var arms = vec::<PanicArm>();
        var cxx  = vec::<PanicArm>();
        for var i: usize = 0; i < n->catch_arms.size(); ++i {
            var a = n->catch_arms.get(i);
            var pa = PanicArm();
            pa.filter   = a->filter;
            pa.decl     = a->decl;
            pa.is_const = a->is_const;
            pa.is_dead  = a->is_dead;
            pa.ebody    = a->body;
            pa.range    = a->range;
            pa.is_cxx   = a->is_cxx;
            if pa.is_cxx { cxx.push_back(pa); } else { arms.push_back(pa); }
        }
        if (n->reach.size() == 0) && (cxx.size() == 0) { return self.transform_expr(n->try_expr); }

        var t = self._value_type(n->type_);
        var orig = static_cast::<*Expr>(n);
        var lb = self.list_builder::<*Stmt>();
        var res: *VariableDecl = &null;
        if !self.tu.is_void(t) { res = self._raw(at, "r", t, &lb); }

        var pc = self._as_call(n->try_expr);
        if n->reach.size() == 0 {
            // Only C++ arms: `try { r <- operand } catch (T& e) { r <- arm }`.
            self._cxx_depth += 1;
            var v = self.transform_expr(n->try_expr);
            self._cxx_depth -= 1;
            var bv = vec::<*Stmt>();
            if res != &null { bv.push_back(static_cast::<*Stmt>(ExpressionStmt::create(self.ctx, at, self._slot_put(at, res, v)))); }
            else { bv.push_back(static_cast::<*Stmt>(ExpressionStmt::create(self.ctx, at, v))); }
            lb.push(self._cxx_try(at, static_cast::<*Stmt>(self._block(at, &bv)), &cxx, res));
        } else if (cxx.size() == 0) && (pc.call != &null) && (self._sites_in_expr(n->try_expr) == 1) {
            // Direct: the operand IS the one call that can panic.
            ASTWriter::<PanicLowering>::transform_call_expr(pc.call);
            self._retype(pc);
            var h = self.synth.bind(at, "p", pc.rc, static_cast::<*Expr>(pc.call), &lb);
            var okv = vec::<*Stmt>();
            if res != &null {
                okv.push_back(static_cast::<*Stmt>(ExpressionStmt::create(self.ctx, at, self._slot_put(at, res, self._read_value(at, h, self._value_of(pc.rc))))));
            }
            var errv = vec::<*Stmt>();
            errv.push_back(self._dispatch(at, h, &arms, res, &(n->reach)));
            lb.push(static_cast::<*Stmt>(ConditionalStmt::create(self.ctx, at, self._ok(at, h), self._block(at, &okv), self._block(at, &errv))));
        } else {
            var st = self._slot_type(at, &(n->reach));
            var slot = self._raw(at, "s", st, &lb);
            var tg = PanicTarget();
            tg.slot  = slot;
            tg.type_ = st;
            tg.label = self.synth.fresh(at, "catch");
            var done = self.synth.fresh(at, "done");
            self._targets.push_back(tg);
            if cxx.size() > 0 { self._cxx_depth += 1; }
            var v = self.transform_expr(n->try_expr);
            if cxx.size() > 0 { self._cxx_depth -= 1; }
            self._targets.pop_back();
            var bv = vec::<*Stmt>();
            if res != &null { bv.push_back(static_cast::<*Stmt>(ExpressionStmt::create(self.ctx, at, self._slot_put(at, res, v)))); }
            else { bv.push_back(static_cast::<*Stmt>(ExpressionStmt::create(self.ctx, at, v))); }
            bv.push_back(static_cast::<*Stmt>(JumpIntrinsicStmt::create(self.ctx, at, done)));
            var bs = static_cast::<*Stmt>(self._block(at, &bv));
            lb.push((self._cxx_try(at, bs, &cxx, res)) if (cxx.size() > 0) else (bs));
            // A C++ arm ends below its `try`, not at the jump inside it: on
            // to the value, past the dispatch.
            if cxx.size() > 0 { lb.push(static_cast::<*Stmt>(JumpIntrinsicStmt::create(self.ctx, at, done))); }
            lb.push(static_cast::<*Stmt>(LabelIntrinsicStmt::create(self.ctx, at, tg.label)));
            lb.push(self._catch_block(at, slot, st, &arms, res));
            lb.push(static_cast::<*Stmt>(LabelIntrinsicStmt::create(self.ctx, at, done)));
        }
        if res != &null {
            var take = PanicOpExpr::create(self.ctx, at, PanicOp::SlotTake, &null, self.synth.use_of(res, at, Expr::ValueCategory::LValue));
            take->type_          = t;
            take->value_category = Expr::ValueCategory::RValue;
            lb.push(static_cast::<*Stmt>(ExpressionStmt::create(self.ctx, at, static_cast::<*Expr>(take))));
        }
        return self.synth.stmt_expr(orig, &lb, t);
    }

    /// The C++ `try` of a `try` with C++ exception arms (§3.5, §4.5a H):
    /// \p body, already lowered, inside a TryCatchStmt marked `cxx` whose
    /// arms are those arms, each binding a reference to the exception and
    /// lowered with the `try`'s target closed (an arm is outside its `try`).
    /// Every Kairo function stays noexcept: an exception this does not catch
    /// reaches the frame's boundary and terminates there, as one thrown
    /// anywhere else in a noexcept frame does. Only a call lexically inside
    /// the `try` is covered; one inside a Kairo callee stops at that
    /// callee's own boundary unless it is `@unwind` (c-cpp-exceptions.mdx).
    priv fn _cxx_try(self, at: SourceRange, body: *Stmt, cxx: *vec::<PanicArm>, res: *VariableDecl) -> *Stmt {
        var blk = dyn_cast::<CompoundStmt>(body);
        if blk == &null {
            var one = vec::<*Stmt>();
            one.push_back(body);
            blk = self._block(at, &one);
        }
        var t = TryCatchStmt::create(self.ctx, at, blk);
        t->cxx = true;
        var cas = vec::<CatchArm>();
        for var i: usize = 0; i < cxx->size(); ++i {
            var a = &((*cxx)[i]);
            var stmts = vec::<*Stmt>();
            if (a->decl != &null) && isa::<VariableDecl>(a->decl) {
                var vd = cast::<VariableDecl>(a->decl);
                var et = canon_unqual(a->filter->canonical);
                if a->is_const { et = self.sc->types->qualified(et, QUAL_CONST()); }
                vd->type_   = self.sc->types->cxx_lref(et);
                vd->storage = StorageClass::Var;   // the `const` is in the type.
                vd->init    = &null;
                self._cxx_binders.push_back(a->decl);
            }
            self._arm_body(a, &null, res, &stmts);
            var ca = CatchArm{};
            ca.filter  = a->filter;
            ca.binding = &null;
            ca.body    = self._block(a->range, &stmts);
            ca.range   = a->range;
            ca.decl    = a->decl;
            ca.is_dead = false;
            ca.is_cxx  = true;
            cas.push_back(ca);
        }
        t->arms.from_vec(&cas, self.ctx);
        return static_cast::<*Stmt>(t);
    }

    priv fn _is_cxx_binder(self, d: *Decl) -> bool {
        for var i: usize = 0; i < self._cxx_binders.size(); ++i { if self._cxx_binders[i] == d { return true; } }
        return false;
    }

    /// `{ var __kairo_e = take(slot); <dispatch e> }`: the error moved out
    /// of the slot, which is destroyed, before any arm runs.
    priv fn _catch_block(self, at: SourceRange, slot: *VariableDecl, st: *Type, arms: *vec::<PanicArm>, res: *VariableDecl) -> *Stmt {
        var take = PanicOpExpr::create(self.ctx, at, PanicOp::SlotTake, &null, self.synth.use_of(slot, at, Expr::ValueCategory::LValue));
        take->type_          = st;
        take->value_category = Expr::ValueCategory::RValue;
        var lb = self.list_builder::<*Stmt>();
        var e = self.synth.bind(at, "e", st, static_cast::<*Expr>(take), &lb);
        lb.push(self._dispatch(at, e, arms, res));
        var blk = CompoundStmt::create(self.ctx, at);
        lb.freeze_into(&(blk->body));
        return static_cast::<*Stmt>(blk);
    }

    /// The arms over the error held in \p h (not Ok): an `if` chain, each
    /// typed arm its type's compare, a bare arm the final `else`, and with
    /// none, what is left delivered to the next target. Typed arms whose
    /// type \p h cannot hold (dead) get no compare.
    ///
    /// \p reach, when given, is what can actually be held: a direct form's
    /// callee may be an override or a conformer, whose result is its base's
    /// or requirement's and so names types its own (smaller) set never
    /// panics with. Those get no arm and are not "left" to deliver: the
    /// enclosing function's set need not hold them.
    priv fn _dispatch(self, at: SourceRange, h: *VariableDecl, arms: *vec::<PanicArm>, res: *VariableDecl,
                      reach: *FrozenList::<*Type> = &null) -> *Stmt {
        var hset = self.tu.record_args(self.tu.as_value(h->type_));
        var can = vec::<*Type>();
        if reach != &null { for var i: usize = 0; i < reach->size(); ++i { can.push_back(canon_unqual((*reach)[i])); } }
        var held = vec::<*Type>();
        for var i: usize = 1; i < hset.size(); ++i {
            var c = canon_unqual(hset[i]);
            if (reach == &null) || pset_has(&can, c) { held.push_back(c); }
        }

        var typed = vec::<usize>();
        var caught = vec::<*Type>();
        var bare: i64 = -1;
        for var i: usize = 0; i < arms->size(); ++i {
            var a = &((*arms)[i]);
            if a->filter == &null { bare = i64(i); continue; }
            if a->is_dead || (a->filter->canonical == &null) { continue; }
            var c = canon_unqual(a->filter->canonical);
            if !pset_has(&held, c) { continue; }
            typed.push_back(i);
            caught.push_back(c);
        }

        // The tail: the bare arm, or what is left delivered, when anything
        // is left; nothing at all otherwise (a bare arm then never runs).
        var tail: *Stmt = &null;
        var left = false;
        for var i: usize = 0; i < held.size(); ++i { if !pset_has(&caught, held[i]) { left = true; } }
        if left && (bare >= 0) {
            tail = static_cast::<*Stmt>(self._bare_arm(at, h, &((*arms)[usize(bare)]), res));
        } else if left {
            var stmts = vec::<*Stmt>();
            self._deliver(at, h, &stmts);
            tail = static_cast::<*Stmt>(self._block(at, &stmts));
        }
        var k = typed.size();
        while k > 0 {
            k -= 1;
            var a = &((*arms)[typed[k]]);
            var arm = self._typed_arm(at, h, a, caught[k], res);
            if tail == &null { tail = static_cast::<*Stmt>(arm); continue; }   // the last one left needs no compare.
            tail = static_cast::<*Stmt>(ConditionalStmt::create(self.ctx, a->range, self.q.panic_holds(a->range, self.synth.use_of(h, at, Expr::ValueCategory::LValue), caught[k]), arm, tail));
        }
        if tail == &null {
            var none = vec::<*Stmt>();
            tail = static_cast::<*Stmt>(self._block(at, &none));
        }
        return tail;
    }

    /// `{ E& e = <h's E payload>; body }`.
    priv fn _typed_arm(self, at: SourceRange, h: *VariableDecl, a: *PanicArm, e: *Type, res: *VariableDecl) -> *CompoundStmt {
        var stmts = vec::<*Stmt>();
        if (a->decl != &null) && isa::<VariableDecl>(a->decl) {
            var vd = cast::<VariableDecl>(a->decl);
            var et = e;
            if a->is_const { et = self.sc->types->qualified(e, QUAL_CONST()); }
            vd->type_   = self.sc->types->cxx_lref(et);
            vd->storage = StorageClass::Var;   // the `const` is in the type.
            vd->init    = self.q.panic_error_ref(a->range, self.synth.use_of(h, at, Expr::ValueCategory::LValue), e);
            stmts.push_back(static_cast::<*Stmt>(DeclStmt::create(self.ctx, a->range, static_cast::<*Decl>(vd))));
        }
        self._arm_body(a, h, res, &stmts);
        return self._block(a->range, &stmts);
    }

    /// `{ var e: Panic<void, L...> = fwd(h); body }`: the bare binding is
    /// what is left, as its own result; a re-panic of it forwards it.
    priv fn _bare_arm(self, at: SourceRange, h: *VariableDecl, a: *PanicArm, res: *VariableDecl) -> *CompoundStmt {
        var stmts = vec::<*Stmt>();
        var holder = h;
        if (a->decl != &null) && isa::<VariableDecl>(a->decl) {
            var vd = cast::<VariableDecl>(a->decl);
            var bt = vd->type_;
            if (bt != &null) && (self.q.panic_adt(bt) != &null) && (self.tu.record_args(self.tu.as_value(bt)).size() > 1) {
                var use = self.synth.use_of(h, at, Expr::ValueCategory::LValue);
                vd->init    = (self._rref(at, use, bt)) if (canon_unqual(bt) == canon_unqual(h->type_)) else (self._fwd(at, PanicOp::Fwd, canon_unqual(bt), use));
                vd->storage = StorageClass::Var;
                stmts.push_back(static_cast::<*Stmt>(DeclStmt::create(self.ctx, a->range, static_cast::<*Decl>(vd))));
                holder = vd;
            }
        }
        self._arm_body(a, holder, res, &stmts);
        return self._block(a->range, &stmts);
    }

    /// The arm's body after its binding, lowered with the `try`'s target
    /// closed: a statement body as it is, a value put into the result slot,
    /// an arm that leaves as its statement.
    priv fn _arm_body(self, a: *PanicArm, holder: *VariableDecl, res: *VariableDecl, out: *vec::<*Stmt>) {
        var ph = PanicHolder();
        ph.decl   = a->decl;
        ph.holder = holder;
        self._holders.push_back(ph);
        if a->sbody != &null {
            out->push_back(self.transform_stmt_scalar(static_cast::<*Stmt>(a->sbody)));
        } else if a->ebody != &null {
            var se = dyn_cast::<StmtExpr>(a->ebody);
            if (se != &null) && se->is_jump {
                out->push_back(self.transform_stmt_scalar(static_cast::<*Stmt>(se->body)));
            } else {
                var v = self.transform_expr(a->ebody);
                // An arm of type `!` (`crash!()`, a call of a `-> !` fn) fits
                // any arm type (§3.2) but has no value to put: as a statement
                // it never returns, so the slot is never read on its path. Put
                // into the slot it is a cast from `void` C++ refuses.
                var never = (v->type_ != &null) && self.tu.is_never(canon_unqual(v->type_));
                if (res != &null) && (!never) { v = self._slot_put(a->range, res, v); }
                out->push_back(static_cast::<*Stmt>(ExpressionStmt::create(self.ctx, a->range, v)));
            }
        }
        self._holders.pop_back();
    }

    // === the direct form's shape ======================================================

    /// The direct form applies when the body is one statement whose call
    /// is the only site that can panic in the `try` and is evaluated first:
    /// 0 the statement is the call, 1 `x = call` (x a pure place), 2
    /// `return call`, 3 `var x = call`. -1 otherwise.
    priv fn _direct_shape(self, n: *TryCatchStmt) -> i32 {
        if (n->try_body == &null) || (n->try_body->body.size() != 1) { return -1; }
        var s = n->try_body->body[0];
        var shape: i32 = -1;
        if isa::<ExpressionStmt>(s) {
            var e = self.tu.strip_parens(cast::<ExpressionStmt>(s)->expr);
            if (e != &null) && isa::<CallExpr>(e) { shape = 0; }
            else if (e != &null) && isa::<AssignOperatorExpr>(e) {
                var asg = cast::<AssignOperatorExpr>(e);
                if (asg->resolved_op == &null) && (asg->op_token.kind == TokenKind::OpEqual) && LowerSynth::pure(asg->lhs) { shape = 1; }
            }
        } else if isa::<ReturnStmt>(s) {
            if cast::<ReturnStmt>(s)->value != &null { shape = 2; }
        } else if isa::<DeclStmt>(s) {
            var vd = dyn_cast::<VariableDecl>(cast::<DeclStmt>(s)->decl);
            if (vd != &null) && (vd->init != &null) && (!vd->raw_slot) && (vd->storage != StorageClass::Static) { shape = 3; }
        }
        if shape < 0 { return -1; }
        var pc = self._as_call(self._direct_call(s, shape));
        if (pc.call == &null) || (!pc.fails) { return -1; }
        var w = PanicWalk(self.sc);
        w.keep_sites = true;
        w.walk_stmt(static_cast::<*Stmt>(n->try_body));
        if self._reaching(&w) != 1 { return -1; }
        return shape;
    }

    priv fn _direct_call(self, s: *Stmt, shape: i32) -> *Expr {
        if shape == 0 { return cast::<ExpressionStmt>(s)->expr; }
        if shape == 1 { return cast::<AssignOperatorExpr>(self.tu.strip_parens(cast::<ExpressionStmt>(s)->expr))->rhs; }
        if shape == 2 { return cast::<ReturnStmt>(s)->value; }
        return cast::<VariableDecl>(cast::<DeclStmt>(s)->decl)->init;
    }

    priv fn _replace_call(self, s: *Stmt, shape: i32, v: *Expr) {
        if shape == 1 { cast::<AssignOperatorExpr>(self.tu.strip_parens(cast::<ExpressionStmt>(s)->expr))->rhs = v; }
        else if shape == 2 { cast::<ReturnStmt>(s)->value = v; }
        else if shape == 3 { cast::<VariableDecl>(cast::<DeclStmt>(s)->decl)->init = v; }
    }

    /// How many sites of a walk's body reach the `try` around it.
    priv fn _reaching(self, w: *PanicWalk) -> usize {
        var n: usize = 0;
        for var i: usize = 0; i < w->sites.size(); ++i { if w->sites[i].left.size() > 0 { n += 1; } }
        return n;
    }

    priv fn _sites_in_expr(self, e: *Expr) -> usize {
        var w = PanicWalk(self.sc);
        w.keep_sites = true;
        w.walk_expr(e);
        return self._reaching(&w);
    }

    // === helpers =========================================================================

    /// `Panic<void, reach...>`, a `try`'s slot.
    priv fn _slot_type(self, at: SourceRange, reach: *FrozenList::<*Type>) -> *Type {
        var set = vec::<*Type>();
        for var i: usize = 0; i < reach->size(); ++i { set.push_back((*reach)[i]); }
        var st = PanicSets(self.sc).form(at, self.sc->builtin(BuiltinKind::Void), &set);
        ICE_IF(st == &null, "PanicLowering: a try's set did not form; PanicSets reported the collision and the lowerings should not run");
        return st;
    }

    /// A raw-storage local of \p t, declared on \p lb.
    priv fn _raw(self, at: SourceRange, hint: string, t: *Type, lb: *ListBuilder::<*Stmt>) -> *VariableDecl {
        var vd = self.synth.local(at, hint, t, &null);
        vd->raw_slot = true;
        lb->push(static_cast::<*Stmt>(DeclStmt::create(self.ctx, at, static_cast::<*Decl>(vd))));
        return vd;
    }

    priv fn _slot_put(self, at: SourceRange, slot: *VariableDecl, v: *Expr) -> *Expr {
        var p = PanicOpExpr::create(self.ctx, at, PanicOp::SlotPut, v, self.synth.use_of(slot, at, Expr::ValueCategory::LValue));
        p->type_          = self.sc->builtin(BuiltinKind::Void);
        p->value_category = Expr::ValueCategory::RValue;
        return static_cast::<*Expr>(p);
    }

    priv fn _fwd(self, at: SourceRange, which: PanicOp, to: *Type, v: *Expr) -> *Expr {
        var p = PanicOpExpr::create(self.ctx, at, which, v, &null);
        p->type_          = to;
        p->value_category = Expr::ValueCategory::RValue;
        return static_cast::<*Expr>(p);
    }

    /// The value type T of a panic result type.
    priv fn _value_of(self, rc: *Type) -> *Type {
        var args = self.tu.record_args(self.tu.as_value(rc));
        ICE_IF(args.size() == 0, "PanicLowering: a panic result with no value type");
        return canon_unqual(args[0]);
    }

    /// `(h.value as T&&)`: the value moved out of the held result.
    priv fn _read_value(self, at: SourceRange, h: *VariableDecl, vt: *Type) -> *Expr {
        var r = self.q.panic_value_ref(at, self.synth.use_of(h, at, Expr::ValueCategory::LValue), vt);
        return self._rref(at, r, vt);
    }

    priv fn _ok(self, at: SourceRange, h: *VariableDecl) -> *Expr {
        return self.q.panic_is_ok(at, self.synth.use_of(h, at, Expr::ValueCategory::LValue));
    }

    priv fn _not(self, at: SourceRange, e: *Expr) -> *Expr {
        var u = UnaryOperatorExpr::create(self.ctx, at, e, self.synth.punct(at, TokenKind::OpExclaim), UnaryOperatorExpr::Fix::Prefix);
        u->type_          = self.sc->builtin(BuiltinKind::Bool);
        u->value_category = Expr::ValueCategory::RValue;
        return static_cast::<*Expr>(u);
    }

    priv fn _rref(self, at: SourceRange, e: *Expr, t: *Type) -> *Expr {
        return self.synth.cast_to(at, e, self.sc->types->cxx_rref(canon_unqual(t)), CastMode::Default);
    }

    priv fn _block(self, at: SourceRange, stmts: *vec::<*Stmt>) -> *CompoundStmt {
        var blk = CompoundStmt::create(self.ctx, at);
        var lb = self.list_builder::<*Stmt>();
        for var i: usize = 0; i < stmts->size(); ++i { lb.push((*stmts)[i]); }
        lb.freeze_into(&(blk->body));
        return blk;
    }

    /// \p v as \p t when only a builtin conversion lies between them (the
    /// payload is built from braces, which refuse a narrowing).
    priv fn _conv(self, v: *Expr, t: *Type) -> *Expr {
        if (v == &null) || (v->type_ == &null) { return v; }
        var have = canon_unqual(v->type_);
        if (have != &null) && isa::<CXXRValueRefType>(have) { have = canon_unqual(cast::<CXXRValueRefType>(have)->referee); }
        if (have != &null) && isa::<CXXLValueRefType>(have) { have = canon_unqual(cast::<CXXLValueRefType>(have)->referee); }
        var want = canon_unqual(t);
        if (have == &null) || (want == &null) || (have == want) { return v; }
        if (have->kind == TypeKind::RecordType) || (want->kind == TypeKind::RecordType) { return v; }
        if self.tu.is_never(have) { return v; }
        return self.synth.cast_to(v->range, v, want, CastMode::Default);
    }

    /// A local or by-value parameter named whole, moved: it is the value's
    /// last use (a `return` or a `panic` leaves), which C++ would move from
    /// on its own in a plain `return x`. Anything else as it is.
    priv fn _moved_local(self, v: *Expr) -> *Expr {
        var e = self.tu.strip_parens(v);
        if (e == &null) || (!isa::<NamedIdentExpr>(e)) || (e->type_ == &null) { return v; }
        var c = canon_unqual(e->type_);
        if (c == &null) || (c->kind != TypeKind::RecordType) { return v; }
        var d = cast::<NamedIdentExpr>(e)->resolved_decl;
        if d == &null { return v; }
        var t: *Type = &null;
        if isa::<VariableDecl>(d) {
            var vd = cast::<VariableDecl>(d);
            if (vd->storage == StorageClass::Static) || vd->raw_slot { return v; }
            var dc = reinterpret_cast::<*DeclContext>(vd->semantic_dc);
            if (dc == &null) || dc->is_translation_unit() || dc->is_type_scope() { return v; }
            var o = dc->owner_decl();
            if (o != &null) && isa::<ModuleDecl>(o) { return v; }
            t = vd->type_;
        } else if isa::<ParamDecl>(d) {
            var p = cast::<ParamDecl>(d);
            if p->is_self || (p->mode != ParamMode::Value) { return v; }
            t = p->type_;
        } else {
            return v;
        }
        if (t == &null) || (t->canonical == &null) { return v; }
        var tc = canon_unqual(t->canonical);
        if isa::<CXXLValueRefType>(tc) || isa::<CXXRValueRefType>(tc) || (tc != c) { return v; }
        return self._rref(v->range, v, c);
    }
}
