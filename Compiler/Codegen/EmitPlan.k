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
///       2  function declarations, any order (extension members are not
///          here: they are static members of their scope)
///       3  explicit instantiations: `template class X<A>;` in the instance's
///          home TU, `extern template ...` everywhere else
///
///     Two modes decide the ROOTS; the closure and ordering are identical:
///
///       Preamble  every own decl (all visibilities) + everything foreign it
///                 reaches. What the TU's .cpp starts with.
///       Header    own `pub` decls + what they reach. What the module's
///                 .hh contains; the emitter turns a foreign Complete entry
///                 into an `#include` and a foreign Fwd entry into a
///                 forward declaration.
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
import Codegen::Emit::CXXSpell::*;
import AST::Context::ASTContext::*;
import AST::Context::DeclContext::*;
import AST::Context::TranslationUnit::*;
import AST::Context::SymbolTable::*;
import AST::Context::InstantiationRegistry::*;
import AST::ASTSupport::*;
import AST::ParamMode::*;
import AST::DeclFacts::*;
import AST::Node::Base::*;
import AST::Node::Program::*;
import AST::Node::Types::*;
import AST::Node::CanonicalNodes::*;
import AST::Node::Expressions::*;
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
}

/// `struct N::__kairo_ext_X`: every extension member of target X declared in
/// namespace N, as one struct of static members (RESOLUTION.md §2b). One per
/// (N, X); every extend block in that scope contributes. Always COMPLETE --
/// all its blocks, priv members included -- so its text is the same in every
/// TU and header that carries it (invariant 11).
class ExtScope {
    pub var ns:        vec::<string>;
    pub var name:      string;                ///< `__kairo_ext_X`.
    /// The target's layout decl for a record (a generic one's primary), or
    /// null for a builtin, which is keyed by `target_ty` instead.
    pub var target:    *Decl = &null;
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
    /// Every extension scope the plan touches. Indexed while the closure
    /// runs (it grows); PlanEntry::scope points in only once it is done.
    priv var _scopes:   vec::<ExtScope>;

    /// Memo for param_by_value: (primary, index) -> answer. Pairs, linear
    /// scan; a build has tens of generic primaries, not thousands.
    priv var _pbv_key:  vec::<u64>;
    priv var _pbv_val:  vec::<bool>;
    priv var _pbv_depth: usize = 0;

    pub var entries: vec::<PlanEntry>;

    /// Nothing of this TU's own to define. Written once, at the end of run().
    priv var _empty: bool = true;

    fn EmitPlan(self, cg: *CodegenContext, mode: PlanMode = PlanMode::Preamble) {
        self._cg    = cg;
        self._spell = CXXSpell(cg);
        self._mode  = mode;
    }

    fn run(self);
    fn is_empty(self) -> bool;
    fn mode(self)  -> PlanMode;
    fn home(self)  -> u32;
    fn spell(self) -> *CXXSpell;
    fn _close(self);
    fn _order(self);
    fn _collect_uses(self);
    fn friend_scopes_of(self, d: *Decl, out: *vec::<*ExtScope>);
    fn dump(self, path: string);
    fn _tier_name(self, t: PlanTier) -> string;
    fn _need_name(self, n: PlanNeed) -> string;
    fn _kind_name(self, d: *Decl) -> string;
    fn _collect_own(self, dc: *DeclContext);
    fn _collect_own_decl(self, d: *Decl);
    fn _scope_for(self, x: *ExtensionDecl, reach: bool) -> usize;
    fn _fill_scope(self, k: usize, cand: *Decl);
    fn _same_scope(self, k: usize, x: *ExtensionDecl) -> bool;
    fn _scope_dep(self, k: usize, t: *Type);
    fn _scope_sig_dep(self, k: usize, t: *Type);
    fn _scope_add_dep(self, k: usize, d: *Decl);
    fn visit_expr(self, e: *Expr) -> bool;
    fn visit_type(self, t: *Type) -> bool;
    fn visit_decl(self, d: *Decl) -> bool;
    fn _admit_use(self, d: *Decl);
    fn _admit_cell(self, cell: *OverloadCell);
    fn _member_owner(self, d: *Decl) -> *Decl;
    fn _admit(self, d: *Decl, need: PlanNeed);
    fn _admit_instance(self, e: *InstanceEntry, need: PlanNeed);
    fn _admit_type(self, t: *Type, need: PlanNeed);
    fn _expand(self, d: *Decl, need: PlanNeed);
    fn _expand_fn(self, n: *FunctionDecl);
    fn _expand_type(self, d: *Decl);
    fn _bases(self, bases: *FrozenList::<InheritEdge>);
    fn _fields(self, fields: *FrozenList::<*FieldDecl>);
    fn _methods(self, methods: *FrozenList::<*FunctionDecl>);
    fn _collect_same_file_extensions(self, d: *Decl);
    fn _collect_ext_in(self, cand: *Decl, target: *Decl);
    fn _ext_target(self, x: *ExtensionDecl) -> *Decl;
    fn layout_decl(self, d: *Decl) -> *Decl;
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
    fn _plannable(self, d: *Decl) -> bool;
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
        self._target = target;
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
            case TypeKind::RecordType {
                var r = cast::<RecordType>(c);
                var d = self._plan->layout_decl(r->decl);
                if d == self._target { return true; }
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

    self._collect_own(static_cast::<*DeclContext>(tu));
    if self._mode == PlanMode::Preamble { self._collect_uses(); }
    self._close();
    self._order();

    // The one writer of is_empty. Foreign entries alone do not count: they
    // are only here to support this TU's own bodies, and there are none.
    self._empty = true;
    for var i: usize = 0; i < self.entries.size(); ++i {
        var e = &(self.entries[i]);
        if e->own { self._empty = false; break; }
        if (e->tier == PlanTier::Instantiations) && e->is_home { self._empty = false; break; }
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
    for var i: usize = 0; i < self._scopes.size(); ++i {
        var s = &(self._scopes[i]);
        if (s->target == &null) || (s->target != c) { continue; }
        if CXXSpell::fid_of(static_cast::<*Decl>(s->anchor)) != CXXSpell::fid_of(c) { continue; }
        out->push_back(s);
    }
}

// --- Dump --------------------------------------------------------------------

fn EmitPlan::dump(path: string) {
    var m = ("preamble") if (self._mode == PlanMode::Preamble) else ("header");
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
        if (self._mode == PlanMode::Header) && _hidden_in_header(CXXSpell::vis_of(d)) { return; }
        var visible = false;
        for var i: usize = 0; i < x->methods.size(); ++i {
            var m = x->methods[i];
            if m == &null { continue; }
            if (self._mode == PlanMode::Header) && _hidden_in_header(CXXSpell::vis_of(static_cast::<*Decl>(m))) { continue; }
            visible = true;
        }
        if visible { self._scope_for(x, true); }
        return;
    }
    if !self._plannable(d) { return; }
    if (self._mode == PlanMode::Header) && _hidden_in_header(CXXSpell::vis_of(d)) { return; }
    if self._is_type_decl(d) {
        // A definition here means every own type is Complete; its own
        // dependencies come in through _expand.
        self._admit(d, PlanNeed::Complete);
    } else {
        self._admit(d, PlanNeed::Fwd);
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
        ICE_IF(!self._same_scope(i, x),
            f"EmitPlan: two extension targets in one namespace both spell '{name}'; the scope naming rule needs a disambiguator");
        if reach { s->reachable = true; }
        return i;
    }

    var fresh = ExtScope();
    fresh.ns   = ns;
    fresh.name = name;
    var c = canon_unqual(x->target->canonical);
    if isa::<RecordType>(c) {
        fresh.target = self.layout_decl(cast::<RecordType>(c)->decl);
    } else {
        fresh.target_ty = c;
    }
    fresh.reachable = reach;
    self._scopes.push_back(fresh);
    var k = self._scopes.size() - 1;

    // Every block of this (N, X) lives in x's file: N is that file's
    // module path plus its module blocks.
    var tu = CXXSpell::tu_of(static_cast::<*Decl>(x));
    ICE_IF((tu == &null) || (tu->program == &null), "EmitPlan: extension with no owning TU");
    var items = &(tu->program->items);
    for var i: usize = 0; i < items->size(); ++i {
        var item = *(items->get(i));
        if item.kind != TopLevelKind::Decl { continue; }
        self._fill_scope(k, item.as_decl());
    }
    ICE_IF(self._scopes[k].anchor == &null, "EmitPlan: an extension's own file does not contain it");

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
        self._expand_fn(m);
        self._scope_sig_dep(k, m->return_type);
        for var j: usize = 0; j < m->params.size(); ++j {
            var p = m->params[j];
            if (p == &null) || p->is_self { continue; }
            self._scope_sig_dep(k, ((p->pack_type) if (p->is_pack && (p->pack_type != &null)) else (p->type_)));
        }
        if (!m->is_operator) || (self._spell.ext_forwarder_name(m).size() == 0) { continue; }
        self._scope_dep(k, m->return_type);
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
    if isa::<RecordType>(c) { return (s->target != &null) && (self.layout_decl(cast::<RecordType>(c)->decl) == s->target); }
    return (s->target == &null) && (s->target_ty == c);
}

/// A by-value record \p t is a Complete dependency of scope \p k, recorded
/// as the tier-1 entry that defines it (an outermost type, a primary).
fn EmitPlan::_scope_dep(k: usize, t: *Type) {
    if (t == &null) || (t->canonical == &null) { return; }
    var c = canon_unqual(t->canonical);
    if !isa::<RecordType>(c) { return; }
    var d = self.layout_decl(cast::<RecordType>(c)->decl);
    if (d == &null) || decl_is_imported(d) || isa::<InterfaceDecl>(d) { return; }
    self._admit_type(t, PlanNeed::Complete);
    self._scope_add_dep(k, self._outermost_type(d));
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
        case TypeKind::NullableType     { self._scope_sig_dep(k, cast::<NullableType>(c)->inner); }
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
            var d = self.layout_decl(r->decl);
            if (d == &null) || decl_is_imported(d) || isa::<InterfaceDecl>(d) { return; }
            var outer = self._outermost_type(d);
            if outer == d { return; }
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
            }
        } case ExprKind::CallExpr {
            // A generic callee's instance: tier 3, homed where it was first
            // named, `extern template` elsewhere. A FUNCTION instance's decl
            // is the primary itself (InstantiationRegistry::_new_instance),
            // so it never comes through _admit's instance-shell path.
            var ie = reinterpret_cast::<*InstanceEntry>(cast::<CallExpr>(e)->instance);
            if ie != &null { self._admit_instance(ie, PlanNeed::Fwd); }
        } default { break; }
    }
    return true;
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
        case DeclKind::VariableDecl  { self._admit_type(cast::<VariableDecl>(d)->type_, PlanNeed::Complete); }
        case DeclKind::FieldDecl     { self._admit_type(cast::<FieldDecl>(d)->type_, PlanNeed::Complete); }
        case DeclKind::ParamDecl {
            var p = cast::<ParamDecl>(d);
            self._admit_type(((p->pack_type) if (p->is_pack && (p->pack_type != &null)) else (p->type_)), PlanNeed::Complete);
        }
        case DeclKind::FunctionDecl  { self._admit_type(cast::<FunctionDecl>(d)->return_type, PlanNeed::Complete); }
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
    if decl_is_imported(c) { return; }             // the header declares it (IMPORTS.md §5).
    if isa::<InterfaceDecl>(c) { return; }         // no C++ entity yet (witnesses MISSING).
    // An extension member reached through a use (`l.pos.len()`) is not a
    // member by _member_owner, so without this it is admitted a second time
    // as an ordinary function; it is its scope's static member instead.
    var x = decl_extension_of(c);
    if x != &null { self._scope_for(x, true); return; }

    if decl_is_instance(c) {
        var e = self._cg->instances->entry_of(c);
        ICE_IF(e == &null, "EmitPlan: instance shell with no registry entry");
        self._admit_instance(e, need);
        return;
    }
    if !self._plannable(c) { return; }

    // A nested type is part of its outermost owner's definition.
    var outer = self._outermost_type(c);
    if outer != c { self._admit(outer, need); return; }

    var at = self._index_of(c);
    if at == usize(-1) {
        self._set.push_back(c);
        self._need.push_back(need);
        self._queue.push_back(self._set.size() - 1);
        return;
    }
    if static_cast::<u8>(need) > static_cast::<u8>(self._need[at]) {
        self._need[at] = need;
        self._queue.push_back(at);
    }
}

/// `Box<Foo>`: the primary at \p need, each argument at \p need only
/// where the primary stores it by value, else Fwd; the instance itself
/// recorded for tier 3.
fn EmitPlan::_admit_instance(e: *InstanceEntry, need: PlanNeed) {
    var prim = CXXSpell::rep(e->primary);
    if decl_is_imported(prim) { return; }          // clang instantiates it from the PCH.
    var seen = false;
    for var i: usize = 0; i < self._insts.size(); ++i { if self._insts[i] == e { seen = true; break; } }
    if !seen { self._insts.push_back(e); }
    self._admit(prim, PlanNeed::Complete);
    for var i: usize = 0; i < e->args.size(); ++i {
        var n = need;
        if !self.param_by_value(prim, static_cast::<u32>(i)) { n = PlanNeed::Fwd; }
        self._admit_type(e->args[i], n);
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
            if (d != &null) && decl_is_instance(d) {
                self._admit(d, need);                 // _admit_instance handles the args.
            } else {
                self._admit(d, need);
                for var i: usize = 0; i < r->args.size(); ++i {
                    var n = need;
                    if !self.param_by_value(d, static_cast::<u32>(i)) { n = PlanNeed::Fwd; }
                    self._admit_type(*(r->args.get(i)), n);
                }
            }
        }
        case TypeKind::PointerType      { self._admit_type(cast::<PointerType>(c)->pointee, PlanNeed::Fwd); }
        case TypeKind::CXXLValueRefType { self._admit_type(cast::<CXXLValueRefType>(c)->referee, PlanNeed::Fwd); }
        case TypeKind::CXXRValueRefType { self._admit_type(cast::<CXXRValueRefType>(c)->referee, PlanNeed::Fwd); }
        case TypeKind::NullableType     { self._admit_type(cast::<NullableType>(c)->inner, PlanNeed::Fwd); }
        // No Vector/Set/Map arms: they are RecordTypes now and admit through
        // the record path, which already walks their generic arguments.
        case TypeKind::TupleType {
            var tp = cast::<TupleType>(c);
            for var i: usize = 0; i < tp->elements.size(); ++i { self._admit_type(*(tp->elements.get(i)), need); }
        }
        case TypeKind::FixedArrayType { self._admit_type(cast::<FixedArrayType>(c)->element, need); }
        case TypeKind::FunctionPointerType {
            var f = cast::<FunctionPointerType>(c);
            for var i: usize = 0; i < f->params.size(); ++i { self._admit_type(*(f->params.get(i)), PlanNeed::Fwd); }
            self._admit_type(f->return_type, PlanNeed::Fwd);
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
    if need != PlanNeed::Complete { return; }
    self._expand_type(d);
}

/// A declaration names its types, it does not lay them out.
fn EmitPlan::_expand_fn(n: *FunctionDecl) {
    for var i: usize = 0; i < n->params.size(); ++i {
        var p = *(n->params.get(i));
        if (p == &null) || p->is_self { continue; }
        self._admit_type(((p->pack_type) if (p->is_pack && (p->pack_type != &null)) else (p->type_)), PlanNeed::Fwd);
    }
    self._admit_type(n->return_type, PlanNeed::Fwd);
}

/// The whole definition (invariant 11): bases and by-value fields at
/// Complete, method signatures at Fwd, nested types recursively, and the
/// same-file extension members that will be named as friends.
fn EmitPlan::_expand_type(d: *Decl) {
    switch d->kind {
        case DeclKind::ClassDecl {
            var n = cast::<ClassDecl>(d);
            self._bases(&(n->derives_list));
            self._fields(&(n->fields));
            self._methods(&(n->methods));
        } case DeclKind::StructDecl {
            var n = cast::<StructDecl>(d);
            self._fields(&(n->fields));
            self._methods(&(n->methods));
        } case DeclKind::UnionDecl {
            var n = cast::<UnionDecl>(d);
            self._fields(&(n->fields));
            self._methods(&(n->methods));
        } case DeclKind::EnumDecl {
            var n = cast::<EnumDecl>(d);
            for var i: usize = 0; i < n->variants.size(); ++i {
                var v = *(n->variants.get(i));
                if v == &null { continue; }
                self._fields(&(v->payload));
            }
        } case DeclKind::TypeAliasDecl {
            self._admit_type(cast::<TypeAliasDecl>(d)->aliased, PlanNeed::Complete);
        } default { break; }
    }
    // Nested types ride inside this definition.
    var dc = CXXSpell::dc_of(d);
    if dc != &null {
        for var i: usize = 0; i < dc->dc_decls.size(); ++i {
            var nd = *(dc->dc_decls.get(i));
            if (nd == &null) || (!self._is_type_decl(nd)) { continue; }
            self._expand_type(CXXSpell::rep(nd));
        }
    }
    self._collect_same_file_extensions(d);
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
        self._admit_type(f->type_, PlanNeed::Complete);
    }
}

fn EmitPlan::_methods(methods: *FrozenList::<*FunctionDecl>) {
    for var i: usize = 0; i < methods->size(); ++i {
        var m = *(methods->get(i));
        if m == &null { continue; }
        self._expand_fn(m);
    }
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

// --- Layout queries (LayoutSpine + _admit_instance) ------------------------------

/// The decl whose fields define a record's layout: an instance's pattern
/// (its shell is empty until M2 fills it), the representative otherwise.
fn EmitPlan::layout_decl(d: *Decl) -> *Decl {
    var r = CXXSpell::rep(d);
    if (r != &null) && decl_is_instance(r) { return CXXSpell::rep(decl_pattern(r)); }
    return r;
}

/// True iff \p prim's layout reaches its \p idx-th generic parameter by
/// value. `Box<T> { var v: T }` yes; `Box<T> { var p: *T }` no. Memoized.
/// Recursion through another generic's field bottoms out at a depth cap
/// and answers "by value", the safe direction (an over-strong edge can
/// only trip the cycle assert, never miss a definition).
fn EmitPlan::param_by_value(prim: *Decl, idx: u32) -> bool {
    if prim == &null { return false; }
    var key = (reinterpret_cast::<u64>(prim) << 8) ^ static_cast::<u64>(idx);
    for var i: usize = 0; i < self._pbv_key.size(); ++i {
        if self._pbv_key[i] == key { return self._pbv_val[i]; }
    }
    if self._pbv_depth > 32 { return true; }
    self._pbv_depth += 1;
    var ans = self._param_by_value_walk(prim, idx);
    self._pbv_depth -= 1;
    self._pbv_key.push_back(key);
    self._pbv_val.push_back(ans);
    return ans;
}

fn EmitPlan::_param_by_value_walk(prim: *Decl, idx: u32) -> bool {
    switch prim->kind {
        case DeclKind::ClassDecl {
            var n = cast::<ClassDecl>(prim);
            if self._edges_reach_param(&(n->derives_list), prim, idx) { return true; }
            return self._fields_reach_param(&(n->fields), prim, idx);
        } case DeclKind::StructDecl {
            return self._fields_reach_param(&(cast::<StructDecl>(prim)->fields), prim, idx);
        } case DeclKind::UnionDecl {
            return self._fields_reach_param(&(cast::<UnionDecl>(prim)->fields), prim, idx);
        } case DeclKind::EnumDecl {
            var n = cast::<EnumDecl>(prim);
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
        if (f != &null) && self._type_reaches_param(f->type_, prim, idx) { return true; }
    }
    return false;
}

fn EmitPlan::_type_reaches_param(t: *Type, prim: *Decl, idx: u32) -> bool {
    if t == &null { return false; }
    var c = t->canonical;
    if c == &null { c = t; }
    switch c->kind {
        case TypeKind::QualifiedType { return self._type_reaches_param(cast::<QualifiedType>(c)->inner, prim, idx); }
        case TypeKind::GenericParamType {
            var g = cast::<GenericParamType>(c);
            return (CXXSpell::rep(g->owner) == prim) && (g->param_index == idx);
        }
        case TypeKind::RecordType {
            var r = cast::<RecordType>(c);
            var d = self.layout_decl(r->decl);
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
    self._sort(&t0);
    for var i: usize = 0; i < t0.size(); ++i { self.entries.push_back(t0[i]); }

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
        if (self._mode == PlanMode::Header) && (!self._scopes[i].reachable) { continue; }
        var e = self._entry(static_cast::<*Decl>(self._scopes[i].anchor), PlanNeed::Complete, PlanTier::Definitions);
        e.scope = &(self._scopes[i]);
        t1.push_back(e);
    }
    self._sort(&t1);
    self._toposort(&t1);
    for var i: usize = 0; i < t1.size(); ++i { self.entries.push_back(t1[i]); }

    // Tier 2: functions. Extension members are declared by their scope's
    // definition and never listed here.
    var t2: vec::<PlanEntry>;
    for var i: usize = 0; i < self._set.size(); ++i {
        var d = self._set[i];
        if d->kind != DeclKind::FunctionDecl { continue; }
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
    if dep->scope != &null { return false; }
    if who->scope != &null {
        for var i: usize = 0; i < who->scope->deps.size(); ++i {
            if who->scope->deps[i] == dep->decl { return true; }
        }
        return false;
    }
    return self._needs_complete(who->decl, dep->decl);
}

/// True when \p who's definition requires \p dep's definition first.
fn EmitPlan::_needs_complete(who: *Decl, dep: *Decl) -> bool {
    if (who == &null) || (dep == &null) { return false; }
    var probe = LayoutSpine(&self, dep);
    switch who->kind {
        case DeclKind::ClassDecl {
            var n = cast::<ClassDecl>(who);
            if probe.bases(&(n->derives_list)) { return true; }
            return probe.fields(&(n->fields));
        } case DeclKind::StructDecl { return probe.fields(&(cast::<StructDecl>(who)->fields)); }
        case DeclKind::UnionDecl  { return probe.fields(&(cast::<UnionDecl>(who)->fields)); }
        case DeclKind::EnumDecl {
            var n = cast::<EnumDecl>(who);
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

fn EmitPlan::_plannable(d: *Decl) -> bool {
    return self._is_type_decl(d) || (d->kind == DeclKind::FunctionDecl);
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