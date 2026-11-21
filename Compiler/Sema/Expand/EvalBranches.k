/// --- The Kairo Project ------------------- Sema/Expand/EvalBranches.k --- ///
///
/// The declarations an `eval if` deferred on a type fact holds, by
/// branch: which of them never coexist, and which scopes still
/// wait for their member set.
///
///   \detail
///     Compiler/Spec/Eval.md#deferred-conditions. A declaration-scope `eval if` whose condition reads a
///     type fact cannot be decided in phase E, before types are resolved.
///     EvalIfFolding leaves it in place with every branch indexed (the
///     parser indexed them all) and files it here; EvalIfLateFolding decides
///     it after T and RedeclMerge (EvalIfFolding::run_late).
///
///     Until then N, T and RedeclMerge see every branch. Two declarations in
///     different branches of one such `eval if` never both exist, so they
///     are never a redefinition (N(a)) and never one entity (R(a)): both ask
///     `exclusive` before judging a cell. One rule, keyed on the `eval if`
///     (its head ConditionalStmt) and the branch (its CompoundStmt).
///
///     A row per (declaration, enclosing deferred `eval if`): a declaration
///     in one nested inside another's branch has a row for each, and two
///     declarations exclude each other when any one `eval if` holds them in
///     different branches. Linear scans: deferred `eval if`s are rare and
///     short, and the cells N(a) and R(a) ask about hold a few entries; a TU
///     with none pays one size test per multi-entry cell.
///
///     `pending_in` and `in_pending` are the late fold's: a record whose own
///     body still holds an undecided `eval if` has no final member set, so a
///     fact about it waits; so does a name declared only in such branches.
///
///   Phase: EXPAND (filed), RESOLVE (read by N(a) and R(a); retired by the
///          late fold)
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import AST::Context::DeclContext::DeclContext
import AST::Node::Base::{
    Decl,
    Stmt,
}

/// A deferred `eval if`: its head statement, the scope its branches
/// declare into, and whether it is decided (or discarded with a branch of
/// another one).
struct EvalIfRow {
    var head:  unsafe *Stmt        = &null
    var owner: unsafe *DeclContext = &null
    var done:  bool                = false
}

/// A declaration, the index of its `eval if` in EvalBranchTable's `_ifs`,
/// and the branch of that `eval if` it sits in.
struct EvalDeclRow {
    var decl: unsafe *Decl = &null
    var at:   usize        = 0
    var arm:  unsafe *Stmt = &null
}

pub class EvalBranchTable {
    priv var _ifs:   [EvalIfRow]
    priv var _decls: [EvalDeclRow]

    fn EvalBranchTable(self) { }

    /// File `head`, whose branches declare into `owner`; its index.
    fn add_if(self, head: unsafe *Stmt, owner: unsafe *DeclContext) -> usize {
        var r = EvalIfRow{}
        r.head  = head
        r.owner = owner
        self._ifs.push(r)
        return self._ifs.size() - 1
    }

    /// `d` sits in branch `arm` of the `eval if` filed at `at`.
    fn add_decl(self, at: usize, arm: unsafe *Stmt, d: unsafe *Decl) {
        var r = EvalDeclRow{}
        r.decl = d
        r.at   = at
        r.arm  = arm
        self._decls.push(r)
    }

    /// `head` is decided, or gone with a discarded branch: it holds nothing
    /// back any more. A head never filed is ignored.
    fn retire(self, head: unsafe *Stmt) {
        for var i: usize = 0; i < self._ifs.size(); ++i {
            if self._ifs[i].head == head {
                self._ifs[i].done = true
            }
        }
    }

    /// Any declaration filed at all: the fast "no" for N(a) and R(a).
    fn has_rows(self) -> bool {
        return self._decls.size() > 0
    }

    /// How many filed `eval if`s are still undecided.
    pub fn pending(self) -> usize {
        var n: usize = 0
        for var i: usize = 0; i < self._ifs.size(); ++i {
            if !self._ifs[i].done {
                n += 1
            }
        }

        return n
    }

    /// An undecided `eval if` declares into `dc`: its member set is open.
    fn pending_in(self, dc: unsafe *DeclContext) -> bool {
        if dc == &null {
            return false
        }

        for var i: usize = 0; i < self._ifs.size(); ++i {
            if !self._ifs[i].done && self._ifs[i].owner == dc {
                return true
            }
        }

        return false
    }

    /// `d` sits in a branch of an undecided `eval if`: it may yet be
    /// discarded.
    fn in_pending(self, d: unsafe *Decl) -> bool {
        for var i: usize = 0; i < self._decls.size(); ++i {
            if self._decls[i].decl == d && !self._ifs[self._decls[i].at].done {
                return true
            }
        }

        return false
    }

    /// `a` and `b` sit in different branches of one filed `eval if`, so at
    /// most one of them is ever declared.
    fn exclusive(self, a: unsafe *Decl, b: unsafe *Decl) -> bool {
        if self._decls.size() == 0 || a == &null || b == &null || a == b {
            return false
        }

        for var i: usize = 0; i < self._decls.size(); ++i {
            if self._decls[i].decl != a {
                continue
            }

            for var j: usize = 0; j < self._decls.size(); ++j {
                if self._decls[j].decl != b {
                    continue
                }

                if self._decls[i].at == self._decls[j].at
                    && self._decls[i].arm != self._decls[j].arm {
                    return true
                }
            }
        }

        return false
    }
}
