/// --- The Kairo Project --------------- Sema/Check/LocalDisposition.k --- ///
///
/// How each automatic local's destructor runs (LocalDtor), and the
/// one place that writes it.
///
///   \detail
///     A block-scope local whose destructor is non-trivial is `T x` in C++,
///     destroyed at every exit of its scope, unless something ends its
///     lifetime earlier. Then it is stored as the member of a union whose
///     own destructor does nothing, and its mode says what runs the
///     destructor (Compiler/Spec/Lowering.md#union-storage-locals):
///
///       Scope    `T x`; nothing ends it early.
///       Cleanup  union storage and a cleanup hook that runs at every exit.
///       Elided   union storage and no hook: every exit is reached only
///                after a site that ended the object.
///       Flagged  union storage, a `live` flag and a hook that tests it:
///                some exits are reached with the object alive, some not.
///
///     A site that ends a local is a `x.finally()` call (CallExpr::finalize)
///     or a disarmed move (a move site recorded by disarm_local_at). Every
///     mode a provider asks for is joined into what the local already has
///     (join_local_dtor): Flagged is correct wherever any mode is, so two
///     providers that disagree get the flag, never a double destruction or
///     a leak.
///
///     LocalEnds is MoveCheck's record of both providers: the locals each
///     body declares, which of them a `finally()` ends, which a real
///     transfer moves out of (a destructive type's moved-from object needs
///     no destructor, destructive_type), and which are still alive (or may
///     be) at some exit of their scope. settle() turns that into each
///     local's mode when the body's walk ends, and writes every local of
///     the body, so a second check of the same tree (the language
///     server's) leaves no stale mode behind.
///
///   Phase: CHECK (MoveCheck). EmitIR reads VariableDecl::dtor_mode.
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

import AST::DeclFacts::{
    decl_is_imported,
    decl_pattern,
}
import AST::Kind::TypeKind::TypeKind
import AST::Node::Base::{
    Decl,
    Expr,
    Type,
}
import AST::Node::CanonicalNodes::{
    RecordType,
    canon_unqual,
}
import AST::Node::Casting::{
    cast,
    dyn_cast,
    isa,
}
import AST::Node::Declarations::{
    LocalDtor,
    StorageClass,
    VariableDecl,
}
import AST::Node::Expressions
import AST::Node::Types::{
    CXXLValueRefType,
    CXXRValueRefType,
    PointerType,
}
import Sema::Check::ClassLifecycle::{
    LifecycleTri,
    lifecycle_of,
}
import Sema::SemaContext::SemaContext

/// The move at `site` is a real transfer of the whole local `d`
/// (MoveKind::Transfer: a Kairo move construction, move assignment or
/// return of its value). MoveCheck records it as it marks the move, for a
/// provider to ask after the walk (is_real_transfer).
pub fn record_real_transfer(sc: unsafe *SemaContext, site: unsafe *Expr, d: unsafe *Decl) {
    var unsafe *v = dyn_cast<VariableDecl>(d)
    if v == &null || v->is_static() {
        return
    }

    sc->real_moves[site as usize as u64] = d as usize as u64
}

/// The query a provider asks before it disarms: the move at `site` is a
/// real transfer of the WHOLE local `v`. Every other move MoveCheck
/// counts (MoveKind) may leave the object owning its resource.
pub fn is_real_transfer(sc:   unsafe *SemaContext,
                        site: unsafe *Expr,
                        v:    unsafe *VariableDecl) -> bool {
    var it = sc->real_moves.find(site as usize as u64)
    return it != sc->real_moves.end() && it->second == (v as usize as u64)
}

/// The one call of a provider that proves a move ends a local's lifetime
/// ("definitely moved"): the move at `site` transfers the whole local
/// `v` (is_real_transfer), and the moved-from object is not destroyed.
/// `mode` is what the provider proved for every exit of `v`'s scope:
/// Elided when each is reached only after a site that ended `v` (this
/// one, another disarmed move, or a `finally()`), Flagged otherwise. The
/// site is recorded (SemaContext::disarm_sites; CopyMoveLowering puts it
/// on the cast, TypeCastExpr::disarms) and the mode is joined into the
/// local's, so a provider never weakens what another decided. The
/// provider is LocalEnds::settle, which writes the local's mode afresh on
/// every check first.
///
/// EmitIR does at the site what it does after `finally()` minus the
/// destructor call: flagged, it clears `live` with the move; elided,
/// nothing runs at the scope's end. A site on a local whose mode does
/// not end it, or an ending mode with no site, is an ICE there.
pub fn disarm_local_at(sc:   unsafe *SemaContext,
                       site: unsafe *Expr,
                       v:    unsafe *VariableDecl,
                       mode: LocalDtor) {
    if mode != LocalDtor::Elided && mode != LocalDtor::Flagged {
        kairo::std::ice_fail(
            "LocalDisposition: a disarmed move with a mode that destroys the object",
        )
    }

    if !is_real_transfer(sc, site, v) {
        kairo::std::ice_fail(
            "LocalDisposition: a disarmed move that is not a real transfer of the whole local",
        )
    }

    sc->disarm_sites[site as usize as u64] = v as usize as u64
    v->dtor_mode                           = join_local_dtor(v->dtor_mode, mode)
}

/// The mode that is correct wherever `a` or `b` is: Flagged over
/// everything, an ending mode (Elided) over a destroying one, union
/// storage (Cleanup) over plain.
pub fn join_local_dtor(a: LocalDtor, b: LocalDtor) -> LocalDtor {
    if a == LocalDtor::Flagged || b == LocalDtor::Flagged {
        return LocalDtor::Flagged
    }

    if a == LocalDtor::Elided || b == LocalDtor::Elided {
        return LocalDtor::Elided
    }

    if a == LocalDtor::Cleanup || b == LocalDtor::Cleanup {
        return LocalDtor::Cleanup
    }

    return LocalDtor::Scope
}

/// Whether `v`'s destructor is non-trivial: Yes / No / Unknown (a type
/// that depends on a generic parameter, or none known yet).
pub fn local_has_dtor(sc: unsafe *SemaContext, v: unsafe *VariableDecl) -> LifecycleTri {
    if v->type_ == &null || v->type_->canonical == &null || v->type_->canonical->is_dependent() {
        return LifecycleTri::Unknown
    }

    var f = lifecycle_of(sc)->facts_of_type(v->type_->canonical)
    if f.trivial_dtor == LifecycleTri::Yes {
        return LifecycleTri::No
    }

    if f.trivial_dtor == LifecycleTri::No {
        return LifecycleTri::Yes
    }

    return LifecycleTri::Unknown
}

/// Whether a moved-from object of type `t` need not be destroyed
/// (ClassLifecycle, destructive): Yes / No / Unknown (a type that depends
/// on a generic parameter, or none known yet). The one predicate every
/// provider of a disarmed move asks: skipping the destructor of a
/// moved-from object of any other type leaks what its move left behind.
pub fn destructive_type(sc: unsafe *SemaContext, t: unsafe *Type) -> LifecycleTri {
    if t == &null || t->canonical == &null || t->canonical->is_dependent() {
        return LifecycleTri::Unknown
    }

    return lifecycle_of(sc)->facts_of_type(t->canonical).destructive
}

/// Why `v`, a block-scope local with a non-trivial destructor, cannot be
/// stored in a union (""  when it can). Each reason is a local whose C++
/// declaration has no single `T` to wrap or whose storage is not
/// automatic.
pub fn union_storage_refusal(v: unsafe *VariableDecl) -> string {
    if v->storage == StorageClass::Static || v->is_thread {
        return "it has static storage"
    }

    if v->storage == StorageClass::Eval {
        return "it is an 'eval' constant"
    }

    if v->type_ == &null || v->type_->canonical == &null {
        return "its type is not known"
    }

    var unsafe *c = canon_unqual(v->type_->canonical)
    if c == &null || c->kind == TypeKind::FixedArrayType {
        return "it is a fixed-size array"
    }

    return ""
}

/// `t` names, through pointers, references, generic arguments and outer
/// records, an imported record declared inside a class. EmitIR spells a
/// local whose type names a private or protected one of those `auto`
/// (Speller::names_hidden_member), which no union member can be; this is
/// that test without the access check, so it refuses at least every type
/// EmitIR would.
pub fn names_cxx_member_type(t: unsafe *Type) -> bool {
    if t == &null || t->canonical == &null {
        return false
    }

    var unsafe *c = canon_unqual(t->canonical)
    if c == &null {
        return false
    }

    if c->kind == TypeKind::PointerType {
        return names_cxx_member_type(cast<PointerType>(c)->pointee)
    }

    if c->kind == TypeKind::CXXLValueRefType {
        return names_cxx_member_type(cast<CXXLValueRefType>(c)->referee)
    }

    if c->kind == TypeKind::CXXRValueRefType {
        return names_cxx_member_type(cast<CXXRValueRefType>(c)->referee)
    }

    var unsafe *r = dyn_cast<RecordType>(c)
    if r == &null {
        return false
    }

    if r->decl != &null && decl_is_imported(r->decl) {
        if _in_type_scope(r->decl) || _in_type_scope(decl_pattern(r->decl)) {
            return true
        }
    }

    for var i: usize = 0; i < r->args.size(); ++i {
        if names_cxx_member_type(r->args[i]) {
            return true
        }
    }

    return r->outer != &null && names_cxx_member_type(r->outer)
}

fn _in_type_scope(d: unsafe *Decl) -> bool {
    return d != &null && d->semantic_dc != &null && d->semantic_dc->is_type_scope()
}

/// Why a real transfer out of `v` cannot skip the moved-from object's
/// destructor ("" when it can): its storage cannot be a union, it is a
/// binder or a local a lowering made, or its type's moved-from object
/// still owns something (destructive_type is not Yes: a COPY class, a C++
/// type, a type a generic parameter decides). The caller adds what only
/// the body knows (a constructor, an `eval` or constexpr function, a
/// C-style `for` variable). EmitIR (`_union_local_decl`) keeps a plain
/// `T x` for a declaration it cannot wrap and ICEs on an ending mode
/// there, so every such case is refused here first: an attribute covers
/// `@align`.
pub fn disarm_refusal(sc: unsafe *SemaContext, v: unsafe *VariableDecl) -> string {
    var u = union_storage_refusal(v)
    if u.size() > 0 {
        return u
    }

    if v->has_attribute() {
        return "it has an attribute"
    }

    if names_cxx_member_type(v->type_) {
        return "its type names a member type of a C++ class"
    }

    if v->borrows
        || v->borrow_inst
        || v->place_ref
        || v->auto_copy
        || v->raw_slot
        || v->starts_empty
        || v->gen_iter
        || v->header_scope {
        return "it is a binder or a lowering's local"
    }

    if destructive_type(sc, v->type_) != LifecycleTri::Yes {
        return "its type's moved-from object is destroyed"
    }

    return ""
}

/// One local a body declares, as both providers follow it.
pub class LocalEndRow {
    pub var d:     unsafe *VariableDecl = &null
    pub var ends:  usize                = 0 ///< sites that end it (a `finally()` call).
    pub var alive: bool                 = false ///< some exit of its scope is reached with it not finalized on every path.
    /// Why its declaration cannot take union storage ("" when it can): it
    /// keeps `Scope`, and a `finally()` of it is SC116E.
    pub var refusal: string = ""
    /// A real transfer out of it may skip the moved-from object's
    /// destructor (disarm_refusal and the body's own refusals passed).
    pub var cand: bool = false
    /// Some real transfer of it cannot disarm (inside a `finally { }` body,
    /// an unevaluated operand, a self-assignment): none of them does.
    pub var bad: bool = false
    /// Its real transfers other than `return x`, each once, a dead path's
    /// included (EmitIR writes every one), and its `return x` values.
    pub var sites: [unsafe *Expr]
    pub var rets:  [unsafe *Expr]
    /// Its Move captures: the closure and the index of the capture row
    /// (ClosureExpr::Held::disarms, written by settle). Each is also in
    /// `sites`, keyed by the capture's first use.
    pub var caps:   [unsafe *Expressions::ClosureExpr]
    pub var cap_at: [usize]
    /// Visits of its sites, loop passes included: an assignment to it
    /// compares the count before and after its right-hand side.
    pub var visits: usize = 0
    /// Some exit of its scope is reached with it neither finalized nor
    /// moved by a real transfer on every path.
    pub var alive_unmoved: bool = false
    /// Whole assignments that construct it again after a `finally()`
    /// (AssignOperatorExpr::remake).
    pub var remakes: [unsafe *Expressions::AssignOperatorExpr]
    /// Whole assignments reached after a move of it, with the states they
    /// are reached in (REMAKE_DEAD / REMAKE_MAYBE): written onto the node
    /// only when its moves are disarmed (settle), since until then the
    /// moved-from object is still there and `op =` is what runs.
    pub var mremakes: [unsafe *Expressions::AssignOperatorExpr]
    pub var mbits:    [u8]
    fn LocalEndRow(self) { }

    /// Its real transfers are disarmed: it can take the storage, every one
    /// of them can disarm, and there is one that is not a `return`, or a
    /// `finally()` gives it the storage anyway. A local only returned
    /// stays a plain `T x`, which C++ elides into the result.
    fn managed(self) -> bool {
        if !self.cand || self.bad || self.refusal.size() > 0 {
            return false
        }

        return self.sites.size() > 0 || self.ends > 0 && self.rets.size() > 0
    }
}

/// MoveCheck's record of the locals of the body being walked; one per
/// body (saved and restored around a nested one).
pub class LocalEnds {
    pub var rows: [LocalEndRow]
    fn LocalEnds(self) { }

    /// `d` is a local this body declares (a DeclStmt of one of its blocks);
    /// `refusal` as LocalEndRow::refusal, `cand` as LocalEndRow::cand.
    fn declare(self, d: unsafe *VariableDecl, const refusal: string, cand: bool) {
        if self.index_of(d) != usize::MAX {
            return
        }

        var r = LocalEndRow()
        r.d       = d
        r.refusal = refusal.copy()
        r.cand    = cand && refusal.size() == 0
        self.rows.push(r)
    }

    /// LocalEndRow::refusal of `d` ("" when it is not a row).
    fn refusal_of(self, d: unsafe *Decl) -> string {
        var i = self.index_of(d)
        return if (i != usize::MAX) => (self.rows[i].refusal.copy()) else => ""
    }

    fn index_of(self, d: unsafe *Decl) -> usize {
        for var i: usize = 0; i < self.rows.size(); ++i {
            if unsafe (self.rows[i].d as unsafe *Decl) == d {
                return i
            }
        }

        return usize::MAX
    }

    fn has(self, d: unsafe *Decl) -> bool {
        return self.index_of(d) != usize::MAX
    }

    /// `d` is a row whose real transfers may disarm (LocalEndRow::cand).
    fn is_cand(self, d: unsafe *Decl) -> bool {
        var i = self.index_of(d)
        return i != usize::MAX && self.rows[i].cand
    }

    /// A site ends `d` here.
    fn ended_at_site(self, d: unsafe *Decl) {
        var i = self.index_of(d)
        if i != usize::MAX {
            self.rows[i].ends += 1
        }
    }

    /// `site` is a real transfer of the whole local `d`; `ok` false when
    /// this one cannot disarm, which rules out all of them.
    fn moved_at(self, d: unsafe *Decl, site: unsafe *Expr, ok: bool) {
        var i = self.index_of(d)
        if i == usize::MAX || !self.rows[i].cand {
            return
        }

        self.rows[i].visits += 1
        if !ok {
            self.rows[i].bad = true
        }

        for var k: usize = 0; k < self.rows[i].sites.size(); ++k {
            if self.rows[i].sites[k] == site {
                return
            }
        }

        self.rows[i].sites.push(site)
    }

    /// Capture row `k` of closure `c` moves the whole local `d` in.
    fn captured_at(self, d: unsafe *Decl, c: unsafe *Expressions::ClosureExpr, k: usize) {
        var i = self.index_of(d)
        if i == usize::MAX || !self.rows[i].cand {
            return
        }

        for var j: usize = 0; j < self.rows[i].caps.size(); ++j {
            if self.rows[i].caps[j] == c && self.rows[i].cap_at[j] == k {
                return
            }
        }

        self.rows[i].caps.push(c)
        self.rows[i].cap_at.push(k)
    }

    /// `v` is a `return d` of the whole local `d`.
    fn returned_at(self, d: unsafe *Decl, v: unsafe *Expr, ok: bool) {
        var i = self.index_of(d)
        if i == usize::MAX || !self.rows[i].cand {
            return
        }

        if !ok {
            self.rows[i].bad = true
        }

        for var k: usize = 0; k < self.rows[i].rets.size(); ++k {
            if self.rows[i].rets[k] == v {
                return
            }
        }

        self.rows[i].rets.push(v)
    }

    /// LocalEndRow::visits of `d` (0 when it is not a row).
    fn visits_of(self, d: unsafe *Decl) -> usize {
        var i = self.index_of(d)
        return if (i != usize::MAX) => (self.rows[i].visits) else => 0
    }

    /// None of `d`'s real transfers may disarm.
    fn spoil(self, d: unsafe *Decl) {
        var i = self.index_of(d)
        if i != usize::MAX {
            self.rows[i].bad = true
        }
    }

    /// `asn` constructs `d` again after a `finally()`.
    fn remade_at(self, d: unsafe *Decl, asn: unsafe *Expressions::AssignOperatorExpr) {
        var i = self.index_of(d)
        if i == usize::MAX {
            return
        }

        for var k: usize = 0; k < self.rows[i].remakes.size(); ++k {
            if self.rows[i].remakes[k] == asn {
                return
            }
        }

        self.rows[i].remakes.push(asn)
    }

    /// `asn` assigns the whole of `d` reached after a move of it, in the
    /// state `bit` (REMAKE_DEAD: moved by a real transfer on every path;
    /// REMAKE_MAYBE: on some, or by another kind of move).
    fn move_remade_at(self,
                      d:   unsafe *Decl,
                      asn: unsafe *Expressions::AssignOperatorExpr,
                      bit: u8) {
        var i = self.index_of(d)
        if i == usize::MAX {
            return
        }

        for var k: usize = 0; k < self.rows[i].mremakes.size(); ++k {
            if self.rows[i].mremakes[k] == asn {
                self.rows[i].mbits[k] = self.rows[i].mbits[k] | bit
                return
            }
        }

        self.rows[i].mremakes.push(asn)
        self.rows[i].mbits.push(bit)
    }

    /// An exit of `d`'s scope is reached with `d` not ended on every path.
    fn alive_at_exit(self, d: unsafe *Decl) {
        var i = self.index_of(d)
        if i != usize::MAX {
            self.rows[i].alive = true
        }
    }

    /// ...and with `d` not moved by a real transfer on every path either.
    fn alive_unmoved_at_exit(self, d: unsafe *Decl) {
        var i = self.index_of(d)
        if i != usize::MAX {
            self.rows[i].alive_unmoved = true
        }
    }

    /// Each local's mode, written onto the declaration, and the disarmed
    /// moves of the locals whose real transfers skip the moved-from
    /// object's destructor (disarm_local_at). `may_unwind`: a C++
    /// exception can leave the body at a point the walk does not see (an
    /// `@unwind` function, `-funwind`, a closure), so a local some site
    /// ends is never elided there: the hook must still run on that path.
    ///
    /// A local's move-driven assignments (LocalEndRow::mremakes) become
    /// constructions only when its moves are disarmed; otherwise the
    /// moved-from object is there and each is an ordinary assignment
    /// (REMAKE_LIVE), which also makes one a `finally()` reached dead a
    /// maybe-dead construction. Each `return x` of a disarmed local is a
    /// move site of its own, so CopyMoveLowering casts it and EmitIR
    /// clears the flag there.
    fn settle(self, sc: unsafe *SemaContext, may_unwind: bool) {
        for var i: usize = 0; i < self.rows.size(); ++i {
            var *r      = &self.rows[i]
            var managed = r->managed()
            for var k: usize = 0; k < r->rets.size(); ++k {
                sc->move_sites.erase(r->rets[k] as usize as u64)
            }

            for var k: usize = 0; k < r->mremakes.size(); ++k {
                var unsafe *asn = r->mremakes[k]
                asn->remake = asn->remake | (if (managed) => (r->mbits[k])
                                             else => Expressions::REMAKE_LIVE)
            }

            // A construction that may find an object there tests `live`.
            var maybe = _maybe_remade(r->remakes) || managed && _maybe_remade(r->mremakes)
            var m = LocalDtor::Scope
            if r->refusal.size() > 0 {
                m = LocalDtor::Scope
            } else if managed {
                m = if (r->alive_unmoved || maybe || may_unwind) => (LocalDtor::Flagged)
                    else => LocalDtor::Elided
            } else if r->ends > 0 {
                m = if (r->alive || maybe || may_unwind) => (LocalDtor::Flagged)
                    else => LocalDtor::Elided
            } else if sc->opts.union_locals_all
                && union_storage_refusal(r->d).size() == 0
                && local_has_dtor(sc, r->d) == LifecycleTri::Yes {
                m = LocalDtor::Cleanup
            }

            r->d->dtor_mode = m
            for var k: usize = 0; k < r->caps.size(); ++k {
                r->caps[k]->held.get(r->cap_at[k])->disarms = managed
            }

            if !managed {
                continue
            }

            for var k: usize = 0; k < r->sites.size(); ++k {
                disarm_local_at(sc, r->sites[k], r->d, m)
            }

            for var k: usize = 0; k < r->rets.size(); ++k {
                sc->move_sites.insert(r->rets[k] as usize as u64)
                disarm_local_at(sc, r->rets[k], r->d, m)
            }
        }
    }
}

/// Some assignment of `v` is reached maybe dead: MAYBE, or DEAD on one
/// visit and LIVE on another.
fn _maybe_remade(const v: [unsafe *Expressions::AssignOperatorExpr]) -> bool {
    for var k: usize = 0; k < v.size(); ++k {
        var b = v[k]->remake
        if (b & Expressions::REMAKE_MAYBE) != 0
            || (b & Expressions::REMAKE_DEAD) != 0 && (b & Expressions::REMAKE_LIVE) != 0 {
            return true
        }
    }

    return false
}
