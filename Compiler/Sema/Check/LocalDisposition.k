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
///     LocalEnds is MoveCheck's record of the `finally()` provider: the
///     locals each body declares, which of them a site ends, and which are
///     still alive (or may be) at some exit of their scope. settle() turns
///     that into each local's mode when the body's walk ends, and writes
///     every local of the body, so a second check of the same tree (the
///     language server's) leaves no stale mode behind.
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

import AST::Kind::TypeKind::TypeKind
import AST::Node::Base::{
    Decl,
    Expr,
    Type,
}
import AST::Node::CanonicalNodes::canon_unqual
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
/// local's, so a provider never weakens what another decided. A provider
/// runs after MoveCheck, which writes every local's mode afresh.
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

/// One local a body declares and a `finally()` provider follows.
pub class LocalEndRow {
    pub var d:     unsafe *VariableDecl = &null
    pub var ends:  usize                = 0 ///< sites that end it (a `finally()` call).
    pub var alive: bool                 = false ///< some exit of its scope is reached with it alive, or maybe alive.
    /// Why its declaration cannot take union storage ("" when it can): it
    /// keeps `Scope`, and a `finally()` of it is SC116E.
    pub var refusal: string = ""
    /// The test provider's (Sema/Check/TestDisarm.k): the one real
    /// transfer of the whole local it may disarm, whether a second one or
    /// the code around it ruled that out, whether the block's scan
    /// accepted it, and whether an exit is reached with the local neither
    /// ended nor moved there.
    pub var disarm_site:   unsafe *Expr = &null
    pub var disarm_bad:    bool         = false
    pub var disarm_ok:     bool         = false
    pub var alive_unmoved: bool         = false
    /// Whole assignments that construct it again after a `finally()`
    /// (AssignOperatorExpr::remake).
    pub var remakes: [unsafe *Expressions::AssignOperatorExpr]
    fn LocalEndRow(self) { }
}

/// MoveCheck's record of the locals of the body being walked; one per
/// body (saved and restored around a nested one).
pub class LocalEnds {
    pub var rows: [LocalEndRow]
    fn LocalEnds(self) { }

    /// `d` is a local this body declares (a DeclStmt of one of its blocks);
    /// `refusal` as LocalEndRow::refusal.
    fn declare(self, d: unsafe *VariableDecl, const refusal: string) {
        if self.index_of(d) != usize::MAX {
            return
        }

        var r = LocalEndRow()
        r.d       = d
        r.refusal = refusal.copy()
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

    /// A site ends `d` here.
    fn ended_at_site(self, d: unsafe *Decl) {
        var i = self.index_of(d)
        if i != usize::MAX {
            self.rows[i].ends += 1
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

    /// An exit of `d`'s scope is reached with `d` not ended on every path.
    fn alive_at_exit(self, d: unsafe *Decl) {
        var i = self.index_of(d)
        if i != usize::MAX {
            self.rows[i].alive = true
        }
    }

    /// ...and with `d` not disarmed-moved on every path either.
    fn alive_unmoved_at_exit(self, d: unsafe *Decl) {
        var i = self.index_of(d)
        if i != usize::MAX {
            self.rows[i].alive_unmoved = true
        }
    }

    /// The test provider: `site` is a real transfer of the whole local `d`.
    /// A second, different one rules both out.
    fn disarm_candidate(self, d: unsafe *Decl, site: unsafe *Expr) {
        var i = self.index_of(d)
        if i == usize::MAX {
            return
        }

        if self.rows[i].disarm_site != &null && self.rows[i].disarm_site != site {
            self.rows[i].disarm_bad = true
            return
        }

        self.rows[i].disarm_site = site
    }

    /// The test provider's disarms, through the one API every provider
    /// uses, once settle() has written the body's modes.
    fn settle_disarms(self, sc: unsafe *SemaContext, may_unwind: bool) {
        for var i: usize = 0; i < self.rows.size(); ++i {
            var *r = &self.rows[i]
            if !r->disarm_ok || r->disarm_bad || r->disarm_site == &null || r->ends > 0 {
                continue
            }

            if !is_real_transfer(sc, r->disarm_site, r->d) {
                continue
            }

            var m = if (r->alive_unmoved || may_unwind) => (LocalDtor::Flagged)
                    else => LocalDtor::Elided
            disarm_local_at(sc, r->disarm_site, r->d, m)
        }
    }

    /// Each local's mode, written onto the declaration. `may_unwind`: a C++
    /// exception can leave the body at a point the walk does not see (an
    /// `@unwind` function, `-funwind`, a closure), so a local some site ends
    /// is never elided there: the hook must still run on that path.
    fn settle(self, sc: unsafe *SemaContext, may_unwind: bool) {
        for var i: usize = 0; i < self.rows.size(); ++i {
            var *r = &self.rows[i]
            var m  = LocalDtor::Scope
            if r->refusal.size() > 0 {
                m = LocalDtor::Scope
            } else if r->ends > 0 {
                // A construction that may find an object there tests `live`.
                var maybe = false
                for var k: usize = 0; k < r->remakes.size(); ++k {
                    var b = r->remakes[k]->remake
                    if (b & Expressions::REMAKE_MAYBE) != 0
                        || (b & Expressions::REMAKE_DEAD) != 0
                            && (b & Expressions::REMAKE_LIVE) != 0 {
                        maybe = true
                    }
                }

                m = if (r->alive || maybe || may_unwind) => (LocalDtor::Flagged)
                    else => LocalDtor::Elided
            } else if sc->opts.union_locals_all
                && union_storage_refusal(r->d).size() == 0
                && local_has_dtor(sc, r->d) == LifecycleTri::Yes {
                m = LocalDtor::Cleanup
            }

            r->d->dtor_mode = m
        }
    }
}
