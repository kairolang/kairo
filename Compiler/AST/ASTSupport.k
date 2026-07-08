/// --- The Kairo Project ----------------------------- AST/ASTSupport.k --- ///
///
///   Provides shared utilities, types, and helper functions for the AST module.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///
/// Support code for the parser and related tools.  This is not intended to be
/// a general-purpose library, but rather a place for shared utilities that
/// are used across multiple parser components (e.g. the main parser, the
/// lexer, the AST printer, etc).

/// This contains:
///   - Common data strcutures, interfaces, and utilities for the parser and related tools.
///   - Also our custom RTTI system.

import AST::Context::ASTContext::*;
import Token::TokenKind::*;
import Memory::ArenaList::*;
import Location::SourceManager::*;
import Macro::Sentinel::*;
import Lexer::Immediate::*;
import Token::Token::*;
import Token::TokenText::*;

///
/// \class FrozenList<T>
/// \brief Non-owning, immutable view over a contiguous arena-allocated array.
///
/// Created by freezing an ArenaList<T> into the node arena via
/// ArenaList::freeze(). Once frozen, the array is fixedno push, no pop.
///
/// Lifetime: valid as long as the arena it was allocated from is alive.
/// The ASTContext's node_arena outlives all FrozenList instances.
///
/// Use this for all variable-length sequences inside AST nodes:
///   CompoundStmt::stmts
///   PathExpr::segments
///   ParamList::params
///   StringLiteralExpr::strings
///   ArgList::args
///   etc.
///
class <T> FrozenList {
    pub var items: *T    = &null;
    pub var count: usize = 0;
    pub var MAX:   usize = inline "c++" { (libcxx::numeric_limits<usize>::max)() };

    ///
    /// \brief Freeze an ArenaList into a FrozenList, allocating the
    /// contiguous backing array from the given arena.
    ///
    /// The ArenaList can be destroyed after this callthe FrozenList
    /// is fully independent.
    ///
    fn from_list(self, l: *ArenaList::<T>, arena: *ArenaAllocator) {
        self.count = l->size();
        self.items = l->freeze(arena);
    }

    fn from_vec(self, v: *vec::<T>, ctx: *ASTContext) {
        if (v == &null) || (v->size() == 0) {
            self.count = 0;
            self.items = &null;
            return;
        }

        self.count = v->size();
        self.items = ctx->alloc_array::<T>(self.count);
        for var i: usize = 0; i < self.count; ++i {
            self.items[i] = (*v)[i];
        }
    }

    fn from_buf(self, data: *T, count: usize, ctx: *ASTContext) {
        if count == 0 {
            self.count = 0;
            self.items = &null;
            return;
        }

        self.count = count;
        self.items = ctx->alloc_array::<T>(count);
        libcxx::memcpy(items, data, sizeof(T) * count);
    }

    fn begin(self) -> *T {
        return self.items;
    }

    fn end(self) -> *T {
        return self.items + self.count;
    }

    ///
    /// \brief Create directly from a raw pointer + count.
    /// Use when you already have an arena-allocated array.
    ///
    fn from_raw(self, items: *T, count: usize) {
        self.items = items;
        self.count = count;
    }

    ///
    /// \brief Empty FrozenListnull items, zero count.
    ///
    static fn empty() -> FrozenList::<T> {
        var fl: FrozenList::<T>;
        fl.items = &null;
        fl.count = 0;
        return fl;
    }

    ///
    /// \brief Bounds-checked element access. Returns null if OOB.
    ///
    fn get(self, index: usize) -> *T {
        if index >= self.count {
            return &null;
        }
        
        if self.items == &null {
            return &null;
        }

        return self.items + index;
    }

    ///
    /// \brief Bounds-checked subscript. Asserts if OOB.
    ///
    fn op [](self, index: usize) -> T {
        assert((index < self.count) && r"FrozenList index out of bounds");
        return *(self.items + index);
    }

    ///
    /// \brief First element. Null if empty.
    ///
    fn front(self) -> *T {
        if self.count == 0 { return &null; }
        return self.items;
    }

    ///
    /// \brief Last element. Null if empty.
    ///
    fn back(self) -> *T {
        if self.count == 0 { return &null; }
        return self.items + (self.count - 1);
    }

    fn size(self)  -> usize { return self.count; }
    fn is_empty(self) -> bool  { return self.count == 0; }

    ///
    /// \brief Linear searchreturns index of first match, usize::MAX if not found.
    /// Comparison uses == operator on T.
    ///
    fn find(self, val: T) -> usize {
        for var i: usize = 0; i < self.count; ++i {
            if self.items[i] == val {
                return i;
            }
        }

        return MAX; // not found
    }

    ///
    /// \brief Returns true if any element satisfies the predicate.
    /// pred must be a callable: fn(*T) -> bool
    ///
    fn any(self, pred: fn(*T) -> bool) -> bool {
        for var i: usize = 0; i < self.count; ++i {
            if pred(self.items + i) {
                return true;
            }
        }
        
        return false;
    }

    ///
    /// \brief Returns true if all elements satisfy the predicate.
    ///
    fn all(self, pred: fn(*T) -> bool) -> bool {
        for var i: usize = 0; i < self.count; ++i {
            if !pred(self.items + i) {
                return false;
            }
        }
        
        return true;
    }
}

fn <T> create_empty_frozen_list() -> FrozenList::<T> {
    inline "c++" {
        return FrozenList<T>::empty();
    }
}

/// ⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿ ///
/// ⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⡿⢟⣛⣛⣛⣛⡻⠿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿ ///
/// ⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⡟⢁⣺⣿⣿⣿⣿⣿⣿⣿⣶⠈⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿ ///
/// ⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⡟⠃⠼⢽⣿⣿⠿⠻⠛⠻⢿⣿⠀⣾⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿ ///
/// ⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⠁⠀⠀⠀⠙⠁⠀⠀⢠⡀⠀⢬⠃⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿ ///
/// ⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⡟⠀⠀⠻⡄⠀⣇⠀⠃⠀⠘⡇⠀⠄⢿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿ ///
/// ⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⡟⠀⠀⠀⢈⢸⡿⣦⣀⢀⣀⣴⣿⡆⢸⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿ ///
/// ⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⡇⠙⠳⠞⠁⠸⠷⠦⠈⠉⠉⠉⠀⠀⢸⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿ ///
/// ⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣦⠀⠀⠆⠀⠀⠤⠿⠂⠀⠀⠀⠀⢸⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿ ///
/// ⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣧⡄⠀⠀⠀⠈⣠⡼⠃⠀⠀⠀⢸⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿ ///
/// ⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⠃⠀⠀⠀⠛⠉⠀⢀⠠⠀⠀⢸⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿ ///
/// ⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⠠⠀⠀⠀⠀⢤⠘⠤⠁⢰⡆⢸⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿ ///
/// ⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⠀⠀⠀⢠⠋⠤⡉⠐⡀⠀⢿⠸⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿ ///
/// ⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⠀⠄⠀⠀⡘⢀⠆⠡⠀⠀⣈⠀⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿ ///
/// ⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⡇⠀⠀⠀⠀⡐⠈⠤⢁⠂⠀⡟⢰⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿ ///
/// ⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⡇⡀⠀⠀⠀⠠⠁⠂⠄⠀⣸⠁⣸⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿ ///
/// ⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⡇⠁⠀⠀⠀⠀⠀⠀⠀⠈⠁⢰⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿ ///
/// ⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⡿⢁⠆⠀⠀⠀⢀⣐⠀⠀⠀⢀⣸⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿ ///
/// ⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⡟⡁⠁⣼⡇⠀⠀⣿⣿⠀⡀⢀⣷⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿ ///
/// ⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⠏⡔⠀⣼⣿⡇⣀⠀⣿⣿⡆⣡⠘⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿ ///
/// ⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⡿⢡⡞⢀⣾⣿⣿⣇⠀⠀⢿⣿⡇⠁⠀⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿ ///
/// ⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⡏⣴⡇⢠⣾⣿⣿⣿⣿⠀⠀⢸⣿⣧⠀⠀⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿ ///
/// ⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⠏⣼⠍⢀⣿⣿⣿⣿⣿⣿⡀⠀⢸⣿⣿⡀⠀⣻⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿ ///
/// ⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⡿⠋⡸⠁⢀⣾⣿⣿⣿⣿⣿⣿⣇⢀⠈⣿⣿⡇⠀⢸⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿ ///
/// ⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⠟⠁⠄⠀⢠⣾⣿⣿⣿⣿⣿⣿⣿⡟⠀⠀⢿⡿⠁⠀⠘⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿ ///
/// ⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⡿⠋⠀⠀⠀⣠⣾⣿⣿⣿⠿⠛⣛⣹⡏⠀⠀⠀⠀⢠⣾⣆⠀⢻⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿ ///
/// ⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣦⣀⡀⠀⢰⣿⣿⣿⡃⠄⠤⡶⠋⠉⣁⣠⣴⡆⠰⠛⠻⠻⠢⠘⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿ ///
/// ⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣷⣿⣿⣿⣿⣿⣷⣶⣶⣾⣿⣿⣿⣯⣁⣀⡊⣘⣀⣀⣤⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿ ///
/// ⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿ ///
///                                                                          ///
/// Yes, do not question the existence of this T^3 ascii art.                ///
/// It is a necessary part of the parser support code.     ~ @OjasTalgaonkar ///
///                                                                          ///
/// WHAT THE FUCK IS THIS                                          ~ @Ze7111 ///
///                                                                          ///