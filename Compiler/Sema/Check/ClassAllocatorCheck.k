/// --- The Kairo Project ------------- Sema/Check/ClassAllocatorCheck.k --- ///
///
///   \brief `op new` / `op delete` as a class's own allocator (P215): where
///          they may stand and what they must look like.
///
///   \detail
///     A class may carry the allocator its objects come from:
///
///         class Node {
///             static fn op new(size: usize, align: usize) -> unsafe *u8 { ... }
///             static fn op delete(ptr: unsafe *u8, size: usize, align: usize) { ... }
///         }
///
///     The parser declares the pair under the Allocator interface's member
///     names, `alloc` and `free` (FunctionDecl::class_alloc_op), so the
///     class IS an Allocator by them, and CallTyping routes `create<Node>`,
///     `try_create<Node>` and `destroy<Node>` (and the `@create` / `@destroy`
///     sugar) to their `_in<Node, Node>` forms. alloc.k's `create_in` calls
///     `A::alloc(size, align)` and `destroy_in` calls `A::free(ptr, size,
///     align)`, so the operators must be exactly those: static, in a type,
///     with Allocator's signatures, and both present (a class that
///     allocates its own way and frees the global way corrupts both heaps).
///     A non-static `op delete(self)` is the destructor, as before; it never
///     reaches here.
///
///     Errors, one per broken rule, each with a note at the operator.
///
///   Phase: CHECK (after T: reads the parameter and return types; before
///          ExprTyper, which routes on the pair this pass vouches for)
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import Sema::SemaContext::*;
import Sema::Type::TypeUtil::*;
import Sema::Resolve::NameLookup::*;
import AST::Context::DeclContext::*;
import AST::Context::SymbolTable::*;
import AST::ASTSupport::*;
import AST::LangItems::*;
import AST::Node::Base::*;
import AST::Node::Program::*;
import AST::Node::Types::*;
import AST::Node::CanonicalNodes::*;
import AST::Node::Declarations::*;
import AST::Node::Casting::*;
import AST::Visitor::RecursiveASTVisitor::*;
import Location::SourceRange::*;
import Diagnostic::Registry::*;

class ClassAllocatorCheck derives RecursiveASTVisitor::<ClassAllocatorCheck> {
    pub var sc: *SemaContext;
    priv var _tu: TypeUtil;

    fn ClassAllocatorCheck(self, sc: *SemaContext) {
        self.sc  = sc;
        self._tu = TypeUtil(sc);
    }

    fn run(self) {
        self.sc->require_phase(SemaPhase::TypesResolved);
        var tu = self.sc->tu;
        if (tu == &null) || (tu->program == &null) { return; }
        var items = &(tu->program->items);
        for var i: usize = 0; i < items->size(); ++i {
            if self.stop { break; }
            var item = *(items->get(i));
            switch item.get_kind() {
                case TopLevelKind::Decl { self.dyn()->dispatch_decl(item.as_decl()); }
                case TopLevelKind::Stmt { self.dyn()->dispatch_stmt(item.as_stmt()); }
                case TopLevelKind::Expr { self.dyn()->dispatch_expr(item.as_expr()); }
            }
        }
    }

    fn visit_function_decl(self, n: *FunctionDecl) -> bool {
        if (n == &null) || n->is_poisoned() || (n->class_alloc_op == 0) { return true; }
        var is_new = n->class_alloc_op == 1;
        var word = ("op new") if (is_new) else ("op delete");
        var want = ("static fn op new(size: usize, align: usize) -> unsafe *u8") if (is_new)
                   else ("static fn op delete(ptr: unsafe *u8, size: usize, align: usize)");

        var dc = reinterpret_cast::<*DeclContext>(n->semantic_dc);
        if (dc == &null) || (!dc->is_type_scope()) {
            self._err(n, f"'{word}' is a class's own allocator, so it is declared in a class, as '{want}\x27");
            return true;
        }
        if n->abi != AbiKind::Static {
            self._err(n, f"'{word}' is a class's own allocator and has no object to run on; declare it '{want}\x27");
            return true;
        }
        if !self._signature_ok(n, is_new) {
            var iface = ("Allocator::alloc") if (is_new) else ("Allocator::free");
            self._err(n, f"'{word}' is called as {iface}, so it must be '{want}\x27");
            return true;
        }

        // The pair: report once, from the operator that is there.
        var other = (AllocNames::free_member()) if (is_new) else (AllocNames::alloc_member());
        var other_op: u8 = 1;
        if is_new { other_op = 2; }
        if !self._has_partner(dc, other, other_op) {
            var missing = ("static fn op delete(ptr: unsafe *u8, size: usize, align: usize)") if (is_new)
                          else ("static fn op new(size: usize, align: usize) -> unsafe *u8");
            self._err(n, f"a class with '{word}' must also declare '{missing}': its objects are freed by the allocator they came from");
        }
        return true;
    }

    priv fn _signature_ok(self, f: *FunctionDecl, is_new: bool) -> bool {
        if f->is_variadic || (f->generic_params.size() > 0) { return false; }
        var ps = vec::<*ParamDecl>();
        for var i: usize = 0; i < f->params.size(); ++i {
            if (f->params[i] != &null) && (!f->params[i]->is_self) { ps.push_back(f->params[i]); }
        }
        if is_new {
            if ps.size() != 2 { return false; }
            if (!self._is(ps[0]->type_, BuiltinKind::USize)) || (!self._is(ps[1]->type_, BuiltinKind::USize)) { return false; }
            return self._is_byte_ptr(f->return_type);
        }
        if ps.size() != 3 { return false; }
        if !self._is_byte_ptr(ps[0]->type_) { return false; }
        if (!self._is(ps[1]->type_, BuiltinKind::USize)) || (!self._is(ps[2]->type_, BuiltinKind::USize)) { return false; }
        return (f->return_type == &null) || self._is(f->return_type, BuiltinKind::Void);
    }

    priv fn _is(self, t: *Type, b: BuiltinKind) -> bool {
        if (t == &null) || (t->canonical == &null) { return false; }
        return canon_unqual(t->canonical) == canon_unqual(self.sc->builtin(b));
    }

    /// `unsafe *u8`.
    priv fn _is_byte_ptr(self, t: *Type) -> bool {
        if (t == &null) || (t->canonical == &null) { return false; }
        if !self._tu.is_unsafe_ptr(t->canonical) { return false; }
        var p = self._tu.pointee(t->canonical);
        return (p != &null) && (canon_unqual(p) == canon_unqual(self.sc->builtin(BuiltinKind::U8)));
    }

    priv fn _has_partner(self, dc: *DeclContext, name: string, want_op: u8) -> bool {
        var imm = self.sc->imm_table()->intern_ident_copy(name);
        var cell = self.sc->lookup.in_context(dc, DeclName::ident(imm), name);
        if !cell.found() { return false; }
        for var i: usize = 0; i < cell.cell->size(); ++i {
            var f = dyn_cast::<FunctionDecl>(cell.cell->get(i));
            if (f != &null) && (f->class_alloc_op == want_op) { return true; }
        }
        return false;
    }

    priv fn _err(self, f: *FunctionDecl, msg: string) {
        var at = f->name.range;
        var b = self.sc->diag->report(DiagID::SC001E, at.start, msg);
        b.first(at);
        b.emit();
    }
}
