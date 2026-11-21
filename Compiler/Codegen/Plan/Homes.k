/// --- The Kairo Project ------------------------- Codegen/Plan/Homes.k --- ///
///
///   EmitPlan, part: homes. The build's file order and import graph, set
///   once before the fan-out, and the home TU of every tier-3 instance: the one
///   TU that defines it, from the TUs that hold it.
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
ffi "c++" import "llvm/ADT/DenseMap.h"
ffi "c++" import "llvm/ADT/StringMap.h"
ffi "c++" import "vector"

import AST::Context::InstantiationRegistry::InstanceEntry
import Codegen::Plan::EmitPlan::{
    EmitPlan,
    GraphPhase,
    _FILE_RANK,
    _G_EDGES,
    _G_IS_MOD,
    _G_PHASE,
    _G_PRELUDE,
    _HOMES,
}
import Codegen::Spell::Spell::Speller

extend EmitPlan {
    /// the build's file order: `keys[i]` names `fids[i]` (a module
    /// path, or a file name for a file that has none), and every plan
    /// sorts by the rank of its key instead of by fid.
    ///
    /// Fids are minted in the order the PP walk meets files from
    /// the entry, so two entries over one tree number its modules
    /// differently, and a TU's stream (its object key) differed
    /// between kairo and kcc in order alone. Ties (two files, one
    /// key) go by fid; the caller makes keys unique where it can.
    /// Driver thread, before any plan of the codegen runs.
    pub static fn set_file_ranks(const keys: cxx::std::vector<string>,
                                 const fids: cxx::std::vector<u32>) {
        EmitPlan::_graph_step(GraphPhase::Unset, GraphPhase::Ranked)
        var ix = cxx::std::vector<usize>()
        for var i: usize = 0; i < keys.size(); ++i {
            ix.push_back(i)
        }

        var *kp = &keys
        var *fp = &fids
        llvm::sort(
            ix.begin(),
            ix.end(),
            fn (a: usize, b: usize) |kp, fp| -> bool {
                if (*kp)[a] != (*kp)[b] {
                    return (*kp)[a] < (*kp)[b]
                }

                return (*fp)[a] < (*fp)[b]
            },
        )

        _FILE_RANK.clear()
        for var r: usize = 0; r < ix.size(); ++r {
            var f = fids[ix[r]]
            if f == u32::MAX {
                continue
            }

            while _FILE_RANK.size() <= (f as usize) {
                _FILE_RANK.push_back(u32::MAX)
            }

            _FILE_RANK[f as usize] = (r as u32)
        }
    }

    /// the build's import graph: `edges[i]` are module `mods[i]`'s
    /// import edge targets in declaration order (TranslationUnit::
    /// import_edges), `prelude` the prelude's fid (0: none). What a
    /// TU's own file order (_rank_of) and assign_homes walk.
    pub static fn set_graph(const mods:  cxx::std::vector<u32>,
                            const edges: cxx::std::vector<cxx::std::vector<u32>>,
                            prelude:     u32) {
        EmitPlan::_graph_step(GraphPhase::Ranked, GraphPhase::Graphed)
        _G_EDGES.clear()
        _G_IS_MOD.clear()
        for var i: usize = 0; i < mods.size(); ++i {
            var f = (mods[i] as usize)
            while _G_EDGES.size() <= f {
                _G_EDGES.push_back(cxx::std::vector<u32>())
                _G_IS_MOD.push_back(0 as u8)
            }

            _G_EDGES[f]  = edges[i]
            _G_IS_MOD[f] = (1 as u8)
        }

        _G_PRELUDE = prelude
    }

    /// Whether module `from` imports `to`, transitively (set_graph's
    /// edges); `memo` holds each asked module's marks.
    static fn _reaches(memo: *cxx::std::vector<cxx::std::vector<u8>>, from: u32, to: u32) -> bool {
        while memo->size() <= (from as usize) {
            memo->push_back(cxx::std::vector<u8>())
        }

        if (*memo)[from as usize].empty() {
            var marks = cxx::std::vector<u8>()
            marks.resize(_G_EDGES.size() + 1, 0 as u8)
            var stack = cxx::std::vector<u32>()
            if EmitPlan::_is_mod(from) {
                for var t: u32 in _G_EDGES[from as usize] {
                    stack.push_back(t)
                }
            }

            while !stack.empty() {
                var f = stack[stack.size() - 1]
                stack.pop_back()
                if !EmitPlan::_is_mod(f) || marks[f as usize] != (0 as u8) {
                    continue
                }

                marks[f as usize] = (1 as u8)
                for var t: u32 in _G_EDGES[f as usize] {
                    stack.push_back(t)
                }
            }

            (*memo)[from as usize] = marks
        }

        var *mk = &(*memo)[from as usize]
        return (to as usize) < mk->size() && (*mk)[to as usize] != (0 as u8)
    }

    static fn _is_mod(f: u32) -> bool {
        return (f as usize) < _G_IS_MOD.size() && _G_IS_MOD[f as usize] != (0 as u8)
    }

    /// the sort key of `fid` in THIS TU: the order in which a
    /// depth-first walk of the imports from this TU (then from the
    /// prelude) meets the file, then every other file by module path
    /// (set_file_ranks), then by fid.
    ///
    /// The walk is the one the PP's dependency scan makes from the
    /// entry, which mints fids, so the entry TU's order is what
    /// ordering by fid gave; but it starts from this TU, so it reads
    /// only this TU's own imports, transitively: the same in every
    /// graph that holds the TU (Compiler/Spec/Incremental.md#shared-across-graphs).
    fn _rank_of(self, fid: u32) -> u64 {
        eval if defined!(DEBUG) {
            if _G_PHASE == GraphPhase::Ranked {
                kairo::std::ice_fail(
                    r"EmitPlan: a plan ranked files between set_file_ranks and set_graph (driver schedule bug)",
                )
            }
        }

        if !self._ranked {
            self._rank_walk()
        }

        if (fid as usize) < self._rank.size() && self._rank[fid as usize] != u32::MAX {
            return self._rank[fid as usize] as u64
        }

        if (fid as usize) < _FILE_RANK.size() && _FILE_RANK[fid as usize] != u32::MAX {
            return ((1 as u64) << 32) + (_FILE_RANK[fid as usize] as u64)
        }

        return ((2 as u64) << 32) + (fid as u64)
    }

    fn _rank_walk(self) {
        self._ranked = true
        var next: u32 = 0
        var roots     = cxx::std::vector<u32>()
        roots.push_back(self._home)
        if _G_PRELUDE != 0 {
            roots.push_back(_G_PRELUDE)
        }

        for var r: u32 in roots {
            if !EmitPlan::_is_mod(r) {
                continue
            }

            var stack = cxx::std::vector<u32>()
            stack.push_back(r)
            while !stack.empty() {
                var f = stack[stack.size() - 1]
                stack.pop_back()
                while self._rank.size() <= (f as usize) {
                    self._rank.push_back(u32::MAX)
                }

                if self._rank[f as usize] != u32::MAX {
                    continue
                }

                self._rank[f as usize] = next
                next += 1
                // Children in reverse, so the first import is walked first.
                var *es = &_G_EDGES[f as usize]
                var k   = es->size()
                while k > 0 {
                    k -= 1
                    var t = (*es)[k]
                    if EmitPlan::_is_mod(t)
                        && ((t as usize) >= self._rank.size()
                            || self._rank[t as usize] == u32::MAX) {
                        stack.push_back(t)
                    }
                }
            }
        }
    }

    /// The codegen home of `ie`: assign_homes' choice, else its home_fid.
    pub static fn home_of(ie: unsafe *InstanceEntry) -> u32 {
        var it = _HOMES.find(ie as usize as u64)
        if it != _HOMES.end() {
            return it->second
        }

        return ie->home_fid
    }

    /// One step of GraphPhase, which only runs forward from `from`: a
    /// fact set out of order is read by plans that assume the ones before it.
    static fn _graph_step(from: GraphPhase, to: GraphPhase) {
        eval if defined!(DEBUG) {
            if _G_PHASE != from {
                kairo::std::ice_fail(
                    r"EmitPlan: graph facts set out of order (set_file_ranks, set_graph, assign_homes, reset_graph_facts)",
                )
            }
        }

        _G_PHASE = to
    }

    /// Forgets set_file_ranks and assign_homes: the next codegen sets its own.
    pub static fn reset_graph_facts() {
        _G_PHASE = GraphPhase::Unset
        _FILE_RANK.clear()
        _HOMES.clear()
        _G_EDGES.clear()
        _G_IS_MOD.clear()
        _G_PRELUDE = 0
    }

    /// each tier-3 instance's home, from the TUs that hold it and
    /// nothing else in the graph.
    ///
    /// ### Parameters
    /// - `plans`: every TU of this codegen, its Preamble plan run.
    /// - `keys`: parallel: each TU's module path, the graph-stable name.
    ///
    /// The rule (Compiler/Spec/Generics.md's one home, Incremental.md):
    /// the users of an instance are the TUs whose plan ADMITTED it
    /// (only they can define it: a plan that holds an instance has
    /// its body visible, and is_home is all that changes), in the
    /// root of its Sema home (home_fid; a root's objects ship
    /// together, as header mode assumes). The home is the user with
    /// the least module path among those that import no other user
    /// (transitively; two in one import cycle do not count as below
    /// each other). That is Sema's first namer (D3: the generic's own
    /// TU when it uses the instance, else the first user in
    /// dependency order) with its graph-wide parts taken out: which
    /// entry the build started from and the import order of
    /// siblings, for which the module path stands in. It depends only
    /// on the users and their imports, so a TU shared by kairo and
    /// kcc homes the same instances in both, and a new user takes an
    /// instance over only when no other user imports it and its path
    /// sorts first. An instance whose Sema home is not a TU of this
    /// codegen (a library built separately), or that no plan
    /// admitted, keeps home_fid. Driver thread, plans finished,
    /// set_graph called.
    pub static fn assign_homes(const plans: cxx::std::vector<unsafe *EmitPlan>,
                               const keys:  cxx::std::vector<string>) {
        EmitPlan::_graph_step(GraphPhase::Graphed, GraphPhase::Homed)
        _HOMES.clear()
        // fid -> index into plans.
        var at = llvm::DenseMap<u64, usize>()
        for var i: usize = 0; i < plans.size(); ++i {
            at.try_emplace(plans[i]->_home as u64, i)
        }

        // Instance -> its users, in plan order; and the instances in first-seen order.
        var users = llvm::DenseMap<u64, usize>()
        var lists = cxx::std::vector<cxx::std::vector<usize>>()
        var order = cxx::std::vector<unsafe *InstanceEntry>()
        for var i: usize = 0; i < plans.size(); ++i {
            var unsafe *v = plans[i]->instances()
            for var k: usize = 0; k < v->size(); ++k {
                var unsafe *ie = (*v)[k]
                var        key = ie as usize as u64
                var        it  = users.find(key)
                if it == users.end() {
                    users.try_emplace(key, lists.size())
                    lists.push_back(cxx::std::vector<usize>())
                    order.push_back(ie)
                    lists[lists.size() - 1].push_back(i)
                } else {
                    lists[it->second as usize].push_back(i)
                }
            }
        }

        // Each instance's candidates and C++ name. Two instances can be one
        // C++ entity (`*T` and `unsafe *T`, `usize` and `u64` on LP64): they
        // are homed as one, from the union of their users, or one TU would
        // write the entity's explicit instantiation twice (CL001E) or two TUs
        // once each. The name: the primary, by the order its first instance
        // is met, and the arguments as the user with the least module path
        // spells them with sizes folded (tier 3's key). The primary is the
        // declaration, never its place in its file: every declaration one
        // macro invocation makes is at that invocation, and two generics
        // homed as one leave the second defined by a TU that does not hold it.
        var gname = cxx::std::vector<string>()
        var gcand = cxx::std::vector<cxx::std::vector<usize>>()
        var gmembers = cxx::std::vector<cxx::std::vector<unsafe *InstanceEntry>>()
        var prims   = llvm::DenseMap<u64, u32>()
        var by_name = llvm::StringMap<u32>()
        for var n: usize = 0; n < order.size(); ++n {
            var unsafe *ie = order[n]
            var        hit = at.find(ie->home_fid as u64)
            if hit == at.end() { // homed outside this codegen: as Sema said.
                continue
            }

            var unsafe *sema_home = plans[hit->second as usize]
            var unsafe *list      = unsafe &lists[n]
            var        cand       = cxx::std::vector<usize>()
            for var k: usize = 0; k < list->size(); ++k {
                var u = (*list)[k]
                if sema_home->_same_root(plans[u]->_home, ie->home_fid) {
                    cand.push_back(u)
                }
            }

            if cand.empty() {
                continue
            }

            var least = cand[0]
            for var k: usize = 1; k < cand.size(); ++k {
                if keys[cand[k]] < keys[least] {
                    least = cand[k]
                }
            }

            var unsafe *lp   = plans[least]
            var unsafe *prim = Speller::rep(ie->primary)
            var        pit   = prims.find(prim as usize as u64)
            var        pn    = prims.size() as u32
            if pit == prims.end() {
                prims.try_emplace(prim as usize as u64, pn)
            } else {
                pn = pit->second
            }

            var name = f"{pn}"
            lp->_spell.fold_sizes   = true
            lp->_spell.sizes_folded = 0
            name += lp->_spell.args_str(ie->args)
            lp->_spell.fold_sizes = false
            var git       = by_name.find(kairo::sref(name))
            var g:  usize = 0
            if git == by_name.end() {
                g = gname.size()
                by_name.try_emplace(kairo::sref(name), g as u32)
                gname.push_back(name)
                gcand.push_back(cxx::std::vector<usize>())
                gmembers.push_back(cxx::std::vector<unsafe *InstanceEntry>())
            } else {
                g = (git->second as usize)
            }

            for var u: usize in cand {
                var dup = false
                for var w: usize in gcand[g] {
                    if w == u {
                        dup = true
                        break
                    }
                }

                if !dup {
                    gcand[g].push_back(u)
                }
            }

            gmembers[g].push_back(ie)
        }

        // Each user's transitive imports, on demand (fid -> marks by fid).
        var reach = cxx::std::vector<cxx::std::vector<u8>>()
        for var g: usize = 0; g < gname.size(); ++g {
            var unsafe *cand = unsafe &gcand[g]
            // In module-path order: the first user no other user lies below.
            var *kp = &keys
            llvm::sort(
                cand->begin(),
                cand->end(),
                fn (a: usize, b: usize) |kp| -> bool {
                    if (*kp)[a] != (*kp)[b] {
                        return (*kp)[a] < (*kp)[b]
                    }

                    return a < b
                },
            )

            var pick = usize::MAX
            for var k: usize = 0; k < cand->size() && pick == usize::MAX; ++k {
                var u     = plans[(*cand)[k]]->_home
                var below = false
                for var m: usize = 0; m < cand->size(); ++m {
                    if m == k {
                        continue
                    }

                    var v = plans[(*cand)[m]]->_home
                    if EmitPlan::_reaches(&reach, u, v) && !EmitPlan::_reaches(&reach, v, u) {
                        below = true
                        break
                    }
                }

                if !below {
                    pick = (*cand)[k]
                }
            }

            if pick == usize::MAX {
                pick = (*cand)[0]
            }

            for var ie: unsafe *InstanceEntry in gmembers[g] {
                _HOMES.try_emplace(ie as usize as u64, plans[pick]->_home)
            }
        }
    }
}
