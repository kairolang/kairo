/// --- The Kairo Project -------------------- Sema/Verify/ForeignName.k --- ///
///
/// Verify that every user-declared name is spellable as a C++
/// identifier. Kairo emits identical spellings across the FFI
/// boundary (no mangling), so a name that collides with a C++
/// keyword or a reserved identifier pattern cannot be emitted and
/// cannot be called from real C++.
///
///   \detail
///     Two rule families, both reported at the DECLARATION, never at a use:
///       1. C++ KEYWORDS   set built from clang's own tables (see
///          ForeignReservedWords.k), so it cannot drift from what clang rejects.
///       2. RESERVED PATTERNS   double underscore anywhere and leading
///          underscore + uppercase, which [lex.name]/3 reserves at every
///          scope, and a plain leading underscore, which C++ reserves only
///          at global scope. Not keywords, so clang accepts them; UB to
///          define where C++ reserves them, and an interop hazard.
///
///     The everywhere-reserved patterns apply to every user-written name,
///     locals and members included. A plain leading underscore is checked
///     only on a declaration C++ can name by its spelling (_exported): a
///     `pub` one, or an unmarked or `prot` one under a module.k, which the
///     C++ files of that directory see. A `priv` one, or any declaration of
///     a file with no module.k above it, is named only by Kairo, and C++
///     allows `_count` at class and local scope.
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

import AST::ForeignReservedWords::{
    CxxKeywordSet,
    cxx_reserved_everywhere,
    cxx_reserved_reason,
}
import AST::LangItems::LowerTargets
import AST::Mixin::Annotation::VisibilityKind
import AST::Node::Declarations
import AST::Node::Expressions
import AST::Node::Patterns::BindingPattern
import AST::VisibilityFacts::tu_module_dir
import AST::Visitor::RecursiveASTVisitor::RecursiveASTVisitor
import Diagnostic::Registry::DiagID
import Sema::SemaContext::SemaContext
import Token::Token::Token
import Token::TokenKind::{
    TokenKind,
    is_annotation,
}

pub class CxxNameCheck derives RecursiveASTVisitor<CxxNameCheck> {
    pub var sc: *SemaContext
    var     kw: CxxKeywordSet ///< table-local index set; dies with the pass.
    /// Functions and closures being walked: a variable declared at depth 0
    /// is a module's or a type's, one deeper is a local, which C++ never names.
    priv var _fn_depth: u32 = 0

    fn CxxNameCheck(self, sc: *SemaContext) {
        self.sc = sc
    }

    fn run(self) {
        var unsafe *tu = self.sc->tu
        if tu == &null || tu->program == &null {
            return
        }

        // Requires a fully-populated imm table   see ForeignReservedWords.k.
        self.kw.build(self.sc->imm_table())

        self.run(tu)
    }

    /// `what` is the noun used in the message ("function", "class", ...).
    /// `exported` is whether C++ can name the declaration (_exported); a
    /// plain leading underscore is reported only then.
    priv fn _check(self, name: Token, const what: string, exported: bool) {
        // A primitive type's name always denotes the type, so a declaration
        // it names could never be used (S047E is the parser's half, for a
        // function's name).
        if is_annotation(name.kind) && name.kind != TokenKind::AtComment {
            var nm = self.sc->ctx->get_spelling(name)
            self.sc->diag->report(
                DiagID::SC331E,
                name.range.start,
                f"{what} name '{nm}' is the name of a primitive type, which it always denotes; choose another name",
            ).first(name.range)->emit()
            return
        }

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
        if s.starts_with(rp) {
            self.sc->diag->report(
                DiagID::SC017E,
                name.range.start,
                f"identifier '{s}' uses the reserved prefix '{rp}'",
            ).first(name.range)->emit()
            return
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
        if !why.is_empty() {
            // Two messages, because only one of them is C++'s rule. A plain
            // `_lower` is reserved by C++ at global scope alone; Kairo
            // refuses it only where C++ code can spell the name (_exported).
            var msg = f"{what} name is reserved by C++ at every scope: {why}"
            if !cxx_reserved_everywhere(s) {
                if !exported {
                    return
                }

                msg = f"{what} name begins with an underscore, and C++ code can name it; it may collide with a name C++ reserves"
            }

            self.sc->diag->report(DiagID::SC005W, name.range.start, msg.copy()).first(
                name.range,
            )->emit()
        }
    }

    /// Whether C++ can name a declaration of visibility `v` by its spelling:
    /// a `pub` one always; an unmarked, `prot` or internal one when a module.k
    /// is above its file, which shares it with every file of that directory,
    /// the C++ files beside it included; a `priv` one never.
    priv fn _exported(self, v: VisibilityKind) -> bool {
        if v == VisibilityKind::Public {
            return true
        }

        if v == VisibilityKind::Private {
            return false
        }

        return !tu_module_dir(self.sc->tu).is_empty()
    }

    fn traverse_function_decl(self,
                              n: unsafe *Declarations::FunctionDecl) -> unsafe *Declarations::FunctionDecl {
        self._fn_depth++
        var r = RecursiveASTVisitor<CxxNameCheck>::traverse_function_decl(
            self,
            n,
        )

        self._fn_depth--
        return r
    }

    fn traverse_closure_expr(self,
                             n: unsafe *Expressions::ClosureExpr) -> unsafe *Expressions::ClosureExpr {
        self._fn_depth++
        var r = RecursiveASTVisitor<CxxNameCheck>::traverse_closure_expr(
            self,
            n,
        )

        self._fn_depth--
        return r
    }

    /// `s` starts `__builtin_`.
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

        self._check(n->name, "function", self._exported(n->visibility))
        return true
    }

    /// A local or field the compiler made before this pass (the guards and
    /// the arena fields of `@set_scoped_allocator`) carries the reserved
    /// prefix on purpose.
    fn visit_variable_decl(self, n: *Declarations::VariableDecl) -> bool {
        if n->is_implicit {
            return true
        }

        self._check(
            n->name,
            "variable",
            self._fn_depth == 0 && self._exported(n->visibility),
        )

        return true
    }

    fn visit_field_decl(self, n: *Declarations::FieldDecl) -> bool {
        if n->is_implicit {
            return true
        }

        self._check(n->name, "field", self._exported(n->visibility))
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

        self._check(n->name, "parameter", false)
        return true
    }

    fn visit_generic_param_decl(self, n: *Declarations::GenericParamDecl) -> bool {
        self._check(n->name, "generic parameter", false)
        return true
    }

    fn visit_struct_decl(self, n: *Declarations::StructDecl) -> bool {
        self._check(n->name, "struct", self._exported(n->visibility))
        return true
    }

    fn visit_class_decl(self, n: *Declarations::ClassDecl) -> bool {
        self._check(n->name, "class", self._exported(n->visibility))
        return true
    }

    fn visit_interface_decl(self, n: *Declarations::InterfaceDecl) -> bool {
        self._check(n->name, "interface", self._exported(n->visibility))
        return true
    }

    fn visit_enum_decl(self, n: *Declarations::EnumDecl) -> bool {
        self._check(n->name, "enum", self._exported(n->visibility))
        return true
    }

    fn visit_enum_variant_decl(self, n: *Declarations::EnumVariantDecl) -> bool {
        self._check(n->name, "enum variant", self._exported(n->visibility))
        return true
    }

    fn visit_union_decl(self, n: *Declarations::UnionDecl) -> bool {
        self._check(n->name, "union", self._exported(n->visibility))
        return true
    }

    fn visit_type_alias_decl(self, n: *Declarations::TypeAliasDecl) -> bool {
        self._check(n->name, "type alias", self._exported(n->visibility))
        return true
    }

    /// Anonymous modules have no name token; get_ident_imm rejects it.
    fn visit_module_decl(self, n: *Declarations::ModuleDecl) -> bool {
        if n->is_anonymous {
            return true
        }

        self._check(n->name, "module", self._exported(n->visibility))
        return true
    }

    /// Pattern bindings become C++ locals after match lowering.
    fn visit_binding_pattern(self, n: *BindingPattern) -> bool {
        self._check(n->name, "binding", false)
        return true
    }
}
