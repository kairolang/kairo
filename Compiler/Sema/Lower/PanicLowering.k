/// --- The Kairo Project ------------------- Sema/Lower/PanicLowering.k --- ///
///
///   \brief A panic is a returned value: signatures, `return`, `panic`,
///          propagation at a call, and `try` / `catch` as tag compares.
///
///   \detail
///     A function whose final set (EffectPropagation) is not empty returns
///     `Panic<T, E...>` (Compiler/Spec/Panic.md#paniclowering), formed here with PanicSets::form
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
///       a + b (op + may panic) -> OperatorLowering::lower_one's call(s),
///                             each held as f(a) is: `a != b` from `op ==`
///                             is `!(held a.op==(b))` (_op_call)
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
///   \par Generic bodies
///     A generic body's result may name its type parameters: one C++
///     template serves every instance, and CXXSpell spells such a result
///     through `__kairo_pset`, which C++ orders per instance. Nothing here
///     spells what only the instance knows -- an arm's test and binding of
///     a dependent set are PanicOpExpr Holds / ErrorRef, an Err's place is
///     `__kairo_pidx` (EnumLayoutQuery, EmitIR). A call reads its callee's
///     result at its own arguments (panic_call_type), formed. The dependent
///     results a body names are recorded (FunctionDecl::panic_deps) for
///     PanicInstances, below, to form at each live instance in M2.
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
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ----------------------------------------------------------------- ///

ffi "c++" import "Native/Types.hh"
ffi "c++" import "vector"

import AST::ASTSupport::{
    FrozenList,
    create_empty_frozen_list,
}
import AST::Context::InstantiationRegistry::{
    ConformanceRow,
    InstanceEntry,
}
import AST::DeclFacts::{
    decl_extension_of,
    decl_generic_params,
}
import AST::Kind::TypeKind::TypeKind
import AST::Node::Base::{
    Decl,
    Expr,
    Stmt,
    Type,
}
import AST::Node::CanonicalNodes::{
    BuiltinKind,
    QUAL_CONST,
    canon_unqual,
}
import AST::Node::Casting::{
    cast,
    dyn_cast,
    isa,
}
import AST::Node::Declarations::{
    AbiKind,   ClassDecl,    ExtensionDecl, FnModifier, FunctionDecl, ModuleDecl, PanicSetState,
    ParamDecl, StorageClass, StructDecl,    UnionDecl,  VariableDecl,
}
import AST::Node::Expressions
import AST::Node::PrimaryExpressions::{
    ChainExpr,
    NamedIdentExpr,
}
import AST::Node::Statements::{
    CatchArm,   CompoundStmt,      ConditionalStmt,    DeclStmt,  ExpressionStmt,
    IterKind,   JumpIntrinsicStmt, LabelIntrinsicStmt, PanicStmt, RangedForStmt,
    ReturnStmt, TryCatchStmt,
}
import AST::Node::Types::{
    CXXLValueRefType,
    CXXRValueRefType,
    FunctionPointerType,
    NullableType,
    PointerType,
}
import AST::OperatorFacts::OperatorFacts
import AST::ParamMode::ParamMode
import AST::Visitor::ASTWriter::{
    ASTWriter,
    ListBuilder,
}
import Location::SourceRange::SourceRange
import Sema::Check::EffectPropagation::{
    PanicKnown, PanicWalk,  canonical_set, panic_call_receiver, panic_call_set,  panic_call_type,
    panic_dep,  panic_home, panic_in_duck, panic_overridden_at, panic_set_of_fn, pset_has,
}
import Sema::Lower::EnumLayoutLowering::EnumLayoutQuery
import Sema::Lower::LowerSynth::LowerSynth
import Sema::Lower::OperatorLowering::OperatorLowering
import Sema::Resolve::MemberLookup::MemberLookup
import Sema::Resolve::NameLookup::NameLookup
import Sema::SemaContext::{
    SemaContext,
    SemaPhase,
}
import Sema::Type::ArgumentDeduction::Deduction
import Sema::Type::PanicSets::PanicSets
import Sema::Type::Substitution::Substitution
import Sema::Type::TypeUtil::TypeUtil
import Token::Token::Token
import Token::TokenKind::TokenKind

/// Where an error from a site goes: the function's return (`slot` null),
/// or a `try`'s raw slot, filled before a jump to its dispatch.
pub struct PanicTarget {
    var slot:  unsafe *VariableDecl = &null
    var type_: unsafe *Type         = &null ///< the slot's type, or the function's result.
    var label: Token                        ///< the `try`'s dispatch.
    /// Set by a site inside an `eval for` copy that delivers here: the
    /// `try`'s flag, `var __kairo_efjK = false`, declared ahead of its body
    /// (_to_slot); null while none has.
    var efj: unsafe *VariableDecl = &null
}

/// A `try` target (an index into _targets) that a site inside the copy loop
/// _copy_bars[copy] delivers to from outside it.
pub struct PanicCopyExit {
    var copy:   usize = 0
    var target: usize = 0
}

/// A catch arm's binding, and the panic result its error is held in: what
/// a re-panic `panic e` forwards.
pub struct PanicHolder {
    var decl:   unsafe *Decl         = &null
    var holder: unsafe *VariableDecl = &null
}

/// A call that may panic: the call, its result type, and whether its set
/// is non-empty (an override of a panicking base, or a conformer of a
/// panicking requirement, returns the base's or requirement's result even
/// when its own body cannot panic: nothing to test then).
pub struct PanicCall {
    var call:  unsafe *Expressions::CallExpr = &null
    var rc:    unsafe *Type                  = &null
    var fails: bool                          = false
}

/// One catch arm, of either form.
pub struct PanicArm {
    var filter:   unsafe *Type         = &null
    var decl:     unsafe *Decl         = &null
    var is_const: bool                 = false
    var is_dead:  bool                 = false
    var sbody:    unsafe *CompoundStmt = &null ///< the statement form's body.
    var ebody:    unsafe *Expr         = &null ///< the expression form's value (or jump).
    var range:    SourceRange
    var is_cxx:   bool                 = false ///< a C++ exception arm (§3.5).
}

pub class PanicLowering derives ASTWriter<PanicLowering> {
    pub var  sc:    unsafe *SemaContext
    priv var tu:    TypeUtil
    priv var synth: LowerSynth
    priv var q:     EnumLayoutQuery

    priv var _targets: cxx::std::vector<PanicTarget> ///< innermost last; empty in a body that cannot panic, outside a `try`.
    /// Per enclosing `eval for` / pack `for` (a copy loop: EmitIR expands its
    /// body into one C++ lambda per copy), innermost last: _targets.size()
    /// at its entry. A target below that is outside the copy.
    priv var _copy_bars:  cxx::std::vector<usize>
    priv var _copy_exits: cxx::std::vector<PanicCopyExit>
    priv var _holders:    cxx::std::vector<PanicHolder>
    /// The bindings of C++ exception arms: `panic e` of one panics a copy of
    /// the caught object (its arm's type, what the set holds), from here.
    priv var _cxx_binders: cxx::std::vector<unsafe *Decl>
    /// Inside the body of a `try` with a C++ arm: a value that can throw is
    /// computed first too (_leaves).
    priv var _cxx_depth: i32          = 0
    priv var _fn_r:      unsafe *Type = &null ///< the current body's result, or null when it does not panic.
    priv var _fn_t:      unsafe *Type = &null ///< its value type T.
    /// The extension index, built on the first conforming-method question
    /// (_requirement_of): most TUs never ask it.
    priv var _ml:       MemberLookup
    priv var _ml_ready: bool         = false
    /// The function being lowered, and the dependent panic results its body
    /// names so far (_dep): its FunctionDecl::panic_deps.
    priv var _cur:  unsafe *FunctionDecl           = &null
    priv var _deps: cxx::std::vector<unsafe *Type>
    /// Lowers a panicking operator to its call ahead of OperatorLowering
    /// (_op_call); made on the first one. One for the run: the names it
    /// mints stay unique.
    priv var _ol:       OperatorLowering
    priv var _ol_ready: bool             = false

    fn PanicLowering(self, sc: unsafe *SemaContext) {
        self.sc    = sc
        self.ctx   = sc->ctx
        self.tu    = TypeUtil(sc)
        self.synth = LowerSynth(sc)
        self.q     = EnumLayoutQuery(sc)
    }

    fn run(self) {
        self.sc->require_phase(SemaPhase::Checked)
        if self.sc->tu == &null {
            return
        }

        if PanicSets(self.sc).panic_enum() == &null { // no builtin root: nothing can panic.
            return
        }

        ASTWriter<PanicLowering>::run(self, self.sc->tu)
    }

    /// # signatures (§4.1)

    /// The value type of \p f: its return type, `void` when it has none.
    priv fn _value_type(self, rt: unsafe *Type) -> unsafe *Type {
        if rt == &null || rt->canonical == &null {
            return self.sc->builtin(BuiltinKind::Void)
        }

        return canon_unqual(rt->canonical)
    }

    /// What C++ sees \p f return: `Panic<T, E...>` over its final set, or
    /// null when it does not panic. An override returns its base method's
    /// (C++ requires the same return type through the vtable; its own set is
    /// a subset, §2.10), a conforming method its requirement's (the
    /// witness). Recorded on the decl when it is this TU's.
    priv fn _result_of(self, f: unsafe *FunctionDecl) -> unsafe *Type {
        if f == &null {
            return &null
        }

        if f->panic_result != &null {
            return f->panic_result
        }

        if f->is_poisoned() || f->is_noreturn {
            return &null
        }

        if panic_in_duck(f) { // gated (Compiler/Spec/Generics.md#duck-regime).
            return &null
        }

        if f->abi == AbiKind::Override {
            var unsafe *dc                   = f->semantic_dc
            var        cd: unsafe *ClassDecl = &null
            if dc != &null && dc->owner_decl() != &null {
                cd = dyn_cast<ClassDecl>(dc->owner_decl())
            }

            if cd != &null {
                var bt: unsafe *Type = &null
                var unsafe *base = panic_overridden_at(unsafe &self.tu, cd, f, unsafe &bt)
                if base != &null {
                    // A generic base's result at the arguments this class
                    // derives it at: `B<i32>`'s `Panic<T, T>` is
                    // `Panic<i32, i32>`, the type C++ has in B<int>'s vtable.
                    var unsafe *br = self._through(f->range, self._result_of(base), bt)
                    if br != &null {
                        return self._store(f, br)
                    }
                }
            }
        }

        // A conforming method returns its requirement's result, for the
        // override's reason: the witness forwards `self->m(...)` as the
        // requirement's type, and its `requires` test names that exact
        // member pointer type, so a smaller set (even none) cannot change it.
        // A generic interface's at the row's arguments.
        var        row: unsafe *ConformanceRow = &null
        var unsafe *req                        = self._requirement_of(f, unsafe &row)
        if req != &null {
            var unsafe *qr = self._through(
                f->range,
                self._result_of(req),
                if (row != &null) => (row->iface) else => &null,
            )

            if qr != &null {
                return self._store(f, qr)
            }
        }

        var set = cxx::std::vector<unsafe *Type>()
        if panic_set_of_fn(unsafe &self.tu, f, unsafe &set) != PanicKnown::Set {
            return &null
        }

        var        at = if (f->name.range.is_valid()) => (f->name.range) else => f->range
        var unsafe *r = PanicSets(self.sc).form(at, self._value_type(f->return_type), unsafe &set)
        if r == &null {
            return &null
        }

        return self._store(f, r)
    }

    /// The interface requirement \p f implements, from the conformance rows
    /// ConformanceChecking recorded: those declared by \p f's owner (`class
    /// X impl I`, `extend X impl I` holding it) and, for a record's own
    /// method, by its extensions (`extend X impl I` met by X's member).
    /// Null for a method that implements none. The first row wins; one
    /// method meeting two requirements with different sets is ticketed.
    priv fn _requirement_of(self,
                            f:       unsafe *FunctionDecl,
                            out_row: unsafe * unsafe *ConformanceRow) -> unsafe *FunctionDecl {
        if self.sc->instances == &null {
            return &null
        }

        var unsafe *dc = f->semantic_dc
        if dc == &null || dc->owner_decl() == &null {
            return &null
        }

        var unsafe *owner = NameLookup::representative(dc->owner_decl())
        var        by     = cxx::std::vector<unsafe *Decl>()
        if isa<ExtensionDecl>(owner) {
            by.push_back(owner)
        } else if isa<ClassDecl>(owner) || isa<StructDecl>(owner) {
            by.push_back(owner)
            if !self._ml_ready {
                self._ml = MemberLookup(self.sc)
                self._ml.index_extensions()
                self._ml_ready = true
            }

            var unsafe *exts = self._ml.extensions_of_decl(owner)
            if exts != &null {
                for var i: usize = 0;
                i < exts->size();
                ++i {
                    by.push_back(unsafe ((*exts)[i] as unsafe *Decl))
                }
            }
        } else {
            return &null
        }

        var unsafe *me  = NameLookup::representative(f)
        var        rows = cxx::std::vector<unsafe *ConformanceRow>()
        for var i: usize = 0; i < by.size(); ++i {
            self.sc->instances->declared_rows(by[i], unsafe &rows)
        }

        for var r: usize = 0; r < rows.size(); ++r {
            var unsafe *row = rows[r]
            if row == &null {
                continue
            }

            for var i: usize = 0; i < row->witnesses.size() && i < row->reqs.size(); ++i {
                var unsafe *w = row->witnesses[i]
                if w == &null || NameLookup::representative(w) != me {
                    continue
                }

                var unsafe *q = dyn_cast<FunctionDecl>(row->reqs[i])
                if q != &null && (unsafe (q as unsafe *Decl)) != me {
                    *out_row = row
                    return q
                }
            }
        }

        return &null
    }

    /// \p r read through record \p at (a base `B<i32>`, an interface
    /// instance `Src<IOError>`), formed: null \p r stays null; a concrete
    /// \p r, or a null \p at, is \p r.
    priv fn _through(self, at: SourceRange, r: unsafe *Type, rec: unsafe *Type) -> unsafe *Type {
        if r == &null || rec == &null || !panic_dep(r) {
            return r
        }

        var sub = Substitution(self.sc)
        sub.bind_from_record(rec)
        var unsafe *x = sub.substitute(r)
        if x == &null {
            return r
        }

        return self._formed(at, x)
    }

    /// The panic result \p t formed again (PanicSets::form): canonical, its
    /// collisions checked, its formation noted. What a substituted result
    /// goes through, so it is the type every other former of the same set
    /// gets. Anything else as it is.
    priv fn _formed(self, at: SourceRange, t: unsafe *Type) -> unsafe *Type {
        if t == &null || self.q.panic_adt(t) == &null {
            return t
        }

        var args = self.tu.record_args(self.tu.as_value(t))
        if args.size() == 0 {
            return t
        }

        var els = cxx::std::vector<unsafe *Type>()
        for var i: usize = 1; i < args.size(); ++i {
            els.push_back(canon_unqual(args[i]))
        }

        var unsafe *r = PanicSets(self.sc).form(at, canon_unqual(args[0]), unsafe &els)
        return if (r != &null) => (r) else => t
    }

    /// A panic result the current body names that is still dependent (a
    /// generic body): each instance forms it at its arguments
    /// (FunctionDecl::panic_deps, PanicInstances), so C++ has the ids of
    /// its elements there.
    priv fn _dep(self, t: unsafe *Type) {
        if t == &null || !panic_dep(t) || self._cur == &null {
            return
        }

        var unsafe *c = canon_unqual(t)
        for var i: usize = 0; i < self._deps.size(); ++i {
            if self._deps[i] == c {
                return
            }
        }

        self._deps.push_back(c)
    }

    /// \p r as \p f's result, on every link of its chain in this TU (a
    /// `where` group's links are distinct bodies: only \p f). Another TU's
    /// decl wrote its own when that TU lowered.
    priv fn _store(self, f: unsafe *FunctionDecl, r: unsafe *Type) -> unsafe *Type {
        var fid = self.sc->ctx->fid
        if f->where_lead != &null {
            if self.tu.fid_of(f) == fid {
                f->panic_result = r
            }

            return r
        }

        var unsafe *cur = f
        for var guard: u32 = 0; guard < 4096; ++guard {
            if self.tu.fid_of(cur) == fid {
                cur->panic_result = r
            }

            cur = cur->next_in_chain()
            if cur == f || cur == &null {
                break
            }
        }

        return r
    }

    /// A closure's result: its final set (declared, §2.2) over its value type.
    priv fn _closure_result(self, c: unsafe *Expressions::ClosureExpr) -> unsafe *Type {
        if c->panic_result != &null {
            return c->panic_result
        }

        var panics = ((c->modifiers as u16) & (FnModifier::IsPanic as u16)) != 0
        if !panics || c->is_noreturn {
            return &null
        }

        var set = cxx::std::vector<unsafe *Type>()
        if c->panic_set.size() > 0 {
            if !canonical_set(unsafe &self.tu, &c->panic_set, unsafe &set) {
                return &null
            }
        } else if c->panic_state == PanicSetState::Final {
            for var i: usize = 0; i < c->panic_eff.size(); ++i {
                set.push_back(c->panic_eff[i])
            }
        }

        if set.size() == 0 {
            return &null
        }

        var unsafe *r = PanicSets(self.sc).form(
            c->range,
            self._value_type(c->return_type),
            unsafe &set,
        )

        c->panic_result = r
        self._dep(r)
        return r
    }

    /// A panicking `fn` type's C++ result, formed and recorded on the
    /// canonical node the first time any TU meets it (CXXSpell spells the
    /// value type from it); its parameters' and result's `fn` types too.
    priv fn _fn_type_result(self, fp_in: unsafe *FunctionPointerType) -> unsafe *Type {
        if fp_in == &null {
            return &null
        }

        var unsafe *fp = fp_in
        if fp->canonical != &null && isa<FunctionPointerType>(canon_unqual(fp->canonical)) {
            fp = cast<FunctionPointerType>(canon_unqual(fp->canonical))
        }

        if fp->panic_result != &null {
            return fp->panic_result
        }

        if fp->is_dependent() || fp->is_instantiation_dependent() {
            return &null
        }

        for var i: usize = 0; i < fp->params.size(); ++i {
            self._note_type(fp->params[i])
        }

        self._note_type(fp->return_type)
        if !fp->canon_panics || fp->panic_set.size() == 0 {
            return &null
        }

        var set = cxx::std::vector<unsafe *Type>()
        for var i: usize = 0; i < fp->panic_set.size(); ++i {
            set.push_back(fp->panic_set[i])
        }

        var unsafe *r = PanicSets(self.sc).form(
            fp->range,
            self._value_type(fp->return_type),
            unsafe &set,
        )

        fp->panic_result = r
        return r
    }

    /// Every `fn` type a lowered value has gets its result before codegen
    /// spells it.
    priv fn _note_type(self, t: unsafe *Type) {
        if t == &null || t->canonical == &null {
            return
        }

        var unsafe *c = canon_unqual(t->canonical)
        if c == &null {
            return
        }

        if isa<NullableType>(c) {
            self._note_type(cast<NullableType>(c)->inner)
            return
        }

        if isa<PointerType>(c) {
            self._note_type(cast<PointerType>(c)->pointee)
            return
        }

        if isa<FunctionPointerType>(c) {
            self._fn_type_result(cast<FunctionPointerType>(c))
        }
    }

    fn transform_expr(self, e: unsafe *Expr) -> unsafe *Expr {
        var unsafe *out = ASTWriter<PanicLowering>::transform_expr(self, e)
        if out != &null && out->type_ != &null {
            self._note_type(out->type_)
        }

        return out
    }

    fn transform_type(self, t: unsafe *Type) -> unsafe *Type {
        var unsafe *out = ASTWriter<PanicLowering>::transform_type(self, t)
        self._note_type(out)
        return out
    }

    /// # bodies

    fn transform_function_decl(self, n: unsafe *FunctionDecl) -> cxx::std::vector<unsafe *Decl> {
        var unsafe *r = self._result_of(n)
        if n->body_block == &null && n->body_expr == &null {
            return ASTWriter<PanicLowering>::transform_function_decl(self, n)
        }

        var        st  = self._targets
        var        sh  = self._holders
        var unsafe *sr = self._fn_r
        var unsafe *sv = self._fn_t
        var unsafe *sc = self._cur
        var        sd  = self._deps
        var        sb  = self._copy_bars
        var        se  = self._copy_exits
        self._cur = n
        self._deps.clear()
        self._dep(r)
        self._enter(r, self._value_type(n->return_type))
        var out = ASTWriter<PanicLowering>::transform_function_decl(self, n)
        if r != &null {
            self._end_void(n->body_block)
        }

        if self._deps.size() > 0 {
            panic_home(n)->panic_deps.from_vec(unsafe &self._deps, self.ctx)
        }

        self._targets    = st
        self._holders    = sh
        self._fn_r       = sr
        self._fn_t       = sv
        self._cur        = sc
        self._deps       = sd
        self._copy_bars  = sb
        self._copy_exits = se
        return out
    }

    fn transform_closure_expr(self, n: unsafe *Expressions::ClosureExpr) -> unsafe *Expr {
        var unsafe *r  = self._closure_result(n)
        var        st  = self._targets
        var        sh  = self._holders
        var unsafe *sr = self._fn_r
        var unsafe *sv = self._fn_t
        var        sb  = self._copy_bars
        var        se  = self._copy_exits
        self._enter(r, self._value_type(n->return_type))
        var unsafe *out = ASTWriter<PanicLowering>::transform_closure_expr(self, n)
        if r != &null {
            self._end_void(n->body_block)
        }

        self._targets    = st
        self._holders    = sh
        self._fn_r       = sr
        self._fn_t       = sv
        self._copy_bars  = sb
        self._copy_exits = se
        return out
    }

    priv fn _enter(self, r: unsafe *Type, t: unsafe *Type) {
        self._targets.clear()
        self._holders.clear()
        self._copy_bars.clear() // a body's own copies: a closure's lambda is no copy of the loop around it.
        self._copy_exits.clear()
        self._fn_r = r
        self._fn_t = t
        if r != &null {
            var tg = PanicTarget()
            tg.type_ = r
            self._targets.push_back(tg)
        }
    }

    /// A `void` panicking body that can fall off its end returns Ok there
    /// (§4.2). A body whose last statement is a `return` cannot.
    priv fn _end_void(self, body: unsafe *CompoundStmt) {
        if body == &null || !self.tu.is_void(self._fn_t) {
            return
        }

        var n = body->body.size()
        if n > 0 && isa<ReturnStmt>(body->body[n - 1]) {
            return
        }

        var lb = self.list_builder<unsafe *Stmt>()
        for var i: usize = 0; i < n; ++i {
            lb.push(body->body[i])
        }

        lb.push(
            ReturnStmt::create(
                self.ctx,
                body->range,
                self.q.panic_ok(body->range, self._fn_r, &null),
            ),
        )

        lb.freeze_into(&body->body)
    }

    /// # return and panic (§4.2)

    fn transform_return_stmt(self, n: unsafe *ReturnStmt) -> cxx::std::vector<unsafe *Stmt> {
        if self._fn_r == &null {
            return ASTWriter<PanicLowering>::transform_return_stmt(self, n)
        }

        var at = n->range
        // Tail position: `return g()` straight out of the function, g's
        // value type ours. No test: the result is forwarded whole.
        if n->value != &null && self._targets.size() == 1 {
            var pc = self._as_call(n->value)
            if pc.call != &null
                && canon_unqual(self._value_of(pc.rc)) == canon_unqual(self._fn_t)
                && !self.tu.is_void(self._fn_t) {
                ASTWriter<PanicLowering>::transform_call_expr(self, pc.call)
                self._retype(pc)
                var unsafe *c = unsafe (pc.call as unsafe *Expr)
                n->value = if (pc.rc == self._fn_r) => (c)
                           else => self._fwd(at, Expressions::PanicOp::FwdAll, self._fn_r, c)
                return self._one_stmt(n)
            }
        }

        var leaves = n->value != &null && self._leaves(n->value)
        if n->value != &null {
            n->value = self.transform_expr(n->value)
        }

        var out = cxx::std::vector<unsafe *Stmt>()
        // A value that can leave the function (a held call's `return`, an
        // arm's jump) is computed first: codegen builds the Ok payload in a
        // lambda, where a `return` would leave the lambda instead.
        if leaves && !self.tu.is_void(self._fn_t) {
            n->value = self._bound(at, n->value, unsafe &out)
        }

        if self.tu.is_void(self._fn_t) {
            // `return f()` of a void f: run it, then return Ok.
            if n->value != &null {
                out.push_back(ExpressionStmt::create(self.ctx, at, n->value))
            }

            n->value = self.q.panic_ok(at, self._fn_r, &null)
            out.push_back(n)
            return out
        }

        n->value = self.q.panic_ok(
            at,
            self._fn_r,
            self._conv(self._moved_local(n->value), self._fn_t),
        )

        out.push_back(n)
        return out
    }

    fn transform_panic_stmt(self, n: *PanicStmt) -> cxx::std::vector<unsafe *Stmt> {
        var out = cxx::std::vector<unsafe *Stmt>()
        var at  = n->range
        // A re-panic forwards the result the error is held in, word 0 as
        // it is: the original site (§3.4).
        if n->repanic != &null && !self._is_cxx_binder(n->repanic) {
            var unsafe *h = self._holder_of(n->repanic)
            if h == &null {
                kairo::std::ice_fail(
                    "PanicLowering: a re-panic of a binding no lowered arm holds; PanicEffectChecking stamps only an arm's",
                )
            }

            self._deliver(at, h, unsafe &out)
            return out
        }

        if self._targets.size() == 0 {
            kairo::std::ice_fail(
                "PanicLowering: a 'panic' with nowhere to go; PanicEffectChecking gate failure",
            )
        }

        var        leaves   = self._leaves(n->payload)
        var unsafe *payload = self.transform_expr(n->payload)
        if leaves { // as a returned value is.
            payload = self._bound(at, payload, unsafe &out)
        }

        var unsafe *x   = canon_unqual(payload->type_)
        var        site = PanicSets(self.sc).site_id(at.start)
        var        tg   = self._targets[self._targets.size() - 1]
        // Into the function's return the payload is the local's last use
        // (C++'s implicit move); into a `try`'s slot control goes on, and
        // the local with it: copied.
        var unsafe *pv = if (tg.slot == &null) => (self._moved_local(payload)) else => payload
        var unsafe *v  = self.q.panic_err(at, tg.type_, x, site, pv)
        if tg.slot == &null {
            out.push_back(ReturnStmt::create(self.ctx, at, v))
            return out
        }

        self._to_slot(at, self._targets.size() - 1, v, &out)
        return out
    }

    /// An ADT construction whose payload can leave the function: its fields
    /// are computed first, in the order written, into locals the payload
    /// then moves from. Codegen builds a payload in a lambda, where a
    /// held call's `return` would leave the lambda instead.
    fn transform_variant_init_expr(self, n: unsafe *Expressions::VariantInitExpr) -> unsafe *Expr {
        var leaves = false
        for var i: usize = 0; i < n->fields.size(); ++i {
            if self._leaves(n->fields[i]) {
                leaves = true
            }
        }

        var unsafe *out = ASTWriter<PanicLowering>::transform_variant_init_expr(self, n)
        if !leaves || n->type_ == &null {
            return out
        }

        var count = n->fields.size()
        var lb    = self.list_builder<unsafe *Stmt>()
        var stmts = cxx::std::vector<unsafe *Stmt>()
        var bound = cxx::std::vector<unsafe *Expr>()
        for var i: usize = 0; i < count; ++i {
            bound.push_back(&null)
        }

        for var k: usize = 0; k < count; ++k {
            for var i: usize = 0; i < count; ++i {
                if (n->source_order[i] as usize) != k {
                    continue
                }

                bound[i] = self._bound(n->fields[i]->range, n->fields[i], unsafe &stmts)
            }
        }

        var fields = self.list_builder<unsafe *Expr>()
        var order  = self.list_builder<u32>()
        for var i: usize = 0; i < count; ++i {
            fields.push(bound[i])
            order.push(i as u32)
        }

        fields.freeze_into(&n->fields)
        order.freeze_into(&n->source_order)
        for var i: usize = 0; i < stmts.size(); ++i {
            lb.push(stmts[i])
        }

        lb.push(
            unsafe (ExpressionStmt::create(self.ctx, n->range, unsafe (n as unsafe *Expr)) as unsafe *Stmt),
        )

        return self.synth.stmt_expr(unsafe (n as unsafe *Expr), &lb, n->type_)
    }

    /// \p e can leave the function or jump: it holds a call that may panic,
    /// or a `try`. Or, in the body of a `try` with a C++ arm, it can throw
    /// (anything not pure): codegen builds a payload in a noexcept lambda
    /// and a noexcept constructor, which would stop the exception short of
    /// the C++ `try` and terminate.
    priv fn _leaves(self, e: unsafe *Expr) -> bool {
        if e == &null {
            return false
        }

        if self._cxx_depth > 0 && !LowerSynth::pure(e) {
            return true
        }

        var w = PanicWalk(self.sc)
        w.keep_sites = true
        w.walk_expr(e)
        return w.sites.size() > 0 || w.tries.size() > 0
    }

    /// `var __kairo_vK = e;` onto \p out, and its value moved out (a record)
    /// or read (anything else).
    priv fn _bound(self,
                   at:  SourceRange,
                   e:   unsafe *Expr,
                   out: unsafe *cxx::std::vector<unsafe *Stmt>) -> unsafe *Expr {
        var unsafe *vd = self.synth.local(at, "v", e->type_, e)
        out->push_back(
            unsafe (DeclStmt::create(self.ctx, at, unsafe (vd as unsafe *Decl)) as unsafe *Stmt),
        )

        var unsafe *use = self.synth.use_of(vd, at, Expr::ValueCategory::LValue)
        var unsafe *c   = canon_unqual(e->type_)
        if c != &null && c->kind == TypeKind::RecordType {
            return self._rref(at, use, c)
        }

        return use
    }

    /// # propagation at a call (§4.3, §4.5)

    fn transform_call_expr(self, n: unsafe *Expressions::CallExpr) -> unsafe *Expr {
        var unsafe *out = ASTWriter<PanicLowering>::transform_call_expr(self, n)
        if out != n {
            return out
        }

        var pc = self._as_call(unsafe (n as unsafe *Expr))
        if pc.call == &null {
            return out
        }

        return self._held(pc)
    }

    /// # a panicking operator (§4.3)

    // `a + b` is a call of `op +`, but OperatorLowering, which makes the tree
    // say so, runs after this pass. A panicking operator is lowered to its
    // call here instead, its operands already lowered, and each call it
    // makes is held. A derived form tests the call it is made of, not the
    // node: `a != b` from a panicking `op ==` is `!(held a.op==(b))`, `a < b`
    // from `op <=>` `(held a.op<=>(b)) as i8 < 0`, and `a += b` from `op +`
    // `a = held a.op+(b)`. OperatorLowering then meets plain calls.

    fn transform_binary_operator_expr(self,
                                      n: unsafe *Expressions::BinaryOperatorExpr) -> unsafe *Expr {
        var unsafe *out = ASTWriter<PanicLowering>::transform_binary_operator_expr(self, n)
        // A tag `==` binds no operator; `===`'s `==` is CoalesceLowering's
        // (PanicEffectChecking reports a panicking one).
        if out != (unsafe (n as unsafe *Expr))
            || n->tag_eq
            || n->op_token.kind == TokenKind::OpEqualEqualEqual {
            return out
        }

        return self._op_call(out, n->resolved_op)
    }

    fn transform_unary_operator_expr(self,
                                     n: unsafe *Expressions::UnaryOperatorExpr) -> unsafe *Expr {
        var unsafe *out = ASTWriter<PanicLowering>::transform_unary_operator_expr(self, n)
        if out != n {
            return out
        }

        return self._op_call(out, n->resolved_op)
    }

    fn transform_assign_operator_expr(self,
                                      n: unsafe *Expressions::AssignOperatorExpr) -> unsafe *Expr {
        var unsafe *out = ASTWriter<PanicLowering>::transform_assign_operator_expr(self, n)
        if out != n {
            return out
        }

        return self._op_call(out, n->resolved_op)
    }

    fn transform_subscript_expr(self, n: unsafe *Expressions::SubscriptExpr) -> unsafe *Expr {
        var unsafe *out = ASTWriter<PanicLowering>::transform_subscript_expr(self, n)
        if out != n {
            return out
        }

        return self._op_call(out, n->resolved_op)
    }

    /// \p e, an operator node bound to \p d, as its call(s) held when \p d
    /// returns a panic result; else \p e. A place operator (`op []` giving a
    /// `*T`, which C++ declares returning `T&`) stays the node, and an `op
    /// as` is not met here (a C++ conversion function returns its target):
    /// PanicEffectChecking reports a panicking one.
    priv fn _op_call(self, e: unsafe *Expr, d: unsafe *Decl) -> unsafe *Expr {
        if d == &null || !isa<FunctionDecl>(d) {
            return e
        }

        var unsafe *f = cast<FunctionDecl>(d)
        if OperatorFacts::is_place(f) || self._result_of(f) == &null {
            return e
        }

        if !self._ol_ready {
            self._ol       = OperatorLowering(self.sc)
            self._ol_ready = true
        }

        var unsafe *r   = self._ol.lower_one(e)
        var        made = self._ol.made
        for var i: usize = 0; i < made.size(); ++i {
            var unsafe *c = unsafe (made[i] as unsafe *Expr)
            var        pc = self._as_call(c)
            if pc.call == &null {
                continue
            }

            var unsafe *h    = self._held(pc)
            var        found = self._swap_in(unsafe &r, c, h)
            if !found {
                kairo::std::ice_fail(
                    "PanicLowering: an operator call OperatorLowering made is not where its shapes put one",
                )
            }
        }

        return r
    }

    /// \p from, in the tree at \p slot, replaced by \p to. Searched only
    /// through what OperatorLowering builds around the calls it makes:
    /// parentheses, a builtin unary, binary or cast over the call, an
    /// assignment, a statement expression's statements. False when it is
    /// not there.
    priv fn _swap_in(self,
                     slot: unsafe * unsafe *Expr,
                     from: unsafe *Expr,
                     to:   unsafe *Expr) -> bool {
        var unsafe *e = *slot
        if e == &null {
            return false
        }

        if e == from {
            *slot = to
            return true
        }

        if isa<Expressions::ParenExpr>(e) {
            return self._swap_in(unsafe &cast<Expressions::ParenExpr>(e)->inner, from, to)
        }

        if isa<Expressions::UnaryOperatorExpr>(e) {
            return self._swap_in(unsafe &cast<Expressions::UnaryOperatorExpr>(e)->operand, from, to)
        }

        if isa<Expressions::TypeCastExpr>(e) {
            return self._swap_in(unsafe &cast<Expressions::TypeCastExpr>(e)->operand, from, to)
        }

        if isa<Expressions::BinaryOperatorExpr>(e) {
            var unsafe *b = cast<Expressions::BinaryOperatorExpr>(e)
            if self._swap_in(unsafe &b->lhs, from, to) {
                return true
            }

            return self._swap_in(unsafe &b->rhs, from, to)
        }

        if isa<Expressions::AssignOperatorExpr>(e) {
            return self._swap_in(unsafe &cast<Expressions::AssignOperatorExpr>(e)->rhs, from, to)
        }

        if isa<Expressions::StmtExpr>(e) {
            var unsafe *body = cast<Expressions::StmtExpr>(e)->body
            if body == &null {
                return false
            }

            for var i: usize = 0; i < body->body.size(); ++i {
                var unsafe *st = body->body[i]
                if isa<ExpressionStmt>(st) {
                    if self._swap_in(unsafe &cast<ExpressionStmt>(st)->expr, from, to) {
                        return true
                    }
                } else if isa<DeclStmt>(st) {
                    var unsafe *vd = dyn_cast<VariableDecl>(cast<DeclStmt>(st)->decl)
                    if vd != &null && self._swap_in(unsafe &vd->init, from, to) {
                        return true
                    }
                }
            }
        }

        return false
    }

    /// A statement that IS a panicking call: the held result is tested and
    /// dropped, with no statement expression around it.
    fn transform_expression_stmt(self,
                                 n: unsafe *ExpressionStmt) -> cxx::std::vector<unsafe *Stmt> {
        var pc = self._as_call(n->expr)
        if pc.call == &null {
            return ASTWriter<PanicLowering>::transform_expression_stmt(self, n)
        }

        ASTWriter<PanicLowering>::transform_call_expr(self, pc.call)
        self._retype(pc)
        var        lb = self.list_builder<unsafe *Stmt>()
        var unsafe *h = self.synth.bind(n->range, "p", pc.rc, pc.call, unsafe &lb)
        if pc.fails {
            lb.push(self._test_deliver(n->range, h))
        }

        var        out  = cxx::std::vector<unsafe *Stmt>()
        var unsafe *blk = CompoundStmt::create(self.ctx, n->range)
        lb.freeze_into(&blk->body)
        out.push_back(blk)
        return out
    }

    /// `({ var p = call; if !ok(p) { deliver } (p.value as T&&) })`.
    priv fn _held(self, pc: PanicCall) -> unsafe *Expr {
        var        at    = pc.call->range
        var unsafe *orig = unsafe (pc.call as unsafe *Expr)
        self._retype(pc)
        var        lb = self.list_builder<unsafe *Stmt>()
        var unsafe *h = self.synth.bind(at, "p", pc.rc, orig, unsafe &lb)
        if pc.fails {
            lb.push(self._test_deliver(at, h))
        }

        var unsafe *vt = self._value_of(pc.rc)
        if self.tu.is_void(vt) {
            return self.synth.stmt_expr(orig, &lb, vt)
        }

        lb.push(ExpressionStmt::create(self.ctx, at, self._read_value(at, h, vt)))
        return self.synth.stmt_expr(orig, &lb, vt)
    }

    /// `if !ok(h) { <deliver h> }`.
    priv fn _test_deliver(self, at: SourceRange, h: unsafe *VariableDecl) -> unsafe *Stmt {
        var stmts = cxx::std::vector<unsafe *Stmt>()
        self._deliver(at, h, unsafe &stmts)
        return ConditionalStmt::create(
            self.ctx,
            at,
            self._not(at, self._ok(at, h)),
            self._block(at, stmts),
            &null,
        )
    }

    /// The call \p e is (parentheses aside), when it may panic: its callee
    /// returns a panic result.
    priv fn _as_call(self, e_in: unsafe *Expr) -> PanicCall {
        var        r  = PanicCall()
        var unsafe *e = self.tu.strip_parens(e_in)
        if e == &null || !isa<Expressions::CallExpr>(e) || e->is_poisoned() {
            return r
        }

        var unsafe *c = cast<Expressions::CallExpr>(e)
        var unsafe *f = self._callee_fn(c)
        if f == &null {
            // Through a `fn` value: its type carries the set (§2.10).
            var unsafe *ce = self.tu.strip_parens(c->callee)
            if ce == &null || ce->type_ == &null {
                return r
            }

            var unsafe *fp = dyn_cast<FunctionPointerType>(canon_unqual(ce->type_))
            if fp == &null {
                return r
            }

            var unsafe *frc = self._fn_type_result(fp)
            if frc == &null {
                return r
            }

            r.call  = c
            r.rc    = frc
            r.fails = true
            return r
        }

        var unsafe *rc = self._result_of(f)
        if rc == &null {
            return r
        }

        // A generic callee's result at this call's arguments: `g<A>`
        // returns `Panic<i32, A>`, a requirement through `T impl Src<E>`
        // its result at E. PanicEffectChecking reported a call it cannot
        // bind, and the lowerings do not run after an error.
        var unsafe *recv = panic_call_receiver(unsafe &self.tu, c, f)
        if panic_dep(rc) {
            var unsafe *x = panic_call_type(unsafe &self.tu, f, c, recv, rc)
            if x == &null {
                kairo::std::ice_fail(
                    "PanicLowering: a call whose callee's panic result names a parameter it does not bind; PanicEffectChecking reports it",
                )
            }

            rc = self._formed(c->range, x)
        }

        self._dep(rc)
        var set = cxx::std::vector<unsafe *Type>()
        r.call  = c
        r.rc    = rc
        r.fails = panic_call_set(unsafe &self.tu, f, c, recv, unsafe &set) == PanicKnown::Set
        return r
    }

    /// The function a call selected, or null (PanicWalk's rule).
    priv fn _callee_fn(self, c: unsafe *Expressions::CallExpr) -> unsafe *FunctionDecl {
        if c->ctor_decl != &null && isa<FunctionDecl>(c->ctor_decl) {
            return cast<FunctionDecl>(c->ctor_decl)
        }

        var unsafe *e = self.tu.strip_parens(c->callee)
        if e == &null {
            return &null
        }

        var d: unsafe *Decl = &null
        if isa<NamedIdentExpr>(e) {
            d = cast<NamedIdentExpr>(e)->resolved_decl
        } else if isa<ChainExpr>(e) {
            var unsafe *ch = cast<ChainExpr>(e)
            if ch->steps.size() > 0 {
                var unsafe *st = ch->steps.get(ch->steps.size() - 1)
                d = st->resolved_decl
                if d == &null && st->name != &null {
                    d = st->name->resolved_decl
                }
            }
        }

        return dyn_cast<FunctionDecl>(d)
    }

    /// The call now yields its panic result.
    priv fn _retype(self, pc: PanicCall) {
        pc.call->type_          = pc.rc
        pc.call->value_category = Expr::ValueCategory::RValue
    }

    /// # delivering an error

    /// The error held in \p h, to the innermost target: returned (moved, or
    /// forwarded into the result), or put into the `try`'s slot before a
    /// jump to its dispatch.
    priv fn _deliver(self,
                     at:  SourceRange,
                     h:   unsafe *VariableDecl,
                     out: unsafe *cxx::std::vector<unsafe *Stmt>) {
        if self._targets.size() == 0 {
            kairo::std::ice_fail(
                "PanicLowering: an error with nowhere to go; PanicEffectChecking gate failure",
            )
        }

        var        tg                = self._targets[self._targets.size() - 1]
        var unsafe *use              = self.synth.use_of(h, at, Expr::ValueCategory::LValue)
        var        v:   unsafe *Expr = &null
        if canon_unqual(h->type_) == canon_unqual(tg.type_) {
            v = self._rref(at, use, tg.type_)
        } else {
            v = self._fwd(at, Expressions::PanicOp::Fwd, tg.type_, use)
        }

        if tg.slot == &null {
            out->push_back(ReturnStmt::create(self.ctx, at, v))
            return
        }

        self._to_slot(at, self._targets.size() - 1, v, &*out)
    }

    /// \p v into the slot of the `try` target \p t, then a jump to its
    /// dispatch. From inside a copy loop opened since that `try` (EmitIR's
    /// lambda per copy, which no goto leaves) the jump stops the copy
    /// instead (JumpIntrinsicStmt::ef_leave), after setting the `try`'s
    /// flag; each copy loop it leaves is followed by a jump on that flag
    /// (transform_ranged_for_stmt), the outermost one's the real goto. A
    /// delivery to the function's return needs none of this: a `return`
    /// in a copy already goes out through EmitIR's flag and value slot.
    priv fn _to_slot(self,
                     at:         SourceRange,
                     t:          usize,
                     v:          unsafe *Expr,
                     @inout out: cxx::std::vector<unsafe *Stmt>) {
        var tg = self._targets[t]
        out.push_back(ExpressionStmt::create(self.ctx, at, self._slot_put(at, tg.slot, v)))
        var unsafe *j      = JumpIntrinsicStmt::create(self.ctx, at, tg.label)
        var        crossed = false
        for var c: usize = 0; c < self._copy_bars.size(); ++c {
            if self._copy_bars[c] <= t {
                continue
            }

            crossed = true
            var have = false
            for var k: usize = 0; k < self._copy_exits.size(); ++k {
                if self._copy_exits[k].copy == c && self._copy_exits[k].target == t {
                    have = true
                    break
                }
            }

            if !have {
                var ex = PanicCopyExit()
                ex.copy   = c
                ex.target = t
                self._copy_exits.push_back(ex)
            }
        }

        if crossed {
            if self._targets[t].efj == &null {
                self._targets[t].efj = self.synth.local(
                    at,
                    "efj",
                    self.sc->builtin(BuiltinKind::Bool),
                    self.synth.bool_literal(at, false),
                )
            }

            var unsafe *flag = self.synth.use_of(
                self._targets[t].efj,
                at,
                Expr::ValueCategory::LValue,
            )

            var unsafe *put = Expressions::AssignOperatorExpr::create(
                self.ctx,
                at,
                flag,
                self.synth.bool_literal(at, true),
                self.synth.punct(at, TokenKind::OpEqual),
            )

            put->type_          = flag->type_
            put->value_category = Expr::ValueCategory::LValue
            out.push_back(
                unsafe (ExpressionStmt::create(self.ctx, at, unsafe (put as unsafe *Expr)) as unsafe *Stmt),
            )

            j->ef_leave = true
        }

        out.push_back(j)
    }

    /// An `eval for`, or a `for` over a pack: EmitIR expands the body into a
    /// C++ lambda per copy, so a delivery inside it to a `try` outside it
    /// cannot jump there (_to_slot). After the expansion, for each such
    /// `try`: `if flag { jump }` -- the goto to its dispatch when the `try`
    /// is right outside this loop, else (another copy around this one, also
    /// inside the `try`) the stop of that copy, which repeats this.
    fn transform_ranged_for_stmt(self, n: unsafe *RangedForStmt) -> cxx::std::vector<unsafe *Stmt> {
        if !n->is_eval && n->iter_kind != IterKind::Pack {
            return ASTWriter<PanicLowering>::transform_ranged_for_stmt(self, n)
        }

        // The iterable is computed outside the copies (a pack's elements are
        // the lambda's arguments, an eval for's values are constants).
        if n->iterable != &null {
            n->iterable = self.transform_expr(n->iterable)
        }

        var c = self._copy_bars.size()
        self._copy_bars.push_back(self._targets.size())
        n->body = cast<CompoundStmt>(self.transform_stmt_scalar(n->body))
        self._copy_bars.pop_back()
        var out = cxx::std::vector<unsafe *Stmt>()
        out.push_back(n)
        var keep = cxx::std::vector<PanicCopyExit>()
        for var k: usize = 0; k < self._copy_exits.size(); ++k {
            var ex = self._copy_exits[k]
            if ex.copy != c {
                keep.push_back(ex)
                continue
            }

            var        tg = self._targets[ex.target]
            var        at = n->range
            var unsafe *j = JumpIntrinsicStmt::create(self.ctx, at, tg.label)
            for var b: usize = 0; b < self._copy_bars.size(); ++b {
                if self._copy_bars[b] > ex.target {
                    j->ef_leave = true
                }
            }

            var jv = cxx::std::vector<unsafe *Stmt>()
            jv.push_back(j)
            var unsafe *cond = self.synth.use_of(tg.efj, at, Expr::ValueCategory::LValue)
            out.push_back(ConditionalStmt::create(self.ctx, at, cond, self._block(at, jv), &null))
        }

        self._copy_exits = keep
        return out
    }

    priv fn _holder_of(self, d: unsafe *Decl) -> unsafe *VariableDecl {
        var k = self._holders.size()
        while k > 0 {
            k -= 1
            if self._holders[k].decl == d {
                return self._holders[k].holder
            }
        }

        return &null
    }

    /// # try / catch (§4.4)

    fn transform_try_catch_stmt(self, n: unsafe *TryCatchStmt) -> cxx::std::vector<unsafe *Stmt> {
        var at    = n->range
        var arms  = cxx::std::vector<PanicArm>()
        var cxx_v = cxx::std::vector<PanicArm>()
        for var i: usize = 0; i < n->arms.size(); ++i {
            var unsafe *a = n->arms.get(i)
            var        pa = PanicArm()
            pa.filter  = a->filter
            pa.decl    = a->decl
            pa.is_dead = a->is_dead
            pa.sbody   = a->body
            pa.range   = a->range
            if a->decl != &null && isa<VariableDecl>(a->decl) {
                pa.is_const = cast<VariableDecl>(a->decl)->storage == StorageClass::Const
            }

            pa.is_cxx = a->is_cxx
            if pa.is_cxx {
                cxx_v.push_back(pa)
            } else {
                arms.push_back(pa)
            }
        }

        var out = cxx::std::vector<unsafe *Stmt>()
        // Nothing reaches it: the body alone; no panic arm runs (a C++ one
        // may: the body is its C++ `try`).
        if n->reach.size() == 0 {
            if cxx_v.size() > 0 {
                self._cxx_depth += 1
            }

            var unsafe *only = self.transform_stmt_scalar(unsafe (n->try_body as unsafe *Stmt))
            if cxx_v.size() > 0 {
                self._cxx_depth -= 1
            }

            if cxx_v.size() > 0 {
                only = self._cxx_try(at, only, &cxx_v, &null)
            }

            out.push_back(only)
            return out
        }

        // Direct: one statement, the one call that can panic, first. Not
        // with a C++ arm: the dispatch would sit inside the C++ `try`, and
        // a panic arm is outside its `try`.
        var shape = if (cxx_v.size() > 0) => (-1) else => self._direct_shape(n)
        if shape >= 0 {
            var unsafe *s = n->try_body->body[0]
            var        pc = self._as_call(self._direct_call(s, shape))
            ASTWriter<PanicLowering>::transform_call_expr(self, pc.call)
            self._retype(pc)
            var lb = self.list_builder<unsafe *Stmt>()
            var unsafe *h = self.synth.bind(
                at,
                "p",
                pc.rc,
                unsafe (pc.call as unsafe *Expr),
                unsafe &lb,
            )

            var okv = cxx::std::vector<unsafe *Stmt>()
            if shape > 0 {
                var unsafe *vt = self._value_of(pc.rc)
                self._replace_call(s, shape, self._read_value(at, h, vt))
                var done = self.transform_stmt(s)
                for var i: usize = 0; i < done.size(); ++i {
                    okv.push_back(done[i])
                }
            }

            var errv = cxx::std::vector<unsafe *Stmt>()
            errv.push_back(self._dispatch(at, h, &arms, &null, unsafe &n->reach))
            lb.push(
                unsafe (ConditionalStmt::create(self.ctx, at, self._ok(at, h), self._block(at, okv), self._block(at, errv)) as unsafe *Stmt),
            )

            var unsafe *blk = CompoundStmt::create(self.ctx, at)
            lb.freeze_into(&blk->body)
            out.push_back(unsafe (blk as unsafe *Stmt))
            return out
        }

        // The slot form.
        var unsafe *st   = self._slot_type(at, n->reach)
        var        lb    = self.list_builder<unsafe *Stmt>()
        var unsafe *slot = self._raw(at, "s", st, &lb)
        var        tg    = PanicTarget()
        tg.slot  = slot
        tg.type_ = st
        tg.label = self.synth.fresh(at, "catch")
        var done = self.synth.fresh(at, "done")
        self._targets.push_back(tg)
        if cxx_v.size() > 0 {
            self._cxx_depth += 1
        }

        var unsafe *body = self.transform_stmt_scalar(unsafe (n->try_body as unsafe *Stmt))
        if cxx_v.size() > 0 {
            self._cxx_depth -= 1
        }

        var unsafe *efj = self._targets[self._targets.size() - 1].efj
        self._targets.pop_back()
        // A copy loop's flag (_to_slot), ahead of the body and the label.
        if efj != &null {
            lb.push(
                unsafe (DeclStmt::create(self.ctx, at, unsafe (efj as unsafe *Decl)) as unsafe *Stmt),
            )
        }

        // The C++ `try` holds the body only; a failing site's jump to the
        // dispatch leaves it (a goto out of a C++ try block is legal).
        if cxx_v.size() > 0 {
            body = self._cxx_try(at, body, &cxx_v, &null)
        }

        lb.push(body)
        lb.push(unsafe (JumpIntrinsicStmt::create(self.ctx, at, done) as unsafe *Stmt))
        lb.push(unsafe (LabelIntrinsicStmt::create(self.ctx, at, tg.label) as unsafe *Stmt))
        lb.push(self._catch_block(at, slot, st, unsafe &arms, &null))
        lb.push(unsafe (LabelIntrinsicStmt::create(self.ctx, at, done) as unsafe *Stmt))
        var unsafe *blk = CompoundStmt::create(self.ctx, at)
        lb.freeze_into(&blk->body)
        out.push_back(unsafe (blk as unsafe *Stmt))
        return out
    }

    fn transform_try_catch_expr(self, n: unsafe *Expressions::TryCatchExpr) -> unsafe *Expr {
        var at    = n->range
        var arms  = cxx::std::vector<PanicArm>()
        var cxx_v = cxx::std::vector<PanicArm>()
        for var i: usize = 0; i < n->catch_arms.size(); ++i {
            var unsafe *a = n->catch_arms.get(i)
            var        pa = PanicArm()
            pa.filter   = a->filter
            pa.decl     = a->decl
            pa.is_const = a->is_const
            pa.is_dead  = a->is_dead
            pa.ebody    = a->body
            pa.range    = a->range
            pa.is_cxx   = a->is_cxx
            if pa.is_cxx {
                cxx_v.push_back(pa)
            } else {
                arms.push_back(pa)
            }
        }

        if n->reach.size() == 0 && cxx_v.size() == 0 {
            return self.transform_expr(n->try_expr)
        }

        var unsafe *t                         = self._value_type(n->type_)
        var unsafe *orig                      = unsafe (n as unsafe *Expr)
        var        lb                         = self.list_builder<unsafe *Stmt>()
        var        res:  unsafe *VariableDecl = &null
        if !self.tu.is_void(t) {
            res = self._raw(at, "r", t, &lb)
        }

        var pc = self._as_call(n->try_expr)
        if n->reach.size() == 0 {
            // Only C++ arms: `try { r <- operand } catch (T& e) { r <- arm }`.
            self._cxx_depth += 1
            var unsafe *v = self.transform_expr(n->try_expr)
            self._cxx_depth -= 1
            var bv = cxx::std::vector<unsafe *Stmt>()
            if res != &null {
                bv.push_back(
                    unsafe (ExpressionStmt::create(self.ctx, at, self._slot_put(at, res, v)) as unsafe *Stmt),
                )
            } else {
                bv.push_back(unsafe (ExpressionStmt::create(self.ctx, at, v) as unsafe *Stmt))
            }

            lb.push(self._cxx_try(at, unsafe (self._block(at, bv) as unsafe *Stmt), &cxx_v, res))
        } else if cxx_v.size() == 0 && pc.call != &null && self._sites_in_expr(n->try_expr) == 1 {
            // Direct: the operand IS the one call that can panic.
            ASTWriter<PanicLowering>::transform_call_expr(self, pc.call)
            self._retype(pc)
            var unsafe *h = self.synth.bind(
                at,
                "p",
                pc.rc,
                unsafe (pc.call as unsafe *Expr),
                unsafe &lb,
            )

            var okv = cxx::std::vector<unsafe *Stmt>()
            if res != &null {
                okv.push_back(
                    unsafe (ExpressionStmt::create(self.ctx, at, self._slot_put(at, res, self._read_value(at, h, self._value_of(pc.rc)))) as unsafe *Stmt),
                )
            }

            var errv = cxx::std::vector<unsafe *Stmt>()
            errv.push_back(self._dispatch(at, h, &arms, res, unsafe &n->reach))
            lb.push(
                unsafe (ConditionalStmt::create(self.ctx, at, self._ok(at, h), self._block(at, okv), self._block(at, errv)) as unsafe *Stmt),
            )
        } else {
            var unsafe *st   = self._slot_type(at, n->reach)
            var unsafe *slot = self._raw(at, "s", st, &lb)
            var        tg    = PanicTarget()
            tg.slot  = slot
            tg.type_ = st
            tg.label = self.synth.fresh(at, "catch")
            var done = self.synth.fresh(at, "done")
            self._targets.push_back(tg)
            if cxx_v.size() > 0 {
                self._cxx_depth += 1
            }

            var unsafe *v = self.transform_expr(n->try_expr)
            if cxx_v.size() > 0 {
                self._cxx_depth -= 1
            }

            var unsafe *efj = self._targets[self._targets.size() - 1].efj
            self._targets.pop_back()
            if efj != &null {
                lb.push(
                    unsafe (DeclStmt::create(self.ctx, at, unsafe (efj as unsafe *Decl)) as unsafe *Stmt),
                )
            }

            var bv = cxx::std::vector<unsafe *Stmt>()
            if res != &null {
                bv.push_back(
                    unsafe (ExpressionStmt::create(self.ctx, at, self._slot_put(at, res, v)) as unsafe *Stmt),
                )
            } else {
                bv.push_back(unsafe (ExpressionStmt::create(self.ctx, at, v) as unsafe *Stmt))
            }

            bv.push_back(unsafe (JumpIntrinsicStmt::create(self.ctx, at, done) as unsafe *Stmt))
            var unsafe *bs = unsafe (self._block(at, bv) as unsafe *Stmt)
            lb.push(if (cxx_v.size() > 0) => (self._cxx_try(at, bs, &cxx_v, res)) else => bs)
            // A C++ arm ends below its `try`, not at the jump inside it: on
            // to the value, past the dispatch.
            if cxx_v.size() > 0 {
                lb.push(unsafe (JumpIntrinsicStmt::create(self.ctx, at, done) as unsafe *Stmt))
            }

            lb.push(unsafe (LabelIntrinsicStmt::create(self.ctx, at, tg.label) as unsafe *Stmt))
            lb.push(self._catch_block(at, slot, st, unsafe &arms, res))
            lb.push(unsafe (LabelIntrinsicStmt::create(self.ctx, at, done) as unsafe *Stmt))
        }

        if res != &null {
            var unsafe *take = Expressions::PanicOpExpr::create(
                self.ctx,
                at,
                Expressions::PanicOp::SlotTake,
                &null,
                self.synth.use_of(res, at, Expr::ValueCategory::LValue),
            )

            take->type_          = t
            take->value_category = Expr::ValueCategory::RValue
            lb.push(
                unsafe (ExpressionStmt::create(self.ctx, at, unsafe (take as unsafe *Expr)) as unsafe *Stmt),
            )
        }

        return self.synth.stmt_expr(orig, &lb, t)
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
    priv fn _cxx_try(self,
                     at:           SourceRange,
                     body:         unsafe *Stmt,
                     @inout cxx_v: cxx::std::vector<PanicArm>,
                     res:          unsafe *VariableDecl) -> unsafe *Stmt {
        var unsafe *blk = dyn_cast<CompoundStmt>(body)
        if blk == &null {
            var one = cxx::std::vector<unsafe *Stmt>()
            one.push_back(body)
            blk = self._block(at, one)
        }

        var unsafe *t = TryCatchStmt::create(self.ctx, at, blk)
        t->cxx = true
        var cas = cxx::std::vector<CatchArm>()
        for var i: usize = 0; i < cxx_v.size(); ++i {
            var unsafe *a    = unsafe &(cxx_v)[i]
            var        stmts = cxx::std::vector<unsafe *Stmt>()
            if a->decl != &null && isa<VariableDecl>(a->decl) {
                var unsafe *vd = cast<VariableDecl>(a->decl)
                var unsafe *et = canon_unqual(a->filter->canonical)
                if a->is_const {
                    et = self.sc->types->qualified(et, QUAL_CONST)
                }

                vd->type_   = self.sc->types->cxx_lref(et)
                vd->storage = StorageClass::Var            // the `const` is in the type.
                vd->init    = &null
                self._cxx_binders.push_back(a->decl)
            }

            self._arm_body(a, &null, res, &stmts)
            var ca = CatchArm{}
            ca.filter  = a->filter
            ca.binding = &null
            ca.body    = self._block(a->range, stmts)
            ca.range   = a->range
            ca.decl    = a->decl
            ca.is_dead = false
            ca.is_cxx  = true
            cas.push_back(ca)
        }

        t->arms.from_vec(unsafe &cas, self.ctx)
        return unsafe (t as unsafe *Stmt)
    }

    priv fn _is_cxx_binder(self, d: unsafe *Decl) -> bool {
        for var i: usize = 0; i < self._cxx_binders.size(); ++i {
            if self._cxx_binders[i] == d {
                return true
            }
        }

        return false
    }

    /// `{ var __kairo_e = take(slot); <dispatch e> }`: the error moved out
    /// of the slot, which is destroyed, before any arm runs.
    priv fn _catch_block(self,
                         at:   SourceRange,
                         slot: unsafe *VariableDecl,
                         st:   unsafe *Type,
                         arms: unsafe *cxx::std::vector<PanicArm>,
                         res:  unsafe *VariableDecl) -> unsafe *Stmt {
        var unsafe *take = Expressions::PanicOpExpr::create(
            self.ctx,
            at,
            Expressions::PanicOp::SlotTake,
            &null,
            self.synth.use_of(slot, at, Expr::ValueCategory::LValue),
        )

        take->type_          = st
        take->value_category = Expr::ValueCategory::RValue
        var        lb = self.list_builder<unsafe *Stmt>()
        var unsafe *e = self.synth.bind(at, "e", st, take, unsafe &lb)
        lb.push(self._dispatch(at, e, &*arms, res))
        var unsafe *blk = CompoundStmt::create(self.ctx, at)
        lb.freeze_into(&blk->body)
        return blk
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
    priv fn _dispatch(self,
                      at:          SourceRange,
                      h:           unsafe *VariableDecl,
                      @inout arms: cxx::std::vector<PanicArm>,
                      res:         unsafe *VariableDecl,
                      reach:       unsafe *FrozenList<unsafe *Type> = &null) -> unsafe *Stmt {
        var hset = self.tu.record_args(self.tu.as_value(h->type_))
        var can  = cxx::std::vector<unsafe *Type>()
        if reach != &null {
            for var i: usize = 0;
            i < reach->size();
            ++i {
                can.push_back(canon_unqual((*reach)[i]))
            }
        }

        var held = cxx::std::vector<unsafe *Type>()
        for var i: usize = 1; i < hset.size(); ++i {
            var unsafe *c = canon_unqual(hset[i])
            if reach == &null || pset_has(unsafe &can, c) {
                held.push_back(c)
            }
        }

        var typed      = cxx::std::vector<usize>()
        var caught     = cxx::std::vector<unsafe *Type>()
        var bare:  i64 = -1
        for var i: usize = 0; i < arms.size(); ++i {
            var unsafe *a = unsafe &(arms)[i]
            if a->filter == &null {
                bare = (i as i64)
                continue
            }

            if a->is_dead || a->filter->canonical == &null {
                continue
            }

            var unsafe *c = canon_unqual(a->filter->canonical)
            if !pset_has(unsafe &held, c) {
                continue
            }

            typed.push_back(i)
            caught.push_back(c)
        }

        // The tail: the bare arm, or what is left delivered, when anything
        // is left; nothing at all otherwise (a bare arm then never runs).
        var tail: unsafe *Stmt = &null
        var left               = false
        for var i: usize = 0; i < held.size(); ++i {
            if !pset_has(unsafe &caught, held[i]) {
                left = true
            }
        }

        if left && bare >= 0 {
            tail = unsafe (self._bare_arm(at, h, unsafe &(arms)[bare as usize], res) as unsafe *Stmt)
        } else if left {
            var stmts = cxx::std::vector<unsafe *Stmt>()
            self._deliver(at, h, unsafe &stmts)
            tail = unsafe (self._block(at, stmts) as unsafe *Stmt)
        }

        var k = typed.size()
        while k > 0 {
            k -= 1
            var unsafe *a   = unsafe &(arms)[typed[k]]
            var unsafe *arm = self._typed_arm(at, h, a, caught[k], res)
            if tail == &null {
                tail = unsafe (arm as unsafe *Stmt)
                continue
            } // the last one left needs no compare.

            tail = unsafe (ConditionalStmt::create(self.ctx, a->range, self.q.panic_holds(a->range, self.synth.use_of(h, at, Expr::ValueCategory::LValue), caught[k]), arm, tail) as unsafe *Stmt)
        }

        if tail == &null {
            var none = cxx::std::vector<unsafe *Stmt>()
            tail = unsafe (self._block(at, none) as unsafe *Stmt)
        }

        return tail
    }

    /// `{ E& e = <h's E payload>; body }`.
    priv fn _typed_arm(self,
                       at:  SourceRange,
                       h:   unsafe *VariableDecl,
                       a:   unsafe *PanicArm,
                       e:   unsafe *Type,
                       res: unsafe *VariableDecl) -> unsafe *CompoundStmt {
        var stmts = cxx::std::vector<unsafe *Stmt>()
        if a->decl != &null && isa<VariableDecl>(a->decl) {
            var unsafe *vd = cast<VariableDecl>(a->decl)
            var unsafe *et = e
            if a->is_const {
                et = self.sc->types->qualified(e, QUAL_CONST)
            }

            vd->type_   = self.sc->types->cxx_lref(et)
            vd->storage = StorageClass::Var            // the `const` is in the type.
            vd->init = self.q.panic_error_ref(
                a->range,
                self.synth.use_of(h, at, Expr::ValueCategory::LValue),
                e,
            )

            stmts.push_back(
                unsafe (DeclStmt::create(self.ctx, a->range, unsafe (vd as unsafe *Decl)) as unsafe *Stmt),
            )
        }

        self._arm_body(a, h, res, &stmts)
        return self._block(a->range, stmts)
    }

    /// `{ var e: Panic<void, L...> = fwd(h); body }`: the bare binding is
    /// what is left, as its own result; a re-panic of it forwards it.
    priv fn _bare_arm(self,
                      at:  SourceRange,
                      h:   unsafe *VariableDecl,
                      a:   unsafe *PanicArm,
                      res: unsafe *VariableDecl) -> unsafe *CompoundStmt {
        var        stmts   = cxx::std::vector<unsafe *Stmt>()
        var unsafe *holder = h
        if a->decl != &null && isa<VariableDecl>(a->decl) {
            var unsafe *vd = cast<VariableDecl>(a->decl)
            var unsafe *bt = vd->type_
            self._dep(bt)
            if bt != &null
                && self.q.panic_adt(bt) != &null
                && self.tu.record_args(self.tu.as_value(bt)).size() > 1 {
                var unsafe *use = self.synth.use_of(h, at, Expr::ValueCategory::LValue)
                vd->init = if (canon_unqual(bt) == canon_unqual(h->type_)) => (self._rref(
                               at,
                               use,
                               bt,
                           ))
                           else => self._fwd(at, Expressions::PanicOp::Fwd, canon_unqual(bt), use)
                vd->storage = StorageClass::Var
                stmts.push_back(
                    unsafe (DeclStmt::create(self.ctx, a->range, unsafe (vd as unsafe *Decl)) as unsafe *Stmt),
                )

                holder = vd
            }
        }

        self._arm_body(a, holder, res, &stmts)
        return self._block(a->range, stmts)
    }

    /// The arm's body after its binding, lowered with the `try`'s target
    /// closed: a statement body as it is, a value put into the result slot,
    /// an arm that leaves as its statement.
    priv fn _arm_body(self,
                      a:          unsafe *PanicArm,
                      holder:     unsafe *VariableDecl,
                      res:        unsafe *VariableDecl,
                      @inout out: cxx::std::vector<unsafe *Stmt>) {
        var ph = PanicHolder()
        ph.decl   = a->decl
        ph.holder = holder
        self._holders.push_back(ph)
        if a->sbody != &null {
            out.push_back(self.transform_stmt_scalar(unsafe (a->sbody as unsafe *Stmt)))
        } else if a->ebody != &null {
            var unsafe *se = dyn_cast<Expressions::StmtExpr>(a->ebody)
            if se != &null && se->is_jump {
                out.push_back(self.transform_stmt_scalar(se->body))
            } else {
                var unsafe *v = self.transform_expr(a->ebody)
                // An arm of type `!` (`crash!()`, a call of a `-> !` fn) fits
                // any arm type (§3.2) but has no value to put: as a statement
                // it never returns, so the slot is never read on its path. Put
                // into the slot it is a cast from `void` C++ refuses.
                var never = v->type_ != &null && self.tu.is_never(canon_unqual(v->type_))
                if res != &null && !never {
                    v = self._slot_put(a->range, res, v)
                }

                out.push_back(ExpressionStmt::create(self.ctx, a->range, v))
            }
        }

        self._holders.pop_back()
    }

    /// # the direct form's shape

    /// The direct form applies when the body is one statement whose call
    /// is the only site that can panic in the `try` and is evaluated first:
    /// 0 the statement is the call, 1 `x = call` (x a pure place), 2
    /// `return call`, 3 `var x = call`. -1 otherwise.
    priv fn _direct_shape(self, n: unsafe *TryCatchStmt) -> i32 {
        if n->try_body == &null || n->try_body->body.size() != 1 {
            return -1
        }

        var unsafe *s         = n->try_body->body[0]
        var        shape: i32 = -1
        if isa<ExpressionStmt>(s) {
            var unsafe *e = self.tu.strip_parens(cast<ExpressionStmt>(s)->expr)
            if e != &null && isa<Expressions::CallExpr>(e) {
                shape = 0
            } else if e != &null && isa<Expressions::AssignOperatorExpr>(e) {
                var unsafe *asg = cast<Expressions::AssignOperatorExpr>(e)
                if asg->resolved_op == &null
                    && asg->op_token.kind == TokenKind::OpEqual
                    && LowerSynth::pure(asg->lhs) {
                    shape = 1
                }
            }
        } else if isa<ReturnStmt>(s) {
            if cast<ReturnStmt>(s)->value != &null {
                shape = 2
            }
        } else if isa<DeclStmt>(s) {
            var unsafe *vd = dyn_cast<VariableDecl>(cast<DeclStmt>(s)->decl)
            if vd != &null
                && vd->init != &null
                && !vd->raw_slot
                && vd->storage != StorageClass::Static {
                shape = 3
            }
        }

        if shape < 0 {
            return -1
        }

        var pc = self._as_call(self._direct_call(s, shape))
        if pc.call == &null || !pc.fails {
            return -1
        }

        var w = PanicWalk(self.sc)
        w.keep_sites = true
        w.walk_stmt(n->try_body)
        if self._reaching(&w) != 1 {
            return -1
        }

        return shape
    }

    priv fn _direct_call(self, s: unsafe *Stmt, shape: i32) -> unsafe *Expr {
        if shape == 0 {
            return cast<ExpressionStmt>(s)->expr
        }

        if shape == 1 {
            return cast<Expressions::AssignOperatorExpr>(
                self.tu.strip_parens(cast<ExpressionStmt>(s)->expr),
            )->rhs
        }

        if shape == 2 {
            return cast<ReturnStmt>(s)->value
        }

        return cast<VariableDecl>(cast<DeclStmt>(s)->decl)->init
    }

    priv fn _replace_call(self, s: unsafe *Stmt, shape: i32, v: unsafe *Expr) {
        if shape == 1 {
            cast<Expressions::AssignOperatorExpr>(
                self.tu.strip_parens(cast<ExpressionStmt>(s)->expr),
            )->rhs = v
        } else if shape == 2 {
            cast<ReturnStmt>(s)->value = v
        } else if shape == 3 {
            cast<VariableDecl>(cast<DeclStmt>(s)->decl)->init = v
        }
    }

    /// How many sites of a walk's body reach the `try` around it.
    priv fn _reaching(self, w: *PanicWalk) -> usize {
        var n: usize = 0
        for var i: usize = 0; i < w->sites.size(); ++i {
            if w->sites[i].left.size() > 0 {
                n += 1
            }
        }

        return n
    }

    priv fn _sites_in_expr(self, e: unsafe *Expr) -> usize {
        var w = PanicWalk(self.sc)
        w.keep_sites = true
        w.walk_expr(e)
        return self._reaching(&w)
    }

    /// # helpers

    /// `Panic<void, reach...>`, a `try`'s slot.
    priv fn _slot_type(self,
                       at:          SourceRange,
                       const reach: FrozenList<unsafe *Type>) -> unsafe *Type {
        var set = cxx::std::vector<unsafe *Type>()
        for var i: usize = 0; i < reach.size(); ++i {
            set.push_back((reach)[i])
        }

        var unsafe *st = PanicSets(self.sc).form(
            at,
            self.sc->builtin(BuiltinKind::Void),
            unsafe &set,
        )

        if st == &null {
            kairo::std::ice_fail(
                "PanicLowering: a try's set did not form; PanicSets reported the collision and the lowerings should not run",
            )
        }

        self._dep(st)
        return st
    }

    /// A raw-storage local of \p t, declared on \p lb.
    priv fn _raw(self,
                 at:         SourceRange,
                 const hint: string,
                 t:          unsafe *Type,
                 @inout lb:  ListBuilder<unsafe *Stmt>) -> unsafe *VariableDecl {
        var unsafe *vd = self.synth.local(at, hint, t, &null)
        vd->raw_slot = true
        lb.push(
            unsafe (DeclStmt::create(self.ctx, at, unsafe (vd as unsafe *Decl)) as unsafe *Stmt),
        )

        return vd
    }

    priv fn _slot_put(self,
                      at:   SourceRange,
                      slot: unsafe *VariableDecl,
                      v:    unsafe *Expr) -> unsafe *Expr {
        var unsafe *p = Expressions::PanicOpExpr::create(
            self.ctx,
            at,
            Expressions::PanicOp::SlotPut,
            v,
            self.synth.use_of(slot, at, Expr::ValueCategory::LValue),
        )

        p->type_          = self.sc->builtin(BuiltinKind::Void)
        p->value_category = Expr::ValueCategory::RValue
        return p
    }

    priv fn _fwd(self,
                 at:    SourceRange,
                 which: Expressions::PanicOp,
                 to:    unsafe *Type,
                 v:     unsafe *Expr) -> unsafe *Expr {
        var unsafe *p = Expressions::PanicOpExpr::create(self.ctx, at, which, v, &null)
        p->type_          = to
        p->value_category = Expr::ValueCategory::RValue
        return p
    }

    /// The value type T of a panic result type.
    priv fn _value_of(self, rc: unsafe *Type) -> unsafe *Type {
        var args = self.tu.record_args(self.tu.as_value(rc))
        if args.size() == 0 {
            kairo::std::ice_fail("PanicLowering: a panic result with no value type")
        }

        return canon_unqual(args[0])
    }

    /// `(h.value as T&&)`: the value moved out of the held result.
    priv fn _read_value(self,
                        at: SourceRange,
                        h:  unsafe *VariableDecl,
                        vt: unsafe *Type) -> unsafe *Expr {
        var unsafe *r = self.q.panic_value_ref(
            at,
            self.synth.use_of(h, at, Expr::ValueCategory::LValue),
            vt,
        )

        return self._rref(at, r, vt)
    }

    priv fn _ok(self, at: SourceRange, h: unsafe *VariableDecl) -> unsafe *Expr {
        return self.q.panic_is_ok(at, self.synth.use_of(h, at, Expr::ValueCategory::LValue))
    }

    priv fn _not(self, at: SourceRange, e: unsafe *Expr) -> unsafe *Expr {
        var unsafe *u = Expressions::UnaryOperatorExpr::create(
            self.ctx,
            at,
            e,
            self.synth.punct(at, TokenKind::OpExclaim),
            Expressions::UnaryOperatorExpr::Fix::Prefix,
        )

        u->type_          = self.sc->builtin(BuiltinKind::Bool)
        u->value_category = Expr::ValueCategory::RValue
        return u
    }

    priv fn _rref(self, at: SourceRange, e: unsafe *Expr, t: unsafe *Type) -> unsafe *Expr {
        return self.synth.cast_to(
            at,
            e,
            self.sc->types->cxx_rref(canon_unqual(t)),
            Expressions::CastMode::Default,
        )
    }

    priv fn _block(self,
                   at:          SourceRange,
                   const stmts: cxx::std::vector<unsafe *Stmt>) -> unsafe *CompoundStmt {
        var unsafe *blk = CompoundStmt::create(self.ctx, at)
        var        lb   = self.list_builder<unsafe *Stmt>()
        for var i: usize = 0; i < stmts.size(); ++i {
            lb.push((stmts)[i])
        }

        lb.freeze_into(&blk->body)
        return blk
    }

    /// \p v as \p t when only a builtin conversion lies between them (the
    /// payload is built from braces, which refuse a narrowing).
    priv fn _conv(self, v: unsafe *Expr, t: unsafe *Type) -> unsafe *Expr {
        if v == &null || v->type_ == &null {
            return v
        }

        var unsafe *have = canon_unqual(v->type_)
        if have != &null && isa<CXXRValueRefType>(have) {
            have = canon_unqual(cast<CXXRValueRefType>(have)->referee)
        }

        if have != &null && isa<CXXLValueRefType>(have) {
            have = canon_unqual(cast<CXXLValueRefType>(have)->referee)
        }

        var unsafe *want = canon_unqual(t)
        if have == &null || want == &null || have == want {
            return v
        }

        if have->kind == TypeKind::RecordType || want->kind == TypeKind::RecordType {
            return v
        }

        if self.tu.is_never(have) {
            return v
        }

        return self.synth.cast_to(v->range, v, want, Expressions::CastMode::Default)
    }

    /// A local or by-value parameter named whole, moved: it is the value's
    /// last use (a `return` or a `panic` leaves), which C++ would move from
    /// on its own in a plain `return x`. Anything else as it is.
    priv fn _moved_local(self, v: unsafe *Expr) -> unsafe *Expr {
        var unsafe *e = self.tu.strip_parens(v)
        if e == &null || !isa<NamedIdentExpr>(e) || e->type_ == &null {
            return v
        }

        var unsafe *c = canon_unqual(e->type_)
        if c == &null || c->kind != TypeKind::RecordType {
            return v
        }

        var unsafe *d = cast<NamedIdentExpr>(e)->resolved_decl
        if d == &null {
            return v
        }

        var t: unsafe *Type = &null
        if isa<VariableDecl>(d) {
            var unsafe *vd = cast<VariableDecl>(d)
            if vd->storage == StorageClass::Static || vd->raw_slot {
                return v
            }

            var unsafe *dc = vd->semantic_dc
            if dc == &null || dc->is_translation_unit() || dc->is_type_scope() {
                return v
            }

            var unsafe *o = dc->owner_decl()
            if o != &null && isa<ModuleDecl>(o) {
                return v
            }

            t = vd->type_
        } else if isa<ParamDecl>(d) {
            var unsafe *p = cast<ParamDecl>(d)
            if p->is_self || p->mode != ParamMode::Value {
                return v
            }

            t = p->type_
        } else {
            return v
        }

        if t == &null || t->canonical == &null {
            return v
        }

        var unsafe *tc = canon_unqual(t->canonical)
        if isa<CXXLValueRefType>(tc) || isa<CXXRValueRefType>(tc) || tc != c {
            return v
        }

        return self._rref(v->range, v, c)
    }
}

/// M2's panic facts (Compiler/Spec/Panic.md#generic-bodies, Compiler/Spec/Generics.md#decisions): what each live instance of
/// a generic function -- or of a generic record, for its methods -- needs
/// of the panic system, by SUBSTITUTION into what the definition recorded,
/// never by re-checking the body:
///   - the function's result at the instance's arguments, canonical
///     (InstanceEntry::panic_result): the explicit instantiation spells it,
///     a static_assert pins C++'s ordering (`__kairo_pset`) to it;
///   - every dependent panic result its body names (FunctionDecl::
///     panic_deps), formed (InstanceEntry::panic_types): EmitPlan admits
///     them so each element's `__kairo_tid` is written where C++ may form
///     the result; a collision is reported where it forms;
/// Run per TU after the lowerings (Sema's M2 stage), over every live entry
/// not done yet: a generic's own TU lowered first (imports go first), so
/// its facts are recorded by then. An entry made live later is done by the
/// TU that made it live.
pub class PanicInstances {
    pub var  sc:          unsafe *SemaContext
    priv var tu:          TypeUtil
    priv var _formed_any: bool                = false

    fn PanicInstances(self, sc: unsafe *SemaContext) {
        self.sc = sc
        self.tu = TypeUtil(sc)
    }

    /// True when it formed a panic result type the layout sweep has not
    /// seen (EnumLayoutQuery::sweep must run again for its ids).
    fn run(self) -> bool {
        if self.sc->instances == &null || PanicSets(self.sc).panic_enum() == &null {
            return false
        }

        var all = cxx::std::vector<unsafe *InstanceEntry>()
        self.sc->instances->collect(&all)
        for var i: usize = 0; i < all.size(); ++i {
            var unsafe *e = all[i]
            if e == &null || e->depth == 0 || e->panic_done || e->primary == &null {
                continue
            }

            var dep = false
            for var k: usize = 0; k < e->args.size(); ++k {
                if panic_dep(e->args[k]) {
                    dep = true
                }
            }

            if dep {
                continue
            }

            e->panic_done = true
            var unsafe *prim = e->primary
            if isa<FunctionDecl>(prim) {
                var unsafe *f = cast<FunctionDecl>(prim)
                if !self._has_facts(f) {
                    continue
                }

                var d = Deduction(self.sc, &null)
                self._bind_instance(&d, e, prim)
                self._facts(e, f, &d, true)
                continue
            }

            var ms = self._methods_of(prim)
            if ms.size() == 0 {
                continue
            }

            var unsafe *rt = if (e->decl != &null) => (self.sc->types->record(
                                 e->decl,
                                 unsafe &e->args,
                             ))
                             else => &null
            for var k: usize = 0; k < ms.size(); ++k {
                var unsafe *m = ms[k]
                if m == &null || !self._has_facts(m) {
                    continue
                }

                var d = Deduction(self.sc, &null)
                if rt != &null {
                    d.bind_from_record(rt)
                }

                self._facts(e, m, &d, false)
            }
        }

        return self._formed_any
    }

    priv fn _has_facts(self, f: unsafe *FunctionDecl) -> bool {
        var unsafe *h = panic_home(f)
        if h->panic_result != &null && panic_dep(h->panic_result) {
            return true
        }

        return h->panic_deps.size() > 0
    }

    /// \p e's arguments bound to \p prim's parameters (an extension
    /// member's extension's first), ConformanceChecking's order.
    priv fn _bind_instance(self, d: *Deduction, e: unsafe *InstanceEntry, prim: unsafe *Decl) {
        var        k: usize = 0
        var unsafe *x       = decl_extension_of(prim)
        if x != &null {
            var        eps = decl_generic_params(x)
            var unsafe *xr = NameLookup::representative(x)
            for var i: usize = 0; i < eps.size() && k < e->args.size(); ++i {
                if eps[i] != &null {
                    d->bind(xr, eps[i]->index, e->args[k])
                }

                k += 1
            }
        }

        var        gps = decl_generic_params(prim)
        var unsafe *pr = NameLookup::representative(prim)
        for var i: usize = 0; i < gps.size() && k < e->args.size(); ++i {
            var unsafe *gp = gps[i]
            if gp == &null {
                k += 1
                continue
            }

            if gp->is_pack {
                d->open_pack(pr, gp->index)
                while k < e->args.size() {
                    d->push_pack(pr, gp->index, e->args[k])
                    k += 1
                }

                break
            }

            d->bind(pr, gp->index, e->args[k])
            k += 1
        }
    }

    priv fn _methods_of(self, d: unsafe *Decl) -> FrozenList<unsafe *FunctionDecl> {
        if isa<ClassDecl>(d) {
            return cast<ClassDecl>(d)->methods
        }

        if isa<StructDecl>(d) {
            return cast<StructDecl>(d)->methods
        }

        if isa<UnionDecl>(d) {
            return cast<UnionDecl>(d)->methods
        }

        return create_empty_frozen_list<unsafe *FunctionDecl>()
    }

    priv fn _facts(self,
                   e:   unsafe *InstanceEntry,
                   f:   unsafe *FunctionDecl,
                   d:   *Deduction,
                   own: bool) {
        var unsafe *h = panic_home(f)
        var        at = if (e->use_at.start.is_valid()) => (e->use_at) else => f->range
        if own && h->panic_result != &null {
            var unsafe *r = self._at(e, at, h->panic_result, d)
            if r != &null {
                e->panic_result = r
            }
        }

        for var i: usize = 0; i < h->panic_deps.size(); ++i {
            self._at(e, at, h->panic_deps[i], d)
        }
    }

    /// Dependent panic result \p t at the instance \p e, formed and kept
    /// in its panic_types (null when it does not substitute). A concrete
    /// \p t is any instance's: formed where it is named, as it is.
    priv fn _at(self,
                e:  unsafe *InstanceEntry,
                at: SourceRange,
                t:  unsafe *Type,
                d:  *Deduction) -> unsafe *Type {
        if t == &null {
            return &null
        }

        if !panic_dep(t) {
            return t
        }

        var unsafe *x = d->substitute(t)
        if x == &null || panic_dep(x) {
            return &null
        }

        var args = self.tu.record_args(self.tu.as_value(x))
        if args.size() == 0 {
            return &null
        }

        var els = cxx::std::vector<unsafe *Type>()
        for var i: usize = 1; i < args.size(); ++i {
            els.push_back(canon_unqual(args[i]))
        }

        var unsafe *r = PanicSets(self.sc).form(at, canon_unqual(args[0]), unsafe &els)
        if r == &null {
            return &null
        }

        var unsafe *c = canon_unqual(r)
        for var i: usize = 0; i < e->panic_types.size(); ++i {
            if e->panic_types[i] == c {
                return c
            }
        }

        e->panic_types.push_back(c)
        self._formed_any = true
        return c
    }
}
