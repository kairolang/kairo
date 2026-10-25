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
    /// Tiers 0 and 1: the witness piece this entry declares or defines
    /// (CODEGEN.md §7b.6), or null. `decl` is then its InterfaceDecl.
    pub var witness: *WitnessPiece  = &null;
    /// Tier 0 only, with `witness` a primary: this entry defines its
    /// concept, not its forward declaration.
    pub var is_concept: bool        = false;

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
    /// Every witness piece the plan holds: interface primaries and row
    /// specializations. Index-based while the closure runs, as _scopes.
    priv var _witnesses: vec::<WitnessPiece>;

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

    /// ICE naming the Kairo source at \p at (CodegenICE).
    priv fn _ice(self, at: SourceRange, msg: string) {
        codegen_ice(self._cg->ctx, at, msg);
    }

    fn run(self);
    fn is_empty(self) -> bool;
    fn visible_bodies(self) -> vec::<*FunctionDecl>;
    fn include_bodies(self) -> vec::<*FunctionDecl>;
    fn _bodies(self, want_own: bool) -> vec::<*FunctionDecl>;
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
    fn _collect_uses(self);
    fn friend_scopes_of(self, d: *Decl, out: *vec::<*ExtScope>);
    fn dump(self, path: string);
    fn _tier_name(self, t: PlanTier) -> string;
    fn _need_name(self, n: PlanNeed) -> string;
    fn _kind_name(self, d: *Decl) -> string;
    fn _collect_own(self, dc: *DeclContext);
    fn _collect_own_decl(self, d: *Decl);
    fn _collect_own_globals(self);
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
    fn _expand_member_sig(self, n: *FunctionDecl);
    fn _expand_type(self, d: *Decl);
    fn _bases(self, bases: *FrozenList::<InheritEdge>);
    fn _fields(self, fields: *FrozenList::<*FieldDecl>);
    fn _methods(self, methods: *FrozenList::<*FunctionDecl>);
    fn _collect_same_file_extensions(self, d: *Decl);
    fn _collect_ext_in(self, cand: *Decl, target: *Decl);
    fn _ext_target(self, x: *ExtensionDecl) -> *Decl;
    fn layout_decl(self, d: *Decl) -> *Decl;
    fn adt_record(self, d: *Decl) -> *Decl;
    fn anon_union_of(self, f: *FieldDecl) -> *UnionDecl;
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
    for var i: usize = 0; i < self._scopes.size(); ++i {
        var s = &(self._scopes[i]);
        if (s->target == &null) || (s->target != c) { continue; }
        if CXXSpell::fid_of(static_cast::<*Decl>(s->anchor)) != CXXSpell::fid_of(c) { continue; }
        out->push_back(s);
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
    var iface = CXXSpell::rep(row->iface_decl);
    self._witness_primary(iface);
    var ew = EmitWitness(self._cg, &(self._spell));
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
    var ms = ew.members(cast::<InterfaceDecl>(iface));
    for var i: usize = 0; i < ms.size(); ++i {
        var m = ms[i];
        if (m == &null) || m->is_poisoned() { continue; }
        self._witness_sig(k, m);
    }
    for var i: usize = 0; i < row->witnesses.size(); ++i {
        var w = row->witnesses[i];
        if w == &null { continue; }
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
    if c->is_dependent() { return; }
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
    }
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
        if (CXXSpell::template_params(d).size() == 0) && (!cast::<FunctionDecl>(d)->is_inline()) { continue; }
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
            if (CXXSpell::template_params(static_cast::<*Decl>(m)).size() == 0) && (!m->is_inline()) { continue; }
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
            if (!templ) && (m->generic_params.size() == 0) && (!m->is_inline()) { continue; }
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
            // `I::m(x)` on a concrete x: its row rides on the call.
            var wr = reinterpret_cast::<*ConformanceRow>(cast::<CallExpr>(e)->witness_row);
            if wr != &null { self._witness_row(wr); }
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
    // A record declared in a function body (FinallyLowering's guard) is part
    // of that body: EmitIR emits it in place, and nothing about it belongs
    // in the preamble or the header. Its fields' owner and its destructor
    // land here too and are skipped the same way.
    if CXXSpell::in_function_scope(c) { return; }
    if decl_is_imported(c) { return; }             // the header declares it (IMPORTS.md §5).
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
        return;
    }
    var seen = false;
    for var i: usize = 0; i < self._insts.size(); ++i { if self._insts[i] == e { seen = true; break; } }
    if !seen { self._insts.push_back(e); }
    self._admit(prim, PlanNeed::Complete);
    // Every TU holding the instance may compile its body (it is a visible
    // C++ inline body), so every one needs the specializations its bounds
    // bind, or it compiles the primary instead (CODEGEN.md §7b.6).
    for var i: usize = 0; i < e->rows.size(); ++i { self._witness_row(e->rows[i]); }
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
        // No Vector/Set/Map/Tuple arms: they are RecordTypes now and admit
        // through the record path, which already walks their generic
        // arguments (a tuple's elements are by value, so at \p need).
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
}

/// The whole definition (invariant 11): bases and by-value fields at
/// Complete, the by-value types of method signatures at Complete too
/// (_expand_member_sig), nested types recursively, and the same-file
/// extension members that will be named as friends. An ADT is defined as
/// its layout record (adt_record): its fields, role functions, nested tag
/// enum and payload structs, and the friends written on it.
fn EmitPlan::_expand_type(d: *Decl) {
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
/// (its shell is empty until M2 fills it), and for an ADT enum its layout
/// record (adt_record); the representative otherwise.
fn EmitPlan::layout_decl(d: *Decl) -> *Decl {
    var r = CXXSpell::rep(d);
    if (r != &null) && decl_is_instance(r) { r = CXXSpell::rep(decl_pattern(r)); }
    return self.adt_record(r);
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
fn EmitPlan::param_by_value(prim: *Decl, idx: u32) -> bool {
    if prim == &null { return false; }
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
    return self._needs_complete(who->decl, dep->decl);
}

/// True when \p who's definition requires \p dep's definition first. An
/// ADT's definition is its layout record's (adt_record); LayoutSpine sees
/// through its anonymous union and payload structs.
fn EmitPlan::_needs_complete(who: *Decl, dep: *Decl) -> bool {
    if (who == &null) || (dep == &null) { return false; }
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