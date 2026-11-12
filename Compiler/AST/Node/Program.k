/// --- The Kairo Project --------------------------- AST/Node/Program.k --- ///
///
///   Program, a file's ordered list of top-level declarations, statements and
///   expressions.
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

import AST::Context::ASTContext::ASTContext
import AST::Node::Base::{
    Decl,
    Expr,
    Stmt,
}
import Location::SourceRange::SourceRange
import Memory::ArenaList::ArenaList

pub enum TopLevelKind derives u8 {
    Decl,
    Stmt,
    Expr,
}

pub class TopLevelItem {
    pub var kind: TopLevelKind
    pub var ptr:  unsafe *void

    // TODO(GENERIC-MEMBER-REQUIRES): exists only because ArenaList<T> is
    // instantiated with every member, and its emplace() default-constructs T.
    // Remove once a generic member can state what it needs of T.
    fn TopLevelItem(self) {
        self.kind = TopLevelKind::Decl
        self.ptr  = &null
    }

    fn TopLevelItem(self, kind: TopLevelKind, ptr: unsafe *void) {
        self.kind = kind
        self.ptr  = ptr
    }

    pub static fn from_decl(decl: unsafe *Decl) -> TopLevelItem {
        return TopLevelItem(TopLevelKind::Decl, unsafe (decl as unsafe *void))
    }

    pub static fn from_stmt(stmt: unsafe *Stmt) -> TopLevelItem {
        return TopLevelItem(TopLevelKind::Stmt, unsafe (stmt as unsafe *void))
    }

    pub static fn from_expr(expr: *Expr) -> TopLevelItem {
        return TopLevelItem(TopLevelKind::Expr, unsafe (expr as unsafe *void))
    }

    pub inline fn as_decl(self) -> unsafe *Decl {
        eval if defined!(DEBUG) {
            if !(self.kind == TopLevelKind::Decl) {
                kairo::std::ice_fail(
                    "assertion failed: self.kind == TopLevelKind::Decl",
                )
            }
        }

        return unsafe (self.ptr as unsafe *Decl)
    }

    pub inline fn as_stmt(self) -> unsafe *Stmt {
        eval if defined!(DEBUG) {
            if !(self.kind == TopLevelKind::Stmt) {
                kairo::std::ice_fail(
                    "assertion failed: self.kind == TopLevelKind::Stmt",
                )
            }
        }

        return unsafe (self.ptr as unsafe *Stmt)
    }

    pub inline fn as_expr(self) -> unsafe *Expr {
        eval if defined!(DEBUG) {
            if !(self.kind == TopLevelKind::Expr) {
                kairo::std::ice_fail(
                    "assertion failed: self.kind == TopLevelKind::Expr",
                )
            }
        }

        return unsafe (self.ptr as unsafe *Expr)
    }

    pub inline fn get_kind(self) -> TopLevelKind {
        return self.kind
    }

    pub inline fn get_range(self) -> SourceRange {
        match self.kind {
            case TopLevelKind::Decl {
                return self.as_decl()->range
            } case TopLevelKind::Stmt {
                return self.as_stmt()->range
            } case TopLevelKind::Expr {
                return self.as_expr()->range
            }
        }
    }
}

pub class Program {
    pub var items: ArenaList<TopLevelItem>
    pub var ctx:   *ASTContext
    pub var fid:   usize                   // file id assigned by SourceManager

    fn Program(self, fid: u32, ctx: *ASTContext) {
        self.items.set_allocator(unsafe &ctx->ast_alloc) // 256 is a reasonable default slab
        self.ctx = ctx
        self.fid = (fid as usize)
    }

    fn get_filename(self) -> string {
        return self.ctx->sm->get_filename((self.fid as u32))
    }

    pub fn add_item(self, item: TopLevelItem) {
        self.items.push(item)
    }
}
