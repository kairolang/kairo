/// --- The Kairo Project ----------------- Analyzer/Server/DeclTables.k --- ///
///
///   The declaration tables of an entry's graph, decoded: what completion
///   reads instead of running the compiler.
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

import DocumentStore::fnv1a
import Index::Snapshot::*
import Json::{
    JSON_NONE,
    JsonDoc,
}

/// one file's declarations (Index/Tables.k writes them, Snapshot.k
/// names the columns), a column per array: a row is an index.
pub class DeclTable {
    pub var path:    string   = ""
    pub var mod:     string   = ""    ///< the file's module directory, "" for none
    pub var builtin: bool     = false
    pub var files:   [string]         ///< what `tfile` and a base's file index

    pub var name:   [string]
    pub var kind:   [i64]
    pub var parent: [i64]
    pub var off:    [i64]
    pub var line:   [i64]
    pub var ch:     [i64]
    pub var vis:    [i64]
    pub var flags:  [i64]
    pub var detail: [string]
    pub var tfile:  [i64]
    pub var toff:   [i64]
    pub var efile:  [i64]    ///< DC_EFILE: what a subscript of the value is, as `tfile`
    pub var eoff:   [i64]

    /// TB_* rows, four numbers each.
    pub var bases: [i64]
    /// XB_* rows, four numbers each.
    pub var xb: [i64]

    /// A declared name's byte offset -> its row.
    pub var by_off: {u64: u32}

    pub fn DeclTable(self) = default

    pub fn rows(self) -> usize {
        return self.name.size()
    }

    /// The row declared at byte `off`, or -1.
    pub fn row_at(self, off: i64) -> i64 {
        if off < 0 {
            return -1
        }

        var hit = self.by_off.get(off as u64)
        if hit == null {
            return -1
        }

        return (*hit) as i64
    }

    /// The row declared at (`line`, `ch`), as a ref row names a
    /// declaration, or -1.
    pub fn row_at_pos(self, line: i64, ch: i64) -> i64 {
        for var r: usize = 0; r < self.name.size(); ++r {
            if (self.line[r] == line) && (self.ch[r] == ch) && (self.off[r] >= 0) {
                return r as i64
            }
        }

        return -1
    }

    /// Reads table node `n` of `d`.
    pub fn read(self, d: *const JsonDoc, n: u32) {
        self.path    = d->get_str(n, SK_PATH)
        self.mod     = d->get_str(n, SK_MOD)
        self.builtin = d->get_bool(n, SK_BUILTIN)
        var f = d->first(d->get(n, SK_FILES))
        while f != JSON_NONE() {
            self.files.push(d->str(f))
            f = d->next(f)
        }

        var r = d->first(d->get(n, SK_DECLS))
        while r != JSON_NONE() {
            // the DC_* columns, in order
            var c = d->first(r)
            self.name.push(d->str(c))
            c = d->next(c)
            self.kind.push(d->as_int(c))
            c = d->next(c)
            self.parent.push(d->as_int(c))
            c = d->next(c)
            var off = d->as_int(c)
            self.off.push(off)
            c = d->next(c)
            self.line.push(d->as_int(c))
            c = d->next(c)
            self.ch.push(d->as_int(c))
            c = d->next(c)
            self.vis.push(d->as_int(c))
            c = d->next(c)
            self.flags.push(d->as_int(c))
            c = d->next(c)
            self.detail.push(d->str(c))
            c = d->next(c)
            self.tfile.push(d->as_int(c))
            c = d->next(c)
            self.toff.push(d->as_int(c))
            c = d->next(c)
            self.efile.push(
                if (c == JSON_NONE()) => (-1 as i64) else => (d->as_int(c)),
            )

            if c != JSON_NONE() {
                c = d->next(c)
            }

            self.eoff.push(
                if (c == JSON_NONE()) => (-1 as i64) else => (d->as_int(c)),
            )

            if off >= 0 {
                self.by_off[off as u64] = (self.name.size() - 1) as u32
            }

            r = d->next(r)
        }

        var b = d->first(d->get(n, SK_TBASES))
        while b != JSON_NONE() {
            var c = d->first(b)
            while c != JSON_NONE() {
                self.bases.push(d->as_int(c))
                c = d->next(c)
            }

            b = d->next(b)
        }

        var x = d->first(d->get(n, SK_XB))
        while x != JSON_NONE() {
            var c = d->first(x)
            while c != JSON_NONE() {
                self.xb.push(d->as_int(c))
                c = d->next(c)
            }

            x = d->next(x)
        }
    }

    /// Whether the bounded `extend` block at byte `eoff` of file `epath`
    /// holds for the type of row `r`: 1, 0, or -1 when no row says.
    pub fn bound_holds(self, r: i64, const epath: string, eoff: i64) -> i64 {
        var x: usize = 0
        while (x + 3) < self.xb.size() {
            if (self.xb[x] == r)
                && (self.xb[x + 2] == eoff)
                && (self.xb[x + 1] >= 0)
                && ((self.xb[x + 1] as usize) < self.files.size())
                && (self.files[self.xb[x + 1] as usize] == epath) {
                return self.xb[x + 3]
            }

            x += 4
        }

        return -1
    }
}

/// A row of some table: which table, which row. `t` is usize::MAX for none.
pub struct RowRef {
    var t: usize = usize::MAX
    var r: i64   = -1
}

/// every table of one entry's graph, by path.
///
/// A snapshot brings the tables of the files its worker walked
/// since the last one the server installed (LiveWorker.k,
/// live_snapshot), or all of them (a run, a first answer):
/// `merge` replaces a path's table or adds it.
pub class DeclTables {
    pub var t: [DeclTable]

    /// fnv1a(path) -> index into `t` (the path is compared on a hit).
    var by_path_: {u64: u32}

    /// Every DF_EXT row, as (table << 32) | row: the `extend` blocks of the
    /// graph. Found again after a merge (few, and a scan of flags).
    var exts_:       [u64]
    var exts_stale_: bool  = true

    pub fn DeclTables(self) = default

    pub fn clear(self) {
        self.t.clear()
        self.by_path_.clear()
        self.exts_.clear()
        self.exts_stale_ = true
    }

    /// Index of `path`'s table, or usize::MAX.
    pub fn find(self, const path: string) -> usize {
        var hit = self.by_path_.get(fnv1a(path))
        if (hit != null) && (self.t[(*hit) as usize].path == path) {
            return (*hit) as usize
        }

        // Two paths with one hash: the second is not in the map.
        if hit != null {
            for var i: usize = 0; i < self.t.size(); ++i {
                if self.t[i].path == path {
                    return i
                }
            }
        }

        return usize::MAX
    }

    /// Takes the tables of snapshot `d`: all of them replace what is held
    /// when the snapshot says it has every file's. Returns how many came.
    pub fn merge(self, d: *const JsonDoc) -> usize {
        var arr = d->get(d->root, SK_TABLES)
        if arr == JSON_NONE() {
            return 0
        }

        if d->get_bool(d->root, SK_TABLES_ALL) && (d->first(arr) != JSON_NONE()) {
            // Every table the check made is in the snapshot. A file of the
            // graph it made none for keeps the one of its last check: a
            // file left unchecked (a syntax error in it or in an import),
            // one whose check stopped before Sema (an import that does not
            // resolve yet), every file when the run made none at all. It
            // would otherwise lose its own names until it is checked
            // again. A file that LEFT the graph loses its table.
            var deps: {u64: u32}
            var dn               = d->first(d->get(d->root, SK_DEPS))
            while dn != JSON_NONE() {
                deps[fnv1a(d->str(dn))] = 1
                dn                      = d->next(dn)
            }

            // Tables are moved out (a table is large and has no copy), kept
            // in their order, and the ones of files still in the graph are
            // put back.
            var held: [DeclTable]
            while self.t.size() > 0 {
                var x = self.t.pop()
                if x? {
                    held.push(x)
                }
            }

            self.clear()
            while held.size() > 0 {
                var x = held.pop()
                if x? {
                    var h = fnv1a(x.path)
                    if deps.get(h) != null {
                        if self.by_path_.get(h) == null {
                            self.by_path_[h] = self.t.size() as u32
                        }

                        self.t.push(x)
                    }
                }
            }
        }

        var n: usize = 0
        var x        = d->first(arr)
        while x != JSON_NONE() {
            var nt = DeclTable()
            nt.read(d, x)
            var at = self.find(nt.path)
            if at == usize::MAX {
                var h = fnv1a(nt.path)
                if self.by_path_.get(h) == null {
                    self.by_path_[h] = self.t.size() as u32
                }

                self.t.push(nt)
            } else {
                self.t[at] = nt
            }

            n += 1
            x = d->next(x)
        }

        if n > 0 {
            self.exts_stale_ = true
        }

        return n
    }

    /// The row `tfile` / `toff` of table `ti` names (a type, a base, an
    /// alias's declaration), or none: a C or C++ declaration, a file the
    /// graph has no table of.
    pub fn follow(self, ti: usize, tfile: i64, toff: i64) -> RowRef {
        var out = RowRef{}
        if (ti >= self.t.size()) || (tfile < 0) || ((tfile as usize) >= self.t[ti].files.size()) {
            return out
        }

        var to = self.find(self.t[ti].files[tfile as usize])
        if to == usize::MAX {
            return out
        }

        var r = self.t[to].row_at(toff)
        if r < 0 {
            return out
        }

        out.t = to
        out.r = r
        return out
    }

    /// The `extend` blocks of the graph, as (table << 32) | row.
    pub fn extensions(self) -> *const [u64] {
        if self.exts_stale_ {
            self.exts_.clear()
            for var i: usize = 0; i < self.t.size(); ++i {
                for var r: usize = 0; r < self.t[i].flags.size(); ++r {
                    if (self.t[i].flags[r] & DF_EXT) != 0 {
                        self.exts_.push(((i as u64) << 32) | (r as u64))
                    }
                }
            }

            self.exts_stale_ = false
        }

        return const &self.exts_
    }

    /// Whether class row `d` reaches class row `base` through `derives`
    /// edges (not itself).
    pub fn derives_from(self, d: RowRef, base: RowRef, depth: u32) -> bool {
        if (d.t >= self.t.size()) || (depth > 16) {
            return false
        }

        var *tb       = &self.t[d.t]
        var b:  usize = 0
        while (b + 3) < tb->bases.size() {
            // TB_ROW, TB_FILE, TB_OFF, TB_VIS
            if tb->bases[b] == d.r {
                var to = self.follow(d.t, tb->bases[b + 1], tb->bases[b + 2])
                if to.t != usize::MAX {
                    if ((to.t == base.t) && (to.r == base.r))
                        || self.derives_from(to, base, depth + 1) {
                        return true
                    }
                }
            }

            b += 4
        }

        return false
    }
}
