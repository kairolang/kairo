/// --- The Kairo Project ----- Sema/Check/ConditionalExtensionCheck.k --- ///
///
/// A conditional extension's members are used, in the extension's
/// own file, only from inside it.
///
///   \detail
///     An extension whose `requires` clause asks `__builtin_is_declared`
///     about a path its own file does not declare (ExtensionDecl::gate,
///     `local` false) exists in the files that do declare it. Member lookup
///     decides that per file, and it lets the extension's own file see the
///     block, because the block's members call each other and use its
///     conversions (DeclaredQuery::gate_holds). Lookup has no position, so
///     the rest of that file would see the block too:
///
///       extend string requires __builtin_is_declared<cxx::std::string>() {
///           pub fn to_cxx(const self) -> cxx::std::string { ... }
///       }
///
///       pub fn len(const s: string) -> usize { return s.to_cxx().size() }   // SC343E
///
///     `len` is unconditional. It would exist in every build, name a C++
///     type in this file's own translation unit, and stop compiling in a
///     build whose headers do not declare the path. This pass reports the
///     use: a member of such a block is used here only from a conditional
///     block whose clause asks about the same paths, or more.
///
///     Every way a member is named is covered: an identifier, a chain
///     step, an operator a node resolved to, a cast through `op as`, and
///     an implicit conversion X accepted (SemaContext::implicit_convs).
///
///   Phase: CHECK, after X. A file with no such block is not walked.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "llvm/ADT/DenseMap.h"
ffi "c++" import "vector"

import AST::Context::DeclContext::DeclContext
import AST::DeclFacts::decl_extension_of
import AST::Node::Base::{
    Decl,
    Expr,
}
import AST::Node::Declarations
import AST::Node::Expressions
import AST::Node::PrimaryExpressions::{
    ChainExpr,
    NamedIdentExpr,
}
import AST::Node::Program::TopLevelKind
import AST::Visitor::RecursiveASTVisitor::RecursiveASTVisitor
import Diagnostic::Code::DiagCode
import Diagnostic::Registry::DiagID
import Location::SourceRange::SourceRange
import Sema::Resolve::NameLookup::NameLookup
import Sema::SemaContext::SemaContext

pub class ConditionalExtensionCheck derives RecursiveASTVisitor<ConditionalExtensionCheck> {
    pub var sc: unsafe *SemaContext
    /// The gates of the conditional blocks enclosing the walk, innermost last.
    priv var _in: cxx::std::vector<unsafe *Declarations::ExtensionGate>

    fn ConditionalExtensionCheck(self, sc: unsafe *SemaContext) {
        self.sc = sc
    }

    fn run(self) {
        var unsafe *tu = self.sc->tu
        if tu == &null || tu->program == &null || self.sc->conditional_blocks == 0 {
            return
        }

        var *items = &tu->program->items
        for var i: usize = 0; i < items->size(); ++i {
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

    fn traverse_extension_decl(self,
                               n: unsafe *Declarations::ExtensionDecl) -> unsafe *Declarations::ExtensionDecl {
        if n->gate == &null {
            return RecursiveASTVisitor<ConditionalExtensionCheck>::traverse_extension_decl(
                self,
                n,
            )
        }

        self._in.push_back(n->gate)
        RecursiveASTVisitor<ConditionalExtensionCheck>::traverse_extension_decl(
            self,
            n,
        )

        self._in.pop_back()
        return n
    }

    pub fn dispatch_expr(self, e: unsafe *Expr) -> unsafe *Expr {
        if e != &null && !self.sc->implicit_convs.empty() {
            var it = self.sc->implicit_convs.find(e as usize as u64)
            if it != self.sc->implicit_convs.end() {
                self._use(unsafe (it->second as unsafe *Decl), e->range)
            }
        }

        return RecursiveASTVisitor<ConditionalExtensionCheck>::dispatch_expr(
            self,
            e,
        )
    }

    fn visit_named_ident_expr(self, n: *NamedIdentExpr) -> bool {
        self._use(n->resolved_decl, n->range)
        return true
    }

    fn visit_chain_expr(self, n: *ChainExpr) -> bool {
        for var i: usize = 0; i < n->steps.size(); ++i {
            var unsafe *st = n->steps.get(i)
            self._use(st->resolved_decl, st->range)
        }

        return true
    }

    fn visit_type_cast_expr(self, n: *Expressions::TypeCastExpr) -> bool {
        self._use(n->resolved_op, n->range)
        return true
    }

    fn visit_binary_operator_expr(self, n: *Expressions::BinaryOperatorExpr) -> bool {
        self._use(n->resolved_op, n->range)
        return true
    }

    fn visit_unary_operator_expr(self, n: *Expressions::UnaryOperatorExpr) -> bool {
        self._use(n->resolved_op, n->range)
        return true
    }

    fn visit_assign_operator_expr(self, n: *Expressions::AssignOperatorExpr) -> bool {
        self._use(n->resolved_op, n->range)
        return true
    }

    /// `d` is named at `at`: report it when it is a member of a
    /// conditional block of this file that the position is not inside.
    priv fn _use(self, d: unsafe *Decl, at: SourceRange) {
        var unsafe *x = decl_extension_of(d)
        if x == &null || x->gate == &null || x->gate->local {
            return
        }

        if NameLookup::tu_of(unsafe (x as unsafe *DeclContext)) != self.sc->tu {
            return
        }

        for var i: usize = 0; i < self._in.size(); ++i {
            if self._covers(self._in[i], x->gate) {
                return
            }
        }

        var need = ""
        for var i: usize = 0; i < x->gate->paths.size(); ++i {
            if i > 0 {
                need += "', '"
            }

            need += x->gate->paths[i]
        }

        var b = self.sc->diag->report(
            DiagID::SC343E,
            at.start,
            f"this uses a member of an extension that exists only where '{need}' is declared, from code that exists everywhere; move the use into an extension with the same 'requires' clause",
        )

        b.first(at)
        b.note(
            DiagCode(DiagID::SC343N),
            x->range.start,
            "the extension is declared here; this file does not declare the path itself",
        )->child_first(x->range)

        b.emit()
    }

    /// Every path `inner` asks about, `outer` asks about too.
    priv fn _covers(self,
                    outer: unsafe *Declarations::ExtensionGate,
                    inner: unsafe *Declarations::ExtensionGate) -> bool {
        for var i: usize = 0; i < inner->paths.size(); ++i {
            var hit = false
            for var k: usize = 0; k < outer->paths.size(); ++k {
                if outer->paths[k] == inner->paths[i] {
                    hit = true
                    break
                }
            }

            if !hit {
                return false
            }
        }

        return true
    }
}
