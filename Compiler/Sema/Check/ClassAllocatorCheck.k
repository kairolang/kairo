/// --- The Kairo Project ------------- Sema/Check/ClassAllocatorCheck.k --- ///
///
///   \brief A class's own allocator (`op new` / `static fn op delete`)
///          is not part of Kairo; and the destructor's old spelling,
///          `fn op delete(self)`.
///
///   \detail
///     A class cannot carry the allocator its objects come from:
///
///         class Node {
///             static fn op new(size: usize, align: usize) -> unsafe *u8 { ... }   // SC149E
///             static fn op delete(ptr: unsafe *u8, size: usize, align: usize) { ... }  // SC149E
///         }
///
///     Decided 2026-11-02 ( reaffirmed 2026-11-08): a per-class
///     allocator breaks the memory-safety model, since every block a
///     `@create` hands out must go back to the allocator in effect and
///     every C++ `delete` of a Kairo object to the global one
///     (c-cpp-memory.mdx). The parser still declares the pair under the
///     Allocator member names (`alloc` / `free`, FunctionDecl::
///     class_alloc_op) so the head hoists as any member does; this pass
///     rejects each one, at its name.
///
///     The destructor is `fn op finally(self)` since 0.2.0. The parser keys
///     `fn op delete(self)` as `op finally` (so nothing else sees it) and
///     records where `delete` was (FunctionDecl::old_dtor_at); this pass
///     reports it, S090E with the fix-it, except in the builtin / std
///     library, which migrates on its own schedule. (That exemption is
///     temporary: remove it once Lib/ spells `op finally`.)
///
///   Phase: CHECK (after T; before ExprTyper)
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import AST::Node::Declarations::FunctionDecl
import AST::Node::Program::TopLevelKind
import AST::Visitor::RecursiveASTVisitor::RecursiveASTVisitor
import Diagnostic::Registry::DiagID
import Sema::SemaContext::{
    SemaContext,
    SemaPhase,
}

pub class ClassAllocatorCheck derives RecursiveASTVisitor<ClassAllocatorCheck> {
    pub var  sc:   unsafe *SemaContext
    priv var _lib: bool                = false

    fn ClassAllocatorCheck(self, sc: unsafe *SemaContext) {
        self.sc = sc
    }

    fn run(self) {
        self.sc->require_phase(SemaPhase::TypesResolved)
        var unsafe *tu = self.sc->tu
        if tu == &null || tu->program == &null {
            return
        }

        self._lib = tu->is_lib_tu || self.sc->g != &null && self.sc->g->is_builtin_fid(tu->fid)
        var *items = &tu->program->items
        for var i: usize = 0; i < items->size(); ++i {
            if self.stop {
                break
            }

            var item = *items->get(i)
            match item.get_kind() {
                case TopLevelKind::Decl {
                    self.dyn()->dispatch_decl(item.as_decl())
                } case TopLevelKind::Stmt {
                    self.dyn()->dispatch_stmt(item.as_stmt())
                } case TopLevelKind::Expr {
                    self.dyn()->dispatch_expr(item.as_expr())
                }
            }
        }
    }

    fn visit_function_decl(self, n: unsafe *FunctionDecl) -> bool {
        if n == &null || n->is_poisoned() {
            return true
        }

        if n->old_dtor_at.is_valid() && !self._lib {
            var at = n->old_dtor_at
            var b = self.sc->diag->report(
                DiagID::S090E,
                at.start,
                "the destructor is spelled 'fn op finally(self)'; 'op delete' is no longer a destructor",
            )

            b.first(at)
            b.fix(at, "finally", "rename it to 'op finally'")
            b.emit()
        }

        if n->class_alloc_op == 0 {
            return true
        }

        var word = if (n->class_alloc_op == 1) => ("op new") else => "op delete"
        var at   = n->name.range
        var b = self.sc->diag->report(
            DiagID::SC149E,
            at.start,
            f"a class cannot declare its own allocator ('{word}'); objects are allocated with '@create' and freed with '@destroy' through the allocator in effect",
        )

        b.first(at)
        b.emit()
        return true
    }
}
