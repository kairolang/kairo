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
///       2. RESERVED PATTERNS   double underscore anywhere and leading
///          underscore + uppercase, which [lex.name]/3 reserves at every
///          scope, and a plain leading underscore, which C++ reserves only
///          at global scope. Not keywords, so clang accepts them; UB to
///          define where C++ reserves them, and an interop hazard.
///
///     Applies to every user-written name including locals and members: a
///     KAIRO rule for the leading-underscore case, wider than C++'s on
///     purpose. A rule that holds at one scope and not another costs users
///     more to remember than the occasional forced rename. The message says
///     which of the two rules a name broke.
///
///     RecoveryDecl nodes never reach _check: their `kind` is RecoveryDecl,
///     so the RAV dispatch never routes them to a visit_*_decl hook.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import AST::CxxReservedWords::{
    CxxKeywordSet,
    cxx_reserved_everywhere,
    cxx_reserved_reason,
}
import AST::LangItems::LowerTargets
import AST::Node::Declarations
import AST::Node::Patterns::BindingPattern
import AST::Node::Program::TopLevelKind
import AST::Visitor::RecursiveASTVisitor::RecursiveASTVisitor
import Diagnostic::Registry::DiagID
import Sema::SemaContext::SemaContext
import Token::Token::Token

pub class CxxNameCheck derives RecursiveASTVisitor<CxxNameCheck> {
    pub var sc: *SemaContext
    var     kw: CxxKeywordSet ///< table-local index set; dies with the pass.

    fn CxxNameCheck(self, sc: *SemaContext) {
        self.sc = sc
    }

    fn run(self) {
        var unsafe *tu = self.sc->tu
        if tu == &null {
            return
        }

        if tu->program == &null {
            return
        }

        // Requires a fully-populated imm table   see CxxReservedWords.k.
        self.kw.build(self.sc->imm_table())

        var *items = &tu->program->items
        for var i: usize = 0; i < items->size(); i++ {
            var item = *items->get(i)
            match item.kind {
                case TopLevelKind::Decl {
                    self.dispatch_decl(item.as_decl())
                } case TopLevelKind::Stmt {
                    self.dispatch_stmt(item.as_stmt())
                } case TopLevelKind::Expr {
                    self.dispatch_expr(item.as_expr())
                }
            }
        }
    }

    /// \p what is the noun used in the message ("function", "class", ...).
    priv fn _check(self, name: Token, const what: string) {
        // get_ident_imm unwraps macro-expansion chains and yields u32(-1)
        // for anything that is not an identifier   an empty/absent name
        // token (anonymous module, unnamed param) lands there and is
        // correctly skipped.
        var imm = self.sc->ctx->get_ident_imm(name)
        if imm == u32::MAX {
            return
        }

        if self.kw.contains(imm) {
            var kw = self.sc->ctx->get_spelling(name)
            self.sc->diag->report(
                DiagID::SC004E,
                name.range.start,
                f"{what} name '{kw}' is a C++ keyword; Kairo names are emitted unchanged, so C++ cannot declare or name it",
            ).first(name.range)->emit()
            return
        }

        var s = self.sc->ctx->get_spelling(name)

        // BEFORE the [lex.name] patterns below, not after: the reserved prefix
        // contains a double underscore, so cxx_reserved_reason would answer
        // first and report the generic pattern warning instead of this. The
        // compiler MINTS names with this prefix (LowerTargets: `op in` becomes
        // __kairo_contains, and so on), so a user declaring one does not merely
        // risk UB -- it collides with an invented name in the emitted C++.
        var rp = LowerTargets::reserved_prefix()
        if s.length() >= rp.length() {
            var hit = true
            for var i: usize = 0; i < rp.length(); ++i {
                if s[i] != rp[i] {
                    hit = false
                    break
                }
            }

            if hit {
                self.sc->diag->report(
                    DiagID::SC017E,
                    name.range.start,
                    f"identifier '{s}' uses the reserved prefix '{rp}'",
                ).first(name.range)->emit()
                return
            }
        }

        // The builtin root IS the implementation the C++ rule reserves these
        // names for: a `__builtin_` intrinsic it declares (__builtin_niche_of)
        // is answered by the compiler, and spelled that way on purpose.
        if self.sc->g != &null
            && self.sc->g->is_builtin_fid(self.sc->ctx->fid)
            && self._is_intrinsic_name(s) {
            return
        }

        var why = cxx_reserved_reason(s)
        if !why.empty() {
            // Two messages, because only one of them is C++'s rule. A plain
            // `_lower` is reserved by C++ at global scope alone; a member or
            // a local spelled so is legal C++, and Kairo refuses it on its
            // own account (file header). Saying "reserved in C++" there sent
            // people looking for a C++ rule that does not exist.
            var msg = f"{what} name is reserved by C++ at every scope: {why}"
            if !cxx_reserved_everywhere(s) {
                msg = f"{what} name begins with an underscore; Kairo reserves leading-underscore names at every scope for C++ interop"
            }

            self.sc->diag->report(DiagID::SC005W, name.range.start, msg).first(name.range)->emit()
        }
    }

    /// \p s starts `__builtin_`.
    priv fn _is_intrinsic_name(self, const s: string) -> bool {
        return s.starts_with(LowerTargets::clang_builtin_prefix())
    }

    /// Operators carry no user identifier   `op_token` is the spelling and
    /// its C++ form is synthesized by Lower/, not written by the user. Ctors
    /// share the type name and are checked at the type decl.
    fn visit_function_decl(self, n: *Declarations::FunctionDecl) -> bool {
        if n->is_operator {
            return true
        }

        self._check(n->name, "function")
        return true
    }

    fn visit_variable_decl(self, n: *Declarations::VariableDecl) -> bool {
        self._check(n->name, "variable")
        return true
    }

    fn visit_field_decl(self, n: *Declarations::FieldDecl) -> bool {
        self._check(n->name, "field")
        return true
    }

    /// `self` is synthesized-by-grammar and never emitted as a C++ param
    /// name; `unname` params have no name to emit.
    fn visit_param_decl(self, n: *Declarations::ParamDecl) -> bool {
        if n->is_self {
            return true
        }

        if n->unname {
            return true
        }

        self._check(n->name, "parameter")
        return true
    }

    fn visit_generic_param_decl(self, n: *Declarations::GenericParamDecl) -> bool {
        self._check(n->name, "generic parameter")
        return true
    }

    fn visit_struct_decl(self, n: *Declarations::StructDecl) -> bool {
        self._check(n->name, "struct")
        return true
    }

    fn visit_class_decl(self, n: *Declarations::ClassDecl) -> bool {
        self._check(n->name, "class")
        return true
    }

    fn visit_interface_decl(self, n: *Declarations::InterfaceDecl) -> bool {
        self._check(n->name, "interface")
        return true
    }

    fn visit_enum_decl(self, n: *Declarations::EnumDecl) -> bool {
        self._check(n->name, "enum")
        return true
    }

    fn visit_enum_variant_decl(self, n: *Declarations::EnumVariantDecl) -> bool {
        self._check(n->name, "enum variant")
        return true
    }

    fn visit_union_decl(self, n: *Declarations::UnionDecl) -> bool {
        self._check(n->name, "union")
        return true
    }

    fn visit_type_alias_decl(self, n: *Declarations::TypeAliasDecl) -> bool {
        self._check(n->name, "type alias")
        return true
    }

    /// Anonymous modules have no name token; get_ident_imm rejects it.
    fn visit_module_decl(self, n: *Declarations::ModuleDecl) -> bool {
        if n->is_anonymous {
            return true
        }

        self._check(n->name, "module")
        return true
    }

    /// Pattern bindings become C++ locals after match lowering.
    fn visit_binding_pattern(self, n: *BindingPattern) -> bool {
        self._check(n->name, "binding")
        return true
    }
}
