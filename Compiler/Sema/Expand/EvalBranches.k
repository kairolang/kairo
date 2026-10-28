/// --- The Kairo Project ------------------- Sema/Expand/EvalBranches.k --- ///
///
///   \brief The declarations an `eval if` deferred on a type fact holds, by
///          branch: which of them never coexist, and which scopes still
///          wait for their member set.
///
///   \detail
///     EVAL.md 4.2b. A declaration-scope `eval if` whose condition reads a
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
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import AST::Node::Base::*;
import AST::Context::DeclContext::*;

class EvalBranchTable {
    /// Per deferred `eval if`: its head statement, the scope its branches
    /// declare into, and whether it is decided (or discarded with a branch
    /// of another one).
    priv var _heads:  vec::<*Stmt>;
    priv var _owners: vec::<*DeclContext>;
    priv var _done:   vec::<bool>;
    /// Per row: a declaration, the index of its `eval if` in _heads, and the
    /// branch of that `eval if` it sits in.
    priv var _decls: vec::<*Decl>;
    priv var _ifs:   vec::<usize>;
    priv var _arms:  vec::<*Stmt>;

    fn EvalBranchTable(self) { }

    /// File \p head, whose branches declare into \p owner; its index.
    fn add_if(self, head: *Stmt, owner: *DeclContext) -> usize {
        self._heads.push_back(head);
        self._owners.push_back(owner);
        self._done.push_back(false);
        return self._heads.size() - 1;
    }

    /// \p d sits in branch \p arm of the `eval if` filed at \p at.
    fn add_decl(self, at: usize, arm: *Stmt, d: *Decl) {
        self._decls.push_back(d);
        self._ifs.push_back(at);
        self._arms.push_back(arm);
    }

    /// \p head is decided, or gone with a discarded branch: it holds nothing
    /// back any more. A head never filed is ignored.
    fn retire(self, head: *Stmt) {
        for var i: usize = 0; i < self._heads.size(); ++i {
            if self._heads[i] == head { self._done[i] = true; }
        }
    }

    /// Any declaration filed at all: the fast "no" for N(a) and R(a).
    fn has_rows(self) -> bool { return self._decls.size() > 0; }

    /// How many filed `eval if`s are still undecided.
    fn pending(self) -> usize {
        var n: usize = 0;
        for var i: usize = 0; i < self._done.size(); ++i {
            if !self._done[i] { n += 1; }
        }
        return n;
    }

    /// An undecided `eval if` declares into \p dc: its member set is open.
    fn pending_in(self, dc: *DeclContext) -> bool {
        if dc == &null { return false; }
        for var i: usize = 0; i < self._heads.size(); ++i {
            if (!self._done[i]) && (self._owners[i] == dc) { return true; }
        }
        return false;
    }

    /// \p d sits in a branch of an undecided `eval if`: it may yet be
    /// discarded.
    fn in_pending(self, d: *Decl) -> bool {
        for var i: usize = 0; i < self._decls.size(); ++i {
            if (self._decls[i] == d) && (!self._done[self._ifs[i]]) { return true; }
        }
        return false;
    }

    /// \p a and \p b sit in different branches of one filed `eval if`, so at
    /// most one of them is ever declared.
    fn exclusive(self, a: *Decl, b: *Decl) -> bool {
        if (self._decls.size() == 0) || (a == &null) || (b == &null) || (a == b) { return false; }
        for var i: usize = 0; i < self._decls.size(); ++i {
            if self._decls[i] != a { continue; }
            for var j: usize = 0; j < self._decls.size(); ++j {
                if self._decls[j] != b { continue; }
                if (self._ifs[i] == self._ifs[j]) && (self._arms[i] != self._arms[j]) { return true; }
            }
        }
        return false;
    }

    /// Every pair in \p ds is exclusive: a cell whose entries never coexist.
    fn all_exclusive(self, ds: *vec::<*Decl>) -> bool {
        if (ds == &null) || (ds->size() < 2) || (self._decls.size() == 0) { return false; }
        for var i: usize = 0; i < ds->size(); ++i {
            for var j: usize = i + 1; j < ds->size(); ++j {
                if !self.exclusive((*ds)[i], (*ds)[j]) { return false; }
            }
        }
        return true;
    }
}
