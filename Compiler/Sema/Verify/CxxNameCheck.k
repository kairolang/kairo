/// --- The Kairo Project ------------------- Sema/Verify/CxxNameCheck.k --- ///
///
///   \brief Verify that every user-declared name is spellable as a C++
///          identifier. Kairo emits identical spellings across the FFI
///          boundary (no mangling), so a name that collides with a C++
///          keyword or a reserved identifier pattern cannot be emitted and
///          cannot be called from real C++.
///
///   \detail
///     Two rule families, both reported at the DECLARATION, never at a use:
///       1. C++ KEYWORDS   set built from clang's own tables (see
///          CxxReservedWords.k), so it cannot drift from what clang rejects.
///       2. RESERVED PATTERNS ([lex.name]/3)   double underscore anywhere,
///          leading underscore, leading underscore + uppercase. Not keywords,
///          so clang accepts them; still UB to define and an interop hazard.
///
///     Applies to every user-written name including locals. A rule that
///     holds at one scope and not another costs users more to remember than
///     the occasional forced rename.
///
///     RecoveryDecl nodes never reach _check: their `kind` is RecoveryDecl,
///     so the RAV dispatch never routes them to a visit_*_decl hook.
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
import AST::Context::ASTContext::*;
import AST::Context::TranslationUnit::*;
import AST::ASTSupport::*;
import AST::Node::Base::*;
import AST::Node::Program::*;
import AST::Node::Declarations::*;
import AST::Node::Patterns::*;
import AST::Node::Casting::*;
import AST::Visitor::RecursiveASTVisitor::*;
import Sema::Verify::CxxReservedWords::*;
import Token::Token::*;
import Diagnostic::Registry::*;

class CxxNameCheck derives RecursiveASTVisitor::<CxxNameCheck> {
    pub var sc: *SemaContext;
    var kw: CxxKeywordSet;   ///< table-local index set; dies with the pass.

    fn CxxNameCheck(self, sc: *SemaContext) {
        self.sc = sc;
    }

    fn run(self) {
        var tu = self.sc->tu;
        if tu == &null { return; }
        if tu->program == &null { return; }

        // Requires a fully-populated imm table   see CxxReservedWords.k.
        self.kw.build(self.sc->imm_table());

        var items = &(tu->program->items);
        for var i: usize = 0; i < items->size(); i++ {
            var item = *(items->get(i));
            switch item.kind {
                case TopLevelKind::Decl { self.dispatch_decl(item.as_decl()); }
                case TopLevelKind::Stmt { self.dispatch_stmt(item.as_stmt()); }
                case TopLevelKind::Expr { self.dispatch_expr(item.as_expr()); }
                default { }
            }
        }
    }

    /// \p what is the noun used in the message ("function", "class", ...).
    priv fn _check(self, name: Token, what: string) {
        // get_ident_imm unwraps macro-expansion chains and yields u32(-1)
        // for anything that is not an identifier   an empty/absent name
        // token (anonymous module, unnamed param) lands there and is
        // correctly skipped.
        var imm = self.sc->ctx->get_ident_imm(name);
        if imm == u32(-1) { return; }

        if self.kw.contains(imm) {
            self.sc->diag->report(DiagID::SC001E, name.range.start,
                f"{what} name is a C++ keyword; this name cannot be would be undefined behavior with C/C++ interop and cannot be used"
            ).first(name.range).emit();
            return;
        }

        var why = cxx_reserved_reason(self.sc->ctx->get_spelling(name));
        if !why.empty() {
            self.sc->diag->report(DiagID::SC001W, name.range.start,
                f"{what} name is reserved for the implementation in C++: {why}"
            ).first(name.range).emit();
        }
    }

    /// Operators carry no user identifier   `op_token` is the spelling and
    /// its C++ form is synthesized by Lower/, not written by the user. Ctors
    /// share the type name and are checked at the type decl.
    fn visit_function_decl(self, n: *FunctionDecl) -> bool {
        if n->is_operator { return true; }
        self._check(n->name, "function");
        return true;
    }

    fn visit_variable_decl(self, n: *VariableDecl) -> bool {
        self._check(n->name, "variable");
        return true;
    }

    fn visit_field_decl(self, n: *FieldDecl) -> bool {
        self._check(n->name, "field");
        return true;
    }

    /// `self` is synthesized-by-grammar and never emitted as a C++ param
    /// name; `unname` params have no name to emit.
    fn visit_param_decl(self, n: *ParamDecl) -> bool {
        if n->is_self { return true; }
        if n->unname  { return true; }
        self._check(n->name, "parameter");
        return true;
    }

    fn visit_generic_param_decl(self, n: *GenericParamDecl) -> bool {
        self._check(n->name, "generic parameter");
        return true;
    }

    fn visit_struct_decl(self, n: *StructDecl) -> bool {
        self._check(n->name, "struct");
        return true;
    }

    fn visit_class_decl(self, n: *ClassDecl) -> bool {
        self._check(n->name, "class");
        return true;
    }

    fn visit_interface_decl(self, n: *InterfaceDecl) -> bool {
        self._check(n->name, "interface");
        return true;
    }

    fn visit_enum_decl(self, n: *EnumDecl) -> bool {
        self._check(n->name, "enum");
        return true;
    }

    fn visit_enum_variant_decl(self, n: *EnumVariantDecl) -> bool {
        self._check(n->name, "enum variant");
        return true;
    }

    fn visit_union_decl(self, n: *UnionDecl) -> bool {
        self._check(n->name, "union");
        return true;
    }

    fn visit_type_alias_decl(self, n: *TypeAliasDecl) -> bool {
        self._check(n->name, "type alias");
        return true;
    }

    /// Anonymous modules have no name token; get_ident_imm rejects it.
    fn visit_module_decl(self, n: *ModuleDecl) -> bool {
        if n->is_anonymous { return true; }
        self._check(n->name, "module");
        return true;
    }

    /// Pattern bindings become C++ locals after match lowering.
    fn visit_binding_pattern(self, n: *BindingPattern) -> bool {
        self._check(n->name, "binding");
        return true;
    }
}