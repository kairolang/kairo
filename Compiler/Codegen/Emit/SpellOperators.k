/// --- The Kairo Project ---------------- Codegen/Emit/SpellOperators.k --- ///
///
///   Speller, part: operators. The C++ name of an operator member, the
///   forwarders of a split subscript, place operators and the return type they
///   spell (`T&` for a `*T`), and the record an operator belongs to.
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
ffi "c++" import "vector"

import AST::Context::ASTContext::ASTContext
import AST::Context::DeclContext::DeclContextKind
import AST::Context::InstantiationRegistry::InstanceEntry
import AST::Context::SymbolTable::DeclName
import AST::DeclFacts
import AST::Kind::TypeKind::TypeKind
import AST::LangItems::LowerTargets
import AST::Node::Base::{
    Decl,
    Type,
}
import AST::Node::CanonicalNodes::{
    RecordType,
    canon_unqual,
}
import AST::Node::Casting::{
    cast,
    dyn_cast,
    isa,
}
import AST::Node::Declarations
import AST::Node::Types::PointerType
import AST::OperatorFacts::OperatorFacts
import Codegen::Emit::Spell::Speller
import Codegen::Emit::SpellConstraints
import Codegen::Emit::SpellFacts
import Codegen::Emit::SpellScopes
import Codegen::Emit::SpellTypes
import Token::Token::Token
import Token::TokenKind::TokenKind

extend Speller {
    /// `operator+`, `operator[]`, `operator<=>`; `op as` -> `operator T`;
    /// `op finally` -> `~Owner`; operators C++ cannot spell -> LowerTargets.
    /// l/r on ++/-- is fixity, not part of the name (see op_is_postfix).
    fn operator_name(self, f: unsafe *Declarations::FunctionDecl) -> string {
        var sym = self._op_symbol(f)
        var k   = OperatorFacts::single_kind(f)
        if k == TokenKind::KwFinally {
            return "~" + self.leaf(self.operator_owner(f))
        }

        if k == TokenKind::KwAs {
            if f->return_type == &null {
                self._ice(f->range, "CXXSpell: `op as` with no target type")
            }

            // An extension's conversion is a static member of its scope, and
            // a static member cannot be an `operator T`. Two conversions of
            // one scope take the same receiver and differ only in the
            // result, so the result is in the name, as a witness member's is.
            if DeclFacts::decl_extension_of(f) != &null {
                var rt = self._type(f->return_type)
                return LowerTargets::witness_conversion(
                    Speller::cxx_segment(rt),
                )
            }

            return "operator " + self._type(f->return_type)
        }

        // A split subscript (its type declares `op []=`): each form is
        // a named member, called by that name, so the form Sema chose is the
        // one that runs (clang would pick `operator[]` by the object's
        // constness, the non-const one -- the place form -- for every read
        // of a mutable object). C++ users reach them through `operator[]`
        // forwarders (InterfaceEmitter::_subscript_forwarders).
        if OperatorFacts::in_split_subscript(f) {
            return if (OperatorFacts::is_subscript_set(f)) => (LowerTargets::subscript_set())
                   else => LowerTargets::subscript_get()
        }

        var named = Speller::named_operator(f)
        if named.size() > 0 {
            return named
        }

        // An extension operator is a STATIC MEMBER of its scope, and a static
        // member cannot be an `operator+`: it gets a mnemonic, and
        // InterfaceEmitter writes the `operator+` forwarder beside the scope.
        // The member-only set never gets here from an extension;
        // OperatorSignatureCheck rejects it.
        if DeclFacts::decl_extension_of(f) != &null {
            var key = sym
            if k == TokenKind::OpPlusPlus || k == TokenKind::OpMinusMinus {
                key = (if (Speller::op_is_postfix(f)) => ("r") else => "l") + sym
            }

            var m = LowerTargets::ext_op(key)
            if m.size() == 0 {
                self._ice(
                    f->range,
                    f"CXXSpell: extension 'op {sym}' has no C++ non-member form; OperatorSignatureCheck should reject it",
                )
            }

            return m
        }

        return "operator" + sym
    }

    /// A witness member's name for requirement \p f: its leaf, or for an
    /// operator the name an extension member of the same operator has --
    /// a witness member is static, so it cannot be an `operator==` either
    /// (Compiler/Spec/Witnesses.md#the-c-shape).
    fn witness_member_name(self, f: unsafe *Declarations::FunctionDecl) -> string {
        if !f->is_operator {
            return self.leaf(unsafe (f as unsafe *Decl))
        }

        var sym   = self._op_symbol(f)
        var k     = OperatorFacts::single_kind(f)
        var named = Speller::named_operator(f)
        if named.size() > 0 {
            return named
        }

        if OperatorFacts::is_subscript(f) {
            return LowerTargets::witness_subscript()
        }

        if OperatorFacts::is_subscript_set(f) {
            return LowerTargets::witness_subscript_set()
        }

        if k == TokenKind::KwAs {
            var rt = "void"
            if f->return_type != &null && f->return_type->canonical != &null {
                rt = self._type(f->return_type->canonical)
            }

            return LowerTargets::witness_conversion(Speller::cxx_segment(rt))
        }

        var key = sym
        if k == TokenKind::OpPlusPlus || k == TokenKind::OpMinusMinus {
            key = (if (Speller::op_is_postfix(f)) => ("r") else => "l") + sym
        }

        var m = LowerTargets::ext_op(key)
        if m.size() == 0 {
            self._ice(
                f->range,
                f"CXXSpell: requirement 'op {sym}' has no static-member name; OperatorSignatureCheck should reject it",
            )
        }

        return m
    }

    /// The namespace-scope `operator<sym>` an extension operator is forwarded
    /// from, or "" when it has none: the operators named by LowerTargets
    /// (`in`, `^^`, ...) are not C++ operators, and are only static members.
    fn ext_forwarder_name(self, f: unsafe *Declarations::FunctionDecl) -> string {
        var sym = self._op_symbol(f)
        if Speller::named_operator(f).size() > 0 {
            return ""
        }

        // A conversion function is a member in C++ ([class.conv.fct]): an
        // extension's `op as` has no namespace-scope form to forward from.
        if OperatorFacts::single_kind(f) == TokenKind::KwAs {
            return ""
        }

        return "operator" + sym
    }

    /// The operator's symbol as C++ spells it: word operators mapped, and
    /// `l`/`r` dropped from `++`/`--` (fixity is op_is_postfix's).
    priv fn _op_symbol(self, f: unsafe *Declarations::FunctionDecl) -> string {
        var unsafe *ctx = Speller::tu_of(unsafe (f as unsafe *Decl))->ctx
        var marked = f->op_token.size() == 2
            && f->op_token[0].kind == TokenKind::LitIdentifier
            && (f->op_token[1].kind == TokenKind::OpPlusPlus
                || f->op_token[1].kind == TokenKind::OpMinusMinus)
        if marked {
            return if (f->op_token[1].kind == TokenKind::OpPlusPlus) => ("++") else => "--"
        }

        var sym = ""
        for var i: usize = 0; i < f->op_token.size(); ++i {
            sym += self._op_sym(f->op_token[i], ctx)
        }

        return sym
    }

    /// The LowerTargets name of an operator C++ has no `operator` for, or "".
    static fn named_operator(f: unsafe *Declarations::FunctionDecl) -> string {
        var k = OperatorFacts::single_kind(f)
        if k == TokenKind::KwIn {
            return if (f->params.size() > 1) => (LowerTargets::op_contains())
                   else => LowerTargets::op_iter()
        }

        if k == TokenKind::OpCaretCaret {
            return LowerTargets::op_pow()
        }

        if k == TokenKind::KwAwait {
            return LowerTargets::op_await()
        }

        if k == TokenKind::KwSpawn {
            return LowerTargets::op_spawn()
        }

        if k == TokenKind::KwThread {
            return LowerTargets::op_thread()
        }

        if k == TokenKind::KwPanic {
            return LowerTargets::op_panic()
        }

        return ""
    }

    /// \p f, a form of a split subscript (OperatorFacts::in_split_subscript),
    /// gets a C++ `operator[]` forwarder to its named member, so C++
    /// code subscripts the type as it always did: the place form's on a
    /// mutable object, a read form's (`const` when it takes `const self`)
    /// on a const one. InterfaceEmitter declares it, EmitIR defines it
    /// beside the form's own definition. None for a member template or an
    /// unnamed operand (nothing to forward without spelling arguments), and
    /// none for a read form C++ would see as the same overload as a place
    /// form of its type (one constness, one operand type): the place form
    /// takes `operator[]`, since C++ writes through it, and the read form is
    /// reached by its name.
    fn subscript_forwarded(self, f: unsafe *Declarations::FunctionDecl) -> bool {
        if f == &null || f->is_poisoned() || !OperatorFacts::in_split_subscript(f) {
            return false
        }

        if self.template_head(unsafe (f as unsafe *Decl)).size() > 0 {
            return false
        }

        for var i: usize = 0; i < f->params.size(); ++i {
            var unsafe *p = f->params[i]
            if p != &null && !p->is_self && (p->unname || p->is_pack) {
                return false
            }
        }

        if OperatorFacts::is_subscript_set(f) {
            return true
        }

        var unsafe *dc = f->semantic_dc
        if dc == &null || !dc->is_type_scope() {
            dc = f->lexical_dc
        }

        var unsafe *sets = if (dc != &null) => (dc->lookup_symbol(
                               DeclName::subscript_set_name(),
                           ))
                           else => &null
        if sets == &null {
            return true
        }

        var unsafe *mine = Speller::_operand_of(f)
        for var i: usize = 0; i < sets->size(); ++i {
            var unsafe *g = dyn_cast<Declarations::FunctionDecl>(sets->get(i))
            if g == &null || g->is_poisoned() || g->is_const() != f->is_const() {
                continue
            }

            var unsafe *theirs = Speller::_operand_of(g)
            if mine != &null && mine == theirs {
                return false
            }
        }

        return true
    }

    /// The first operand's type after the receiver, unqualified.
    priv static fn _operand_of(f: unsafe *Declarations::FunctionDecl) -> unsafe *Type {
        for var i: usize = 0; i < f->params.size(); ++i {
            var unsafe *p = f->params[i]
            if p == &null || p->is_self {
                continue
            }

            if p->type_ == &null {
                return &null
            }

            return canon_unqual(p->type_->canonical)
        }

        return &null
    }

    /// `op r++` / `op r--`: the postfix form, which C++ declares with an
    /// `int` dummy parameter. By kind, as AST/OperatorFacts.k decides it.
    static fn op_is_postfix(f: unsafe *Declarations::FunctionDecl) -> bool {
        if !f->is_operator || f->op_token.size() != 2 {
            return false
        }

        if f->op_token[0].kind != TokenKind::LitIdentifier {
            return false
        }

        var k = f->op_token[1].kind
        if k != TokenKind::OpPlusPlus && k != TokenKind::OpMinusMinus {
            return false
        }

        var unsafe *ctx = Speller::tu_of(unsafe (f as unsafe *Decl))->ctx
        var        s    = ctx->get_spelling(f->op_token[0])
        return s.size() > 0 && s[0] == ('r' as u8)
    }

    /// `[]` or `[]=` returning a safe `*T` / `*const T`: a place
    /// (OperatorFacts::is_place). Any other return is a value operator and
    /// is spelled as declared.
    static fn is_place_operator(f: unsafe *Declarations::FunctionDecl) -> bool {
        return OperatorFacts::is_place(f)
    }

    /// The C++ return type of \p f: a place operator's `*T` / `*const T`
    /// becomes `T&` / `const T&`, so C++ code can write `v[i] = x` on a Kairo
    /// type and an imported `T&` and a Kairo place are one ABI. Everything
    /// else, a value `op []` included, is the declared type. The pointee of `*const T` is the `const T`
    /// canonical, so _type already spells the const and `&` goes on the end.
    fn return_spelling(self,
                       f:     unsafe *Declarations::FunctionDecl,
                       subst: unsafe *InstanceEntry,
                       scope: unsafe *Decl = &null) -> string {
        // A panicking function returns its Panic result (Compiler/Spec/Panic.md#paniclowering);
        // return_type stays the value type an importer's typing reads.
        if f->panic_result != &null {
            return self._type(f->panic_result, subst, scope)
        }

        if f->return_type == &null || f->return_type->canonical == &null {
            return self._type(f->return_type, subst, scope)
        }

        // An eval generator runs at compile time, where nothing suspends: it
        // returns the buffer its `yield`s push into (Compiler/Spec/Eval.md#eval-for).
        if f->is_eval() && f->is_generator {
            var unsafe *gr = dyn_cast<RecordType>(
                canon_unqual(f->return_type->canonical),
            )

            if gr != &null && gr->args.size() > 0 {
                return "::" + LowerTargets::eval_buf() + "<" + self._type(
                    gr->args[0],
                    subst,
                    scope,
                ) + ">"
            }
        }

        if !Speller::is_place_operator(f) && !f->cxx_ref_return {
            return self._type(f->return_type, subst, scope)
        }

        var unsafe *c = canon_unqual(f->return_type->canonical)
        if c == &null || !isa<PointerType>(c) {
            self._ice(
                f->range,
                "CXXSpell: is_place_operator accepted a non-pointer result",
            )
        }

        return self._type(cast<PointerType>(c)->pointee, subst, scope) + "&"
    }

    /// The return type a declaration or a definition of \p f is written
    /// with: its Panic result when PanicLowering gave it one
    /// (Compiler/Spec/Panic.md#paniclowering), `void` when it never returns
    /// or declares no type, else return_spelling's.
    fn declared_return(self,
                       f:     unsafe *Declarations::FunctionDecl,
                       scope: unsafe *Decl = &null) -> string {
        if f->panic_result != &null {
            return self._type(f->panic_result)
        }

        if f->is_noreturn || f->return_type == &null {
            return "void"
        }

        return self.return_spelling(f, &null, scope)
    }

    /// The type an operator belongs to: its class, or its extension's target.
    fn operator_owner(self, f: unsafe *Declarations::FunctionDecl) -> unsafe *Decl {
        var unsafe *lex = f->lexical_dc
        if lex != &null && lex->dc_kind == DeclContextKind::Extension {
            var unsafe *x = cast<Declarations::ExtensionDecl>(lex->dc_owner)
            var unsafe *c = x->target->canonical
            if c == &null || c->kind != TypeKind::RecordType {
                self._ice(
                    f->range,
                    "CXXSpell: extension operator on a non-record target",
                )
            }

            return Speller::rep(cast<RecordType>(c)->decl)
        }

        var unsafe *dc = f->semantic_dc
        if dc == &null || !dc->is_type_scope() {
            self._ice(f->range, "CXXSpell: operator with no owning type")
        }

        return Speller::rep(dc->dc_owner)
    }

    /// \p t as C++ spells it: a keyword form's symbol, any other token's own text.
    priv fn _op_sym(self, t: Token, ctx: unsafe *ASTContext) -> string {
        var s = OperatorFacts::cxx_symbol(t.kind)
        if s.size() > 0 {
            return s
        }

        return ctx->get_spelling(t)
    }
}
