/// --- The Kairo Project ----------------- Sema/Incremental/Retract.k --- ///
///
///   \brief Taking a set of files back out of the instantiation registry
///          before a live check re-checks them (Tooling/LiveCheck.k,
///          Compiler/Spec/IncrementalSema.md phase 4).
///
///   The registry is build-wide and its entries outlive the files that
///   caused them. Two things are true of an entry once a set of files is
///   re-read:
///
///     - It NAMES a declaration of the set (its primary, its pattern, an
///       explicit specialization, or a record in its arguments, directly or
///       through another such instance). No kept file can name that
///       declaration, so no kept file names the entry: it is DROPPED. Left
///       in, the discovery walk would read a tree that is gone.
///     - It names kept declarations only, and a kept file may hold its node
///       (a second namer), so it stays, at the same address. But what the
///       registry did ONCE for it on behalf of a file of the set is taken
///       back: if the use that made it live is in the set, it is no longer
///       live nor walked, and its once-only reports are armed again, so the
///       set's re-check makes it live from the new text and reports what a
///       fresh run reports there.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "llvm/ADT/DenseSet.h"
ffi "c++" import "Native/Types.hh"
ffi "c++" import "vector"
ffi "c++" import "cstdlib"

import AST::Context::ASTContext::ASTContext
import AST::Context::GlobalDisambigTable::GlobalDisambigTable
import AST::Context::InstantiationRegistry::{
    InstanceEntry,
    InstantiationRegistry,
}
import AST::DeclFacts::decl_is_imported
import AST::Kind::TypeKind::TypeKind
import AST::Node::Base::{
    Decl,
    Type,
}
import AST::Node::CanonicalNodes::{
    AssocType,
    QualifiedType,
    RecordType,
}
import AST::Node::Casting::cast
import AST::Node::Types
import Location::SourceManager::SourceManager
import std::io
import Location::SourceRange::SourceRange
import Sema::Foreign::ForeignRegistry::ForeignRegistry
import Sema::Resolve::NameLookup::NameLookup

/// Every record declaration the canonical type \p c_in mentions.
fn retract_records(c_in: unsafe *Type, depth: u32, out: unsafe *cxx::std::vector<unsafe *Decl>) {
    if c_in == &null || depth > 24 {
        return
    }

    var unsafe *c = c_in
    if c->canonical != &null {
        c = c->canonical
    }

    match c->kind {
        case TypeKind::RecordType {
            var unsafe *r = cast<RecordType>(c)
            if r->decl != &null {
                out->push_back(r->decl)
            }

            for var i: usize = 0; i < r->args.size(); ++i {
                retract_records(r->args[i], depth + 1, out)
            }

            retract_records(r->outer, depth + 1, out)
        } case TypeKind::QualifiedType {
            retract_records(cast<QualifiedType>(c)->inner, depth + 1, out)
        } case TypeKind::PointerType {
            retract_records(cast<Types::PointerType>(c)->pointee, depth + 1, out)
        } case TypeKind::NullableType {
            retract_records(cast<Types::NullableType>(c)->inner, depth + 1, out)
        } case TypeKind::FixedArrayType {
            retract_records(cast<Types::FixedArrayType>(c)->element, depth + 1, out)
        } case TypeKind::VectorType {
            retract_records(cast<Types::VectorType>(c)->element, depth + 1, out)
        } case TypeKind::SetType {
            retract_records(cast<Types::SetType>(c)->element, depth + 1, out)
        } case TypeKind::MapType {
            var unsafe *m = cast<Types::MapType>(c)
            retract_records(m->key, depth + 1, out)
            retract_records(m->value, depth + 1, out)
        } case TypeKind::CXXLValueRefType {
            retract_records(cast<Types::CXXLValueRefType>(c)->referee, depth + 1, out)
        } case TypeKind::CXXRValueRefType {
            retract_records(cast<Types::CXXRValueRefType>(c)->referee, depth + 1, out)
        } case TypeKind::FunctionPointerType {
            var unsafe *f = cast<Types::FunctionPointerType>(c)
            for var i: usize = 0; i < f->params.size(); ++i {
                retract_records(f->params[i], depth + 1, out)
            }

            retract_records(f->return_type, depth + 1, out)
        } case TypeKind::AssocType {
            var unsafe *a = cast<AssocType>(c)
            retract_records(a->base, depth + 1, out)
            for var i: usize = 0; i < a->args.size(); ++i {
                retract_records(a->args[i], depth + 1, out)
            }
        } default {
            return
        }
    }
}

/// \class RetractStats
pub class RetractStats {
    pub var entries: usize = 0 ///< in the registry before
    pub var dropped: usize = 0
    pub var rearmed: usize = 0
    pub var foreign: usize = 0 ///< USRs forgotten
    /// Kept C++ template shells whose one fill was demanded by the set.
    pub var fills_owned: usize = 0
    /// The re-armed entries: a re-check that does not make one live again
    /// has lost its first use to a kept file.
    pub var rearmed_list: cxx::std::vector<unsafe *InstanceEntry>
    pub var rearmed_was:  cxx::std::vector<string> ///< parallel: depth, and whether it was reached

    pub fn RetractStats(self) = default
}

/// \brief takes the files \p fids (their contexts still in \p gs: call
///        before they are detached) out of the registry.
pub fn retract_instances(gs:         unsafe *GlobalDisambigTable,
                         sm:         unsafe *SourceManager,
                         freg:       unsafe *ForeignRegistry,
                         const fids: cxx::std::vector<u32>) -> RetractStats {
    var st = RetractStats()
    var ctxs = llvm::DenseSet<u64>()
    var in_f = llvm::DenseSet<u64>()
    for var f: u32 in fids {
        in_f.insert(f as u64)
        var unsafe *c = gs->get_context(f)
        if c != &null {
            ctxs.insert(c as usize as u64)
        }
    }

    var unsafe *reg = gs->instances()
    var all = cxx::std::vector<unsafe *InstanceEntry>()
    reg->collect(&all)
    st.entries = all.size()

    // The records each entry's arguments name, once.
    var arg_decls = cxx::std::vector<cxx::std::vector<unsafe *Decl>>()
    for var i: usize = 0; i < all.size(); ++i {
        var ds = cxx::std::vector<unsafe *Decl>()
        for var k: usize = 0; k < all[i]->args.size(); ++k {
            retract_records(all[i]->args[k], 0, unsafe &ds)
        }

        for var k: usize = 0; k < all[i]->pattern_args.size(); ++k {
            retract_records(all[i]->pattern_args[k], 0, unsafe &ds)
        }

        arg_decls.push_back(ds)
    }

    // Dead: names a declaration of the set, or an instance that does.
    var dead_nodes = llvm::DenseSet<u64>()
    var dead       = cxx::std::vector<u8>()
    for var i: usize = 0; i < all.size(); ++i {
        dead.push_back(0 as u8)
    }

    var grew = true
    while grew {
        grew = false
        for var i: usize = 0; i < all.size(); ++i {
            if dead[i] != 0 {
                continue
            }

            var unsafe *e = all[i]
            var hit       = false
            var own       = cxx::std::vector<unsafe *Decl>()
            own.push_back(e->primary)
            own.push_back(e->pattern)
            if e->is_explicit {
                own.push_back(e->decl)
            }

            for var k: usize = 0; k < arg_decls[i].size(); ++k {
                own.push_back(arg_decls[i][k])
            }

            for var k: usize = 0; k < own.size() && !hit; ++k {
                var unsafe *d = own[k]
                if d == &null {
                    continue
                }

                if dead_nodes.contains(d as usize as u64) {
                    hit = true
                    break
                }

                var unsafe *dc = NameLookup::ctx_of(d)
                if dc != &null && ctxs.contains(dc as usize as u64) {
                    hit = true
                }
            }

            if hit {
                dead[i] = (1 as u8)
                grew    = true
                // The node minted for THIS instance is dead with it. Not
                // every entry has one of its own: a function template's
                // entry holds the template's declaration itself, which
                // every other instance of the template and the foreign
                // registry share, and an explicit specialization's is the
                // user's declaration, judged by its own file.
                if e->decl != &null && e->decl != e->primary && !e->is_explicit {
                    dead_nodes.insert(e->decl as usize as u64)
                }
            }
        }
    }

    var drop = cxx::std::vector<unsafe *InstanceEntry>()
    for var i: usize = 0; i < all.size(); ++i {
        var unsafe *e = all[i]
        if dead[i] != 0 {
            drop.push_back(e)
            continue
        }

        // Kept. What was done once for a file of the set is undone.
        var rearm = false
        if e->use_at.is_valid() && in_f.contains((sm->resolve(e->use_at.start).fid as u32) as u64) {
            rearm = true
        }

        if e->via_at.is_valid() && in_f.contains((sm->resolve(e->via_at.start).fid as u32) as u64) {
            rearm = true
        }

        // An imported C++ template's shell is made live by the fill that
        // demanded it (ForeignInstantiate::fill), which runs once and is
        // not run again by a re-check; it has no bounds to report and no
        // Kairo body to walk, so it is left as it is.
        if rearm && e->primary != &null && decl_is_imported(e->primary) {
            rearm = false
        }

        // A kept shell that was FILLED on behalf of a file of the set: the
        // fill ran once, for that file (its requests, clang's reports for
        // the instantiation), and a re-check of the file does not run it
        // again. Counted; the caller does not re-check in place over one.
        if e->fill_fid >= 0 && in_f.contains((e->fill_fid as u32) as u64) {
            st.fills_owned += 1
        }

        if rearm {
            st.rearmed_was.push_back(
                f"depth {e->depth}" + (if (e->via != &null) => (", reached") else => "") + (if (e->failed) => (", failed") else => "") + (if (e->checked) => (", walked") else => ""),
            )
            e->depth              = 0
            e->use_at             = SourceRange::invalid()
            e->via                = &null
            e->via_at             = SourceRange::invalid()
            e->checked            = false
            e->ambiguity_reported = false
            e->undecided_reported = false
            e->panic_checked      = false
            st.rearmed += 1
            st.rearmed_list.push_back(e)
        }

        if e->formed_fid != u32::MAX && in_f.contains(e->formed_fid as u64) {
            e->formed_fid  = u32::MAX
            e->formed_at   = SourceRange::invalid()
            e->formed_rank = u64::MAX
            e->formed_seq  = u64::MAX
        }
    }

    st.dropped = drop.size()
    reg->drop_entries(&drop)

    // The foreign registry: a USR that stands for a declaration of the set
    // (the C++ stand-in of a Kairo record) or for something imported into a
    // dropped shell would hand the next fill the old declaration.
    if freg != &null {
        var usrs  = cxx::std::vector<string>()
        var decls = cxx::std::vector<unsafe *Decl>()
        freg->entries(unsafe &usrs, unsafe &decls)
        var dbg     = cxx::std::getenv(r"KAIRO_LIVE_DEBUG") != &null
        var gone    = cxx::std::vector<string>()
        var orphans = cxx::std::vector<string>()
        for var i: usize = 0; i < usrs.size(); ++i {
            var unsafe *cur = decls[i]
            var is_dead     = false
            for var hop: usize = 0; hop < 16 && cur != &null && !is_dead; ++hop {
                if dead_nodes.contains(cur as usize as u64) {
                    is_dead = true
                    break
                }

                var unsafe *dc = NameLookup::ctx_of(cur)
                if dc != &null && ctxs.contains(dc as usize as u64) {
                    is_dead = true
                    break
                }

                var unsafe *up = cur->semantic_dc
                if up == &null {
                    up = cur->lexical_dc
                }

                if up == &null {
                    break
                }

                cur = up->dc_owner
            }

            if is_dead {
                // The stand-in of a declaration of the set itself, against
                // something imported into a dropped shell.
                var unsafe *own = NameLookup::ctx_of(decls[i])
                if own != &null && ctxs.contains(own as usize as u64) && !dead_nodes.contains(decls[i] as usize as u64) {
                    orphans.push_back(usrs[i])
                    if dbg {
                        io::eprintln(f"[retract] orphan {usrs[i]}")
                    }
                } else {
                    gone.push_back(usrs[i])
                    if dbg {
                        var unsafe *oc = NameLookup::ctx_of(decls[i])
                        var where_ = if (oc != &null && oc->sm != &null) => (oc->sm->get_filename(oc->fid)) else => "?"
                        var dn = if (dead_nodes.contains(decls[i] as usize as u64)) => (" dead-node") else => ""
                        io::eprintln(f"[retract] gone {usrs[i]} kind={(decls[i]->kind as u8) as u32} ctx={where_}{dn}")
                    }
                }
            }
        }

        var shells = cxx::std::vector<unsafe *Decl>()
        for var i: usize = 0; i < drop.size(); ++i {
            if drop[i]->decl != &null && dead_nodes.contains(drop[i]->decl as usize as u64) {
                shells.push_back(drop[i]->decl)
            }
        }

        st.foreign = gone.size() + orphans.size()
        freg->adopted.clear()
        freg->forget(unsafe &gone, unsafe &orphans, unsafe &shells)
    }

    return st
}
