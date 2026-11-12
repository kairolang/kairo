/// --- The Kairo Project -------------------- Sema/Incremental/Plan.k --- ///
///
///   \brief Incremental Sema's invalidation rules, in the compiler
///          (Compiler/Spec/IncrementalSema.md#invalidation-rules): from the
///          facts a previous run stored per module (its interface and its
///          dependency rows) and the interfaces of the present run, the set
///          of modules that must be re-checked, each with the rule that put
///          it there.
///
///   This is M(m) evaluated over the stored rows: what Scripts/incr_oracle.py
///   computes in Python from the two dumps, on the same rules R0 to R7, so
///   the two can be compared scenario by scenario. Nothing here touches a
///   tree: the input is strings, the output is a list. The driver prints it
///   (--print-incr-plan) and, under --incr-verify, proves it against the
///   full run it sits beside (incr_plan_verify). No result is reused on its
///   strength yet, so a hole in the rules is a failed verification and never
///   a wrong build.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "llvm/ADT/StringMap.h"
ffi "c++" import "llvm/ADT/StringSet.h"
ffi "c++" import "Native/KShims.hh"
ffi "c++" import "Native/Types.hh"
ffi "c++" import "vector"

/// Bumped by any change to a plan record's lines.
pub
const INCR_PLAN_SCHEMA: u32 = 1

/// Between the items of a list inside one field (a declaration's refs, a
/// scope's names). No identifier, written type or path holds it.
pub fn plan_list_sep() -> string {
    return "\x1f"
}

pub fn plan_split(const s: string, sep: u8) -> cxx::std::vector<string> {
    var out          = cxx::std::vector<string>()
    var start: usize = 0
    for var i: usize = 0; i < s.size(); ++i {
        if s[i] == sep {
            out.push_back(s.subslice(start, i - start))
            start = i + 1
        }
    }

    out.push_back(s.subslice(start, s.size() - start))
    return out
}

/// The items of a list field; none for an empty field.
pub fn plan_items(const s: string) -> cxx::std::vector<string> {
    if s.empty() {
        return cxx::std::vector<string>()
    }

    return plan_split(s, 31 as u8)
}

pub fn plan_join(v: *cxx::std::vector<string>, const sep: string) -> string {
    var out = ""
    for var i: usize = 0; i < v->size(); ++i {
        if i > 0 {
            out += sep
        }

        out += (*v)[i]
    }

    return out
}

fn plan_num(const s: string) -> usize {
    var n: usize = 0
    for var i: usize = 0; i < s.size(); ++i {
        if s[i] < ('0' as u8) || s[i] > ('9' as u8) {
            break
        }

        n = n * 10 + ((s[i] - ('0' as u8)) as usize)
    }

    return n
}

/// \class PlanModule
/// \brief What one run knows about one module, as the rules read it.
///
/// \details Every list is sorted. A line of the stored form is a one-letter
///          tag, a tab and the fields, tab-separated:
///            E  id, scope, name, I, body hash, extended type, refs
///            C  scope, extended type, names
///            S  a module of the surface
///            N  module, scope, name          (a name row)
///            O  module whose overlay, name   (an overlay row)
///            D  part, id                     (a declaration row)
///            F  a file the diagnostics name besides the module's own
///          then `diag <bytes>`, the diagnostics as the run rendered them,
///          and `end`.
pub class PlanModule {
    pub var name:    string                   = ""
    pub var path:    string                   = ""
    pub var hash:    string                   = "" ///< I(m)
    pub var macros:  string                   = ""
    pub var decls:   cxx::std::vector<string>
    pub var scopes:  cxx::std::vector<string>
    pub var surface: cxx::std::vector<string>
    pub var names:   cxx::std::vector<string>
    pub var overlay: cxx::std::vector<string>
    pub var rows:    cxx::std::vector<string>
    /// The module's own diagnostics, rendered, in delivery order.
    pub var diag: string = ""
    /// Files those diagnostics name a position in, the module's own left
    /// out: a note into another file is stale once that file's text moves.
    pub var diag_files: cxx::std::vector<string>

    pub fn PlanModule(self) = default

    pub fn render(self) -> string {
        var s = f"kairo-incr-plan {INCR_PLAN_SCHEMA}\n"
        s += "module " + self.name + "\n"
        s += "path " + self.path + "\n"
        s += "hash " + self.hash + "\n"
        s += "macros " + self.macros + "\n"
        for var l: string in self.decls {
            s += "E\t" + l + "\n"
        }

        for var l: string in self.scopes {
            s += "C\t" + l + "\n"
        }

        for var l: string in self.surface {
            s += "S\t" + l + "\n"
        }

        for var l: string in self.names {
            s += "N\t" + l + "\n"
        }

        for var l: string in self.overlay {
            s += "O\t" + l + "\n"
        }

        for var l: string in self.rows {
            s += "D\t" + l + "\n"
        }

        for var l: string in self.diag_files {
            s += "F\t" + l + "\n"
        }

        s += f"diag {self.diag.size()}\n" + self.diag + "\nend\n"
        return s
    }

    /// false for a record of another schema or a damaged one.
    pub fn parse(self, const text: string) -> bool {
        var head = f"kairo-incr-plan {INCR_PLAN_SCHEMA}\n"
        if (!text.starts_with(head)) || !text.ends_with("\nend\n") {
            return false
        }

        var at: usize = head.size()
        var n         = text.size()
        while at < n {
            var e = at
            while e < n && text[e] != ('\n' as u8) {
                e += 1
            }

            var l = text.subslice(at, e - at)
            at = e + 1
            if l.starts_with("diag ") {
                var len = plan_num(l.subslice(5, l.size() - 5))
                if at + len + 5 != n {
                    return false
                }

                self.diag = text.subslice(at, len)
                return true
            }

            if l.size() >= 2 && l[1] == (9 as u8) {
                var body = l.subslice(2, l.size() - 2)
                var tag  = l[0]
                if tag == ('E' as u8) {
                    self.decls.push_back(body)
                } else if tag == ('C' as u8) {
                    self.scopes.push_back(body)
                } else if tag == ('S' as u8) {
                    self.surface.push_back(body)
                } else if tag == ('N' as u8) {
                    self.names.push_back(body)
                } else if tag == ('O' as u8) {
                    self.overlay.push_back(body)
                } else if tag == ('D' as u8) {
                    self.rows.push_back(body)
                } else if tag == ('F' as u8) {
                    self.diag_files.push_back(body)
                } else {
                    return false
                }
            } else if l.starts_with("module ") {
                self.name = l.subslice(7, l.size() - 7)
            } else if l.starts_with("path ") {
                self.path = l.subslice(5, l.size() - 5)
            } else if l.starts_with("hash ") {
                self.hash = l.subslice(5, l.size() - 5)
            } else if l.starts_with("macros ") {
                self.macros = l.subslice(7, l.size() - 7)
            } else {
                return false
            }
        }

        return false
    }
}

/// What PlanLists::get answers for a key it does not hold: a list that is
/// there and empty is not a list that is not there (a name a scope declares
/// through a C++ binding has no entry and still exists).
fn plan_absent() -> string {
    return "?absent"
}

/// \class PlanLists
/// \brief key -> list of strings, compared as one sorted, joined string.
class PlanLists {
    var index: llvm::StringMap<u32>
    var keys:  cxx::std::vector<string>
    var vals:  cxx::std::vector<cxx::std::vector<string>>
    var text:  cxx::std::vector<string>

    fn PlanLists(self) = default

    fn slot(self, const k: string) -> usize {
        var it = self.index.find(kairo::sref(k))
        if it != self.index.end() {
            return it->second as usize
        }

        var id = self.keys.size() as u32
        self.keys.push_back(k)
        self.vals.push_back(cxx::std::vector<string>())
        self.index.try_emplace(kairo::sref(k), id)
        return id as usize
    }

    fn add(self, const k: string, const v: string) {
        var at = self.slot(k)
        self.vals[at].push_back(v)
    }

    /// Sorts every list and fixes its text. Nothing is added afterwards.
    fn seal(self) {
        self.text.clear()
        for var i: usize = 0; i < self.vals.size(); ++i {
            llvm::sort(self.vals[i].begin(), self.vals[i].end())
            self.text.push_back(plan_join(&self.vals[i], "\n"))
        }
    }

    fn at(self, const k: string) -> usize {
        var it = self.index.find(kairo::sref(k))
        if it == self.index.end() {
            return usize::MAX
        }

        return it->second as usize
    }

    fn has(self, const k: string) -> bool {
        return self.at(k) != usize::MAX
    }

    fn get(self, const k: string) -> string {
        var i = self.at(k)
        if i == usize::MAX {
            return plan_absent()
        }

        return self.text[i]
    }

    /// The key is absent or its list is empty.
    fn none(self, const k: string) -> bool {
        var i = self.at(k)
        return i == usize::MAX || self.vals[i].empty()
    }
}

/// \class PlanIndex
/// \brief One run's interfaces, indexed the way the rules ask.
class PlanIndex {
    var names:  PlanLists ///< module \t scope \t name -> [id \x1e I]
    var bodies: PlanLists ///< module \t scope \t name -> [id \x1e body]
    var ext:    PlanLists ///< extended type \t name -> [id \x1e I]
    var decl_i: PlanLists ///< id -> [I]
    var decl_b: PlanLists ///< id -> [body]
    var refs:   PlanLists ///< id -> ids its types name
    var surf:   PlanLists ///< module -> its surface
    /// extension scope id -> extended type
    var ext_of:   llvm::StringMap<u32>
    var ext_of_v: cxx::std::vector<string>
    /// module \t name, for every name at a module's file scope
    var file_names: llvm::StringSet<llvm::MallocAllocator>
    var modules:    cxx::std::vector<string>
    var macros:     llvm::StringMap<u32>
    var macros_v:   cxx::std::vector<string>

    fn PlanIndex(self) = default

    fn build(self, mods: *cxx::std::vector<PlanModule>) {
        for var mi: usize = 0; mi < mods->size(); ++mi {
            var *m = &(*mods)[mi]
            self.modules.push_back(m->name)
            self.macros.try_emplace(
                kairo::sref(m->name),
                self.macros_v.size() as u32,
            )

            self.macros_v.push_back(m->macros)
            self.surf.slot(m->name)
            for var s: string in m->surface {
                self.surf.add(m->name, s)
            }

            for var l: string in m->decls {
                var f = plan_split(l, 9 as u8)
                if f.size() < 7 {
                    continue
                }

                var key = m->name + "\t" + f[1] + "\t" + f[2]
                self.names.add(key, f[0] + "\x1e" + f[3])
                self.bodies.add(key, f[0] + "\x1e" + f[4])
                if !f[5].empty() {
                    self.ext.add(f[5] + "\t" + f[2], f[0] + "\x1e" + f[3])
                }

                self.decl_i.add(f[0], f[3])
                self.decl_b.add(f[0], f[4])
                self.refs.slot(f[0])
                for var r: string in plan_items(f[6]) {
                    self.refs.add(f[0], r)
                }
            }

            for var l: string in m->scopes {
                var f = plan_split(l, 9 as u8)
                if f.size() < 3 {
                    continue
                }

                if !f[1].empty() {
                    var it = self.ext_of.find(kairo::sref(f[0]))
                    if it == self.ext_of.end() {
                        self.ext_of.try_emplace(
                            kairo::sref(f[0]),
                            self.ext_of_v.size() as u32,
                        )

                        self.ext_of_v.push_back(f[1])
                    } else {
                        self.ext_of_v[it->second as usize] = f[1]
                    }
                }

                for var nm: string in plan_items(f[2]) {
                    if f[0].empty() {
                        self.file_names.insert(kairo::sref(m->name + "\t" + nm))
                    }

                    // A name a scope declares with no entry of this file (a
                    // C++ binding) still exists: its presence can change.
                    self.names.slot(m->name + "\t" + f[0] + "\t" + nm)
                }
            }
        }

        self.names.seal()
        self.bodies.seal()
        self.ext.seal()
        self.decl_i.seal()
        self.decl_b.seal()
        self.refs.seal()
        self.surf.seal()
    }

    fn macros_of(self, const m: string) -> string {
        var it = self.macros.find(kairo::sref(m))
        if it == self.macros.end() {
            return ""
        }

        return self.macros_v[it->second as usize]
    }

    fn ext_target(self, const scope: string, @inout out: string) -> bool {
        var it = self.ext_of.find(kairo::sref(scope))
        if it == self.ext_of.end() {
            return false
        }

        out = self.ext_of_v[it->second as usize]
        return true
    }

    fn declares(self, const m: string, const name: string) -> bool {
        return self.file_names.contains(kairo::sref(m + "\t" + name))
    }
}

/// \class PlanDiff
/// \brief What changed between two indexes, as the sets the rules test.
class PlanDiff {
    var names:       llvm::StringSet<llvm::MallocAllocator> ///< module \t scope \t name
    var ext:         llvm::StringSet<llvm::MallocAllocator> ///< extended type \t name
    var sig:         llvm::StringSet<llvm::MallocAllocator> ///< id
    var body:        llvm::StringSet<llvm::MallocAllocator> ///< id
    var layout:      llvm::StringSet<llvm::MallocAllocator> ///< id, closed over refs
    var name_bodies: llvm::StringSet<llvm::MallocAllocator> ///< module \t scope \t name
    var macros:      llvm::StringSet<llvm::MallocAllocator> ///< module
    /// name \t module: the name's declarations at that module's file scope changed.
    var file_changed:   llvm::StringSet<llvm::MallocAllocator>
    var file_changed_n: llvm::StringSet<llvm::MallocAllocator> ///< name alone
    /// name -> modules at whose file scope it appeared or disappeared.
    var presence: PlanLists
    /// name \t module, and the name alone: a body under that name changed.
    var body_scope:   llvm::StringSet<llvm::MallocAllocator>
    var body_scope_n: llvm::StringSet<llvm::MallocAllocator>

    fn PlanDiff(self) = default

    priv fn _presence(self, const key: string) {
        var f = plan_split(key, 9 as u8)
        if f.size() != 3 || !f[1].empty() {
            return
        }

        var at = self.presence.slot(f[2])
        for var have: string in self.presence.vals[at] {
            if have == f[0] {
                return
            }
        }

        self.presence.vals[at].push_back(f[0])
    }

    priv fn _lists(self, a: *PlanLists, b: *PlanLists, which: u8) {
        for var side: usize = 0; side < 2; ++side {
            var *x = if (side == 0) => (a) else => b
            for var i: usize = 0; i < x->keys.size(); ++i {
                var k = x->keys[i]
                if a->get(k) == b->get(k) {
                    continue
                }

                if which == 0 {
                    self.names.insert(kairo::sref(k))
                } else if which == 1 {
                    self.ext.insert(kairo::sref(k))
                } else if which == 2 {
                    self.sig.insert(kairo::sref(k))
                } else if which == 3 {
                    self.body.insert(kairo::sref(k))
                } else {
                    self.name_bodies.insert(kairo::sref(k))
                }
            }
        }
    }

    fn build(self, a: *PlanIndex, b: *PlanIndex) {
        self._lists(&a->names, &b->names, 0)
        self._lists(&a->ext, &b->ext, 1)
        self._lists(&a->decl_i, &b->decl_i, 2)
        self._lists(&a->decl_b, &b->decl_b, 3)
        self._lists(&a->bodies, &b->bodies, 4)

        // Layout: closed over the records a layout names, in either version.
        // Walked from the changed signatures along the reversed refs.
        var rev = PlanLists()
        for var side: usize = 0; side < 2; ++side {
            var *x = if (side == 0) => (&a->refs) else => &b->refs
            for var i: usize = 0; i < x->keys.size(); ++i {
                for var r: string in x->vals[i] {
                    rev.add(r, x->keys[i])
                }
            }
        }

        var work = cxx::std::vector<string>()
        for var side: usize = 0; side < 2; ++side {
            var *x = if (side == 0) => (&a->decl_i) else => &b->decl_i
            for var i: usize = 0; i < x->keys.size(); ++i {
                var k = x->keys[i]
                if self.sig.contains(kairo::sref(k)) && !self.layout.contains(kairo::sref(k)) {
                    self.layout.insert(kairo::sref(k))
                    work.push_back(k)
                }
            }
        }

        while !work.empty() {
            var cur = work.back()
            work.pop_back()
            var at = rev.at(cur)
            if at == usize::MAX {
                continue
            }

            for var dep: string in rev.vals[at] {
                if !self.layout.contains(kairo::sref(dep)) {
                    self.layout.insert(kairo::sref(dep))
                    work.push_back(dep)
                }
            }
        }

        // File-scope names: which changed, and which appeared or went.
        for var side: usize = 0; side < 2; ++side {
            var *x = if (side == 0) => (&a->names) else => &b->names
            for var i: usize = 0; i < x->keys.size(); ++i {
                var k = x->keys[i]
                if !self.names.contains(kairo::sref(k)) {
                    continue
                }

                var f = plan_split(k, 9 as u8)
                if f.size() != 3 || !f[1].empty() {
                    continue
                }

                self.file_changed.insert(kairo::sref(f[2] + "\t" + f[0]))
                self.file_changed_n.insert(kairo::sref(f[2]))
                if a->names.has(k) != b->names.has(k) || a->names.none(k) != b->names.none(k) {
                    self._presence(k)
                }
            }

            var *bx = if (side == 0) => (&a->bodies) else => &b->bodies
            for var i: usize = 0; i < bx->keys.size(); ++i {
                var k = bx->keys[i]
                if !self.name_bodies.contains(kairo::sref(k)) {
                    continue
                }

                var f = plan_split(k, 9 as u8)
                if f.size() == 3 && f[1].empty() {
                    self.body_scope.insert(kairo::sref(f[2] + "\t" + f[0]))
                    self.body_scope_n.insert(kairo::sref(f[2]))
                }
            }
        }

        // A name in one version's file-scope set and not in the other's.
        for var side: usize = 0; side < 2; ++side {
            var *x = if (side == 0) => (a) else => b
            var *y = if (side == 0) => (b) else => a
            for var i: usize = 0; i < x->names.keys.size(); ++i {
                var f = plan_split(x->names.keys[i], 9 as u8)
                if f.size() != 3 || !f[1].empty() {
                    continue
                }

                if x->declares(f[0], f[2]) != y->declares(f[0], f[2]) {
                    self._presence(x->names.keys[i])
                }
            }
        }

        for var side: usize = 0; side < 2; ++side {
            var *x = if (side == 0) => (a) else => b
            for var m: string in x->modules {
                if a->macros_of(m) != b->macros_of(m) {
                    self.macros.insert(kairo::sref(m))
                }
            }
        }
    }
}

/// \class IncrPlan
/// \brief The modules to re-check, in the order the rules found them, each
///        with the first rule that names it.
pub class IncrPlan {
    pub var  mods: cxx::std::vector<string>
    pub var  why:  cxx::std::vector<string>
    priv var _in:  llvm::StringSet<llvm::MallocAllocator>

    pub fn IncrPlan(self) = default

    pub fn has(self, const m: string) -> bool {
        return self._in.contains(kairo::sref(m))
    }

    pub fn add(self, const m: string, const reason: string) {
        if self.has(m) {
            return
        }

        self._in.insert(kairo::sref(m))
        self.mods.push_back(m)
        self.why.push_back(reason)
    }
}

/// The modules of \p a and \p b are the same set.
pub fn incr_plan_same_graph(a: *cxx::std::vector<PlanModule>,
                            b: *cxx::std::vector<PlanModule>) -> bool {
    if a->size() != b->size() {
        return false
    }

    var have = llvm::StringSet<llvm::MallocAllocator>()
    for var i: usize = 0; i < a->size(); ++i {
        have.insert(kairo::sref((*a)[i].name))
    }

    for var i: usize = 0; i < b->size(); ++i {
        if !have.contains(kairo::sref((*b)[i].name)) {
            return false
        }
    }

    return true
}

/// The union of a module's surface in both versions.
fn plan_surface(a: *PlanIndex, b: *PlanIndex, const m: string) -> cxx::std::vector<string> {
    var out = cxx::std::vector<string>()
    var ia  = a->surf.at(m)
    if ia != usize::MAX {
        out = a->surf.vals[ia]
    }

    var ib = b->surf.at(m)
    if ib != usize::MAX {
        for var s: string in b->surf.vals[ib] {
            var seen = false
            for var h: string in out {
                if h == s {
                    seen = true
                    break
                }
            }

            if !seen {
                out.push_back(s)
            }
        }
    }

    return out
}

/// \brief the re-check set.
///
/// \param old      every module as the previous run recorded it (its rows
///                 are the ones evaluated).
/// \param now      every module as the present run found it: the same set
///                 (incr_plan_same_graph); only interfaces and surfaces are
///                 read.
/// \param edited   the modules whose text changed (R0).
/// \param changed  the paths of those files (R8).
///
/// \details R0 to R7 are Scripts/incr_oracle.py's, line for line. R8 is this
///          function's own: a module whose recorded diagnostics name a
///          position in a file whose text changed is re-checked, because a
///          position is in no hash (open hole 1) and the note would be
///          replayed with a stale line. Its reason starts with "R8", which
///          is how a comparison with the oracle leaves it out.
pub fn incr_plan(old:     *cxx::std::vector<PlanModule>,
                 now:     *cxx::std::vector<PlanModule>,
                 edited:  *cxx::std::vector<string>,
                 changed: *cxx::std::vector<string>,
                 out:     *IncrPlan) {
    var ia = PlanIndex()
    var ib = PlanIndex()
    ia.build(old)
    ib.build(now)
    var d = PlanDiff()
    d.build(&ia, &ib)

    for var m: string in (*edited) {
        out->add(m, "R0 edited")
    }

    for var mi: usize = 0; mi < old->size(); ++mi {
        var *f = &(*old)[mi]
        var m  = f->name
        if out->has(m) {
            continue
        }

        var reason = ""
        // R1: a name row whose declarations differ; a row on a type's scope
        // also reads the same-named members of every extension of the type.
        for var r: string in f->names {
            if d.names.contains(kairo::sref(r)) {
                var k = plan_split(r, 9 as u8)
                var where_ = if (k.size() == 3 && !k[1].empty()) => (k[1]) else => k[0] + "#<file>"
                reason = "R1 name " + (if (k.size() == 3) => (k[2]) else => r) + " in " + where_
                break
            }

            var k = plan_split(r, 9 as u8)
            if k.size() == 3 && !k[1].empty() {
                var target = k[1]
                if !ia.ext_target(k[1], &target) {
                    ib.ext_target(k[1], &target)
                }

                if d.ext.contains(kairo::sref(target + "\t" + k[2])) {
                    reason = "R1 extension member " + k[2] + " of " + target
                    break
                }
            }
        }

        // R2: an overlay row, and a file of that overlay's surface changed
        // the name at file scope; or the surface itself changed.
        if reason.empty() {
            for var o: string in f->overlay {
                var k = plan_split(o, 9 as u8)
                if k.size() != 2 {
                    continue
                }

                if ia.surf.get(k[0]) != ib.surf.get(k[0]) {
                    reason = "R2 surface of " + k[0] + " changed"
                    break
                }

                if !d.file_changed_n.contains(kairo::sref(k[1])) {
                    continue
                }

                var si = ia.surf.at(k[0])
                if si == usize::MAX {
                    continue
                }

                for var s: string in ia.surf.vals[si] {
                    if d.file_changed.contains(kairo::sref(k[1] + "\t" + s)) {
                        reason = "R2 overlay name " + k[1] + " via " + s
                        break
                    }
                }

                if !reason.empty() {
                    break
                }
            }
        }

        // R3: a declaration row.
        if reason.empty() {
            for var r: string in f->rows {
                var cut: usize = 0
                while cut < r.size() && r[cut] != (9 as u8) {
                    cut += 1
                }

                if cut >= r.size() {
                    continue
                }

                var part = r.subslice(0, cut)
                var id   = r.subslice(cut + 1, r.size() - cut - 1)
                if part == "sig" && d.sig.contains(kairo::sref(id)) {
                    reason = "R3 signature of " + id
                } else if part == "layout" && d.layout.contains(kairo::sref(id)) {
                    reason = "R3 layout of " + id
                } else if part == "body"
                    && (d.body.contains(kairo::sref(id)) || d.sig.contains(kairo::sref(id))) {
                    reason = "R3 body of " + id
                }

                if !reason.empty() {
                    break
                }
            }
        }

        // R4: a name appeared at or went from the file scope of a file in
        // the surface while another file of it (or this one) declares it.
        if reason.empty() && !d.presence.keys.empty() {
            var surf = plan_surface(&ia, &ib, m)
            for var pi: usize = 0; pi < d.presence.keys.size() && reason.empty(); ++pi {
                var n     = d.presence.keys[pi]
                var *mods = &d.presence.vals[pi]
                var src   = ""
                for var s: string in surf {
                    for var pm: string in (*mods) {
                        if pm == s && (src.empty() || s < src) {
                            src = s
                        }
                    }
                }

                if src.empty() {
                    continue
                }

                var other = ""
                for var s: string in surf {
                    var in_src = false
                    for var pm: string in (*mods) {
                        if pm == s {
                            in_src = true
                            break
                        }
                    }

                    if in_src {
                        continue
                    }

                    if ia.declares(s, n) || ib.declares(s, n) {
                        other = s
                        break
                    }
                }

                if other.empty() && (ia.declares(m, n) || ib.declares(m, n)) {
                    other = m
                }

                if !other.empty() {
                    reason = "R4 import collision on " + n + " (" + src + " vs " + other + ")"
                }
            }
        }

        // R7: the macros of a file in the surface changed.
        if reason.empty() {
            for var s: string in plan_surface(&ia, &ib, m) {
                if d.macros.contains(kairo::sref(s)) {
                    reason = "R7 macros of " + s
                    break
                }
            }
        }

        if !reason.empty() {
            out->add(m, reason)
        }
    }

    // R6: the files that name a declaration whose body changed.
    var names_body = llvm::StringSet<llvm::MallocAllocator>()
    for var mi: usize = 0; mi < old->size(); ++mi {
        var *f  = &(*old)[mi]
        var hit = false
        for var r: string in f->names {
            if d.name_bodies.contains(kairo::sref(r)) {
                hit = true
                break
            }
        }

        for var oi: usize = 0; oi < f->overlay.size() && !hit; ++oi {
            var k = plan_split(f->overlay[oi], 9 as u8)
            if k.size() != 2 || !d.body_scope_n.contains(kairo::sref(k[1])) {
                continue
            }

            var si = ia.surf.at(k[0])
            if si == usize::MAX {
                continue
            }

            for var s: string in ia.surf.vals[si] {
                if d.body_scope.contains(kairo::sref(k[1] + "\t" + s)) {
                    hit = true
                    break
                }
            }
        }

        if hit {
            names_body.insert(kairo::sref(f->name))
        }
    }

    // R5 and R6, to a fixed point: a body row into a file that is itself
    // re-checked, or into one that names a changed body.
    var grew = true
    while grew {
        grew = false
        for var mi: usize = 0; mi < old->size(); ++mi {
            var *f = &(*old)[mi]
            if out->has(f->name) {
                continue
            }

            for var r: string in f->rows {
                if !r.starts_with("body\t") {
                    continue
                }

                var id         = r.subslice(5, r.size() - 5)
                var cut: usize = 0
                while cut < id.size() && id[cut] != ('#' as u8) {
                    cut += 1
                }

                var home = id.subslice(0, cut)
                if out->has(home) {
                    out->add(
                        f->name,
                        "R5 body of " + id + " in re-checked " + home,
                    )

                    grew = true
                    break
                }

                if names_body.contains(kairo::sref(home)) {
                    out->add(
                        f->name,
                        "R6 body of " + id + ", whose file names a changed body",
                    )

                    grew = true
                    break
                }
            }
        }
    }

    // R8: recorded diagnostics that name a position in a changed file.
    for var mi: usize = 0; mi < old->size(); ++mi {
        var *f = &(*old)[mi]
        if out->has(f->name) {
            continue
        }

        for var p: string in f->diag_files {
            var hit = false
            for var c: string in (*changed) {
                if c == p {
                    hit = true
                    break
                }
            }

            if hit {
                out->add(f->name, "R8 its diagnostics name a position in " + p)
                break
            }
        }
    }
}

/// \brief what the plan claims and a full run can check: every module it
///        leaves out has the interface and the diagnostics the previous run
///        recorded for it.
///
/// \return the number of modules for which that is false; \p first names
///         the first, with what differs.
pub fn incr_plan_verify(old:          *cxx::std::vector<PlanModule>,
                        now:          *cxx::std::vector<PlanModule>,
                        plan:         *IncrPlan,
                        @inout first: string) -> usize {
    var at = llvm::StringMap<u32>()
    for var i: usize = 0; i < now->size(); ++i {
        at.try_emplace(kairo::sref((*now)[i].name), i as u32)
    }

    var holes: usize = 0
    for var i: usize = 0; i < old->size(); ++i {
        var *a = &(*old)[i]
        if plan->has(a->name) {
            continue
        }

        var it = at.find(kairo::sref(a->name))
        if it == at.end() {
            continue
        }

        var *b   = &(*now)[it->second as usize]
        var what = ""
        if a->macros != b->macros
            || a->decls.size() != b->decls.size()
            || a->scopes.size() != b->scopes.size() {
            what = "interface"
        }

        for var k: usize = 0; what.empty() && k < a->decls.size(); ++k {
            if a->decls[k] != b->decls[k] {
                what = "interface"
            }
        }

        for var k: usize = 0; what.empty() && k < a->scopes.size(); ++k {
            if a->scopes[k] != b->scopes[k] {
                what = "interface"
            }
        }

        if what.empty() && a->diag != b->diag {
            what = "diagnostics"
        }

        if what.empty() {
            continue
        }

        holes += 1
        if first.empty() {
            first = a->name + ": predicted unaffected, but its " + what + " changed"
        }
    }

    return holes
}
