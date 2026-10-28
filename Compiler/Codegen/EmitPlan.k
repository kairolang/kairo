/// --- The Kairo Project ------------------------- Codegen/EmitPlan.k --- ///
///
///   \brief Per emitted TU, work out every declaration the C++ needs, how
///          much of each (`class X;` or the body-less definition), and the
///          order they must appear in.
///
///   \detail
///     IMPORTS.md §0: imports are erased at name resolution. After N and
///     ChainBinding every use site holds a `*Decl`, and the decl knows its
///     own home through the DeclContext chain. Nothing here reads an
///     `ImportDecl`. What a C++ TU needs is a DECLARATION of everything it
///     names -- own decls included, since the class definition text must
///     come from one emitter wherever it lands (invariant 12).
///
///     Four tiers (IMPORTS.md §6.3 plus the instantiation tier):
///
///       0  every namespace-scope type as a forward declaration, and every
///          extension scope (`struct __kairo_ext_X;`) the plan touches
///       1  type definitions, topologically sorted on Complete edges only;
///          an extension scope's definition after its target's
///       2  function and namespace-scope variable declarations (`extern`),
///          any order (extension members are not here: they are static
///          members of their scope)
///       3  explicit instantiations: `template class X<A>;` in the instance's
///          home TU, `extern template ...` everywhere else
///
///     Three modes decide the ROOTS; the closure and ordering are identical:
///
///       Preamble  every own decl (all visibilities) + everything foreign it
///                 reaches. What the TU's .cpp starts with.
///       Header    own `pub` decls + what they reach. What the module's
///                 .hh contains; the emitter turns a foreign Complete entry
///                 into an `#include` and a foreign Fwd entry into a
///                 forward declaration.
///       Include   a Header's roots and bodies, emitted as a Preamble is:
///                 foreign entries inline, no directive. What
///                 `#include "foo.k"` gives a C++ TU (Backend/
///                 IncludeEmitter.k): a priv or internal decl gets there
///                 only when an inline or template body names it.
///
///     A Complete cycle is TypeCycleCheck's to report, in sema; here the
///     sort asserts. Output is ordered by (fid, offset) inside a tier so the
///     same input produces the same plan on every machine.
///
///   Import law: CodegenContext only.
///
///   Phase: CODEGEN (produces CodegenPhase::Planned)
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import Codegen::CodegenContext::*;
import Codegen::CodegenICE::*;
import Codegen::Emit::CXXSpell::*;
import Codegen::Emit::EmitWitness::*;
import AST::Context::ASTContext::*;
import AST::Context::DeclContext::*;
import AST::Context::TranslationUnit::*;
import AST::Context::SymbolTable::*;
import AST::Context::InstantiationRegistry::*;
import AST::ASTSupport::*;
import AST::ParamMode::*;
import AST::DeclFacts::*;
import AST::LangItems::*;
import Lexer::Immediate::*;
import AST::Node::Base::*;
import AST::Node::Program::*;
import AST::Node::Types::*;
import AST::Node::CanonicalNodes::*;
import AST::Node::Expressions::*;
import AST::Node::Statements::*;
import AST::Node::PrimaryExpressions::*;
import AST::Node::Declarations::*;
import AST::Node::Casting::*;
import AST::Kind::DeclKind::*;
import AST::Kind::TypeKind::*;
import AST::Kind::ExprKind::*;
import AST::Visitor::RecursiveASTVisitor::*;
import Location::SourceManager::*;

/// A module's header carries what another module may name. `priv` is out by
/// definition, and so is `internal`: it is visible within its own module and
/// nowhere else, which is exactly what a header crosses.
fn _hidden_in_header(v: u8) -> bool {
    return (v == VIS_PRIV()) || (v == VIS_INTERNAL());
}

enum PlanNeed derives u8 {
    Fwd = 0,   ///< `class X;` is enough.
    Complete,  ///< the body-less definition must precede.
}

enum PlanTier derives u8 {
    FwdDecls = 0,
    Definitions,
    Functions,
    Instantiations,
}

enum PlanMode derives u8 {
    Preamble = 0,
    Header,
    Include,
}

/// `struct N::__kairo_ext_X`: every extension member of target X declared in
/// namespace N, as one struct of static members (RESOLUTION.md §2b). One per
/// (N, X); every extend block in that scope contributes. Always COMPLETE --
/// all its blocks, priv members included -- so its text is the same in every
/// TU and header that carries it (invariant 11).
/// What one compile-time item needs before C++ evaluates it (EVAL.md
/// §11): an `eval` / `constexpr` body, or an eval binding's initializer.
/// `items`: the compile-time bodies it calls (eval fns, eval and constexpr
/// constructors and operators, an eval field's thunk) and the eval bindings
/// it reads, each needed DEFINED before the item is evaluated. `const_items`:
/// the subset C++ evaluates where the item is DEFINED (what a type inside
/// it computes, an eval local's initializer), each needed defined before
/// the item's own definition. `recs`: the records it lays out or looks
/// into, needed COMPLETE before its definition. EmitPlan::_early reads
/// these on the lowered tree; EvalUsageChecking::EvalNeeds is the Sema
/// side, which reports what no order satisfies.
/// Every hoisted local declaration (CXXSpell::is_hoisted_local) a TU's
/// program holds, in source order, an enclosing one before those nested in
/// it. The plan roots each one as an own declaration and EmitIR emits each
/// one's bodies at namespace scope, so both walk the same list.
class HoistedLocals derives RecursiveASTVisitor::<HoistedLocals> {
    pub var found: vec::<*Decl>;

    fn HoistedLocals(self) { }

    fn run(self, tu: *TranslationUnit) {
        if (tu == &null) || (tu->program == &null) { return; }
        var items = &(tu->program->items);
        for var i: usize = 0; i < items->size(); ++i {
            var item = *(items->get(i));
            switch item.get_kind() {
                case TopLevelKind::Decl { self.dyn()->dispatch_decl(item.as_decl()); }
                case TopLevelKind::Stmt { self.dyn()->dispatch_stmt(item.as_stmt()); }
                case TopLevelKind::Expr { self.dyn()->dispatch_expr(item.as_expr()); }
            }
        }
    }

    fn visit_decl_stmt(self, n: *DeclStmt) -> bool {
        if (n == &null) || (n->decl == &null) || n->decl->is_poisoned() { return true; }
        if CXXSpell::is_hoisted_local(n->decl) { self.found.push_back(n->decl); }
        return true;
    }
}

class EarlyNeeds derives RecursiveASTVisitor::<EarlyNeeds> {
    pub var items:       vec::<*Decl>;
    pub var const_items: vec::<*Decl>;
    pub var recs:        vec::<*Decl>;
    /// > 0 inside an eval local's initializer: what it reads is a const item.
    priv var _const: u32 = 0;

    fn EarlyNeeds(self) { }

    /// A compile-time body or an eval binding, as an item: the defining
    /// link of a function (what EmitIR emits), an eval field as its thunk;
    /// null for anything else.
    static fn item_of(d: *Decl) -> *Decl {
        if d == &null { return &null; }
        var f = dyn_cast::<FunctionDecl>(d);
        if f != &null {
            if (!f->is_eval()) && (!f->is_constexpr()) { return &null; }
            var def = f;
            if !def->has_body() { def = f->definition(); }
            if (def == &null) || def->is_poisoned() || (def->body_kind != FnBodyKind::Block) { return &null; }
            return static_cast::<*Decl>(def);
        }
        var v = dyn_cast::<VariableDecl>(d);
        if (v != &null) && v->is_eval() && (v->init != &null) && (!v->is_poisoned()) {
            var dc = reinterpret_cast::<*DeclContext>(v->semantic_dc);
            if (dc != &null) && ((dc->dc_kind == DeclContextKind::TranslationUnit) || (dc->dc_kind == DeclContextKind::Module)) { return d; }
            return &null;
        }
        var fd = dyn_cast::<FieldDecl>(d);
        if (fd != &null) && fd->is_eval() && (fd->init_fold == FieldFold::Thunk) { return EarlyNeeds::item_of(fd->init_thunk); }
        return &null;
    }

    fn named(self, d: *Decl) {
        if d == &null { return; }
        var dc = reinterpret_cast::<*DeclContext>(d->semantic_dc);
        if (dc != &null) && dc->is_type_scope() && (dc->dc_kind != DeclContextKind::Extension) && (dc->owner_decl() != &null) {
            self._rec(dc->owner_decl());
        }
        var it = EarlyNeeds::item_of(d);
        if it == &null { return; }
        EarlyNeeds::_once(&(self.items), it);
        if self._const > 0 { EarlyNeeds::_once(&(self.const_items), it); }
    }

    static fn _once(v: *vec::<*Decl>, d: *Decl) {
        for var i: usize = 0; i < v->size(); ++i { if (*v)[i] == d { return; } }
        v->push_back(d);
    }

    priv fn _rec(self, d: *Decl) {
        if d != &null { EarlyNeeds::_once(&(self.recs), d); }
    }

    /// The records \p t holds by value (raw: EmitPlan maps each to its
    /// plan entry), and the items its computed values name.
    fn rec_type(self, t: *Type) {
        if t == &null { return; }
        var c = t->canonical;
        if c == &null { c = t; }
        switch c->kind {
            case TypeKind::QualifiedType { self.rec_type(cast::<QualifiedType>(c)->inner); }
            case TypeKind::RecordType {
                var rt = cast::<RecordType>(c);
                self._rec(rt->decl);
                for var i: usize = 0; i < rt->args.size(); ++i { self.values(*(rt->args.get(i))); }
                // `L<i32>::P` is laid out inside L<i32>'s instantiation.
                if rt->outer != &null { self.rec_type(rt->outer); }
            }
            case TypeKind::FixedArrayType {
                self.rec_type(cast::<FixedArrayType>(c)->element);
                self.values(cast::<FixedArrayType>(c)->extent_param);
            }
            case TypeKind::NullableType {
                var lw = cast::<NullableType>(c)->lowered;
                if lw != &null { self.rec_type(lw); } else { self.rec_type(cast::<NullableType>(c)->inner); }
            }
            case TypeKind::TypeExpr { self.values(c); }
            default { break; }
        }
    }

    /// The items a computed value (EVAL.md 0.2) names: C++ evaluates it
    /// where it is spelled, so they are const items. An eval class it
    /// constructs is needed complete, with every compile-time member (its
    /// constructor, its field defaults' thunks).
    fn values(self, t: *Type) {
        var v = dyn_cast::<TypeExpr>(t);
        if (v == &null) || (!v->is_value) || v->is_exact() { return; }
        self._const += 1;
        if v->vop == ValueOp::Str {
            self.rec_type(v->vty);
            var sr = dyn_cast::<RecordType>(canon_unqual(v->vty));
            if sr != &null { self._members(sr->decl); }
        } else if (v->vdecl != &null) && ((v->vop == ValueOp::Call) || (v->vop == ValueOp::Decl)) {
            if isa::<ClassDecl>(v->vdecl) || isa::<StructDecl>(v->vdecl) {
                self._rec(v->vdecl);
                self._members(v->vdecl);
            } else {
                var local = (v->vdecl->semantic_dc == &null) || CXXSpell::in_function_scope(v->vdecl);
                if !local { self.named(v->vdecl); }
            }
        }
        for var i: usize = 0; i < v->vops.size(); ++i { self.values(v->vops[i]); }
        self._const -= 1;
    }

    /// Every compile-time member of record \p d with a body, as items.
    priv fn _members(self, d: *Decl) {
        var ms: *FrozenList::<*FunctionDecl> = &null;
        if isa::<ClassDecl>(d)       { ms = &(cast::<ClassDecl>(d)->methods); }
        else if isa::<StructDecl>(d) { ms = &(cast::<StructDecl>(d)->methods); }
        if ms == &null { return; }
        for var i: usize = 0; i < ms->size(); ++i {
            var m = (*ms)[i];
            if m == &null { continue; }
            var it = EarlyNeeds::item_of(static_cast::<*Decl>(m));
            if it == &null { continue; }
            EarlyNeeds::_once(&(self.items), it);
            if self._const > 0 { EarlyNeeds::_once(&(self.const_items), it); }
        }
    }

    fn visit_expr(self, e: *Expr) -> bool {
        if e == &null { return true; }
        if e->type_ != &null { self.rec_type(e->type_); }
        switch e->kind {
            case ExprKind::NamedIdentExpr { self.named(cast::<NamedIdentExpr>(e)->resolved_decl); }
            case ExprKind::ChainExpr {
                var ch = cast::<ChainExpr>(e);
                for var i: usize = 0; i < ch->steps.size(); ++i {
                    var st = ch->steps.get(i);
                    if st != &null { self.named(st->resolved_decl); }
                }
            }
            case ExprKind::CallExpr { self.named(cast::<CallExpr>(e)->ctor_decl); }
            case ExprKind::BinaryOperatorExpr { self.named(cast::<BinaryOperatorExpr>(e)->resolved_op); }
            case ExprKind::UnaryOperatorExpr { self.named(cast::<UnaryOperatorExpr>(e)->resolved_op); }
            case ExprKind::SizeOfExpr { self.rec_type(cast::<SizeOfExpr>(e)->type_arg); }
            case ExprKind::AlignOfExpr { self.rec_type(cast::<AlignOfExpr>(e)->type_arg); }
            default { break; }
        }
        return true;
    }

    fn visit_decl(self, d: *Decl) -> bool {
        if d == &null { return true; }
        switch d->kind {
            case DeclKind::VariableDecl { self.rec_type(cast::<VariableDecl>(d)->type_); }
            case DeclKind::ParamDecl {
                var p = cast::<ParamDecl>(d);
                if !p->is_self { self.rec_type(p->type_); }
            }
            case DeclKind::FunctionDecl { self.rec_type(cast::<FunctionDecl>(d)->return_type); }
            default { break; }
        }
        return true;
    }

    /// An eval local's initializer is a constant expression C++ evaluates
    /// at the definition (`constexpr T k = g(1);`).
    fn traverse_variable_decl(self, n: *VariableDecl) -> *VariableDecl {
        var ev = n->is_eval() && (n->semantic_dc != &null) && CXXSpell::in_function_scope(static_cast::<*Decl>(n));
        if ev { self._const += 1; }
        var r = RecursiveASTVisitor::<EarlyNeeds>::traverse_variable_decl(n);
        if ev { self._const -= 1; }
        return r;
    }

    fn visit_type(self, t: *Type) -> bool {
        if (t != &null) && (t->canonical != &null) { self.values(t->canonical); }
        return true;
    }
}

class ExtScope {
    pub var ns:        vec::<string>;
    pub var name:      string;                ///< `__kairo_ext_X`.
    /// The target's layout decl for a record (a generic one's primary), or
    /// null for a builtin, which is keyed by `target_ty` instead.
    pub var target:    *Decl = &null;
    /// The record target's TEMPLATE (EmitPlan::_scope_key): what scopes are
    /// matched on, so every specialization's extensions share one struct.
    pub var key:       *Decl = &null;
    pub var target_ty: *Type = &null;
    /// The first extend block in source order: where the scope sits.
    pub var anchor:    *ExtensionDecl = &null;
    /// Every member, in source order, parallel to the block it was written in.
    pub var members:   vec::<*FunctionDecl>;
    pub var exts:      vec::<*ExtensionDecl>;
    /// What the definition and its operator forwarders need complete: the
    /// target, and every by-value record a forwarder's signature names (a
    /// forwarder is an inline DEFINITION, and a definition lays them out).
    pub var deps:      vec::<*Decl>;
    /// A member is reachable from the plan's roots. Header mode defines only
    /// reachable scopes; an unreachable one is declared for a friend line.
    pub var reachable: bool = false;

    fn ExtScope(self) { }
}

/// Whether a namespace-scope variable's initializer names a member C++
/// will see non-public (CXXSpell::cxx_access): a field, method, static,
/// constructor or operator of a record. Such a variable is initialized
/// through a befriended thunk (EmitIR::_global_var), since a C++ variable
/// initializer is checked in the variable's own context, which nothing can
/// befriend. Read off the typed tree, which every TU holding the file has.
class GlobalInitReach derives RecursiveASTVisitor::<GlobalInitReach> {
    pub var spell: *CXXSpell = &null;
    pub var hit: bool = false;

    fn GlobalInitReach(self) { }

    static fn needs_thunk(spell: *CXXSpell, v: *VariableDecl) -> bool {
        if (v == &null) || (v->init == &null) || v->is_eval() || v->is_poisoned() { return false; }
        if (v->type_ == &null) || (v->type_->canonical == &null) { return false; }
        // No function returns an array: its initializer stays where it is.
        if canon_unqual(v->type_->canonical)->kind == TypeKind::FixedArrayType { return false; }
        var r = GlobalInitReach();
        r.spell = spell;
        r.dyn()->dispatch_expr(v->init);
        return r.hit;
    }

    priv fn _see(self, d: *Decl) {
        if (d == &null) || self.hit || decl_is_imported(d) { return; }
        var dc = reinterpret_cast::<*DeclContext>(d->semantic_dc);
        if (dc == &null) || (!dc->is_type_scope()) || (dc->dc_kind == DeclContextKind::Extension) { return; }
        if self.spell->cxx_access(d) != VIS_PUB() {
            self.hit = true;
            self.stop = true;
        }
    }

    fn visit_chain_expr(self, n: *ChainExpr) -> bool {
        for var i: usize = 0; i < n->steps.size(); ++i {
            var st = n->steps.get(i);
            if st != &null { self._see(st->resolved_decl); }
        }
        return true;
    }
    fn visit_named_ident_expr(self, n: *NamedIdentExpr) -> bool { self._see(n->resolved_decl); return true; }
    fn visit_call_expr(self, n: *CallExpr) -> bool { self._see(n->ctor_decl); return true; }
    fn visit_binary_operator_expr(self, n: *BinaryOperatorExpr) -> bool { self._see(n->resolved_op); return true; }
    fn visit_assign_operator_expr(self, n: *AssignOperatorExpr) -> bool { self._see(n->resolved_op); return true; }
    fn visit_unary_operator_expr(self, n: *UnaryOperatorExpr) -> bool { self._see(n->resolved_op); return true; }
    fn visit_subscript_expr(self, n: *SubscriptExpr) -> bool { self._see(n->resolved_op); return true; }
    fn visit_type_cast_expr(self, n: *TypeCastExpr) -> bool {
        self._see(n->resolved_op);
        self._see(n->resolved_ctor);
        return true;
    }
}

/// What a record's definition befriends (EmitPlan::file_friends): the
/// entities of its OWN file that may reach its `private:` / `protected:`
/// members, read off that file's declarations alone, so the list -- like
/// the rest of the record's text -- is the same in every TU, header and
/// include stream that defines the record. Friends change neither layout
/// nor mangling on any target; the access levels do, which is why they
/// cannot vary by view and these lines carry the difference instead.
class FileFriends {
    /// The record has a non-public member at all; nothing else is filled
    /// when it has none.
    pub var needed:  bool = false;
    /// Every other outermost record of the file, and every hoisted local
    /// one (`friend ::ns::X;`, `template <...> friend class ::ns::G;`): a
    /// friend class covers its members and nested classes. Parallel:
    /// `fresh` spells a generic one's head with names of its own, since the
    /// record's own template parameters may not be redeclared inside it.
    pub var records: vec::<*Decl>;
    pub var fresh:   vec::<bool>;
    /// The file's free functions in the record's namespace, generic ones
    /// and hoisted locals included (unqualified `friend R f(P);`).
    pub var fns:     vec::<*FunctionDecl>;
    /// Parallel to `fns`: befriended by its qualified name, after its own
    /// declaration ahead of every record (EmitPlan::friend_early).
    pub var far:     vec::<bool>;
    /// One extension of each scope struct in the record's namespace whose
    /// target is another type (unqualified `friend struct __kairo_ext_X;`);
    /// the record's own scopes are friend_scopes_of's.
    pub var scopes:  vec::<*ExtensionDecl>;
    /// The interfaces the file declares the record implements, with what
    /// they derive: their witness primaries forward to its members.
    pub var ifaces:  vec::<*Decl>;
    /// The program's `main`, when it is in this file.
    pub var main:    *FunctionDecl = &null;
    /// The file's namespace-scope variables in the record's namespace
    /// initialized through a thunk (GlobalInitReach): the thunk is the
    /// friend (`friend T __kairo_ginit_x();`).
    pub var globals: vec::<*VariableDecl>;

    fn FileFriends(self) { }
}

class PlanEntry {
    pub var decl:    *Decl          = &null;
    pub var need:    PlanNeed       = PlanNeed::Fwd;
    pub var tier:    PlanTier       = PlanTier::FwdDecls;
    pub var fid:     u32            = 0;
    pub var off:     usize          = 0;
    pub var own:     bool           = false;   ///< declared by the TU being emitted.
    /// Tier 3 only: the instance. `decl` is the primary.
    pub var inst:    *InstanceEntry = &null;
    /// Tier 3 only: this TU defines the instantiation.
    pub var is_home: bool           = false;
    /// Tiers 0 and 1: the extension scope this entry declares or defines,
    /// or null. `decl` is then the scope's anchor, for position only.
    pub var scope:   *ExtScope      = &null;
    /// Tiers 0 and 1: the witness piece this entry declares or defines
    /// (CODEGEN.md §7b.6), or null. `decl` is then its InterfaceDecl.
    pub var witness: *WitnessPiece  = &null;
    /// Tier 0 only, with `witness` a primary: this entry defines its
    /// concept, not its forward declaration.
    pub var is_concept: bool        = false;
    /// Tier 1 only: an early item (EmitPlan::early, EVAL.md §11) -- a
    /// compile-time body or an eval binding this entry DEFINES, ahead of
    /// the records whose types need it. `decl` is the item too.
    pub var eval_item: *Decl        = &null;

    fn PlanEntry(self) { }
}

class EmitPlan derives RecursiveASTVisitor::<EmitPlan> {
    priv var _cg:    obs::<CodegenContext>;
    priv var _spell: CXXSpell;
    priv var _mode:  PlanMode = PlanMode::Preamble;
    priv var _home:  u32 = 0;

    priv var _set:   vec::<*Decl>;
    priv var _need:  vec::<PlanNeed>;
    priv var _queue: vec::<usize>;
    priv var _insts: vec::<*InstanceEntry>;
    /// Member-template instances admitted (no tier-3 line, so not _insts):
    /// their reach is followed once.
    priv var _members: vec::<*InstanceEntry>;
    /// Every extension scope the plan touches. Indexed while the closure
    /// runs (it grows); PlanEntry::scope points in only once it is done.
    priv var _scopes:   vec::<ExtScope>;
    /// Every witness piece the plan holds: interface primaries and row
    /// specializations. Index-based while the closure runs, as _scopes.
    priv var _witnesses: vec::<WitnessPiece>;
    /// Rows whose ConformanceRow::assoc_rows _witness_row has followed.
    priv var _assoc_seen: vec::<*ConformanceRow>;

    /// Memo for param_by_value: (primary, index) -> answer. Pairs, linear
    /// scan; a build has tens of generic primaries, not thousands.
    priv var _pbv_key:  vec::<u64>;
    priv var _pbv_val:  vec::<bool>;
    priv var _pbv_depth: usize = 0;

    pub var entries: vec::<PlanEntry>;

    /// Some type the plan admits is a Kairo `fn(A) -> R` value (a
    /// signature, a field, a local, a closure in a body): the preamble
    /// must define `::__kairo_fn` (InterfaceEmitter::_fn_value_helper).
    /// Only then, so a TU that names none keeps its text.
    pub var needs_fn_value: bool = false;
    /// A body holds a `try`'s raw-storage slot (PanicLowering) with no Panic
    /// result in sight: a `try` with only C++ exception arms whose value is
    /// put in a slot. The preamble must define `::__kairo_raw`, which it
    /// otherwise writes with the Panic lang item's helpers.
    pub var needs_raw_slot: bool = false;
    /// Compile-time string literals too long for `__kairo_estr<...>`
    /// (LowerTargets::eval_str_inline_max, EVAL.md §11), once each by
    /// content: InterfaceEmitter defines each as a named `inline constexpr`
    /// array at global scope, ahead of every body and type that spells it.
    /// Parallel: the bytes, their count, their eval_str_hash.
    pub var big_str_bytes:  vec::<std::ConstPtr::<u8>>;
    pub var big_str_lens:   vec::<usize>;
    pub var big_str_hashes: vec::<u64>;
    /// A type the plan admits holds a string value node (a string literal
    /// in an eval class's value argument, EVAL.md 7e): its bytes are
    /// `__kairo_estr<...>`, so the eval helpers are written.
    pub var needs_eval_str: bool = false;
    /// A record defined here befriends the program's `main`
    /// (FileFriends::main): `friend int ::main(...)` names it qualified, so
    /// InterfaceEmitter declares it at global scope ahead of every record.
    pub var main_friend: *FunctionDecl = &null;
    /// Functions a friend line names qualified (FileFriends::far): each is
    /// declared in its own namespace ahead of the records, by its own
    /// declaration's text.
    pub var friend_early: vec::<*FunctionDecl>;

    /// Nothing of this TU's own to define. Written once, at the end of run().
    priv var _empty: bool = true;

    /// The early items (EVAL.md §11): every compile-time body (eval fn,
    /// eval or constexpr method, eval field thunk) and eval binding that a
    /// DECLARATION's type names through a computed value (`[i32; f(3)]`,
    /// `Buf<twice(1)>`, `Grid<Pt(2, 3)>`), and everything those read,
    /// transitively. C++ evaluates such a type where the declaration is
    /// written, in the interface, so each item is defined in tier 1 ahead of
    /// the records needing it (an entry with eval_item), and declared ahead
    /// of all of tier 1 (InterfaceEmitter); EmitIR then skips them.
    pub var early: vec::<*Decl>;
    /// Order edges among tier-1 entries that involve an early item:
    /// _eo_who[i] is written after _eo_dep[i].
    priv var _eo_who: vec::<*Decl>;
    priv var _eo_dep: vec::<*Decl>;
    /// EarlyNeeds per item, flattened: for item _en_key[i], _en_val[i] is an
    /// item it reads (kind 0), one it evaluates at its definition (1), or a
    /// record it needs complete (2).
    priv var _en_done: vec::<*Decl>;
    priv var _en_key:  vec::<*Decl>;
    priv var _en_kind: vec::<u8>;
    priv var _en_val:  vec::<*Decl>;

    fn EmitPlan(self, cg: *CodegenContext, mode: PlanMode = PlanMode::Preamble) {
        self._cg    = cg;
        self._spell = CXXSpell(cg);
        self._mode  = mode;
    }

    /// ICE naming the Kairo source at \p at (CodegenICE).
    priv fn _ice(self, at: SourceRange, msg: string) {
        codegen_ice(self._cg->ctx, at, msg);
    }

    fn run(self);
    fn is_empty(self) -> bool;
    fn visible_bodies(self) -> vec::<*FunctionDecl>;
    fn include_bodies(self) -> vec::<*FunctionDecl>;
    fn _bodies(self, want_own: bool) -> vec::<*FunctionDecl>;
    fn visible_eval_vars(self) -> vec::<*VariableDecl>;
    fn include_eval_vars(self) -> vec::<*VariableDecl>;
    fn _eval_vars(self, want_own: bool) -> vec::<*VariableDecl>;
    fn _place_eval_var(self, i: usize, pick: *vec::<*VariableDecl>, state: *vec::<u8>, out: *vec::<*VariableDecl>);
    fn _walk_visible(self);
    fn _find_escaping(self, tu: *TranslationUnit);
    fn _visible_record_bodies(self, d: *Decl, in_template: bool, out: *vec::<*FunctionDecl>);
    fn _push_body(self, f: *FunctionDecl, out: *vec::<*FunctionDecl>);
    fn _walk_body(self, f: *FunctionDecl);
    fn mode(self)  -> PlanMode;
    fn home(self)  -> u32;
    fn spell(self) -> *CXXSpell;
    fn _close(self);
    fn _order(self);
    fn _early(self);
    fn _early_needs(self, x: *Decl);
    fn _early_close(self, seeds: *vec::<*Decl>, kind: u8, out: *vec::<*Decl>);
    fn _decl_type_items(self, d: *Decl, out: *vec::<*Decl>);
    fn _type_items(self, t: *Type, out: *vec::<*Decl>);
    fn _eo_add(self, who: *Decl, dep: *Decl);
    fn _eo_has(self, who: *Decl, dep: *Decl) -> bool;
    fn _layout_key(self, d: *Decl) -> *Decl;
    fn is_early(self, d: *Decl) -> bool;
    fn _collect_uses(self);
    fn friend_scopes_of(self, d: *Decl, out: *vec::<*ExtScope>);
    fn file_friends(self, d: *Decl, out: *FileFriends);
    fn needs_friends(self, d: *Decl) -> bool;
    fn _ff_dc(self, dc: *DeclContext, d: *Decl, mine: *Decl, ns: *vec::<string>, tparams: *vec::<string>, out: *FileFriends);
    fn _ff_decl(self, x: *Decl, d: *Decl, mine: *Decl, ns: *vec::<string>, tparams: *vec::<string>, out: *FileFriends);
    fn _ff_record(self, r: *Decl, tparams: *vec::<string>, out: *FileFriends);
    fn _ff_fn_kind(self, f: *FunctionDecl, ns: *vec::<string>, tparams: *vec::<string>) -> u8;
    fn _ff_add_fn(self, f: *FunctionDecl, ns: *vec::<string>, tparams: *vec::<string>, out: *FileFriends);
    fn _ff_nested(self, t: *Type, depth: u32) -> bool;
    fn _ff_tparams(self, d: *Decl, out: *vec::<string>);
    fn _ff_clash(self, d: *Decl, tparams: *vec::<string>) -> bool;
    fn _ff_iface(self, t: *Type, out: *FileFriends, depth: u32);
    fn _ff_ifaces_in(self, cand: *Decl, d: *Decl, out: *FileFriends);
    fn _admit_friends(self, d: *Decl);
    fn dump(self, path: string);
    fn _tier_name(self, t: PlanTier) -> string;
    fn _need_name(self, n: PlanNeed) -> string;
    fn _kind_name(self, d: *Decl) -> string;
    fn _collect_own(self, dc: *DeclContext);
    fn _collect_own_decl(self, d: *Decl);
    fn _collect_own_globals(self);
    fn _collect_own_locals(self);
    fn _scope_for(self, x: *ExtensionDecl, reach: bool) -> usize;
    fn _fill_scope(self, k: usize, cand: *Decl);
    fn _same_scope(self, k: usize, x: *ExtensionDecl) -> bool;
    fn _scope_dep(self, k: usize, t: *Type);
    fn _scope_sig_dep(self, k: usize, t: *Type);
    fn _scope_add_dep(self, k: usize, d: *Decl);
    fn _witness_primary(self, iface: *Decl) -> usize;
    fn _witness_row(self, row: *ConformanceRow);
    fn _witness_declared(self, d: *Decl);
    fn _witness_bounds(self, f: *Decl);
    fn _witness_sig(self, k: usize, f: *FunctionDecl);
    fn _witness_dep(self, k: usize, t: *Type);
    fn _witness_scope(self, k: usize, x: *ExtensionDecl);
    fn visit_expr(self, e: *Expr) -> bool;
    fn note_eval_str(self, p: std::ConstPtr::<u8>, n: usize);
    fn visit_type(self, t: *Type) -> bool;
    fn visit_decl(self, d: *Decl) -> bool;
    fn _admit_use(self, d: *Decl);
    fn _admit_cell(self, cell: *OverloadCell);
    fn _member_owner(self, d: *Decl) -> *Decl;
    fn _admit(self, d: *Decl, need: PlanNeed);
    fn _admit_instance(self, e: *InstanceEntry, need: PlanNeed);
    fn _admit_reached(self, e: *InstanceEntry);
    fn _admit_type(self, t: *Type, need: PlanNeed);
    fn _nullable_record(self, c: *Type) -> *Type;
    fn _expand(self, d: *Decl, need: PlanNeed);
    fn _expand_fn(self, n: *FunctionDecl);
    fn _expand_member_sig(self, n: *FunctionDecl);
    fn _expand_type(self, d: *Decl);
    fn _bases(self, bases: *FrozenList::<InheritEdge>);
    fn _fields(self, fields: *FrozenList::<*FieldDecl>);
    fn _methods(self, methods: *FrozenList::<*FunctionDecl>);
    fn _collect_same_file_extensions(self, d: *Decl);
    fn _collect_ext_in(self, cand: *Decl, target: *Decl);
    fn _ext_target(self, x: *ExtensionDecl) -> *Decl;
    fn layout_decl(self, d: *Decl) -> *Decl;
    fn _scope_key(self, d: *Decl) -> *Decl;
    fn _admit_specs(self, c: *Decl, need: PlanNeed);
    fn _specs_after_primary(self, v: *vec::<PlanEntry>);
    fn adt_record(self, d: *Decl) -> *Decl;
    fn anon_union_of(self, f: *FieldDecl) -> *UnionDecl;
    fn _arg_by_value(self, prim: *Decl, i: usize) -> bool;
    fn param_by_value(self, prim: *Decl, idx: u32) -> bool;
    fn _param_by_value_walk(self, prim: *Decl, idx: u32) -> bool;
    fn _edges_reach_param(self, list: *FrozenList::<InheritEdge>, prim: *Decl, idx: u32) -> bool;
    fn _fields_reach_param(self, list: *FrozenList::<*FieldDecl>, prim: *Decl, idx: u32) -> bool;
    fn _type_reaches_param(self, t: *Type, prim: *Decl, idx: u32) -> bool;
    fn _same_root(self, a: u32, b: u32) -> bool;
    fn _same_ns_vec(self, a: *vec::<string>, b: *vec::<string>) -> bool;
    fn _entry(self, d: *Decl, need: PlanNeed, tier: PlanTier) -> PlanEntry;
    fn _sort(self, v: *vec::<PlanEntry>);
    fn _toposort(self, v: *vec::<PlanEntry>);
    fn _entry_needs(self, who: *PlanEntry, dep: *PlanEntry) -> bool;
    fn _needs_complete(self, who: *Decl, dep: *Decl) -> bool;
    fn value_param_record(self, who: *Decl, dep: *Decl) -> bool;
    fn _plannable(self, d: *Decl) -> bool;
    fn _is_requirement(self, d: *Decl) -> bool;
    fn _member_of_template(self, d: *Decl) -> bool;
    fn _is_global_var(self, d: *Decl) -> bool;
    fn _is_type_decl(self, d: *Decl) -> bool;
    fn _outermost_type(self, d: *Decl) -> *Decl;
    fn _index_of(self, d: *Decl) -> usize;
    fn _off_of(self, d: *Decl) -> usize;

}

/// "Does this layout reach \p target by value?" over the by-value spine:
/// records, tuples, fixed arrays, and a generic ARGUMENT only where the
/// primary stores that parameter by value. Pointers, references and the
/// (pre-migration) structural containers stop the walk.
class LayoutSpine {
    priv var _plan:   obs::<EmitPlan>;
    priv var _target: obs::<Decl>;

    fn LayoutSpine(self, plan: *EmitPlan, target: *Decl) {
        self._plan   = plan;
        // In the form reaches() compares against: layout_decl's, which for
        // an ADT is its layout record.
        self._target = plan->layout_decl(target);
    }

    fn bases(self, list: *FrozenList::<InheritEdge>) -> bool {
        for var i: usize = 0; i < list->size(); ++i {
            var e = list->get(i);
            if e == &null { continue; }
            if self.reaches(e->base) { return true; }
        }
        return false;
    }

    fn fields(self, list: *FrozenList::<*FieldDecl>) -> bool {
        for var i: usize = 0; i < list->size(); ++i {
            var f = *(list->get(i));
            if f == &null { continue; }
            // An anonymous union's members are laid out inside this record,
            // so they order it exactly as its own fields do.
            if f->is_anonymous_union {
                if self.fields(&(self._plan->anon_union_of(f)->fields)) { return true; }
                continue;
            }
            if self.reaches(f->type_) { return true; }
        }
        return false;
    }

    fn reaches(self, t: *Type) -> bool {
        if t == &null { return false; }
        var c = t->canonical;
        if c == &null { c = t; }
        switch c->kind {
            case TypeKind::QualifiedType { return self.reaches(cast::<QualifiedType>(c)->inner); }
            // `T?` holds its record by value (NullableTypeLowering).
            case TypeKind::NullableType  { return self.reaches(cast::<NullableType>(c)->lowered); }
            case TypeKind::RecordType {
                var r = cast::<RecordType>(c);
                var d = self._plan->layout_decl(r->decl);
                if d == self._target { return true; }
                // A payload struct is defined inside its ADT's body, so what it
                // holds by value orders the ADT exactly as its own fields
                // would. Its type names the struct, never the ADT.
                var ps = dyn_cast::<StructDecl>(d);
                if (ps != &null) && ps->is_adt_payload { return self.fields(&(ps->fields)); }
                for var i: usize = 0; i < r->args.size(); ++i {
                    if !self._plan->param_by_value(d, static_cast::<u32>(i)) { continue; }
                    if self.reaches(*(r->args.get(i))) { return true; }
                }
                return false;
            }
            case TypeKind::TupleType {
                var tp = cast::<TupleType>(c);
                for var i: usize = 0; i < tp->elements.size(); ++i {
                    if self.reaches(*(tp->elements.get(i))) { return true; }
                }
                return false;
            }
            case TypeKind::FixedArrayType { return self.reaches(cast::<FixedArrayType>(c)->element); }
            default { return false; }
        }
        return false;
    }
}

fn EmitPlan::mode()  -> PlanMode { return self._mode; }
fn EmitPlan::home()  -> u32      { return self._home; }
fn EmitPlan::spell() -> *CXXSpell { return &(self._spell); }

// --- Entry point -----------------------------------------------------------

fn EmitPlan::run() {
    var tu = self._cg->tu;
    if tu == &null { return; }
    if tu->program == &null { return; }
    self._home = tu->fid;
    ICE_IF(self._cg->instances == &null, "EmitPlan: no InstantiationRegistry on the CodegenContext");
    if (!tu->cxx_escaping_done) && CXXSpell::is_entry_tu(tu) { self._find_escaping(tu); }

    self._collect_own(static_cast::<*DeclContext>(tu));
    self._collect_own_globals();
    if self._mode == PlanMode::Preamble { self._collect_own_locals(); }
    if self._mode == PlanMode::Preamble { self._collect_uses(); }
    self._walk_visible();
    self._close();
    self._order();

    // The one writer of is_empty. Foreign entries alone do not count: they
    // are only here to support this TU's own bodies, and there are none.
    self._empty = true;
    for var i: usize = 0; i < self.entries.size(); ++i {
        var e = &(self.entries[i]);
        if e->witness != &null { continue; }   // own everywhere, and only ever there for this TU's own code.
        if e->own { self._empty = false; break; }
        if (e->tier == PlanTier::Instantiations) && e->is_home { self._empty = false; break; }
    }
}

/// TranslationUnit::cxx_escaping for pathless TU \p tu: a Header plan of the
/// file roots at its pub decls and walks its inline and template bodies to
/// a fixed point, admitting every hidden decl one names -- exactly the set.
/// Marked done first, so the nested plan does not recurse; nothing in
/// planning reads is_anon.
fn EmitPlan::_find_escaping(tu: *TranslationUnit) {
    tu->cxx_escaping_done = true;
    var hcg = CodegenContext(self._cg->ctx, &null, self._cg->psym, self._cg->instances);
    var hplan = EmitPlan(&hcg, PlanMode::Header);
    hplan.run();
    for var i: usize = 0; i < hplan.entries.size(); ++i {
        var e = &(hplan.entries[i]);
        if (!e->own) || (e->decl == &null) || (e->scope != &null) { continue; }
        if !_hidden_in_header(CXXSpell::vis_of(e->decl)) { continue; }
        var dup = false;
        for var k: usize = 0; k < tu->cxx_escaping.size(); ++k { if tu->cxx_escaping[k] == e->decl { dup = true; break; } }
        if !dup { tu->cxx_escaping.push_back(e->decl); }
    }
}

/// The TU has nothing to define: no entry of its own at any tier and no
/// instantiation homed here. A property of the PLAN, not of the file's
/// bytes -- a file of comments or of `pub import` lines is as empty as a
/// zero-byte one. An empty TU gets no C++, no clang run, no object and no
/// header. True before run(), and for a TU with no program.
fn EmitPlan::is_empty() -> bool { return self._empty; }

/// Every extension scope written in \p d's OWN file, for the definition's
/// `friend struct` lines, in plan order. Usually one; `module Geo { extend
/// Point {...} }` beside a file-scope `extend Point` is two scopes in two
/// namespaces, and both are friends under invariant 18 -- the set is still
/// closed at the file.
fn EmitPlan::friend_scopes_of(d: *Decl, out: *vec::<*ExtScope>) {
    var c = self.layout_decl(d);
    var key = self._scope_key(d);
    for var i: usize = 0; i < self._scopes.size(); ++i {
        var s = &(self._scopes[i]);
        if (s->target == &null) || (s->key != key) { continue; }
        if CXXSpell::fid_of(static_cast::<*Decl>(s->anchor)) != CXXSpell::fid_of(c) { continue; }
        // In source order, not plan order: two TUs touch the scopes in the
        // order their own code does, and the record's text must not care.
        var at = out->size();
        while (at > 0) && ((*out)[at - 1]->anchor->range.start.id > s->anchor->range.start.id) { at -= 1; }
        out->push_back(s);
        var k = out->size() - 1;
        while k > at { (*out)[k] = (*out)[k - 1]; k -= 1; }
        (*out)[at] = s;
    }
}

// --- File friends --------------------------------------------------------------

/// The record has a member C++ will see non-public (CXXSpell::cxx_access).
/// A compiler-made one never counts: only the record's own members call
/// it. A function of the record's declaration, so of its file.
fn EmitPlan::needs_friends(d_in: *Decl) -> bool {
    var d = CXXSpell::rep(d_in);
    if (d == &null) || (!(isa::<ClassDecl>(d) || isa::<StructDecl>(d) || isa::<UnionDecl>(d))) { return false; }
    var fields:  FrozenList::<*FieldDecl>;
    var methods: FrozenList::<*FunctionDecl>;
    if isa::<ClassDecl>(d)      { fields = cast::<ClassDecl>(d)->fields;  methods = cast::<ClassDecl>(d)->methods; }
    else if isa::<UnionDecl>(d) { fields = cast::<UnionDecl>(d)->fields;  methods = cast::<UnionDecl>(d)->methods; }
    else                        { fields = cast::<StructDecl>(d)->fields; methods = cast::<StructDecl>(d)->methods; }
    for var i: usize = 0; i < fields.size(); ++i {
        var f = fields[i];
        if (f == &null) || f->is_implicit { continue; }
        if self._spell.cxx_access(static_cast::<*Decl>(f)) != VIS_PUB() { return true; }
    }
    for var i: usize = 0; i < methods.size(); ++i {
        var m = methods[i];
        if (m == &null) || m->is_implicit { continue; }
        if self._spell.cxx_access(static_cast::<*Decl>(m)) != VIS_PUB() { return true; }
    }
    var dc = CXXSpell::dc_of(d);
    if dc == &null { return false; }
    for var i: usize = 0; i < dc->dc_decls.size(); ++i {
        var nd = *(dc->dc_decls.get(i));
        if (nd == &null) || nd->is_implicit { continue; }
        if (!self._is_type_decl(nd)) && (!isa::<TypeAliasDecl>(nd)) { continue; }
        if self._spell.cxx_access(nd) != VIS_PUB() { return true; }
    }
    return false;
}

/// Record \p d's friends (FileFriends), from \p d's file's declarations.
/// Coarse on purpose: everything of the file that may name a member Kairo
/// lets it name, whether it does or not, so no walk of any body -- which
/// another TU may not have lowered -- decides the text.
///
/// Left out, because C++ cannot befriend them from here, and so still
/// unable to reach a private member in the C++ (ClangDiagAdapter makes the
/// clang error a loud internal one): a function whose signature names a
/// nested type (not declarable ahead of the record), and a generic one, or
/// a constrained generic record, whose template parameters share a name
/// with the record's own. A function in another namespace of the file (a
/// `module` block's), or an `ffi "c"` or `-> !` one, is befriended by its
/// qualified name after a declaration of its own (_ff_fn_kind).
fn EmitPlan::file_friends(d_in: *Decl, out: *FileFriends) {
    var d = CXXSpell::rep(d_in);
    if !self.needs_friends(d) { return; }
    out->needed = true;
    var tu = CXXSpell::tu_of(d);
    if (tu == &null) || (tu->program == &null) { return; }
    var ns = self._spell.ns_segments(d);
    // Only d itself is left out: a nested d befriends its outermost
    // record too, since C++ gives an enclosing class no access to a nested
    // one's private members.
    var mine = d;
    var tparams = vec::<string>();
    self._ff_tparams(d, &tparams);
    self._ff_dc(static_cast::<*DeclContext>(tu), d, mine, &ns, &tparams, out);
    var hl = HoistedLocals();
    hl.run(tu);
    for var i: usize = 0; i < hl.found.size(); ++i {
        var h = CXXSpell::rep(hl.found[i]);
        if (h == &null) || h->is_poisoned() || (h == mine) { continue; }
        if isa::<ClassDecl>(h) || isa::<StructDecl>(h) || isa::<UnionDecl>(h) { self._ff_record(h, &tparams, out); continue; }
        var f = dyn_cast::<FunctionDecl>(h);
        if f != &null { self._ff_add_fn(f, &ns, &tparams, out); }
    }
    // The witnesses of what the file declares d implements: on d itself,
    // and on every `extend d impl I` of the file.
    if isa::<ClassDecl>(d) {
        var ce = &(cast::<ClassDecl>(d)->implements);
        for var i: usize = 0; i < ce->size(); ++i { if ce->get(i) != &null { self._ff_iface(ce->get(i)->base, out, 0); } }
    } else if isa::<StructDecl>(d) {
        var se = &(cast::<StructDecl>(d)->implements);
        for var i: usize = 0; i < se->size(); ++i { if se->get(i) != &null { self._ff_iface(se->get(i)->base, out, 0); } }
    }
    var items = &(tu->program->items);
    for var i: usize = 0; i < items->size(); ++i {
        var item = *(items->get(i));
        if item.kind == TopLevelKind::Stmt {
            var ds = dyn_cast::<DeclStmt>(item.as_stmt());
            var v = (dyn_cast::<VariableDecl>(ds->decl)) if ((ds != &null) && (ds->decl != &null)) else (&null);
            if (v == &null) || (!GlobalInitReach::needs_thunk(&(self._spell), v)) { continue; }
            var vns = self._spell.ns_segments(static_cast::<*Decl>(v));
            if self._same_ns_vec(&vns, &ns) { out->globals.push_back(v); }
            continue;
        }
        if item.kind != TopLevelKind::Decl { continue; }
        self._ff_ifaces_in(item.as_decl(), d, out);
    }
}

fn EmitPlan::_ff_dc(dc: *DeclContext, d: *Decl, mine: *Decl, ns: *vec::<string>, tparams: *vec::<string>, out: *FileFriends) {
    for var i: usize = 0; i < dc->dc_decls.size(); ++i {
        var x = *(dc->dc_decls.get(i));
        if x != &null { self._ff_decl(x, d, mine, ns, tparams, out); }
    }
}

fn EmitPlan::_ff_decl(x: *Decl, d: *Decl, mine: *Decl, ns: *vec::<string>, tparams: *vec::<string>, out: *FileFriends) {
    if x->is_poisoned() { return; }
    if isa::<ModuleDecl>(x) { self._ff_dc(static_cast::<*DeclContext>(cast::<ModuleDecl>(x)), d, mine, ns, tparams, out); return; }
    if isa::<VisibilityGroupDecl>(x) {
        var g = cast::<VisibilityGroupDecl>(x);
        for var i: usize = 0; i < g->members.size(); ++i { if g->members[i] != &null { self._ff_decl(g->members[i], d, mine, ns, tparams, out); } }
        return;
    }
    if isa::<ExtensionDecl>(x) {
        var e = cast::<ExtensionDecl>(x);
        if (e->methods.size() == 0) || (e->target == &null) || (e->target->canonical == &null) { return; }
        // d's own scopes are friend_scopes_of's, qualified and admitted.
        var c = canon_unqual(e->target->canonical);
        if isa::<RecordType>(c) && (self._scope_key(cast::<RecordType>(c)->decl) == self._scope_key(d)) { return; }
        // Unqualified, it names (or first declares) the struct in d's
        // namespace -- the one place it can, with no prior declaration.
        var sns = self._spell.scope_ns(e);
        if !self._same_ns_vec(&sns, ns) { return; }
        var nm = self._spell.ext_scope_name(e);
        for var i: usize = 0; i < out->scopes.size(); ++i { if self._spell.ext_scope_name(out->scopes[i]) == nm { return; } }
        out->scopes.push_back(e);
        return;
    }
    if isa::<ClassDecl>(x) || isa::<StructDecl>(x) || isa::<UnionDecl>(x) {
        var r = CXXSpell::rep(x);
        if (r != x) || (r == mine) || r->is_implicit || CXXSpell::is_record_spec(r) || decl_only_forward(r) { return; }
        if (decl_ffi_tag_target(r) != &null) || (!self._plannable(r)) { return; }
        self._ff_record(r, tparams, out);
        return;
    }
    var f = dyn_cast::<FunctionDecl>(x);
    if f == &null { return; }
    var rf = cast::<FunctionDecl>(CXXSpell::rep(x));
    if self._spell.is_main(static_cast::<*Decl>(rf)) {
        if (out->main == &null) && (CXXSpell::c_linkage(rf).size() == 0) { out->main = rf; }
        return;
    }
    self._ff_add_fn(rf, ns, tparams, out);
}

fn EmitPlan::_ff_add_fn(f: *FunctionDecl, ns: *vec::<string>, tparams: *vec::<string>, out: *FileFriends) {
    var k = self._ff_fn_kind(f, ns, tparams);
    if k == 0 { return; }
    for var i: usize = 0; i < out->fns.size(); ++i { if out->fns[i] == f { return; } }
    out->fns.push_back(f);
    out->far.push_back(k == 2);
}

/// A record friend; a generic one whose parameters clash with \p tparams
/// is spelled with fresh ones, which a requires-clause (written in the
/// parameters' own names) forbids -- that one is left out.
fn EmitPlan::_ff_record(r: *Decl, tparams: *vec::<string>, out: *FileFriends) {
    for var i: usize = 0; i < out->records.size(); ++i { if out->records[i] == r { return; } }
    var fresh = false;
    if CXXSpell::template_params(r).size() > 0 {
        fresh = true;
        if self._spell.requires_clause(r).size() > 0 {
            if self._ff_clash(r, tparams) { return; }
            fresh = false;
        }
    }
    out->records.push_back(r);
    out->fresh.push_back(fresh);
}

/// How \p f is befriended: 0 not at all; 1 unqualified, which names (or
/// first declares) it in the record's namespace; 2 qualified, after an
/// early declaration of its own (EmitPlan::friend_early) -- a function in
/// another namespace of the file, or one whose first declaration must
/// carry its `ffi "c"` linkage or `[[noreturn]]`, which a friend
/// declaration may not.
fn EmitPlan::_ff_fn_kind(f: *FunctionDecl, ns: *vec::<string>, tparams: *vec::<string>) -> u8 {
    if f->is_poisoned() || f->is_method() || (decl_extension_of(static_cast::<*Decl>(f)) != &null) { return 0; }
    if self._ff_clash(static_cast::<*Decl>(f), tparams) { return 0; }
    if self._ff_nested(f->return_type, 0) || self._ff_nested(f->panic_result, 0) { return 0; }
    for var i: usize = 0; i < f->params.size(); ++i {
        var p = f->params[i];
        if (p == &null) || p->is_self { continue; }
        var pt = ((p->pack_type) if (p->is_pack && (p->pack_type != &null)) else (p->type_));
        if self._ff_nested(pt, 0) { return 0; }
    }
    if f->is_noreturn || (CXXSpell::c_linkage(f).size() > 0) { return 2; }
    var fns = self._spell.ns_segments(static_cast::<*Decl>(f));
    if !self._same_ns_vec(&fns, ns) { return 2; }
    return 1;
}

/// \p t names a record nested in another type: a name only a complete
/// outer type declares, which the befriending record's definition may
/// precede.
fn EmitPlan::_ff_nested(t: *Type, depth: u32) -> bool {
    if (t == &null) || (depth > 32) { return false; }
    var c = (t->canonical) if (t->canonical != &null) else (t);
    switch c->kind {
        case TypeKind::QualifiedType { return self._ff_nested(cast::<QualifiedType>(c)->inner, depth + 1); }
        case TypeKind::PointerType   { return self._ff_nested(cast::<PointerType>(c)->pointee, depth + 1); }
        case TypeKind::CXXLValueRefType { return self._ff_nested(cast::<CXXLValueRefType>(c)->referee, depth + 1); }
        case TypeKind::CXXRValueRefType { return self._ff_nested(cast::<CXXRValueRefType>(c)->referee, depth + 1); }
        case TypeKind::FixedArrayType { return self._ff_nested(cast::<FixedArrayType>(c)->element, depth + 1); }
        case TypeKind::NullableType  { return self._ff_nested(cast::<NullableType>(c)->inner, depth + 1); }
        case TypeKind::TupleType {
            var tt = cast::<TupleType>(c);
            for var i: usize = 0; i < tt->elements.size(); ++i { if self._ff_nested(*(tt->elements.get(i)), depth + 1) { return true; } }
            return false;
        }
        case TypeKind::FunctionPointerType {
            var ft = cast::<FunctionPointerType>(c);
            if self._ff_nested(ft->return_type, depth + 1) { return true; }
            for var i: usize = 0; i < ft->params.size(); ++i { if self._ff_nested(*(ft->params.get(i)), depth + 1) { return true; } }
            return false;
        }
        case TypeKind::RecordType {
            var rt = cast::<RecordType>(c);
            if rt->outer != &null { return true; }
            if (rt->decl != &null) && (!decl_is_imported(rt->decl)) {
                var dc = reinterpret_cast::<*DeclContext>(CXXSpell::rep(rt->decl)->semantic_dc);
                if (dc != &null) && dc->is_type_scope() && (dc->dc_kind != DeclContextKind::Extension) { return true; }
            }
            for var i: usize = 0; i < rt->args.size(); ++i { if self._ff_nested(*(rt->args.get(i)), depth + 1) { return true; } }
            return false;
        }
        default { return false; }
    }
    return false;
}

/// The template parameter names in scope inside \p d's body: its own and
/// every enclosing record's.
fn EmitPlan::_ff_tparams(d: *Decl, out: *vec::<string>) {
    var cur = d;
    var depth: u32 = 0;
    while (cur != &null) && (depth < 64) {
        depth += 1;
        var gps = CXXSpell::template_params(cur);
        for var i: usize = 0; i < gps.size(); ++i { out->push_back(self._spell.imm_name(gps[i]->name.imm, CXXSpell::fid_of(cur))); }
        var dc = reinterpret_cast::<*DeclContext>(cur->semantic_dc);
        if (dc == &null) || (!dc->is_type_scope()) || (dc->dc_kind == DeclContextKind::Extension) { break; }
        cur = CXXSpell::rep(dc->dc_owner);
    }
}

/// A template parameter of \p d is spelled as one in \p tparams: declared
/// inside that scope it would redeclare it ([temp.local]/6).
fn EmitPlan::_ff_clash(d: *Decl, tparams: *vec::<string>) -> bool {
    var gps = CXXSpell::template_params(d);
    for var i: usize = 0; i < gps.size(); ++i {
        var nm = self._spell.imm_name(gps[i]->name.imm, CXXSpell::fid_of(d));
        for var k: usize = 0; k < tparams->size(); ++k { if (*tparams)[k] == nm { return true; } }
    }
    return false;
}

/// Interface \p t's decl and everything it derives, once each.
fn EmitPlan::_ff_iface(t: *Type, out: *FileFriends, depth: u32) {
    if (t == &null) || (t->canonical == &null) || (depth > 32) { return; }
    var c = canon_unqual(t->canonical);
    if !isa::<RecordType>(c) { return; }
    var id = dyn_cast::<InterfaceDecl>(CXXSpell::rep(decl_pattern(CXXSpell::rep(cast::<RecordType>(c)->decl))));
    if id == &null { return; }
    var idd = static_cast::<*Decl>(id);
    for var i: usize = 0; i < out->ifaces.size(); ++i { if out->ifaces[i] == idd { return; } }
    out->ifaces.push_back(idd);
    for var i: usize = 0; i < id->derives_list.size(); ++i {
        var e = id->derives_list.get(i);
        if e != &null { self._ff_iface(e->base, out, depth + 1); }
    }
}

fn EmitPlan::_ff_ifaces_in(cand: *Decl, d: *Decl, out: *FileFriends) {
    if cand == &null { return; }
    if isa::<VisibilityGroupDecl>(cand) {
        var g = cast::<VisibilityGroupDecl>(cand);
        for var i: usize = 0; i < g->members.size(); ++i { self._ff_ifaces_in(g->members[i], d, out); }
        return;
    }
    if isa::<ModuleDecl>(cand) {
        var dc = static_cast::<*DeclContext>(cast::<ModuleDecl>(cand));
        for var i: usize = 0; i < dc->dc_decls.size(); ++i { self._ff_ifaces_in(*(dc->dc_decls.get(i)), d, out); }
        return;
    }
    var x = dyn_cast::<ExtensionDecl>(cand);
    if (x == &null) || (x->implements.size() == 0) { return; }
    if self._ext_target(x) != self.layout_decl(d) { return; }
    for var i: usize = 0; i < x->implements.size(); ++i {
        var e = x->implements.get(i);
        if e != &null { self._ff_iface(e->base, out, 0); }
    }
}

/// Where record \p d is Complete, everything its friend lines name is
/// declared ahead of it: each record (tier 0), each function's signature
/// types (as its own declaration would need them; the function itself
/// need not be), each witness primary, and `main` at global scope.
fn EmitPlan::_admit_friends(d: *Decl) {
    var ff = FileFriends();
    self.file_friends(d, &ff);
    if !ff.needed { return; }
    for var i: usize = 0; i < ff.records.size(); ++i { self._admit(ff.records[i], PlanNeed::Fwd); }
    for var i: usize = 0; i < ff.fns.size(); ++i {
        var f = ff.fns[i];
        if ff.far[i] {
            var have = false;
            for var k: usize = 0; k < self.friend_early.size(); ++k { if self.friend_early[k] == f { have = true; break; } }
            if !have { self.friend_early.push_back(f); }
        }
        self._witness_bounds(static_cast::<*Decl>(f));
        for var j: usize = 0; j < f->params.size(); ++j {
            var p = f->params[j];
            if (p == &null) || p->is_self { continue; }
            self._admit_type(((p->pack_type) if (p->is_pack && (p->pack_type != &null)) else (p->type_)), PlanNeed::Fwd);
        }
        self._admit_type(f->return_type, PlanNeed::Fwd);
        self._admit_type(f->panic_result, PlanNeed::Fwd);
    }
    for var i: usize = 0; i < ff.ifaces.size(); ++i { self._witness_primary(ff.ifaces[i]); }
    for var i: usize = 0; i < ff.globals.size(); ++i { self._admit_type(ff.globals[i]->type_, PlanNeed::Fwd); }
    if ff.main != &null {
        self.main_friend = ff.main;
        for var j: usize = 0; j < ff.main->params.size(); ++j {
            var p = ff.main->params[j];
            if (p != &null) && (!p->is_self) { self._admit_type(p->type_, PlanNeed::Fwd); }
        }
    }
}

// --- Dump --------------------------------------------------------------------

fn EmitPlan::dump(path: string) {
    var m = ("preamble") if (self._mode == PlanMode::Preamble) else (("header") if (self._mode == PlanMode::Header) else ("include"));
    std::print(f"===== EMIT PLAN fid {self._home} ({m}): {path} =====");
    if self.entries.size() == 0 { std::print("  (empty)"); return; }
    var tier = u8(255);
    for var i: usize = 0; i < self.entries.size(); ++i {
        var e = &(self.entries[i]);
        if static_cast::<u8>(e->tier) != tier {
            tier = static_cast::<u8>(e->tier);
            std::print(f"  -- {self._tier_name(e->tier)} --");
        }
        var own = ("own") if (e->own) else ("foreign");
        var extra = "";
        var nm = "";
        var kd = "struct";
        if e->scope != &null {
            // The anchor is an ExtensionDecl, which has no name of its own.
            for var k: usize = 0; k < e->scope->ns.size(); ++k { nm += "::"; nm += e->scope->ns[k]; }
            nm += "::";
            nm += e->scope->name;
            extra = f" extension scope, {e->scope->members.size()} members";
        } else {
            nm = self._spell.qual_name(e->decl);
            if e->inst != &null { nm += self._spell.args_str(&(e->inst->args)); }
            kd = self._kind_name(e->decl);
            if e->inst != &null { extra = (" home") if (e->is_home) else (" extern"); }
        }
        std::print(f"    {kd} {nm}   [{self._need_name(e->need)}] {own} fid {e->fid} @ {e->off}{extra}");
    }
}

fn EmitPlan::_tier_name(t: PlanTier) -> string {
    switch t {
        case PlanTier::FwdDecls       { return "tier 0: forward declarations"; }
        case PlanTier::Definitions    { return "tier 1: definitions"; }
        case PlanTier::Functions      { return "tier 2: function declarations"; }
        case PlanTier::Instantiations { return "tier 3: instantiations"; }
    }
    return "tier ?";
}

fn EmitPlan::_need_name(n: PlanNeed) -> string {
    return ("complete") if (n == PlanNeed::Complete) else ("fwd");
}

fn EmitPlan::_kind_name(d: *Decl) -> string {
    switch d->kind {
        case DeclKind::ClassDecl    { return "class";  }
        case DeclKind::StructDecl   { return "struct"; }
        case DeclKind::UnionDecl    { return "union";  }
        case DeclKind::EnumDecl     { return "enum";   }
        case DeclKind::FunctionDecl { return "fn";     }
        case DeclKind::VariableDecl { return "var";    }
        default { return "decl"; }
    }
    return "decl";
}

// --- Roots: own decls --------------------------------------------------------

/// Every plannable decl the TU declares, at the strength its own kind
/// demands: a type is defined here (Complete), a function is declared.
/// Header mode takes only `pub` ones. Modules and visibility groups are
/// walked through; an extension block puts its scope in the plan.
fn EmitPlan::_collect_own(dc: *DeclContext) {
    for var i: usize = 0; i < dc->dc_decls.size(); ++i {
        var d = *(dc->dc_decls.get(i));
        if d == &null { continue; }
        self._collect_own_decl(d);
    }
}

fn EmitPlan::_collect_own_decl(d: *Decl) {
    if d->is_poisoned() { return; }
    if isa::<ModuleDecl>(d) {
        self._collect_own(static_cast::<*DeclContext>(cast::<ModuleDecl>(d)));
        return;
    }
    if isa::<VisibilityGroupDecl>(d) {
        var g = cast::<VisibilityGroupDecl>(d);
        for var i: usize = 0; i < g->members.size(); ++i { self._collect_own_decl(g->members[i]); }
        return;
    }
    if isa::<ExtensionDecl>(d) {
        var x = cast::<ExtensionDecl>(d);
        // A header reaches the scope through any visible member, and then
        // carries the WHOLE struct; a block with none adds no root.
        if (self._mode != PlanMode::Preamble) && _hidden_in_header(CXXSpell::vis_of(d)) { return; }
        var visible = false;
        for var i: usize = 0; i < x->methods.size(); ++i {
            var m = x->methods[i];
            if m == &null { continue; }
            if (self._mode != PlanMode::Preamble) && _hidden_in_header(CXXSpell::vis_of(static_cast::<*Decl>(m))) { continue; }
            visible = true;
        }
        if visible { self._scope_for(x, true); }
        self._witness_declared(d);
        return;
    }
    if !self._plannable(d) { return; }
    if (self._mode != PlanMode::Preamble) && _hidden_in_header(CXXSpell::vis_of(d)) { return; }
    if self._is_type_decl(d) {
        // A definition here means every own type is Complete; its own
        // dependencies come in through _expand.
        self._admit(d, PlanNeed::Complete);
        self._witness_declared(d);
    } else {
        self._admit(d, PlanNeed::Fwd);
    }
}

/// File-scope `var`/`const`/`static`/`eval`. They parse as DeclStmts in
/// program->items and never enter tu->dc_decls (ASTParse::_build_symbols),
/// so the dc walk above cannot see them; without this a TU whose only
/// definitions are globals is is_empty, and a function naming one finds no
/// prior `extern`, which for a `const` is the difference between external
/// and internal linkage.
/// The `fn`s, classes and enums written in this TU's function bodies: each
/// is an own declaration at namespace scope (CXXSpell::is_hoisted_local),
/// defined here whether or not a body names it. A header and an include
/// take one only through a use -- an inline or template body that calls
/// it, which the body walk admits.
fn EmitPlan::_collect_own_locals() {
    var hl = HoistedLocals();
    hl.run(self._cg->tu);
    for var i: usize = 0; i < hl.found.size(); ++i { self._collect_own_decl(hl.found[i]); }
}

fn EmitPlan::_collect_own_globals() {
    var prog = self._cg->tu->program;
    for var i: usize = 0; i < prog->items.size(); ++i {
        var item = *(prog->items.get(i));
        if item.kind != TopLevelKind::Stmt { continue; }
        var ds = dyn_cast::<DeclStmt>(item.as_stmt());
        if (ds == &null) || (ds->decl == &null) { continue; }
        self._collect_own_decl(ds->decl);
    }
}

// --- Extension scopes ----------------------------------------------------------

/// The scope \p x contributes to, created on first touch; \p reach marks it
/// reachable. Index-based: the closure below can grow _scopes.
///
/// Filled COMPLETELY at creation, never from the use that touched it: with
/// members appended per use, TU A's struct would have the three it calls
/// and TU B's the five it calls, two definitions of one class.
fn EmitPlan::_scope_for(x: *ExtensionDecl, reach: bool) -> usize {
    ICE_IF((x == &null) || (x->target == &null) || (x->target->canonical == &null),
        "EmitPlan: extension with an unresolved target reached codegen");
    var ns   = self._spell.scope_ns(x);
    var name = self._spell.ext_scope_name(x);
    for var i: usize = 0; i < self._scopes.size(); ++i {
        var s = &(self._scopes[i]);
        if (s->name != name) || (!self._same_ns_vec(&(s->ns), &ns)) { continue; }
        // Same N, same struct name: it must be the same target, or two
        // targets (`a::Point`, `b::Point`) would share one struct.
        if (!self._same_scope(i, x)) { self._ice(x->range, f"EmitPlan: two extension targets in one namespace both spell '{name}'; the scope naming rule needs a disambiguator"); }
        if reach { s->reachable = true; }
        return i;
    }

    var fresh = ExtScope();
    fresh.ns   = ns;
    fresh.name = name;
    var c = canon_unqual(x->target->canonical);
    if isa::<RecordType>(c) {
        fresh.target = self.layout_decl(cast::<RecordType>(c)->decl);
        fresh.key    = self._scope_key(cast::<RecordType>(c)->decl);
    } else {
        fresh.target_ty = c;
    }
    fresh.reachable = reach;
    self._scopes.push_back(fresh);
    var k = self._scopes.size() - 1;

    // Every block of this (N, X) lives in x's file: N is that file's
    // module path plus its module blocks.
    var tu = CXXSpell::tu_of(static_cast::<*Decl>(x));
    if ((tu == &null) || (tu->program == &null)) { self._ice(x->range, "EmitPlan: extension with no owning TU"); }
    var items = &(tu->program->items);
    for var i: usize = 0; i < items->size(); ++i {
        var item = *(items->get(i));
        if item.kind != TopLevelKind::Decl { continue; }
        self._fill_scope(k, item.as_decl());
    }
    if (self._scopes[k].anchor == &null) { self._ice(x->range, "EmitPlan: an extension's own file does not contain it"); }

    // A static member's signature names its types and lays none out; the
    // definition and its forwarders need the deps complete.
    //
    // EVERY member is expanded, priv included: the struct is emitted whole
    // in every TU that touches it, so a type only a priv member names must
    // be declared in a preamble whose own code never mentions it. A nested
    // type there is a dep too -- `Other::Inner` cannot be named through
    // the bare `class Other;` that Fwd gives.
    self._scope_dep(k, x->target);
    var nm = self._scopes[k].members.size();
    for var i: usize = 0; i < nm; ++i {
        var m = self._scopes[k].members[i];
        // Each block's own target: one scope holds the blocks of every
        // specialization (`extend <> Store<bool>` beside `extend <T>
        // Store<T>`), and a member's receiver names its block's.
        self._scope_dep(k, self._scopes[k].exts[i]->target);
        self._expand_fn(m);
        self._scope_sig_dep(k, m->return_type);
        if m->panic_result != &null { self._scope_sig_dep(k, m->panic_result); }
        for var j: usize = 0; j < m->params.size(); ++j {
            var p = m->params[j];
            if (p == &null) || p->is_self { continue; }
            self._scope_sig_dep(k, ((p->pack_type) if (p->is_pack && (p->pack_type != &null)) else (p->type_)));
        }
        if (!m->is_operator) || (self._spell.ext_forwarder_name(m).size() == 0) { continue; }
        self._scope_dep(k, m->return_type);
        if m->panic_result != &null { self._scope_dep(k, m->panic_result); }
        for var j: usize = 0; j < m->params.size(); ++j {
            var p = m->params[j];
            if (p == &null) || p->is_self || (p->mode != ParamMode::Value) { continue; }
            self._scope_dep(k, p->type_);
        }
    }
    return k;
}

/// Walk \p cand (modules, visibility groups) for every extend block of
/// scope \p k, adding its members in source order.
fn EmitPlan::_fill_scope(k: usize, cand: *Decl) {
    if (cand == &null) || cand->is_poisoned() { return; }
    if isa::<VisibilityGroupDecl>(cand) {
        var g = cast::<VisibilityGroupDecl>(cand);
        for var i: usize = 0; i < g->members.size(); ++i { self._fill_scope(k, g->members[i]); }
        return;
    }
    if isa::<ModuleDecl>(cand) {
        var dc = static_cast::<*DeclContext>(cast::<ModuleDecl>(cand));
        for var i: usize = 0; i < dc->dc_decls.size(); ++i { self._fill_scope(k, *(dc->dc_decls.get(i))); }
        return;
    }
    var x = dyn_cast::<ExtensionDecl>(cand);
    if (x == &null) || (x->target == &null) || (x->target->canonical == &null) { return; }
    if !self._same_scope(k, x) { return; }
    var ns = self._spell.scope_ns(x);
    if !self._same_ns_vec(&(self._scopes[k].ns), &ns) { return; }
    if self._scopes[k].anchor == &null { self._scopes[k].anchor = x; }
    for var i: usize = 0; i < x->methods.size(); ++i {
        var m = x->methods[i];
        if (m == &null) || m->is_poisoned() { continue; }
        var c = cast::<FunctionDecl>(CXXSpell::rep(static_cast::<*Decl>(m)));
        var dup = false;
        for var j: usize = 0; j < self._scopes[k].members.size(); ++j {
            if self._scopes[k].members[j] == c { dup = true; break; }
        }
        if dup { continue; }
        self._scopes[k].members.push_back(c);
        self._scopes[k].exts.push_back(x);
    }
}

/// \p x's target is scope \p k's: the same layout decl for a record, the
/// same canonical type for a builtin. Namespace is the caller's to compare.
fn EmitPlan::_same_scope(k: usize, x: *ExtensionDecl) -> bool {
    var c = canon_unqual(x->target->canonical);
    var s = &(self._scopes[k]);
    if isa::<RecordType>(c) { return (s->target != &null) && (self._scope_key(cast::<RecordType>(c)->decl) == s->key); }
    return (s->target == &null) && (s->target_ty == c);
}

/// A by-value record \p t is a Complete dependency of scope \p k, recorded
/// as the tier-1 entry that defines it (an outermost type, a primary).
fn EmitPlan::_scope_dep(k: usize, t: *Type) {
    if (t == &null) || (t->canonical == &null) { return; }
    var c = canon_unqual(t->canonical);
    if isa::<NullableType>(c) { self._scope_dep(k, self._nullable_record(c)); return; }
    if !isa::<RecordType>(c) { return; }
    var d = self.layout_decl(cast::<RecordType>(c)->decl);
    if (d == &null) || decl_is_imported(d) || isa::<InterfaceDecl>(d) { return; }
    self._admit_type(t, PlanNeed::Complete);
    self._scope_add_dep(k, self._outermost_type(d));
}

/// The record a canonical `T?` is to C++ (NullableType::lowered). None means
/// NullableTypeLowering never saw it: the same ICE CXXSpell raises.
fn EmitPlan::_nullable_record(c: *Type) -> *Type {
    var lw = cast::<NullableType>(c)->lowered;
    if lw == &null { self._ice(c->range, "EmitPlan: T? reached codegen with no lowered record; NullableTypeLowering must run first"); }
    return lw;
}

/// A NESTED record anywhere in a member signature \p t -- behind pointers,
/// references, arrays, as a generic argument -- makes its outermost owner a
/// Complete dep of scope \p k: a member type is named only through a
/// complete enclosing class.
fn EmitPlan::_scope_sig_dep(k: usize, t: *Type) {
    if t == &null { return; }
    var c = t->canonical;
    if c == &null { c = t; }
    switch c->kind {
        case TypeKind::QualifiedType    { self._scope_sig_dep(k, cast::<QualifiedType>(c)->inner); }
        case TypeKind::PointerType      { self._scope_sig_dep(k, cast::<PointerType>(c)->pointee); }
        case TypeKind::CXXLValueRefType { self._scope_sig_dep(k, cast::<CXXLValueRefType>(c)->referee); }
        case TypeKind::CXXRValueRefType { self._scope_sig_dep(k, cast::<CXXRValueRefType>(c)->referee); }
        case TypeKind::NullableType     { self._scope_sig_dep(k, self._nullable_record(c)); }
        case TypeKind::FixedArrayType   { self._scope_sig_dep(k, cast::<FixedArrayType>(c)->element); }
        case TypeKind::TupleType {
            var tp = cast::<TupleType>(c);
            for var i: usize = 0; i < tp->elements.size(); ++i { self._scope_sig_dep(k, *(tp->elements.get(i))); }
        }
        case TypeKind::FunctionPointerType {
            var fp = cast::<FunctionPointerType>(c);
            for var i: usize = 0; i < fp->params.size(); ++i { self._scope_sig_dep(k, *(fp->params.get(i))); }
            self._scope_sig_dep(k, fp->return_type);
        }
        case TypeKind::RecordType {
            var r = cast::<RecordType>(c);
            for var i: usize = 0; i < r->args.size(); ++i { self._scope_sig_dep(k, *(r->args.get(i))); }
            if r->outer != &null { self._scope_sig_dep(k, r->outer); }
            var d = self.layout_decl(r->decl);
            if (d == &null) || decl_is_imported(d) || isa::<InterfaceDecl>(d) { return; }
            var outer = self._outermost_type(d);
            // An ADT's layout record sits in the enum's scope, but it IS the
            // enum, not a type nested in it.
            if (outer == d) || (self.adt_record(outer) == d) { return; }
            self._admit(outer, PlanNeed::Complete);
            self._scope_add_dep(k, outer);
        }
        default { break; }
    }
}

fn EmitPlan::_scope_add_dep(k: usize, d: *Decl) {
    for var i: usize = 0; i < self._scopes[k].deps.size(); ++i {
        if self._scopes[k].deps[i] == d { return; }
    }
    self._scopes[k].deps.push_back(d);
}

// --- Witnesses (CODEGEN.md §7b.6) --------------------------------------------------

/// \p iface's primary and concept, created on first touch. Its deps are the
/// by-value records its forwarders' signatures name (an inline definition
/// lays them out); a concept conjoins its bases' concepts, so their
/// primaries come first.
fn EmitPlan::_witness_primary(iface_in: *Decl) -> usize {
    var iface = CXXSpell::rep(decl_pattern(CXXSpell::rep(iface_in)));
    for var i: usize = 0; i < self._witnesses.size(); ++i {
        if (self._witnesses[i].iface == iface) && (self._witnesses[i].row == &null) { return i; }
    }
    var fresh = WitnessPiece();
    fresh.iface = iface;
    fresh.key   = self._spell.witness_name(iface);
    self._witnesses.push_back(fresh);
    var k = self._witnesses.size() - 1;

    // Every requirement it derives is its own member (InterfaceComposition),
    // and its concept conjoins no base's: no base primary is needed first.
    var ms = EmitWitness(self._cg, &(self._spell)).members(cast::<InterfaceDecl>(iface));
    for var i: usize = 0; i < ms.size(); ++i {
        var m = ms[i];
        if (m == &null) || m->is_poisoned() { continue; }
        self._witness_sig(k, m);
    }
    return k;
}

/// \p row's specialization, when the primary does not serve it (§7b.4):
/// after the primary, the conformer complete, and every extension scope
/// it forwards to defined.
fn EmitPlan::_witness_row(row: *ConformanceRow) {
    if (row == &null) || (row->iface_decl == &null) { return; }
    // The rows its associated types' bounds rest on come with it, whether
    // or not this row needs a specialization of its own: a body reaching
    // `T::Item::Inner` spells `Holder_witness<Purse>` (ConformanceRow::
    // assoc_rows). Once each: a row may name itself through a bound.
    var seen = false;
    for var i: usize = 0; i < self._assoc_seen.size(); ++i { if self._assoc_seen[i] == row { seen = true; } }
    if !seen {
        self._assoc_seen.push_back(row);
        for var i: usize = 0; i < row->assoc_rows.size(); ++i { self._witness_row(row->assoc_rows[i]); }
    }
    var iface = CXXSpell::rep(row->iface_decl);
    self._witness_primary(iface);
    var ew = EmitWitness(self._cg, &(self._spell));
    // A generic declared row's partial specialization is this row's witness
    // already (§7b.3): admitting it, never a full one beside it, keeps one
    // definition per conformance. Only when it is emitted at all -- were the
    // primary to serve the generic row but not this one, the full one is
    // still the only witness this row has.
    var g = row->covered_by;
    if (g != &null) && ew.needs_specialization(g) { self._witness_row(g); return; }
    if !ew.needs_specialization(row) { return; }
    for var i: usize = 0; i < self._witnesses.size(); ++i { if self._witnesses[i].row == row { return; } }

    var fresh = WitnessPiece();
    fresh.iface = iface;
    fresh.row   = row;
    fresh.key   = self._spell.witness_name(iface) + self._spell.witness_args(self._spell._type(row->conformer), row->iface);
    fresh.after.push_back(iface);
    self._witnesses.push_back(fresh);
    var k = self._witnesses.size() - 1;

    self._witness_dep(k, row->conformer);
    if EmitWitness::is_generic_row(row) && isa::<RecordType>(row->conformer) {
        // A partial specialization names the conformer's template, which
        // _witness_dep leaves alone as dependent: the primary must be
        // declared, and is defined first, as a full specialization's is.
        var cd = self.layout_decl(cast::<RecordType>(row->conformer)->decl);
        if (cd != &null) && (!decl_is_imported(cd)) {
            var o = self._outermost_type(cd);
            self._admit(o, PlanNeed::Complete);
            var have = false;
            for var i: usize = 0; i < self._witnesses[k].deps.size(); ++i { if self._witnesses[k].deps[i] == o { have = true; } }
            if !have { self._witnesses[k].deps.push_back(o); }
        }
    }
    var ms = ew.members(cast::<InterfaceDecl>(iface));
    for var i: usize = 0; i < ms.size(); ++i {
        var m = ms[i];
        if (m == &null) || m->is_poisoned() { continue; }
        self._witness_sig(k, m);
    }
    for var i: usize = 0; i < row->witnesses.size(); ++i {
        var w = row->witnesses[i];
        if w == &null { continue; }
        // An associated type's witness is an alias (or the requirement, for
        // a default): what the specialization needs is the TYPE, complete,
        // since its inline members return it by value.
        if isa::<TypeAliasDecl>(w) {
            if (i < row->assoc_types.size()) && (row->assoc_types[i] != &null) { self._witness_dep(k, row->assoc_types[i]); }
            continue;
        }
        // A constructor slot is forwarded to by nothing: the bounded body
        // constructs `T(args)` itself, wherever the conformer is complete.
        if (i < ms.size()) && (ms[i] != &null) && decl_is_ctor_requirement(ms[i]) { continue; }
        var x = decl_extension_of(w);
        if x != &null { self._witness_scope(k, x); continue; }
        self._admit_use(w);   // an own member: its owner complete.
    }
}

/// The rows \p d DECLARES (`class X impl I`, `extend X impl I`), where \p d
/// is emitted: there both X and I are complete -- \p d defines or extends
/// X and names I -- and a C++ host instantiating a bounded template with X
/// finds the specialization in the header that defines X, though no Kairo
/// instance ever paired them (§7b.6). A header leaves out a row whose X or
/// I it does not carry: the host cannot name either.
fn EmitPlan::_witness_declared(d: *Decl) {
    var rows = vec::<*ConformanceRow>();
    self._cg->instances->declared_rows(d, &rows);
    for var i: usize = 0; i < rows.size(); ++i {
        var row = rows[i];
        if self._mode != PlanMode::Preamble {
            if _hidden_in_header(CXXSpell::vis_of(row->iface_decl)) { continue; }
            if isa::<RecordType>(row->conformer) && _hidden_in_header(CXXSpell::vis_of(cast::<RecordType>(row->conformer)->decl)) { continue; }
        }
        self._witness_row(row);
    }
}

/// The primaries of every interface \p f's bounds name: its template head
/// carries their concepts (CXXSpell::requires_clause), so its declaration
/// needs them, not only its body.
fn EmitPlan::_witness_bounds(f: *Decl) {
    if f == &null { return; }
    if self._spell.requires_clause(f).size() == 0 { return; }
    var cs = vec::<*ConstraintExpr>();
    var x = decl_extension_of(f);
    if x != &null { CXXSpell::impl_bounds(decl_requires_clause(static_cast::<*Decl>(x)), &cs); }
    CXXSpell::impl_bounds(decl_requires_clause(f), &cs);
    for var i: usize = 0; i < cs.size(); ++i {
        var c = cs[i];
        if (c->rhs == &null) || (c->rhs->canonical == &null) || (!isa::<RecordType>(canon_unqual(c->rhs->canonical))) { continue; }
        var d = cast::<RecordType>(canon_unqual(c->rhs->canonical))->decl;
        if isa::<InterfaceDecl>(CXXSpell::rep(decl_pattern(CXXSpell::rep(d)))) { self._admit(d, PlanNeed::Complete); }
    }
}

/// Requirement \p f's by-value records, as a forwarder's are.
fn EmitPlan::_witness_sig(k: usize, f: *FunctionDecl) {
    self._witness_dep(k, f->return_type);
    if f->panic_result != &null { self._witness_dep(k, f->panic_result); }
    for var j: usize = 0; j < f->params.size(); ++j {
        var p = f->params[j];
        if (p == &null) || p->is_self || (p->mode != ParamMode::Value) { continue; }
        self._witness_dep(k, p->type_);
    }
}

/// A by-value record \p t is a Complete dependency of witness \p k. An
/// interface (the requirement's own `Self`) is spelled as Self, never laid
/// out; an imported record is the header's.
fn EmitPlan::_witness_dep(k: usize, t: *Type) {
    if (t == &null) || (t->canonical == &null) { return; }
    var c = canon_unqual(t->canonical);
    if !isa::<RecordType>(c) { self._admit_type(t, PlanNeed::Complete); return; }
    var d = self.layout_decl(cast::<RecordType>(c)->decl);
    if (d == &null) || decl_is_imported(d) || isa::<InterfaceDecl>(d) { return; }
    if c->is_dependent() {
        // A generic interface's panic result names its parameters (PANIC.md
        // P10): a full specialization's body returns it at the row's
        // arguments, which C++ instantiates right there -- from the Panic
        // template, defined first, over elements complete by then.
        var en = dyn_cast::<EnumDecl>(CXXSpell::rep(cast::<RecordType>(c)->decl));
        if (en == &null) || (!en->adt_explicit_tags) { return; }
        self._admit(d, PlanNeed::Complete);
        var po = self._outermost_type(d);
        var seen = false;
        for var i: usize = 0; i < self._witnesses[k].deps.size(); ++i { if self._witnesses[k].deps[i] == po { seen = true; } }
        if !seen { self._witnesses[k].deps.push_back(po); }
        var r = cast::<RecordType>(c);
        for var i: usize = 0; i < r->args.size(); ++i { self._witness_dep(k, r->args[i]); }
        return;
    }
    self._admit_type(t, PlanNeed::Complete);
    var o = self._outermost_type(d);
    for var i: usize = 0; i < self._witnesses[k].deps.size(); ++i { if self._witnesses[k].deps[i] == o { return; } }
    self._witnesses[k].deps.push_back(o);
}

fn EmitPlan::_witness_scope(k: usize, x: *ExtensionDecl) {
    var s = self._scope_for(x, true);
    for var i: usize = 0; i < self._witnesses[k].scopes.size(); ++i { if self._witnesses[k].scopes[i] == s { return; } }
    self._witnesses[k].scopes.push_back(s);
}

// --- Roots: uses (preamble only) -------------------------------------------------

fn EmitPlan::_collect_uses() {
    var tu = self._cg->tu;
    var items = &(tu->program->items);
    for var i: usize = 0; i < items->size(); ++i {
        var item = *(items->get(i));
        switch item.kind {
            case TopLevelKind::Decl { self.dispatch_decl(item.as_decl()); }
            case TopLevelKind::Stmt { self.dispatch_stmt(item.as_stmt()); }
            case TopLevelKind::Expr { self.dispatch_expr(item.as_expr()); }
            default { }
        }
    }
}

/// Walk visible_bodies() at body strengths, both modes: a preamble's foreign
/// template and inline bodies, a header's own.
fn EmitPlan::_walk_visible() {
    // Every template and inline body visible here is this TU's body too:
    // EmitIR emits each one into this TU (emit_tu), so what it names has to
    // be in this preamble -- `alignof(YieldPromise<T>)`, `p->cur`, `return Suspend {}`
    // -- at the body strengths, exactly as this TU's own bodies are walked.
    // To a fixed point: a walked body can make another type Complete, and
    // that type's template bodies become visible in turn. In a header the
    // same walk is what declares the priv helpers and types an own inline
    // body names: _collect_own left them out, _admit does not.
    var walked = vec::<*FunctionDecl>();
    var walked_vars = vec::<*VariableDecl>();
    var progressed = true;
    while progressed {
        progressed = false;
        var vis = self.visible_bodies();
        for var i: usize = 0; i < vis.size(); ++i {
            var seen = false;
            for var k: usize = 0; k < walked.size(); ++k { if walked[k] == vis[i] { seen = true; break; } }
            if seen { continue; }
            walked.push_back(vis[i]);
            self._walk_body(vis[i]);
            progressed = true;
        }
        // An eval binding's definition is interface too (EVAL.md 1.2b):
        // what its initializer names -- the eval fn it calls, the eval
        // constant it reads -- is this TU's to declare and define.
        var vv = self.visible_eval_vars();
        for var i: usize = 0; i < vv.size(); ++i {
            var seen = false;
            for var k: usize = 0; k < walked_vars.size(); ++k { if walked_vars[k] == vv[i] { seen = true; break; } }
            if seen { continue; }
            walked_vars.push_back(vv[i]);
            self.dispatch_decl(static_cast::<*Decl>(vv[i]));
            progressed = true;
        }
    }
}

/// The eval bindings (namespace scope) whose `inline constexpr`
/// definitions this TU writes beside its own (EVAL.md 1.2b), chosen as
/// visible_bodies chooses: the foreign ones a preamble declares, a header's
/// own, both for an include. An importer cannot read an `extern const` in
/// a constant expression, so the definition, like a consteval body, is part
/// of the interface.
fn EmitPlan::visible_eval_vars() -> vec::<*VariableDecl> {
    if self._mode == PlanMode::Include { return self.include_eval_vars(); }
    return self._eval_vars(self._mode == PlanMode::Header);
}

fn EmitPlan::include_eval_vars() -> vec::<*VariableDecl> {
    var out = self._eval_vars(false);
    var own = self._eval_vars(true);
    for var i: usize = 0; i < own.size(); ++i { out.push_back(own[i]); }
    return out;
}

/// In dependency order: a constant expression reads another constant only
/// once it is defined, and declarations across files have no order of
/// their own. A cycle is not a constant at all; C++ reports it.
fn EmitPlan::_eval_vars(want_own: bool) -> vec::<*VariableDecl> {
    var pick = vec::<*VariableDecl>();
    for var i: usize = 0; i < self._set.size(); ++i {
        var v = dyn_cast::<VariableDecl>(self._set[i]);
        if (v == &null) || (!v->is_eval()) || (v->init == &null) || v->is_poisoned() { continue; }
        if (CXXSpell::fid_of(static_cast::<*Decl>(v)) == self._home) != want_own { continue; }
        pick.push_back(v);
    }
    var out = vec::<*VariableDecl>();
    var state = vec::<u8>();   // 0 new, 1 on the path, 2 placed; parallel to pick.
    for var i: usize = 0; i < pick.size(); ++i { state.push_back(u8(0)); }
    for var i: usize = 0; i < pick.size(); ++i { self._place_eval_var(i, &pick, &state, &out); }
    return out;
}

fn EmitPlan::_place_eval_var(i: usize, pick: *vec::<*VariableDecl>, state: *vec::<u8>, out: *vec::<*VariableDecl>) {
    if (*state)[i] != u8(0) { return; }
    (*state)[i] = u8(1);
    // What the initializer reads, through the eval fns it calls too: `eval
    // A = f()` with f returning B needs B defined first, though A's
    // initializer never names it.
    var me = static_cast::<*Decl>((*pick)[i]);
    self._early_needs(me);
    var seeds = vec::<*Decl>();
    for var r: usize = 0; r < self._en_key.size(); ++r {
        if (self._en_key[r] == me) && (self._en_kind[r] == u8(0)) { seeds.push_back(self._en_val[r]); }
    }
    var refs = vec::<*Decl>();
    self._early_close(&seeds, u8(0), &refs);
    for var r: usize = 0; r < refs.size(); ++r {
        for var k: usize = 0; k < pick->size(); ++k {
            if static_cast::<*Decl>((*pick)[k]) == refs[r] { self._place_eval_var(k, pick, state, out); }
        }
    }
    (*state)[i] = u8(2);
    out->push_back((*pick)[i]);
}

// --- Early items (EVAL.md §11) -----------------------------------------------

/// Which compile-time items a declaration's type needs defined ahead of it
/// (EmitPlan::early), and the order edges that put them in tier 1. Seeds:
/// the computed values in the type of every record this plan defines
/// (fields, bases, method signatures, nested types), of every function it
/// declares and of every namespace-scope variable. Closed over what each
/// item reads. A record follows every item its own types reach; an item
/// follows the records its definition needs complete, and a binding every
/// item it evaluates (a body only the items it evaluates at its definition:
/// what it merely calls is defined by the time anything evaluates it, and
/// mutual recursion stays free of cycles).
fn EmitPlan::_early() {
    for var i: usize = 0; i < self._set.size(); ++i {
        var d = self._set[i];
        var seeds = vec::<*Decl>();
        var rec = self._is_type_decl(d);
        if rec {
            if self._need[i] != PlanNeed::Complete { continue; }
            self._decl_type_items(d, &seeds);
        } else if isa::<FunctionDecl>(d) {
            var f = cast::<FunctionDecl>(d);
            for var p: usize = 0; p < f->params.size(); ++p {
                var pd = f->params[p];
                if (pd != &null) && (!pd->is_self) { self._type_items(pd->type_, &seeds); }
            }
            self._type_items(f->return_type, &seeds);
        } else if isa::<VariableDecl>(d) {
            self._type_items(cast::<VariableDecl>(d)->type_, &seeds);
        }
        if seeds.size() == 0 { continue; }
        var cl = vec::<*Decl>();
        self._early_close(&seeds, u8(0), &cl);
        for var k: usize = 0; k < cl.size(); ++k {
            EarlyNeeds::_once(&(self.early), cl[k]);
            if rec { self._eo_add(d, cl[k]); }
        }
    }
    for var k: usize = 0; k < self.early.size(); ++k {
        var x = self.early[k];
        self._early_needs(x);
        var defs = vec::<*Decl>();
        var want = (u8(0)) if (isa::<VariableDecl>(x)) else (u8(1));
        for var i: usize = 0; i < self._en_key.size(); ++i {
            if self._en_key[i] != x { continue; }
            if self._en_kind[i] == u8(2) {
                var r = self._layout_key(self._en_val[i]);
                if (r != &null) && (r != x) {
                    var at = self._index_of(r);
                    if (at != usize(-1)) && (self._need[at] == PlanNeed::Complete) { self._eo_add(x, r); }
                }
            } else if self._en_kind[i] == want {
                defs.push_back(self._en_val[i]);
            }
        }
        var cl = vec::<*Decl>();
        self._early_close(&defs, u8(0), &cl);
        for var i: usize = 0; i < cl.size(); ++i { if cl[i] != x { self._eo_add(x, cl[i]); } }
    }
}

/// \p x's EarlyNeeds, computed once into the _en_ tables.
fn EmitPlan::_early_needs(x: *Decl) {
    for var i: usize = 0; i < self._en_done.size(); ++i { if self._en_done[i] == x { return; } }
    self._en_done.push_back(x);
    var n = EarlyNeeds();
    var f = dyn_cast::<FunctionDecl>(x);
    if f != &null {
        // A member's definition is out of line: its class is complete first.
        n.named(x);
        n.dispatch_decl(x);
    }
    var v = dyn_cast::<VariableDecl>(x);
    if v != &null {
        n.rec_type(v->type_);
        if v->init != &null { n.dispatch_expr(v->init); }
    }
    for var i: usize = 0; i < n.items.size(); ++i {
        if n.items[i] == x { continue; }
        self._en_key.push_back(x); self._en_kind.push_back(u8(0)); self._en_val.push_back(n.items[i]);
    }
    for var i: usize = 0; i < n.const_items.size(); ++i {
        if n.const_items[i] == x { continue; }
        self._en_key.push_back(x); self._en_kind.push_back(u8(1)); self._en_val.push_back(n.const_items[i]);
    }
    for var i: usize = 0; i < n.recs.size(); ++i {
        self._en_key.push_back(x); self._en_kind.push_back(u8(2)); self._en_val.push_back(n.recs[i]);
    }
}

/// \p seeds and every item they read (kind 0), transitively, into \p out.
fn EmitPlan::_early_close(seeds: *vec::<*Decl>, kind: u8, out: *vec::<*Decl>) {
    for var i: usize = 0; i < seeds->size(); ++i { EarlyNeeds::_once(out, (*seeds)[i]); }
    for var k: usize = 0; k < out->size(); ++k {
        var it = (*out)[k];
        self._early_needs(it);
        for var i: usize = 0; i < self._en_key.size(); ++i {
            if (self._en_key[i] == it) && (self._en_kind[i] == kind) { EarlyNeeds::_once(out, self._en_val[i]); }
        }
    }
}

/// The items the types written in record \p d's definition compute from:
/// fields, bases, method signatures, nested records' (they are defined
/// inside it).
fn EmitPlan::_decl_type_items(d: *Decl, out: *vec::<*Decl>) {
    var rec = self.adt_record(d);
    var fields: *FrozenList::<*FieldDecl> = &null;
    var methods: *FrozenList::<*FunctionDecl> = &null;
    if isa::<ClassDecl>(rec) {
        var c = cast::<ClassDecl>(rec);
        fields = &(c->fields); methods = &(c->methods);
        for var i: usize = 0; i < c->derives_list.size(); ++i {
            var e = c->derives_list.get(i);
            if e != &null { self._type_items(e->base, out); }
        }
    } else if isa::<StructDecl>(rec) { fields = &(cast::<StructDecl>(rec)->fields); methods = &(cast::<StructDecl>(rec)->methods); }
    else if isa::<UnionDecl>(rec)  { fields = &(cast::<UnionDecl>(rec)->fields);  methods = &(cast::<UnionDecl>(rec)->methods); }
    if fields != &null {
        for var i: usize = 0; i < fields->size(); ++i {
            var f = (*fields)[i];
            if f != &null { self._type_items(f->type_, out); }
        }
    }
    if methods != &null {
        for var i: usize = 0; i < methods->size(); ++i {
            var m = (*methods)[i];
            if m == &null { continue; }
            for var p: usize = 0; p < m->params.size(); ++p {
                var pd = m->params[p];
                if (pd != &null) && (!pd->is_self) { self._type_items(pd->type_, out); }
            }
            self._type_items(m->return_type, out);
        }
    }
    var dc = CXXSpell::dc_of(rec);
    if dc == &null { return; }
    for var i: usize = 0; i < dc->dc_decls.size(); ++i {
        var nd = *(dc->dc_decls.get(i));
        if (nd == &null) || (!self._is_type_decl(nd)) { continue; }
        if isa::<UnionDecl>(nd) && cast::<UnionDecl>(nd)->is_anonymous { continue; }
        self._decl_type_items(CXXSpell::rep(nd), out);
    }
}

/// The items computed values in \p t name.
fn EmitPlan::_type_items(t: *Type, out: *vec::<*Decl>) {
    if t == &null { return; }
    var n = EarlyNeeds();
    n.rec_type(t);
    for var i: usize = 0; i < n.items.size(); ++i { EarlyNeeds::_once(out, n.items[i]); }
}

fn EmitPlan::_eo_add(who: *Decl, dep: *Decl) {
    if (who == &null) || (dep == &null) || (who == dep) { return; }
    if self._eo_has(who, dep) { return; }
    self._eo_who.push_back(who);
    self._eo_dep.push_back(dep);
}

fn EmitPlan::_eo_has(who: *Decl, dep: *Decl) -> bool {
    for var i: usize = 0; i < self._eo_who.size(); ++i {
        if (self._eo_who[i] == who) && (self._eo_dep[i] == dep) { return true; }
    }
    return false;
}

/// The tier-1 decl whose definition lays out record \p d: its primary for
/// an instance, its outermost record for a nested one.
fn EmitPlan::_layout_key(d: *Decl) -> *Decl {
    var c = CXXSpell::rep(d);
    if c == &null { return &null; }
    if decl_is_instance(c) {
        var e = self._cg->instances->entry_of(c);
        if e == &null { return &null; }
        c = CXXSpell::rep(e->primary);
        if c == &null { return &null; }
    }
    if !self._is_type_decl(c) { return &null; }
    return self._outermost_type(c);
}

/// \p d (a defining link) is defined in tier 1 as an early item.
fn EmitPlan::is_early(d: *Decl) -> bool {
    for var i: usize = 0; i < self.early.size(); ++i { if self.early[i] == d { return true; } }
    return false;
}

/// THE list of foreign bodies this TU emits, beside its own (which EmitIR
/// walks off the program): every template and `inline` definition visible
/// here, once each, as the defining link. EmitIR emits exactly this list and
/// _walk_visible walks exactly this list, so what is planned and what is
/// emitted cannot drift.
///
/// In Header mode the same rule picks the OWN bodies instead: a header is
/// the interface for C++ consumers and for nothing else, so it carries
/// exactly what an importing Kairo TU would emit from this module (the
/// foreign ones arrive through the headers it includes).
///
/// The rule is C++'s template model: a template's definition must be
/// visible in every TU that can instantiate it, and Kairo cannot list every
/// instantiation -- clang makes some on its own (a coroutine promise,
/// `await_suspend<coroutine_handle<...>>`, std::sort calling a Kairo
/// comparator). So, wherever the owner is held Complete:
///
///   - every member body of a class template (members of its nested
///     records included -- they are templated by the enclosing one);
///   - every member TEMPLATE of any class, template or not;
///   - every free function template the plan declares;
///   - every generic extension member (its own or its extension's params).
///
/// And `inline` bodies, by the same rule for a different reason: `inline`
/// puts a body in the interface, so importers compile it themselves.
///
///   - every `inline` member of every record held Complete -- ALL of them,
///     never pruned by Kairo-visible references, because Kairo never sees
///     clang's own calls (`await_ready`, `initial_suspend`, ...);
///   - every `inline` free function or extension member the plan declares,
///     at any strength.
///
/// Read off _set rather than this TU's roots, so it is transitive: a
/// `priv inline` helper that an inline body calls is admitted by the walk
/// below and its body joins the list on the next pass. That one matters --
/// clang emits an inline definition only in objects that use it, so the
/// helper's own object may well not hold it.
///
/// Cheap because of `extern template`: a registry instance is still
/// compiled once, in its home TU (InterfaceEmitter's tier 3 declares it
/// `extern` everywhere else, which stops implicit instantiation of its
/// members there). The bodies emitted everywhere are parsed everywhere but
/// only instantiated for the instances Kairo never saw. Those `extern
/// template` lines are NOT redundant with this; removing them would compile
/// every known instance in every TU that uses it.
fn EmitPlan::visible_bodies() -> vec::<*FunctionDecl> {
    // Preamble: foreign only (own bodies are emitted off the program).
    // Header: own only.
    // Include: both. The host is a C++ TU that includes nothing else of
    // Kairo's, and it compiles foo's templates and inline functions itself;
    // _walk_visible walks the same list, so whatever they name is planned.
    if self._mode == PlanMode::Include { return self.include_bodies(); }
    return self._bodies(self._mode == PlanMode::Header);
}

/// The foreign bodies, then the own ones: what an Include plan carries.
fn EmitPlan::include_bodies() -> vec::<*FunctionDecl> {
    var out = self._bodies(false);
    var own = self._bodies(true);
    for var i: usize = 0; i < own.size(); ++i { out.push_back(own[i]); }
    return out;
}

fn EmitPlan::_bodies(want_own: bool) -> vec::<*FunctionDecl> {
    var out = vec::<*FunctionDecl>();
    for var i: usize = 0; i < self._set.size(); ++i {
        var d = self._set[i];
        if (CXXSpell::fid_of(d) == self._home) != want_own { continue; }
        if self._is_type_decl(d) {
            if self._need[i] != PlanNeed::Complete { continue; }
            self._visible_record_bodies(d, false, &out);
            continue;
        }
        if d->kind != DeclKind::FunctionDecl { continue; }
        if (CXXSpell::template_params(d).size() == 0) && (!cast::<FunctionDecl>(d)->is_inline()) && (!cast::<FunctionDecl>(d)->is_eval()) { continue; }
        self._push_body(cast::<FunctionDecl>(d), &out);
    }

    // Extension members are never in _set: their scope declares them, and a
    // preamble defines every scope it touches.
    for var i: usize = 0; i < self._scopes.size(); ++i {
        var sc = &(self._scopes[i]);
        for var k: usize = 0; k < sc->members.size(); ++k {
            var m = sc->members[k];
            if m == &null { continue; }
            if (CXXSpell::fid_of(static_cast::<*Decl>(m)) == self._home) != want_own { continue; }
            if (CXXSpell::template_params(static_cast::<*Decl>(m)).size() == 0) && (!m->is_inline()) && (!m->is_eval()) { continue; }
            self._push_body(m, &out);
        }
    }
    return out;
}

/// \p d's member bodies that are part of its interface: all of them under a
/// class template (\p in_template), only its member templates and `inline`
/// members otherwise. Nested records recurse, as EmitIR::_record_bodies does.
fn EmitPlan::_visible_record_bodies(d: *Decl, in_template: bool, out: *vec::<*FunctionDecl>) {
    var templ = in_template || (decl_generic_params(d).size() > 0);
    var methods: *FrozenList::<*FunctionDecl> = &null;
    if isa::<ClassDecl>(d)       { methods = &(cast::<ClassDecl>(d)->methods);  }
    else if isa::<StructDecl>(d) { methods = &(cast::<StructDecl>(d)->methods); }
    else if isa::<UnionDecl>(d)  { methods = &(cast::<UnionDecl>(d)->methods);  }
    if methods != &null {
        for var i: usize = 0; i < methods->size(); ++i {
            var m = (*methods)[i];
            if m == &null { continue; }
            // Neither template nor inline: linked from its own TU.
            if (!templ) && (m->generic_params.size() == 0) && (!m->is_inline()) && (!m->is_eval()) { continue; }
            self._push_body(m, out);
        }
    }
    var dc = CXXSpell::dc_of(d);
    if dc == &null { return; }
    for var i: usize = 0; i < dc->dc_decls.size(); ++i {
        var nd = *(dc->dc_decls.get(i));
        if nd == &null { continue; }
        if isa::<ClassDecl>(nd) || isa::<StructDecl>(nd) || isa::<UnionDecl>(nd) { self._visible_record_bodies(nd, templ, out); }
    }
}

/// The DEFINING link of \p f -- an in-class declaration whose body is out of
/// line is in the member list, the body is on the chain -- once. Nothing
/// without a block body: there is nothing to make visible.
fn EmitPlan::_push_body(f: *FunctionDecl, out: *vec::<*FunctionDecl>) {
    var def = f;
    if !def->has_body() {
        var d = def->definition();
        if (d == &null) || d->is_poisoned() { return; }
        def = d;
    }
    if def->is_poisoned() || (def->body_kind != FnBodyKind::Block) { return; }
    for var i: usize = 0; i < out->size(); ++i { if (*out)[i] == def { return; } }
    out->push_back(def);
}

/// One visible body, walked as this TU's own bodies are. An extension
/// member's receiver is emitted as its first parameter, so the extension's
/// target is laid out here.
fn EmitPlan::_walk_body(f: *FunctionDecl) {
    var x = decl_extension_of(static_cast::<*Decl>(f));
    if (x != &null) && (x->target != &null) { self._admit_type(x->target, PlanNeed::Complete); }
    self.dispatch_decl(static_cast::<*Decl>(f));
}

/// Every expression: its resolved links, and its TYPE. An expression of
/// class type is a prvalue or an lvalue clang has to lay out, so a
/// by-value record type at any expression is Complete -- that is how a
/// call's return type enters at full strength while the callee's
/// declaration only names it.
fn EmitPlan::visit_expr(e: *Expr) -> bool {
    if e == &null { return true; }
    if e->type_ != &null { self._admit_type(e->type_, PlanNeed::Complete); }
    switch e->kind {
        case ExprKind::NamedIdentExpr {
            var n = cast::<NamedIdentExpr>(e);
            self._admit_use(n->resolved_decl);
            self._admit_cell(n->candidate_cell);
        } case ExprKind::ChainExpr {
            var c = cast::<ChainExpr>(e);
            for var i: usize = 0; i < c->steps.size(); ++i {
                var s = c->steps.get(i);
                if s == &null { continue; }
                self._admit_use(s->resolved_decl);
                self._admit_cell(s->candidate_cell);
                // `Box<int>::count`: the member is looked up in the class,
                // so the instance is complete here (as CallExpr::qualifier).
                self._admit_type(s->through, PlanNeed::Complete);
            }
        } case ExprKind::ClosureExpr {
            // A panicking closure's lambda returns its Panic result.
            self._admit_type(cast::<ClosureExpr>(e)->panic_result, PlanNeed::Complete);
        } case ExprKind::StringLiteralExpr {
            // A byte literal C++ reads at compile time (EVAL.md 2a): a long
            // one is a named array this plan's interface defines.
            var sl = cast::<StringLiteralExpr>(e);
            if sl->const_eval && (sl->imm != &null) && sl->imm->has_owned_text() {
                self.note_eval_str(sl->imm->owned_ptr, static_cast::<usize>(sl->imm->owned_len));
            }
        } case ExprKind::SizeOfExpr {
            // The operand is laid out, not just named: Complete, whatever
            // visit_type (Fwd, for a type merely spelled) would say.
            self._admit_type(cast::<SizeOfExpr>(e)->type_arg, PlanNeed::Complete);
        } case ExprKind::AlignOfExpr {
            self._admit_type(cast::<AlignOfExpr>(e)->type_arg, PlanNeed::Complete);
        } case ExprKind::CallExpr {
            // A generic callee's instance: tier 3, homed where it was first
            // named, `extern template` elsewhere. A FUNCTION instance's decl
            // is the primary itself (InstantiationRegistry::_new_instance),
            // so it never comes through _admit's instance-shell path.
            var ie = reinterpret_cast::<*InstanceEntry>(cast::<CallExpr>(e)->instance);
            if ie != &null { self._admit_instance(ie, PlanNeed::Fwd); }
            // `Box<int>::zero()`: the member is looked up in the class, so
            // the instance is complete here, and homed like any named one.
            self._admit_type(cast::<CallExpr>(e)->qualifier, PlanNeed::Complete);
            // `I::m(x)` on a concrete x: its row rides on the call.
            var wr = reinterpret_cast::<*ConformanceRow>(cast::<CallExpr>(e)->witness_row);
            if wr != &null { self._witness_row(wr); }
        } default { break; }
    }
    return true;
}

/// A compile-time literal's bytes, \p n of them at \p p: one past the
/// inline limit is recorded for its named definition, once per content
/// (the name is the content's, so equal bytes are one definition).
fn EmitPlan::note_eval_str(p: std::ConstPtr::<u8>, n: usize) {
    if n <= LowerTargets::eval_str_inline_max() { return; }
    var h = LowerTargets::eval_str_hash(p, n);
    for var i: usize = 0; i < self.big_str_hashes.size(); ++i {
        if (self.big_str_hashes[i] == h) && (self.big_str_lens[i] == n) { return; }
    }
    self.big_str_bytes.push_back(p);
    self.big_str_lens.push_back(n);
    self.big_str_hashes.push_back(h);
}

/// Naming a type in syntax declares it; layout strength comes from the
/// declaration positions in visit_decl.
fn EmitPlan::visit_type(t: *Type) -> bool {
    if t == &null { return true; }
    var c = t->canonical;
    if c == &null { return true; }
    if c->kind != TypeKind::RecordType { return true; }
    self._admit(cast::<RecordType>(c)->decl, PlanNeed::Fwd);
    return true;
}

/// Declared types are LAYOUT positions: Complete, weakened by the shape.
fn EmitPlan::visit_decl(d: *Decl) -> bool {
    if d == &null { return true; }
    switch d->kind {
        case DeclKind::VariableDecl  {
            if cast::<VariableDecl>(d)->raw_slot { self.needs_raw_slot = true; }
            self._admit_type(cast::<VariableDecl>(d)->type_, PlanNeed::Complete);
        }
        case DeclKind::FieldDecl     { self._admit_type(cast::<FieldDecl>(d)->type_, PlanNeed::Complete); }
        case DeclKind::ParamDecl {
            var p = cast::<ParamDecl>(d);
            self._admit_type(((p->pack_type) if (p->is_pack && (p->pack_type != &null)) else (p->type_)), PlanNeed::Complete);
        }
        case DeclKind::FunctionDecl  {
            self._admit_type(cast::<FunctionDecl>(d)->return_type, PlanNeed::Complete);
            self._admit_type(cast::<FunctionDecl>(d)->panic_result, PlanNeed::Complete);   // PANIC.md §4.1: what C++ returns.
        }
        case DeclKind::TypeAliasDecl { self._admit_type(cast::<TypeAliasDecl>(d)->aliased, PlanNeed::Complete); }
        default { break; }
    }
    return true;
}

/// A use site. A member of a type (method, field, static, nested type)
/// needs its OWNER complete: C++ cannot look into an incomplete class.
/// A free function or a type needs a declaration.
fn EmitPlan::_admit_use(d: *Decl) {
    if d == &null { return; }
    var owner = self._member_owner(d);
    if owner != &null { self._admit(owner, PlanNeed::Complete); return; }
    self._admit(d, PlanNeed::Fwd);
}

fn EmitPlan::_admit_cell(cell: *OverloadCell) {
    if cell == &null { return; }
    for var i: usize = 0; i < cell->size(); ++i { self._admit_use(cell->get(i)); }
}

/// The type whose scope holds \p d, or null for a namespace-scope decl.
fn EmitPlan::_member_owner(d: *Decl) -> *Decl {
    var dc = reinterpret_cast::<*DeclContext>(d->semantic_dc);
    if dc == &null { return &null; }
    if !dc->is_type_scope() { return &null; }
    if dc->dc_kind == DeclContextKind::Extension { return &null; }   // its scope's static member, not the target's.
    return dc->dc_owner;
}

// --- The working set -----------------------------------------------------------

/// Everything funnels through here. Decides what is plannable, redirects
/// instances to their primary and nested types to their outermost owner.
fn EmitPlan::_admit(d: *Decl, need: PlanNeed) {
    if d == &null { return; }
    var c = CXXSpell::rep(d);
    if c == &null { return; }
    // A record declared in a function body (FinallyLowering's guard) is part
    // of that body: EmitIR emits it in place, and nothing about it belongs
    // in the preamble or the header. Its fields' owner and its destructor
    // land here too and are skipped the same way.
    if CXXSpell::in_function_scope(c) { return; }
    if decl_is_imported(c) { return; }             // the header declares it (IMPORTS.md §5).
    if decl_ffi_tag_target(c) != &null { return; } // `ffi "c" struct T`: the header's tag, not a Kairo type (§5.2).
    // An interface's C++ entity is its witness: named by a call through a
    // bound (_admit_use on the requirement), or by a bound's concept.
    if isa::<InterfaceDecl>(c) { self._witness_primary(c); return; }
    // An extension member reached through a use (`l.pos.len()`) is not a
    // member by _member_owner, so without this it is admitted a second time
    // as an ordinary function; it is its scope's static member instead.
    var x = decl_extension_of(c);
    if x != &null { self._scope_for(x, true); return; }

    if decl_is_instance(c) {
        var e = self._cg->instances->entry_of(c);
        if (e == &null) { self._ice(c->range, "EmitPlan: instance shell with no registry entry"); }
        self._admit_instance(e, need);
        return;
    }
    if !self._plannable(c) { return; }

    // A nested type is part of its outermost owner's definition.
    var outer = self._outermost_type(c);
    if outer != c { self._admit(outer, need); return; }
    // A payload struct is minted inside its ADT (its semantic_dc is the
    // enum), so the fold above always takes it to the enum, whose layout
    // record defines it. One planned here as a record of its own would be
    // defined twice -- inside the ADT and again beside it.
    var ps = dyn_cast::<StructDecl>(c);
    if (ps != &null) && ps->is_adt_payload {
        self._ice(c->range, "EmitPlan: an ADT payload struct reached the plan as a record of its own; EnumLayoutLowering places it in its enum");
    }

    var at = self._index_of(c);
    if at == usize(-1) {
        self._set.push_back(c);
        self._need.push_back(need);
        self._queue.push_back(self._set.size() - 1);
        self._admit_specs(c, need);
        return;
    }
    if static_cast::<u8>(need) > static_cast::<u8>(self._need[at]) {
        self._need[at] = need;
        self._queue.push_back(at);
        self._admit_specs(c, need);
    }
}

/// A generic record's specializations ride with it at the same strength:
/// every C++ TU that can name `Store<X>` must have seen each `Store<P*>` /
/// `Store<bool>` before the first use that would instantiate one, or it
/// instantiates the primary for it ([temp.expl.spec]/7, no diagnostic
/// required). A Complete primary admits them Complete so an instance
/// selected into a partial is laid out by it.
fn EmitPlan::_admit_specs(c: *Decl, need: PlanNeed) {
    if (decl_generic_params(c).size() == 0) || CXXSpell::is_record_spec(c) { return; }
    var specs = vec::<*Decl>();
    self._cg->instances->specs_of(c, &specs);
    for var i: usize = 0; i < specs.size(); ++i {
        var sd = CXXSpell::rep(specs[i]);
        if (sd == &null) || sd->is_poisoned() { continue; }
        self._admit(sd, need);
    }
}

/// `Box<Foo>`: the primary at \p need, each argument at \p need only
/// where the primary stores it by value, else Fwd; the instance itself
/// recorded for tier 3.
fn EmitPlan::_admit_instance(e: *InstanceEntry, need: PlanNeed) {
    var prim = CXXSpell::rep(e->primary);
    if decl_is_imported(prim) { return; }          // clang instantiates it from the PCH.
    // A generic REQUIREMENT's instance names no C++ function: the call goes
    // through the witness's member template, instantiated implicitly. No
    // tier-3 line, ever (CODEGEN.md §7b.8); its arguments are still named.
    if self._is_requirement(prim) {
        for var i: usize = 0; i < e->args.size(); ++i { self._admit_type(e->args[i], PlanNeed::Fwd); }
        return;
    }
    // A member template of a CLASS TEMPLATE: the entry holds the member's own
    // arguments only, not the owner's, so it names no one C++ entity
    // (`Box<A>::both<X>` and `Box<B>::both<X>` are one entry) and no tier-3
    // line can spell it. Its body is visible wherever the owner is complete
    // (§7), so the C++ instantiates it implicitly; its rows still apply.
    if self._member_of_template(prim) {
        for var i: usize = 0; i < e->rows.size(); ++i { self._witness_row(e->rows[i]); }
        for var i: usize = 0; i < e->args.size(); ++i { self._admit_type(e->args[i], PlanNeed::Fwd); }
        // Its body is compiled wherever the owner is, so what it reaches is
        // needed there too, rows included (no tier-3 line of its own).
        var mseen = false;
        for var i: usize = 0; i < self._members.size(); ++i { if self._members[i] == e { mseen = true; break; } }
        if !mseen {
            self._members.push_back(e);
            self._admit_reached(e);
            for var i: usize = 0; i < e->panic_types.size(); ++i { self._admit_type(e->panic_types[i], PlanNeed::Complete); }
        }
        return;
    }
    var seen = false;
    for var i: usize = 0; i < self._insts.size(); ++i { if self._insts[i] == e { seen = true; break; } }
    if !seen {
        self._insts.push_back(e);
        self._admit_reached(e);
        // The panic results its body names at these arguments (PANIC.md
        // P10, InstanceEntry::panic_types): C++ forms them only when it
        // instantiates the body, so their elements' ids must be written
        // wherever it may.
        for var i: usize = 0; i < e->panic_types.size(); ++i { self._admit_type(e->panic_types[i], PlanNeed::Complete); }
    }
    self._admit(prim, PlanNeed::Complete);
    // Every TU holding the instance may compile its body (it is a visible
    // C++ inline body), so every one needs the specializations its bounds
    // bind, or it compiles the primary instead (CODEGEN.md §7b.6).
    for var i: usize = 0; i < e->rows.size(); ++i { self._witness_row(e->rows[i]); }
    // A panic result's elements are complete wherever it is named, even
    // where a declaration only names it (a header's `Panic<T, E...> f()`):
    // its tier-3 line asserts its size, and a C++ caller receives it by
    // value and reads its error (PANIC.md §4.6).
    var en = dyn_cast::<EnumDecl>(prim);
    var whole = (en != &null) && en->adt_explicit_tags;
    for var i: usize = 0; i < e->args.size(); ++i {
        var n = (PlanNeed::Complete) if (whole) else (need);
        if !self._arg_by_value(prim, i) { n = PlanNeed::Fwd; }
        self._admit_type(e->args[i], n);
    }
    // Laid out by a partial specialization: what IT holds by value is what
    // the instance needs complete, read off its own parameters' bindings.
    if e->pattern != &null {
        var part = CXXSpell::rep(e->pattern);
        for var i: usize = 0; i < e->pattern_args.size(); ++i {
            if self.param_by_value(part, static_cast::<u32>(i)) { self._admit_type(e->pattern_args[i], need); }
        }
    }
}

/// Follow a type to the records it needs at the strength the SHAPE
/// dictates: an indirection weakens to Fwd, the by-value spine keeps
/// \p need.
fn EmitPlan::_admit_type(t: *Type, need: PlanNeed) {
    if t == &null { return; }
    var c = t->canonical;
    if c == &null { c = t; }
    switch c->kind {
        case TypeKind::QualifiedType { self._admit_type(cast::<QualifiedType>(c)->inner, need); }
        case TypeKind::RecordType {
            var r = cast::<RecordType>(c);
            var d = CXXSpell::rep(r->decl);
            // Naming `L<i32>::P` at all -- through a pointer too -- looks P
            // up inside L<i32>, which C++ must have instantiated.
            if r->outer != &null { self._admit_type(r->outer, PlanNeed::Complete); }
            if (d != &null) && decl_is_instance(d) {
                self._admit(d, need);                 // _admit_instance handles the args.
            } else {
                self._admit(d, need);
                for var i: usize = 0; i < r->args.size(); ++i {
                    var n = need;
                    if !self._arg_by_value(d, i) { n = PlanNeed::Fwd; }
                    self._admit_type(*(r->args.get(i)), n);
                }
            }
        }
        case TypeKind::PointerType      { self._admit_type(cast::<PointerType>(c)->pointee, PlanNeed::Fwd); }
        case TypeKind::CXXLValueRefType { self._admit_type(cast::<CXXLValueRefType>(c)->referee, PlanNeed::Fwd); }
        case TypeKind::CXXRValueRefType { self._admit_type(cast::<CXXRValueRefType>(c)->referee, PlanNeed::Fwd); }
        // `T?` is its record to C++ (NullableTypeLowering), held by value.
        case TypeKind::NullableType     { self._admit_type(self._nullable_record(c), need); }
        // No Vector/Set/Map/Tuple arms: they are RecordTypes now and admit
        // through the record path, which already walks their generic
        // arguments (a tuple's elements are by value, so at \p need).
        case TypeKind::FixedArrayType {
            self._admit_type(cast::<FixedArrayType>(c)->element, need);
            self._admit_type(cast::<FixedArrayType>(c)->extent_param, PlanNeed::Fwd);
        }
        // A computed value (EVAL.md 0.2) names what C++ computes it from:
        // the eval fn it calls (consteval, so its body comes too), the eval
        // constant it reads (its definition comes too, visible_eval_vars),
        // a cast's type.
        case TypeKind::TypeExpr {
            var v = cast::<TypeExpr>(c);
            if (!v->is_value) || v->is_exact() { break; }
            // A string (EVAL.md 7e): the string record is constructed right
            // in the argument, over `__kairo_estr<...>` or a named array.
            if v->vop == ValueOp::Str {
                self.needs_eval_str = true;
                self._admit_type(v->vty, PlanNeed::Complete);
                self.note_eval_str(v->vbytes, static_cast::<usize>(v->vmag));
                break;
            }
            // Not an `eval for` binding: a local, declared where it stands.
            var local = (v->vdecl != &null) && ((v->vdecl->semantic_dc == &null) || CXXSpell::in_function_scope(v->vdecl));
            if (v->vdecl != &null) && (!local) { self._admit_use(v->vdecl); }
            if v->vty != &null { self._admit_type(v->vty, PlanNeed::Fwd); }
            for var i: usize = 0; i < v->vops.size(); ++i { self._admit_type(v->vops[i], PlanNeed::Fwd); }
        }
        case TypeKind::FunctionPointerType {
            var f = cast::<FunctionPointerType>(c);
            if !f->is_unprototyped { self.needs_fn_value = true; }
            for var i: usize = 0; i < f->params.size(); ++i { self._admit_type(*(f->params.get(i)), PlanNeed::Fwd); }
            self._admit_type(f->return_type, PlanNeed::Fwd);
            self._admit_type(f->panic_result, PlanNeed::Complete);   // its value returns this (PANIC.md §4.1).
        }
        // `T::Node` names the bound's witness (its member type) and T.
        case TypeKind::AssocType {
            var a = cast::<AssocType>(c);
            self._admit_type(a->base, PlanNeed::Fwd);
            for var i: usize = 0; i < a->args.size(); ++i { self._admit_type(a->args[i], PlanNeed::Fwd); }
            var ic = canon_unqual(a->iface);
            if (ic != &null) && isa::<RecordType>(ic) { self._admit(cast::<RecordType>(ic)->decl, PlanNeed::Complete); }
        }
        case TypeKind::BuiltinType {
            // A builtin spelled as a Kairo declaration (`byte` -> Byte): an
            // opaque `enum class : unsigned char;` is already complete, so
            // any strength will do.
            var bt = cast::<BuiltinType>(c);
            if bt->lang_decl != &null { self._admit(bt->lang_decl, need); }
        }
        default { break; }   // generic param, opaque: nothing to declare.
    }
}

// --- Closure ---------------------------------------------------------------------

fn EmitPlan::_close() {
    while self._queue.size() > 0 {
        var at = self._queue[self._queue.size() - 1];
        self._queue.pop_back();
        self._expand(self._set[at], self._need[at]);
    }
}

fn EmitPlan::_expand(d: *Decl, need: PlanNeed) {
    if isa::<FunctionDecl>(d) { self._expand_fn(cast::<FunctionDecl>(d)); return; }
    // `extern T x;` only names T; the defining TU's own walk (visit_decl)
    // asks for Complete where the definition lays it out.
    if isa::<VariableDecl>(d) { self._admit_type(cast::<VariableDecl>(d)->type_, PlanNeed::Fwd); return; }
    // A bounded record's head carries its concepts, and even its tier-0
    // forward declaration is a head: at any strength.
    self._witness_bounds(d);
    if need != PlanNeed::Complete { return; }
    self._expand_type(d);
}

/// A declaration names its types, it does not lay them out.
fn EmitPlan::_expand_fn(n: *FunctionDecl) {
    self._witness_bounds(static_cast::<*Decl>(n));
    for var i: usize = 0; i < n->params.size(); ++i {
        var p = *(n->params.get(i));
        if (p == &null) || p->is_self { continue; }
        self._admit_type(((p->pack_type) if (p->is_pack && (p->pack_type != &null)) else (p->type_)), PlanNeed::Fwd);
    }
    self._admit_type(n->return_type, PlanNeed::Fwd);
    self._admit_type(n->panic_result, PlanNeed::Fwd);
}

/// The whole definition (invariant 11): bases and by-value fields at
/// Complete, the by-value types of method signatures at Complete too
/// (_expand_member_sig), nested types recursively, and the same-file
/// extension members that will be named as friends. An ADT is defined as
/// its layout record (adt_record): its fields, role functions, nested tag
/// enum and payload structs, and the friends written on it.
fn EmitPlan::_expand_type(d: *Decl) {
    // A value parameter's class (EVAL.md 7e) is part of the template's head.
    var gps = decl_generic_params(d);
    for var i: usize = 0; i < gps.size(); ++i {
        var gp = gps[i];
        if (gp != &null) && gp->is_const_param && (gp->value_type != &null) { self._admit_type(gp->value_type, PlanNeed::Complete); }
    }
    var rec = self.adt_record(d);
    switch rec->kind {
        case DeclKind::ClassDecl {
            var n = cast::<ClassDecl>(rec);
            self._bases(&(n->derives_list));
            self._fields(&(n->fields));
            self._methods(&(n->methods));
        } case DeclKind::StructDecl {
            var n = cast::<StructDecl>(rec);
            self._fields(&(n->fields));
            self._methods(&(n->methods));
        } case DeclKind::UnionDecl {
            var n = cast::<UnionDecl>(rec);
            self._fields(&(n->fields));
            self._methods(&(n->methods));
        } case DeclKind::EnumDecl {
            // A plain enum, or an ADT whose record was never built.
            var n = cast::<EnumDecl>(rec);
            for var i: usize = 0; i < n->variants.size(); ++i {
                var v = *(n->variants.get(i));
                if v == &null { continue; }
                self._fields(&(v->payload));
            }
        } case DeclKind::TypeAliasDecl {
            self._admit_type(cast::<TypeAliasDecl>(rec)->aliased, PlanNeed::Complete);
        } default { break; }
    }
    // Nested types ride inside this definition. So do member aliases
    // (InterfaceEmitter writes them as `using`), and what one names is held
    // at Complete for the reason _expand_member_sig gives: whoever reads
    // `R::promise_type` -- <coroutine>'s traits, any C++ user -- gets the
    // type itself, not a declaration of it.
    var dc = CXXSpell::dc_of(rec);
    if dc != &null {
        for var i: usize = 0; i < dc->dc_decls.size(); ++i {
            var nd = *(dc->dc_decls.get(i));
            if nd == &null { continue; }
            if isa::<TypeAliasDecl>(nd) {
                self._admit_type(cast::<TypeAliasDecl>(nd)->aliased, PlanNeed::Complete);
                continue;
            }
            if !self._is_type_decl(nd) { continue; }
            // An anonymous union is not a nested type: it has no name and no
            // definition of its own, and its members were walked through its
            // field by _fields. Expanding it here would walk them twice.
            if isa::<UnionDecl>(nd) && cast::<UnionDecl>(nd)->is_anonymous { continue; }
            self._expand_type(CXXSpell::rep(nd));
        }
    }
    self._collect_same_file_extensions(rec);
    self._admit_friends(rec);
}

fn EmitPlan::_bases(bases: *FrozenList::<InheritEdge>) {
    for var i: usize = 0; i < bases->size(); ++i {
        var e = bases->get(i);
        if e == &null { continue; }
        self._admit_type(e->base, PlanNeed::Complete);
    }
}

fn EmitPlan::_fields(fields: *FrozenList::<*FieldDecl>) {
    for var i: usize = 0; i < fields->size(); ++i {
        var f = *(fields->get(i));
        if f == &null { continue; }
        // The union is written inline as this field (`union { ... };`), so
        // what its members hold by value is this record's dependency, at the
        // same strength as an ordinary field's. Admitting the union type
        // itself would only land on the owner again (_outermost_type).
        if f->is_anonymous_union {
            self._fields(&(self.anon_union_of(f)->fields));
            continue;
        }
        self._admit_type(f->type_, PlanNeed::Complete);
    }
}

fn EmitPlan::_methods(methods: *FrozenList::<*FunctionDecl>) {
    for var i: usize = 0; i < methods->size(); ++i {
        var m = *(methods->get(i));
        if m == &null { continue; }
        self._expand_member_sig(m);
    }
}

/// A method of a record this TU holds COMPLETE: what its signature names by
/// value is Complete too, shape-weakened as always (a pointer stays Fwd).
///
/// A free function's declaration only names its types, and _expand_fn keeps
/// them Fwd. A complete class is different: anything in this TU may call
/// any of its members, and a call whose return or parameter is an incomplete
/// class is ill-formed -- including calls Kairo never sees. clang's
/// coroutine machinery calls `promise.initial_suspend()` on a YieldPromise<T>
/// the plan only ever held at Complete for its layout, and Suspend, named in
/// nothing but those signatures, stayed `class Suspend;` in every TU but its
/// own. The body-less definition is all that is needed; no bodies follow.
///
/// Strength only, never ORDER: _needs_complete reads bases and fields, so a
/// method returning a type that returns this one is two definitions in
/// either order, not a tier-1 cycle.
fn EmitPlan::_expand_member_sig(n: *FunctionDecl) {
    self._witness_bounds(static_cast::<*Decl>(n));   // a bounded member template's head.
    for var i: usize = 0; i < n->params.size(); ++i {
        var p = *(n->params.get(i));
        if (p == &null) || p->is_self { continue; }
        self._admit_type(((p->pack_type) if (p->is_pack && (p->pack_type != &null)) else (p->type_)), PlanNeed::Complete);
    }
    self._admit_type(n->return_type, PlanNeed::Complete);
    self._admit_type(n->panic_result, PlanNeed::Complete);
}

/// Extensions targeting \p d written in d's OWN file: their scope is the
/// definition's friend struct (RESOLUTION.md §2b), so it must be declared
/// before it. Touched, not reached. Found by walking that file's program;
/// an extension index lives in sema and codegen keeps no second one.
fn EmitPlan::_collect_same_file_extensions(d: *Decl) {
    var tu = CXXSpell::tu_of(d);
    if (tu == &null) || (tu->program == &null) { return; }
    var items = &(tu->program->items);
    for var i: usize = 0; i < items->size(); ++i {
        var item = *(items->get(i));
        if item.kind != TopLevelKind::Decl { continue; }
        self._collect_ext_in(item.as_decl(), d);
    }
}

fn EmitPlan::_collect_ext_in(cand: *Decl, target: *Decl) {
    if cand == &null { return; }
    if isa::<VisibilityGroupDecl>(cand) {
        var g = cast::<VisibilityGroupDecl>(cand);
        for var i: usize = 0; i < g->members.size(); ++i { self._collect_ext_in(g->members[i], target); }
        return;
    }
    if isa::<ModuleDecl>(cand) {
        var dc = static_cast::<*DeclContext>(cast::<ModuleDecl>(cand));
        for var i: usize = 0; i < dc->dc_decls.size(); ++i { self._collect_ext_in(*(dc->dc_decls.get(i)), target); }
        return;
    }
    var x = dyn_cast::<ExtensionDecl>(cand);
    if x == &null { return; }
    if self._ext_target(x) != target { return; }
    if x->methods.size() == 0 { return; }
    self._scope_for(x, self._mode == PlanMode::Preamble);
}

/// The layout decl an extension targets: the primary for a generic one.
fn EmitPlan::_ext_target(x: *ExtensionDecl) -> *Decl {
    if (x == &null) || (x->target == &null) { return &null; }
    var c = x->target->canonical;
    if (c == &null) || (c->kind != TypeKind::RecordType) { return &null; }
    return self.layout_decl(cast::<RecordType>(c)->decl);
}

/// What \p e's body reaches once its arguments are known (`outer<M>`
/// calling `inner(Wrap<T>{...})`: `inner<Wrap<M>>`, `Wrap<M>`) is named in
/// no tree, yet this TU compiles that body or links against it: hold each
/// reached instance too, so tier 3 writes its explicit instantiation in its
/// home and `extern template` everywhere else, and its witness rows are
/// admitted with it -- an instance's rows are its own bounds', never its
/// reach's (the discovery walk checks each instance once, MONO.md D4).
/// Callers run this once per instance, so a body that reaches itself
/// stops. A function instance comes in as a call's does, its arguments
/// Fwd. A record instance as a type naming it does (_admit: an interface's
/// is its witness, an imported one clang's), Complete: its explicit
/// instantiation lays it out.
fn EmitPlan::_admit_reached(e: *InstanceEntry) {
    var rs = vec::<*InstanceEntry>();
    self._cg->instances->reached_of(e, &rs);
    for var i: usize = 0; i < rs.size(); ++i {
        var r = rs[i];
        if isa::<FunctionDecl>(r->primary) { self._admit_instance(r, PlanNeed::Fwd); }
        else if r->decl != &null { self._admit(r->decl, PlanNeed::Complete); }
    }
}

// --- Layout queries (LayoutSpine + _admit_instance) ------------------------------

/// The decl whose fields define a record's layout: an instance's pattern
/// (its shell is empty until M2 fills it), and for an ADT enum its layout
/// record (adt_record); the representative otherwise.
fn EmitPlan::layout_decl(d: *Decl) -> *Decl {
    var r = CXXSpell::rep(d);
    if (r != &null) && decl_is_instance(r) {
        // Laid out by the partial specialization the registry selected for
        // it, when one was: `Store<*i32>` has the partial's fields, not T's.
        var e = self._cg->instances->entry_of(r);
        if (e != &null) && (e->pattern != &null) { r = CXXSpell::rep(e->pattern); }
        else { r = CXXSpell::rep(decl_pattern(r)); }
    }
    return self.adt_record(r);
}

/// The extension scope a record-targeted extension belongs to, keyed by
/// TEMPLATE: the primary's layout decl for every form of it. One struct
/// per name (ext_scope_name spells the primary), so `extend <> Store<bool>`
/// and `extend <P> Store<*P>` join `extend <T> Store<T>`'s scope, each
/// member over its own receiver, rather than three structs named alike.
fn EmitPlan::_scope_key(d: *Decl) -> *Decl {
    var r = CXXSpell::rep(d);
    if r == &null { return &null; }
    return self.adt_record(CXXSpell::rep(decl_pattern(r)));
}

/// THE redirect from an ADT enum to the record it is written as
/// (EnumDecl::adt_layout). Every walk that reads a record's members comes
/// through here -- layout_decl, _expand_type, _needs_complete,
/// _param_by_value_walk -- so no two of them can disagree about whether an
/// ADT is its variants or its record. A plain enum, every other decl, and an
/// ADT whose record was never built (sema stopped before the lowerings) are
/// themselves.
fn EmitPlan::adt_record(d: *Decl) -> *Decl {
    var en = dyn_cast::<EnumDecl>(d);
    if (en == &null) || (!en->is_adt) || (en->adt_layout == &null) { return d; }
    return en->adt_layout;
}

/// The anonymous union that field \p f (`is_anonymous_union`) declares. One
/// resolver for every walk that sees through such a field -- the plan's,
/// LayoutSpine's and InterfaceEmitter's -- so none of them can disagree on
/// what the members are. A flag on a field whose type is anything else is a
/// broken lowering, not a shape to tolerate.
fn EmitPlan::anon_union_of(f: *FieldDecl) -> *UnionDecl {
    var u: *UnionDecl = &null;
    if (f->type_ != &null) && (f->type_->canonical != &null) {
        var c = canon_unqual(f->type_->canonical);
        if isa::<RecordType>(c) { u = dyn_cast::<UnionDecl>(CXXSpell::rep(cast::<RecordType>(c)->decl)); }
    }
    if (u == &null) || (!u->is_anonymous) {
        self._ice(f->range, "EmitPlan: a field marked is_anonymous_union whose type is not an anonymous union");
    }
    return u;
}

/// True iff \p prim's layout reaches its \p idx-th generic parameter by
/// value. `Box<T> { var v: T }` yes; `Box<T> { var p: *T }` no. Memoized.
/// Recursion through another generic's field bottoms out at a depth cap
/// and answers "by value", the safe direction (an over-strong edge can
/// only trip the cycle assert, never miss a definition).
/// param_by_value for argument \p i of an instance of \p prim, flat. An
/// element of a pack-expanded variant's pack is held by value (a pack field
/// is the pack itself, P0), in the variant's `__kairo_pu` union, which the
/// field walk does not see through: a header declaring a function that
/// returns `Panic<T, E...>` needs every E complete (PANIC.md §4.6).
fn EmitPlan::_arg_by_value(prim: *Decl, i: usize) -> bool {
    var en = dyn_cast::<EnumDecl>(prim);
    if (en != &null) && en->is_adt {
        var p = adt_pack_param(en);
        if (p != usize(-1)) && (i >= p) { return true; }
    }
    return self.param_by_value(prim, static_cast::<u32>(i));
}

fn EmitPlan::param_by_value(prim: *Decl, idx_in: u32) -> bool {
    if prim == &null { return false; }
    // An instance's arguments past a pack's position are the pack's
    // elements (InstanceEntry::args, flat): each is held as the pack is.
    var idx = idx_in;
    var pgs = decl_generic_params(prim);
    for var i: usize = 0; i < pgs.size(); ++i {
        if (pgs[i] != &null) && pgs[i]->is_pack && (usize(idx) > i) { idx = u32(i); break; }
    }
    // One question per record: an ADT asked as its enum or as its layout
    // record is the same one, so it gets one memo key.
    var p   = self.layout_decl(prim);
    var key = (reinterpret_cast::<u64>(p) << 8) ^ static_cast::<u64>(idx);
    for var i: usize = 0; i < self._pbv_key.size(); ++i {
        if self._pbv_key[i] == key { return self._pbv_val[i]; }
    }
    if self._pbv_depth > 32 { return true; }
    self._pbv_depth += 1;
    var ans = self._param_by_value_walk(p, idx);
    self._pbv_depth -= 1;
    self._pbv_key.push_back(key);
    self._pbv_val.push_back(ans);
    return ans;
}

/// An ADT's fields are its layout record's (adt_record). \p prim stays what
/// a generic parameter's owner is compared against (_type_reaches_param).
fn EmitPlan::_param_by_value_walk(prim: *Decl, idx: u32) -> bool {
    var rec = self.adt_record(prim);
    switch rec->kind {
        case DeclKind::ClassDecl {
            var n = cast::<ClassDecl>(rec);
            if self._edges_reach_param(&(n->derives_list), prim, idx) { return true; }
            return self._fields_reach_param(&(n->fields), prim, idx);
        } case DeclKind::StructDecl {
            return self._fields_reach_param(&(cast::<StructDecl>(rec)->fields), prim, idx);
        } case DeclKind::UnionDecl {
            return self._fields_reach_param(&(cast::<UnionDecl>(rec)->fields), prim, idx);
        } case DeclKind::EnumDecl {
            var n = cast::<EnumDecl>(rec);
            for var i: usize = 0; i < n->variants.size(); ++i {
                var v = *(n->variants.get(i));
                if (v != &null) && self._fields_reach_param(&(v->payload), prim, idx) { return true; }
            }
            return false;
        } default { return false; }
    }
    return false;
}

fn EmitPlan::_edges_reach_param(list: *FrozenList::<InheritEdge>, prim: *Decl, idx: u32) -> bool {
    for var i: usize = 0; i < list->size(); ++i {
        var e = list->get(i);
        if (e != &null) && self._type_reaches_param(e->base, prim, idx) { return true; }
    }
    return false;
}

fn EmitPlan::_fields_reach_param(list: *FrozenList::<*FieldDecl>, prim: *Decl, idx: u32) -> bool {
    for var i: usize = 0; i < list->size(); ++i {
        var f = *(list->get(i));
        if f == &null { continue; }
        // An anonymous union's members are stored in the record by value.
        if f->is_anonymous_union {
            if self._fields_reach_param(&(self.anon_union_of(f)->fields), prim, idx) { return true; }
            continue;
        }
        if self._type_reaches_param(f->type_, prim, idx) { return true; }
    }
    return false;
}

fn EmitPlan::_type_reaches_param(t: *Type, prim: *Decl, idx: u32) -> bool {
    if t == &null { return false; }
    var c = t->canonical;
    if c == &null { c = t; }
    switch c->kind {
        case TypeKind::QualifiedType { return self._type_reaches_param(cast::<QualifiedType>(c)->inner, prim, idx); }
        case TypeKind::NullableType  { return self._type_reaches_param(cast::<NullableType>(c)->lowered, prim, idx); }
        case TypeKind::GenericParamType {
            var g = cast::<GenericParamType>(c);
            // Both through layout_decl: walking an ADT's record, \p prim is
            // that record while T's owner is the enum.
            return (self.layout_decl(g->owner) == self.layout_decl(prim)) && (g->param_index == idx);
        }
        case TypeKind::RecordType {
            var r = cast::<RecordType>(c);
            var d = self.layout_decl(r->decl);
            // A payload struct is laid out inside its ADT (LayoutSpine::reaches).
            var ps = dyn_cast::<StructDecl>(d);
            if (ps != &null) && ps->is_adt_payload { return self._fields_reach_param(&(ps->fields), prim, idx); }
            for var i: usize = 0; i < r->args.size(); ++i {
                if !self.param_by_value(d, static_cast::<u32>(i)) { continue; }
                if self._type_reaches_param(*(r->args.get(i)), prim, idx) { return true; }
            }
            return false;
        }
        case TypeKind::TupleType {
            var tp = cast::<TupleType>(c);
            for var i: usize = 0; i < tp->elements.size(); ++i {
                if self._type_reaches_param(*(tp->elements.get(i)), prim, idx) { return true; }
            }
            return false;
        }
        case TypeKind::FixedArrayType { return self._type_reaches_param(cast::<FixedArrayType>(c)->element, prim, idx); }
        default { return false; }
    }
    return false;
}

// --- Ordering ----------------------------------------------------------------------

fn EmitPlan::_order() {
    self._early();
    // Tier 0: forward declarations. Namespace-scope types only; a nested
    // type cannot be forward-declared outside its owner.
    var t0: vec::<PlanEntry>;
    for var i: usize = 0; i < self._set.size(); ++i {
        var d = self._set[i];
        if !self._is_type_decl(d) { continue; }
        t0.push_back(self._entry(d, PlanNeed::Fwd, PlanTier::FwdDecls));
    }
    // The closure is done: _scopes no longer grows, so entries may point in.
    for var i: usize = 0; i < self._scopes.size(); ++i {
        var e = self._entry(static_cast::<*Decl>(self._scopes[i].anchor), PlanNeed::Fwd, PlanTier::FwdDecls);
        e.scope = &(self._scopes[i]);
        t0.push_back(e);
    }
    // A witness primary is declared up front, so a specialization or a
    // body can name it in any order tier 1 settles on.
    for var i: usize = 0; i < self._witnesses.size(); ++i {
        if self._witnesses[i].row != &null { continue; }
        var e = self._entry(self._witnesses[i].iface, PlanNeed::Fwd, PlanTier::FwdDecls);
        e.witness = &(self._witnesses[i]);
        e.own     = true;   // written wherever it is needed; one text everywhere (§7b.6).
        t0.push_back(e);
    }
    self._sort(&t0);
    self._specs_after_primary(&t0);
    // Three runs: every forward declaration whose head names no concept,
    // then the concepts (a requires-parameter needs its type declared, not
    // complete; a base's concept first), then the bounded records' forward
    // declarations, whose heads name them (CODEGEN.md §7b.7).
    var bounded = vec::<PlanEntry>();
    for var i: usize = 0; i < t0.size(); ++i {
        var e = &(t0[i]);
        if (e->witness == &null) && (e->scope == &null) && (self._spell.requires_clause(e->decl).size() > 0) { bounded.push_back(t0[i]); continue; }
        self.entries.push_back(t0[i]);
    }
    var cs = vec::<PlanEntry>();
    for var i: usize = 0; i < self._witnesses.size(); ++i {
        if self._witnesses[i].row != &null { continue; }
        var e = self._entry(self._witnesses[i].iface, PlanNeed::Fwd, PlanTier::FwdDecls);
        e.witness = &(self._witnesses[i]);
        e.is_concept = true;
        e.own     = true;
        cs.push_back(e);
    }
    self._sort(&cs);
    self._toposort(&cs);
    for var i: usize = 0; i < cs.size(); ++i { self.entries.push_back(cs[i]); }
    for var i: usize = 0; i < bounded.size(); ++i { self.entries.push_back(bounded[i]); }

    // Tier 1: definitions, toposorted on Complete edges.
    var t1: vec::<PlanEntry>;
    for var i: usize = 0; i < self._set.size(); ++i {
        var d = self._set[i];
        if !self._is_type_decl(d) { continue; }
        if self._need[i] != PlanNeed::Complete { continue; }
        t1.push_back(self._entry(d, PlanNeed::Complete, PlanTier::Definitions));
    }
    // Every scope a preamble touches is defined (its members' out-of-line
    // definitions and every call need the class); a header defines the ones
    // its roots reach and only declares the rest.
    for var i: usize = 0; i < self._scopes.size(); ++i {
        if (self._mode != PlanMode::Preamble) && (!self._scopes[i].reachable) { continue; }
        var e = self._entry(static_cast::<*Decl>(self._scopes[i].anchor), PlanNeed::Complete, PlanTier::Definitions);
        e.scope = &(self._scopes[i]);
        t1.push_back(e);
    }
    for var i: usize = 0; i < self._witnesses.size(); ++i {
        var e = self._entry(self._witnesses[i].iface, PlanNeed::Complete, PlanTier::Definitions);
        e.witness = &(self._witnesses[i]);
        e.own     = true;
        t1.push_back(e);
    }
    // The early items (EVAL.md §11), each where its edges put it: after the
    // records its definition needs complete, before the records whose
    // types evaluate it.
    for var i: usize = 0; i < self.early.size(); ++i {
        var e = self._entry(self.early[i], PlanNeed::Complete, PlanTier::Definitions);
        e.eval_item = self.early[i];
        t1.push_back(e);
    }
    self._sort(&t1);
    self._toposort(&t1);
    for var i: usize = 0; i < t1.size(); ++i { self.entries.push_back(t1[i]); }

    // Tier 2: functions and globals. Extension members are declared by
    // their scope's definition and never listed here.
    var t2: vec::<PlanEntry>;
    for var i: usize = 0; i < self._set.size(); ++i {
        var d = self._set[i];
        if (d->kind != DeclKind::FunctionDecl) && (d->kind != DeclKind::VariableDecl) { continue; }
        t2.push_back(self._entry(d, PlanNeed::Fwd, PlanTier::Functions));
    }
    self._sort(&t2);
    for var i: usize = 0; i < t2.size(); ++i { self.entries.push_back(t2[i]); }

    // Tier 3: instantiations. Home = the entry's home_fid; in header mode
    // only instances homed inside this file's own root are listed, as
    // `extern`, because the header ships with that root's objects.
    var t3: vec::<PlanEntry>;
    for var i: usize = 0; i < self._insts.size(); ++i {
        var ie = self._insts[i];
        var prim = CXXSpell::rep(ie->primary);
        var e = self._entry(prim, PlanNeed::Complete, PlanTier::Instantiations);
        e.inst    = ie;
        e.is_home = (ie->home_fid == self._home);
        if self._mode == PlanMode::Header {
            if !self._same_root(ie->home_fid, self._home) { continue; }
            e.is_home = false;
        }
        // Tie-break on the instance's home, so two TUs list one
        // instance in the same relative order.
        e.fid = ie->home_fid;
        e.own = (e.fid == self._home);   // own was computed from the primary's fid, before the override.
        t3.push_back(e);
    }
    self._sort(&t3);
    for var i: usize = 0; i < t3.size(); ++i { self.entries.push_back(t3[i]); }
}

fn EmitPlan::_same_root(a: u32, b: u32) -> bool {
    var sm  = self._cg->ctx->sm;
    var res = self._cg->ctx->resolver;
    if (sm == &null) || (res == &null) { return a == b; }
    return res->root_for_dir(sm->get_file_dir(a)) == res->root_for_dir(sm->get_file_dir(b));
}

fn EmitPlan::_same_ns_vec(a: *vec::<string>, b: *vec::<string>) -> bool {
    if a->size() != b->size() { return false; }
    for var i: usize = 0; i < a->size(); ++i { if (*a)[i] != (*b)[i] { return false; } }
    return true;
}

fn EmitPlan::_entry(d: *Decl, need: PlanNeed, tier: PlanTier) -> PlanEntry {
    var e = PlanEntry();
    e.decl = d;
    e.need = need;
    e.tier = tier;
    e.fid  = CXXSpell::fid_of(d);
    e.off  = self._off_of(d);
    e.own  = (e.fid == self._home);
    // A tuple record (TupleRecords) is minted from no file and sits in no
    // module's header: it is OWN everywhere, so a header defines it (under
    // InterfaceEmitter's guard) instead of including the builtin root's,
    // which never declares it.
    var ts = dyn_cast::<StructDecl>(d);
    if (ts != &null) && (ts->tuple_arity > 0) { e.own = true; }
    return e;
}

/// (fid, offset) ascending. Insertion sort: tens of entries, stable.
fn EmitPlan::_sort(v: *vec::<PlanEntry>) {
    for var i: usize = 1; i < v->size(); ++i {
        var j = i;
        while j > 0 {
            var a = &((*v)[j - 1]);
            var b = &((*v)[j]);
            var swap = false;
            if a->fid > b->fid { swap = true; }
            else if (a->fid == b->fid) && (a->off > b->off) { swap = true; }
            if !swap { break; }
            var tmp = (*v)[j - 1];
            (*v)[j - 1] = (*v)[j];
            (*v)[j] = tmp;
            j -= 1;
        }
    }
}

/// Stable topological sort on Complete edges. Nothing takeable means a
/// by-value cycle sema should have rejected (TypeCycleCheck): assert.
fn EmitPlan::_toposort(v: *vec::<PlanEntry>) {
    var n = v->size();
    if n < 2 { return; }
    var out:   vec::<PlanEntry>;
    var taken: vec::<bool>;
    for var i: usize = 0; i < n; ++i { taken.push_back(false); }

    for var round: usize = 0; round < n; ++round {
        var picked = usize(-1);
        for var i: usize = 0; i < n; ++i {
            if taken[i] { continue; }
            var ready = true;
            for var j: usize = 0; j < n; ++j {
                if taken[j] || (j == i) { continue; }
                if self._entry_needs(&((*v)[i]), &((*v)[j])) { ready = false; break; }
            }
            if ready { picked = i; break; }
        }
        if picked == usize(-1) {
            // A cycle through an early item (EVAL.md §11) is EvalUsageChecking's
            // to report; one of records alone, TypeCycleCheck's.
            for var i: usize = 0; i < n; ++i {
                if (!taken[i]) && ((*v)[i].eval_item != &null) {
                    self._ice((*v)[i].decl->range, "EmitPlan: no order defines the eval items a declaration's type computes from ahead of it; EvalUsageChecking::_check_order should have reported the cycle");
                }
            }
        }
        assert((picked != usize(-1))
            && r"EmitPlan: Complete-edge cycle in tier 1; TypeCycleCheck should have rejected this in sema");
        taken[picked] = true;
        out.push_back((*v)[picked]);
    }
    for var i: usize = 0; i < n; ++i { (*v)[i] = out[i]; }
}

/// True when entry \p who must follow entry \p dep. A scope follows its
/// deps; nothing waits on a scope (a friend line needs only tier 0).
fn EmitPlan::_entry_needs(who: *PlanEntry, dep: *PlanEntry) -> bool {
    if (who->eval_item != &null) || (dep->eval_item != &null) {
        if (who->witness != &null) || (who->scope != &null) || (dep->witness != &null) || (dep->scope != &null) { return false; }
        return self._eo_has(who->decl, dep->decl);
    }
    if who->witness != &null {
        var w = who->witness;
        if dep->witness != &null {
            if dep->witness->row != &null { return false; }   // nothing waits on a specialization.
            for var i: usize = 0; i < w->after.size(); ++i { if w->after[i] == dep->witness->iface { return true; } }
            return false;
        }
        if dep->scope != &null {
            for var i: usize = 0; i < w->scopes.size(); ++i {
                var sp = &(self._scopes[w->scopes[i]]);   // bound first: Stage 0 drops a leading `&(...)` in a comparison.
                if sp == dep->scope { return true; }
            }
            return false;
        }
        for var i: usize = 0; i < w->deps.size(); ++i { if w->deps[i] == dep->decl { return true; } }
        return false;
    }
    if dep->witness != &null { return false; }
    if dep->scope != &null { return false; }
    if who->scope != &null {
        for var i: usize = 0; i < who->scope->deps.size(); ++i {
            if who->scope->deps[i] == dep->decl { return true; }
        }
        return false;
    }
    // A specialization's definition follows its primary's: a partial
    // whose pattern instantiates the primary (`Store<Store<P>*>`) needs it
    // defined, and keeping the pair in order costs nothing otherwise.
    if CXXSpell::is_record_spec(who->decl) && (CXXSpell::rep(decl_instantiated_from(who->decl)) == dep->decl) { return true; }
    return self._needs_complete(who->decl, dep->decl);
}

/// Tier 0 is (fid, offset) order, which puts a specialization written
/// above its primary, or in a file sorting before the primary's, ahead of
/// the primary's declaration: C++ rejects a specialization of an
/// undeclared template. Each such entry moves to just after its primary;
/// everything else keeps its place.
fn EmitPlan::_specs_after_primary(v: *vec::<PlanEntry>) {
    var moved = true;
    var guard: usize = 0;
    while moved && (guard < v->size() + 1) {
        moved = false;
        guard += 1;
        for var i: usize = 0; i < v->size(); ++i {
            var d = (*v)[i].decl;
            if ((*v)[i].scope != &null) || ((*v)[i].witness != &null) || (!CXXSpell::is_record_spec(d)) { continue; }
            var prim = CXXSpell::rep(decl_instantiated_from(d));
            var at = usize(-1);
            for var j: usize = i + 1; j < v->size(); ++j {
                if ((*v)[j].scope == &null) && ((*v)[j].witness == &null) && ((*v)[j].decl == prim) { at = j; break; }
            }
            if at == usize(-1) { continue; }
            var e = (*v)[i];
            for var j: usize = i; j < at; ++j { (*v)[j] = (*v)[j + 1]; }
            (*v)[at] = e;
            moved = true;
            break;
        }
    }
}

/// True when \p who's definition requires \p dep's definition first. An
/// ADT's definition is its layout record's (adt_record); LayoutSpine sees
/// through its anonymous union and payload structs.
fn EmitPlan::_needs_complete(who: *Decl, dep: *Decl) -> bool {
    if (who == &null) || (dep == &null) { return false; }
    // A value parameter of class type (`<eval C: Config>`, EVAL.md 7e): C++
    // needs the class complete wherever the template is declared.
    if self.value_param_record(who, dep) { return true; }
    var probe = LayoutSpine(&self, dep);
    var rec   = self.adt_record(who);
    switch rec->kind {
        case DeclKind::ClassDecl {
            var n = cast::<ClassDecl>(rec);
            if probe.bases(&(n->derives_list)) { return true; }
            return probe.fields(&(n->fields));
        } case DeclKind::StructDecl { return probe.fields(&(cast::<StructDecl>(rec)->fields)); }
        case DeclKind::UnionDecl  { return probe.fields(&(cast::<UnionDecl>(rec)->fields)); }
        case DeclKind::EnumDecl {
            var n = cast::<EnumDecl>(rec);
            for var i: usize = 0; i < n->variants.size(); ++i {
                var vr = *(n->variants.get(i));
                if (vr != &null) && probe.fields(&(vr->payload)) { return true; }
            }
            return false;
        } default { return false; }
    }
    return false;
}

// --- Predicates ----------------------------------------------------------------------

/// \p who has a generic value parameter whose type is a record (EVAL.md
/// 7e): \p dep that record, or with \p dep null, any. C++ needs that class
/// complete at every declaration of the template, its forward one included.
fn EmitPlan::value_param_record(who: *Decl, dep: *Decl) -> bool {
    if who == &null { return false; }
    var gps = decl_generic_params(who);
    for var i: usize = 0; i < gps.size(); ++i {
        var gp = gps[i];
        if (gp == &null) || (!gp->is_const_param) || (gp->value_type == &null) || (gp->value_type->canonical == &null) { continue; }
        var c = canon_unqual(gp->value_type->canonical);
        if !isa::<RecordType>(c) { continue; }
        if dep == &null { return true; }
        if CXXSpell::rep(cast::<RecordType>(c)->decl) == dep { return true; }
    }
    return false;
}

/// \p d is a member of a generic record (its own generic params aside).
fn EmitPlan::_member_of_template(d: *Decl) -> bool {
    if (d == &null) || (!isa::<FunctionDecl>(d)) || (d->semantic_dc == &null) { return false; }
    var dc = reinterpret_cast::<*DeclContext>(d->semantic_dc);
    if (!dc->is_type_scope()) || (dc->dc_kind == DeclContextKind::Extension) { return false; }
    var owner = dc->owner_decl();
    return (owner != &null) && (decl_generic_params(owner).size() > 0);
}

/// \p d is declared in an interface: a requirement, never a C++ function.
fn EmitPlan::_is_requirement(d: *Decl) -> bool {
    if (d == &null) || (!isa::<FunctionDecl>(d)) || (d->semantic_dc == &null) { return false; }
    var home = reinterpret_cast::<*DeclContext>(d->semantic_dc)->owner_decl();
    return (home != &null) && isa::<InterfaceDecl>(home);
}

fn EmitPlan::_plannable(d: *Decl) -> bool {
    return self._is_type_decl(d) || (d->kind == DeclKind::FunctionDecl) || self._is_global_var(d);
}

/// A variable with namespace scope: its home is the TU or a module. Every
/// local reaches _admit too (_admit_use on each NamedIdentExpr) and must
/// stay out; a static data member never gets here (_member_owner
/// redirects it to its owner). Same predicate as EmitIR::_is_local.
fn EmitPlan::_is_global_var(d: *Decl) -> bool {
    if d->kind != DeclKind::VariableDecl { return false; }
    var dc = reinterpret_cast::<*DeclContext>(d->semantic_dc);
    if dc == &null { return false; }
    return (dc->dc_kind == DeclContextKind::TranslationUnit) || (dc->dc_kind == DeclContextKind::Module);
}

/// The kinds with a C++ type. Interfaces are excluded on purpose.
fn EmitPlan::_is_type_decl(d: *Decl) -> bool {
    return (d->kind == DeclKind::ClassDecl)
        || (d->kind == DeclKind::StructDecl)
        || (d->kind == DeclKind::UnionDecl)
        || (d->kind == DeclKind::EnumDecl);
}

fn EmitPlan::_outermost_type(d: *Decl) -> *Decl {
    var cur = d;
    var dc  = reinterpret_cast::<*DeclContext>(d->semantic_dc);
    while (dc != &null) && dc->is_type_scope() && (dc->dc_kind != DeclContextKind::Extension) {
        cur = CXXSpell::rep(dc->dc_owner);
        dc  = dc->dc_parent;
    }
    return cur;
}

fn EmitPlan::_index_of(d: *Decl) -> usize {
    for var i: usize = 0; i < self._set.size(); ++i { if self._set[i] == d { return i; } }
    return usize(-1);
}

fn EmitPlan::_off_of(d: *Decl) -> usize {
    var sm = self._cg->ctx->sm;
    if sm == &null { return 0; }
    if !d->range.start.is_valid() { return 0; }
    return sm->get_offset(d->range.start);
}