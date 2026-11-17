/// --- The Kairo Project -------------------------- AST/OperatorFacts.k --- ///
///
/// What an operator declaration IS, read off its tokens: the
/// operator with the fixity marker removed, its table key, whether
/// it is postfix, and the compound/base pairing. Every sema reader
/// of `FunctionDecl::op_token` goes through here. Speller's
/// is_place_operator mirrors is_place, return-type test included,
/// on the codegen side of the import boundary, on purpose.
///
///   Spelled through the DECL'S OWN context: `op_token` carries per-fid imm
///   indices, and reading it against another TU's context gives the
///   interner's fallback text for an operator declared anywhere else.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "vector"

import AST::Context::ASTContext::ASTContext
import AST::Context::DeclContext::{
    DeclContext,
    DeclContextKind,
}
import AST::Context::SymbolTable::DeclName
import AST::Context::TranslationUnit::TranslationUnit
import AST::DeclFacts::tu_of
import AST::LangItems::LangAttrs
import AST::Node::Base::Type
import AST::Node::CanonicalNodes::canon_unqual
import AST::Node::Casting::{
    cast,
    dyn_cast,
    isa,
}
import AST::Node::Declarations::FunctionDecl
import AST::Node::Types::{
    CXXLValueRefType,
    PointerType,
}
import Token::TokenKind::TokenKind

/// One row of the operator table: what an operator token kind is, apart
/// from any declaration of it. Fixity (`op l++` / `op r++`) and whether an
/// `op []` is a place are facts of a declaration: OperatorFacts::is_postfix
/// and OperatorFacts::is_place answer those.
pub class OperatorRow {
    pub var kind:         TokenKind
    pub var cxx:          string ///< the C++ spelling; a keyword form's is its symbol (`and` is `&&`). "" where C++ has none.
    pub var compound:     TokenKind ///< a binary operator's compound assignment (`+` has `+=`), else TkUnknown.
    pub var base:         TokenKind ///< a compound assignment's binary operator (`+=` has `+`), else TkUnknown.
    pub var ext:          string ///< the suffix of the function an extension's operator is named (LowerTargets::ext_op), or "".
    pub var unary_only:   bool ///< no operand besides the receiver.
    pub var returns_bool: bool ///< a comparison: its result is bool.

    fn OperatorRow(self,
                   kind:         TokenKind,
                   cxx_v:        string,
                   compound:     TokenKind,
                   base:         TokenKind,
                   ext:          string,
                   unary_only:   bool,
                   returns_bool: bool) {
        self.kind         = kind
        self.cxx          = cxx_v.copy()
        self.compound     = compound
        self.base         = base
        self.ext          = ext.copy()
        self.unary_only   = unary_only
        self.returns_bool = returns_bool
    }
}

/// Builds the operator table's rows. Called once, by operator_table().
/// A keyword form (`bitand`, `and_eq`) has its own row: it is its own
/// token kind, with its symbol's facts and no `ext` name (an extension's
/// operator is named from the symbol it is spelled with).
fn make_operator_table() -> cxx::std::vector<OperatorRow> {
    var rows: cxx::std::vector<OperatorRow>
    rows.reserve(51)
    rows.push_back(
        OperatorRow(
            TokenKind::OpPlus,
            "+",
            TokenKind::OpPlusEqual,
            TokenKind::TkUnknown,
            "plus",
            false,
            false,
        ),
    )

    rows.push_back(
        OperatorRow(
            TokenKind::OpMinus,
            "-",
            TokenKind::OpMinusEqual,
            TokenKind::TkUnknown,
            "minus",
            false,
            false,
        ),
    )

    rows.push_back(
        OperatorRow(
            TokenKind::OpStar,
            "*",
            TokenKind::OpStarEqual,
            TokenKind::TkUnknown,
            "mul",
            false,
            false,
        ),
    )

    rows.push_back(
        OperatorRow(
            TokenKind::OpSlash,
            "/",
            TokenKind::OpSlashEqual,
            TokenKind::TkUnknown,
            "div",
            false,
            false,
        ),
    )

    rows.push_back(
        OperatorRow(
            TokenKind::OpPercent,
            "%",
            TokenKind::OpPercentEqual,
            TokenKind::TkUnknown,
            "mod",
            false,
            false,
        ),
    )

    rows.push_back(
        OperatorRow(
            TokenKind::OpEqualEqual,
            "==",
            TokenKind::TkUnknown,
            TokenKind::TkUnknown,
            "eq",
            false,
            true,
        ),
    )

    rows.push_back(
        OperatorRow(
            TokenKind::OpExclaimEqual,
            "!=",
            TokenKind::TkUnknown,
            TokenKind::TkUnknown,
            "ne",
            false,
            true,
        ),
    )

    rows.push_back(
        OperatorRow(
            TokenKind::OpLess,
            "<",
            TokenKind::TkUnknown,
            TokenKind::TkUnknown,
            "lt",
            false,
            true,
        ),
    )

    rows.push_back(
        OperatorRow(
            TokenKind::OpLessEqual,
            "<=",
            TokenKind::TkUnknown,
            TokenKind::TkUnknown,
            "le",
            false,
            true,
        ),
    )

    rows.push_back(
        OperatorRow(
            TokenKind::OpGreater,
            ">",
            TokenKind::TkUnknown,
            TokenKind::TkUnknown,
            "gt",
            false,
            true,
        ),
    )

    rows.push_back(
        OperatorRow(
            TokenKind::OpGreaterEqual,
            ">=",
            TokenKind::TkUnknown,
            TokenKind::TkUnknown,
            "ge",
            false,
            true,
        ),
    )

    rows.push_back(
        OperatorRow(
            TokenKind::OpLessEqualGreater,
            "<=>",
            TokenKind::TkUnknown,
            TokenKind::TkUnknown,
            "cmp",
            false,
            false,
        ),
    )

    rows.push_back(
        OperatorRow(
            TokenKind::OpAmp,
            "&",
            TokenKind::OpAmpEqual,
            TokenKind::TkUnknown,
            "band",
            false,
            false,
        ),
    )

    rows.push_back(
        OperatorRow(
            TokenKind::OpPipe,
            "|",
            TokenKind::OpPipeEqual,
            TokenKind::TkUnknown,
            "bor",
            false,
            false,
        ),
    )

    rows.push_back(
        OperatorRow(
            TokenKind::OpCaret,
            "^",
            TokenKind::OpCaretEqual,
            TokenKind::TkUnknown,
            "bxor",
            false,
            false,
        ),
    )

    rows.push_back(
        OperatorRow(
            TokenKind::OpTilde,
            "~",
            TokenKind::TkUnknown,
            TokenKind::TkUnknown,
            "bnot",
            true,
            false,
        ),
    )

    rows.push_back(
        OperatorRow(
            TokenKind::OpLessLess,
            "<<",
            TokenKind::OpLessLessEqual,
            TokenKind::TkUnknown,
            "shl",
            false,
            false,
        ),
    )

    rows.push_back(
        OperatorRow(
            TokenKind::OpGreaterGreater,
            ">>",
            TokenKind::OpGreaterGreaterEqual,
            TokenKind::TkUnknown,
            "shr",
            false,
            false,
        ),
    )

    rows.push_back(
        OperatorRow(
            TokenKind::OpPlusEqual,
            "+=",
            TokenKind::TkUnknown,
            TokenKind::OpPlus,
            "plus_eq",
            false,
            false,
        ),
    )

    rows.push_back(
        OperatorRow(
            TokenKind::OpMinusEqual,
            "-=",
            TokenKind::TkUnknown,
            TokenKind::OpMinus,
            "minus_eq",
            false,
            false,
        ),
    )

    rows.push_back(
        OperatorRow(
            TokenKind::OpStarEqual,
            "*=",
            TokenKind::TkUnknown,
            TokenKind::OpStar,
            "mul_eq",
            false,
            false,
        ),
    )

    rows.push_back(
        OperatorRow(
            TokenKind::OpSlashEqual,
            "/=",
            TokenKind::TkUnknown,
            TokenKind::OpSlash,
            "div_eq",
            false,
            false,
        ),
    )

    rows.push_back(
        OperatorRow(
            TokenKind::OpPercentEqual,
            "%=",
            TokenKind::TkUnknown,
            TokenKind::OpPercent,
            "mod_eq",
            false,
            false,
        ),
    )

    rows.push_back(
        OperatorRow(
            TokenKind::OpAmpEqual,
            "&=",
            TokenKind::TkUnknown,
            TokenKind::OpAmp,
            "band_eq",
            false,
            false,
        ),
    )

    rows.push_back(
        OperatorRow(
            TokenKind::OpPipeEqual,
            "|=",
            TokenKind::TkUnknown,
            TokenKind::OpPipe,
            "bor_eq",
            false,
            false,
        ),
    )

    rows.push_back(
        OperatorRow(
            TokenKind::OpCaretEqual,
            "^=",
            TokenKind::TkUnknown,
            TokenKind::OpCaret,
            "bxor_eq",
            false,
            false,
        ),
    )

    rows.push_back(
        OperatorRow(
            TokenKind::OpLessLessEqual,
            "<<=",
            TokenKind::TkUnknown,
            TokenKind::OpLessLess,
            "shl_eq",
            false,
            false,
        ),
    )

    rows.push_back(
        OperatorRow(
            TokenKind::OpGreaterGreaterEqual,
            ">>=",
            TokenKind::TkUnknown,
            TokenKind::OpGreaterGreater,
            "shr_eq",
            false,
            false,
        ),
    )

    rows.push_back(
        OperatorRow(
            TokenKind::OpExclaim,
            "!",
            TokenKind::TkUnknown,
            TokenKind::TkUnknown,
            "not",
            false,
            false,
        ),
    )

    rows.push_back(
        OperatorRow(
            TokenKind::OpAmpAmp,
            "&&",
            TokenKind::TkUnknown,
            TokenKind::TkUnknown,
            "",
            false,
            false,
        ),
    )

    rows.push_back(
        OperatorRow(
            TokenKind::OpPipePipe,
            "||",
            TokenKind::TkUnknown,
            TokenKind::TkUnknown,
            "",
            false,
            false,
        ),
    )

    rows.push_back(
        OperatorRow(
            TokenKind::OpPlusPlus,
            "++",
            TokenKind::TkUnknown,
            TokenKind::TkUnknown,
            "",
            true,
            false,
        ),
    )

    rows.push_back(
        OperatorRow(
            TokenKind::OpMinusMinus,
            "--",
            TokenKind::TkUnknown,
            TokenKind::TkUnknown,
            "",
            true,
            false,
        ),
    )

    rows.push_back(
        OperatorRow(
            TokenKind::OpArrow,
            "->",
            TokenKind::TkUnknown,
            TokenKind::TkUnknown,
            "",
            true,
            false,
        ),
    )

    rows.push_back(
        OperatorRow(
            TokenKind::KwAnd,
            "&&",
            TokenKind::TkUnknown,
            TokenKind::TkUnknown,
            "",
            false,
            false,
        ),
    )

    rows.push_back(
        OperatorRow(
            TokenKind::KwOr,
            "||",
            TokenKind::TkUnknown,
            TokenKind::TkUnknown,
            "",
            false,
            false,
        ),
    )

    rows.push_back(
        OperatorRow(
            TokenKind::KwNot,
            "!",
            TokenKind::TkUnknown,
            TokenKind::TkUnknown,
            "",
            false,
            false,
        ),
    )

    rows.push_back(
        OperatorRow(
            TokenKind::KwXor,
            "^",
            TokenKind::OpCaretEqual,
            TokenKind::TkUnknown,
            "",
            false,
            false,
        ),
    )

    rows.push_back(
        OperatorRow(
            TokenKind::KwBitand,
            "&",
            TokenKind::OpAmpEqual,
            TokenKind::TkUnknown,
            "",
            false,
            false,
        ),
    )

    rows.push_back(
        OperatorRow(
            TokenKind::KwBitor,
            "|",
            TokenKind::OpPipeEqual,
            TokenKind::TkUnknown,
            "",
            false,
            false,
        ),
    )

    rows.push_back(
        OperatorRow(
            TokenKind::KwCompl,
            "~",
            TokenKind::TkUnknown,
            TokenKind::TkUnknown,
            "",
            true,
            false,
        ),
    )

    rows.push_back(
        OperatorRow(
            TokenKind::KwNotEq,
            "!=",
            TokenKind::TkUnknown,
            TokenKind::TkUnknown,
            "",
            false,
            true,
        ),
    )

    rows.push_back(
        OperatorRow(
            TokenKind::KwAndEq,
            "&=",
            TokenKind::TkUnknown,
            TokenKind::OpAmp,
            "",
            false,
            false,
        ),
    )

    rows.push_back(
        OperatorRow(
            TokenKind::KwOrEq,
            "|=",
            TokenKind::TkUnknown,
            TokenKind::OpPipe,
            "",
            false,
            false,
        ),
    )

    rows.push_back(
        OperatorRow(
            TokenKind::KwXorEq,
            "^=",
            TokenKind::TkUnknown,
            TokenKind::OpCaret,
            "",
            false,
            false,
        ),
    )

    rows.push_back(
        OperatorRow(
            TokenKind::KwAs,
            "",
            TokenKind::TkUnknown,
            TokenKind::TkUnknown,
            "",
            true,
            false,
        ),
    )

    rows.push_back(
        OperatorRow(
            TokenKind::KwFinally,
            "",
            TokenKind::TkUnknown,
            TokenKind::TkUnknown,
            "",
            true,
            false,
        ),
    )

    rows.push_back(
        OperatorRow(
            TokenKind::KwAwait,
            "",
            TokenKind::TkUnknown,
            TokenKind::TkUnknown,
            "",
            true,
            false,
        ),
    )

    rows.push_back(
        OperatorRow(
            TokenKind::KwSpawn,
            "",
            TokenKind::TkUnknown,
            TokenKind::TkUnknown,
            "",
            true,
            false,
        ),
    )

    rows.push_back(
        OperatorRow(
            TokenKind::KwThread,
            "",
            TokenKind::TkUnknown,
            TokenKind::TkUnknown,
            "",
            true,
            false,
        ),
    )

    rows.push_back(
        OperatorRow(
            TokenKind::KwPanic,
            "",
            TokenKind::TkUnknown,
            TokenKind::TkUnknown,
            "",
            true,
            false,
        ),
    )

    return rows
}

/// The operator table: one row per operator token kind that has a C++
/// spelling, a compound twin, or one of the flags.
pub fn operator_table() -> *cxx::std::vector<OperatorRow> {
    static OperatorTable: cxx::std::vector<OperatorRow> = make_operator_table()
    return &OperatorTable
}

/// `k`'s row of the operator table, or null when it has none.
pub fn operator_row(k: TokenKind) -> unsafe *OperatorRow {
    var *t = operator_table()
    for var i: usize = 0; i < t->size(); ++i {
        if (*t)[i].kind == k {
            return unsafe &(*t)[i]
        }
    }

    return &null
}

/// The symbol-table name of the operator `f` declares: its operator
/// tokens with the `l` / `r` fixity marker dropped (OperatorFacts::key), so
/// `op l++` and `op r++` share a name. Null and non-operator functions have
/// no operator name: the answer is `DeclName()`, which matches no cell.
pub fn op_decl_name(f: unsafe *FunctionDecl) -> DeclName {
    if f == &null || !f->is_operator {
        return DeclName()
    }

    return OperatorFacts::key(f)
}

pub class OperatorFacts {
    /// The context `f`'s tokens were interned in: its TU's. NameLookup::
    /// ctx_of's walk, restated here because the AST layer cannot import
    /// Sema -- the function's own scope chain first, then its semantic and
    /// lexical parents for a decl whose own chain is not linked.
    priv static fn _ctx(f: unsafe *FunctionDecl) -> unsafe *ASTContext {
        if f == &null {
            return &null
        }

        var unsafe *tu = tu_of(unsafe (f as unsafe *DeclContext))

        if tu == &null {
            tu = tu_of(f->semantic_dc)
        }

        if tu == &null {
            tu = tu_of(f->lexical_dc)
        }

        if tu == &null {
            return &null
        }

        return tu->ctx
    }

    /// `l` / `r` written in front of `++` / `--`. By KIND: a bare identifier
    /// is never an operator token, and the marker's spelling depends on how
    /// the parser cut the ranges.
    pub static fn has_fixity(f: unsafe *FunctionDecl) -> bool {
        if f == &null || !f->is_operator || f->op_token.size() != 2 {
            return false
        }

        if f->op_token[0].kind != TokenKind::LitIdentifier {
            return false
        }

        var k = f->op_token[1].kind
        return k == TokenKind::OpPlusPlus || k == TokenKind::OpMinusMinus
    }

    /// `op r++` / `op r--`. An unmarked `op ++` is prefix (OperatorSignatureCheck warns).
    pub static fn is_postfix(f: unsafe *FunctionDecl) -> bool {
        if !OperatorFacts::has_fixity(f) {
            return false
        }

        var unsafe *c = OperatorFacts::_ctx(f)
        if c == &null {
            return false
        }

        var s = c->get_spelling(f->op_token[0])
        return s.size() > 0 && s[0] == ('r' as u8)
    }

    /// Index of the first token that is the operator itself.
    priv static fn _first(f: unsafe *FunctionDecl) -> usize {
        return if (OperatorFacts::has_fixity(f)) => (1) else => 0
    }

    /// The operator's token kind (the first one: `[` for `op []`).
    pub static fn op_kind(f: unsafe *FunctionDecl) -> TokenKind {
        if f == &null || f->op_token.size() == 0 {
            return TokenKind::TkUnknown
        }

        var i = OperatorFacts::_first(f)
        if i >= f->op_token.size() {
            return TokenKind::TkUnknown
        }

        return f->op_token[i].kind
    }

    /// THE table key. Fixity is a fact about the decl, not part of its name:
    /// `op l++` and `op r++` are one cell, and X picks by is_postfix.
    /// ASTParse::_op_decl_name keys the parser side by the same rule.
    pub static fn key(f: unsafe *FunctionDecl) -> DeclName {
        var k0 = TokenKind::TkUnknown
        var k1 = TokenKind::TkUnknown
        var k2 = TokenKind::TkUnknown
        var n  = f->op_token.size()
        var i  = OperatorFacts::_first(f)
        if i < n {
            k0 = f->op_token[i].kind
        }

        if i + 1 < n {
            k1 = f->op_token[i + 1].kind
        }

        if i + 2 < n {
            k2 = f->op_token[i + 2].kind
        }

        return DeclName::op_name_of(k0, k1, k2)
    }

    /// `+`, `+=`, `[]`, `<=>`, `in`: the spelling with the marker dropped.
    /// A marked `++`/`--` is spelled from its kind: the token's own range may
    /// include the marker.
    pub static fn symbol(f: unsafe *FunctionDecl) -> string {
        if OperatorFacts::has_fixity(f) {
            return if (f->op_token[1].kind == TokenKind::OpPlusPlus) => ("++") else => "--"
        }

        var unsafe *c = OperatorFacts::_ctx(f)
        if c == &null {
            return "<op>"
        }

        var s = ""
        for var i: usize = 0; i < f->op_token.size(); ++i {
            s += c->get_spelling(f->op_token[i])
        }

        return s
    }

    /// `[]` and `[]=`: the operators that MAY be a place, whatever they
    /// return. `->` is not one: C++'s `operator->` returns a pointer, and so
    /// does Kairo's. `.*` and `->*` are not overloadable at all (the parser
    /// rejects the declaration), so they never reach here. The place/value
    /// decision is is_place's. Signature identity (RedeclMerge's const
    /// exemption) keys on is_subscript alone: `op []=` has no const pair.
    pub static fn is_place_kind(f: unsafe *FunctionDecl) -> bool {
        if f == &null || !f->is_operator || !f->is_method() {
            return false
        }

        return OperatorFacts::is_subscript(f) || OperatorFacts::is_subscript_set(f)
    }

    /// `op []`: the two bracket tokens (the parser takes no other pair
    /// after `[`), with the l/r marker, which `[]` never has, dropped. The
    /// read form when its type also declares `op []=`; otherwise today's
    /// one operator, place or value by its return.
    pub static fn is_subscript(f: unsafe *FunctionDecl) -> bool {
        if f == &null {
            return false
        }

        var i = OperatorFacts::_first(f)
        return f->op_token.size() == i + 2
            && OperatorFacts::_kind_at(f, i) == TokenKind::OpLSquare
            && OperatorFacts::_kind_at(f, i + 1) == TokenKind::OpRSquare
    }

    /// `op ->`: one token, member-only. With `op []` and the iteration
    /// `op in` (is_iteration) an operator a `self` / `const self` pair may
    /// declare (operator-overloading.mdx, "Const Overloading Operators");
    /// Substitution::arrow_target picks by the receiver's const.
    pub static fn is_arrow(f: unsafe *FunctionDecl) -> bool {
        return OperatorFacts::single_kind(f) == TokenKind::OpArrow
    }

    /// `op in (self)` / `op in (const self)`: the iteration form, a member
    /// `in` with no parameter but the receiver. `op in (self, x)` is
    /// containment, never this. The third operator a `self` / `const self`
    /// pair may declare (operator-overloading.mdx); StmtTyping::_iter_own_op
    /// picks by the iterable's const.
    pub static fn is_iteration(f: unsafe *FunctionDecl) -> bool {
        if OperatorFacts::single_kind(f) != TokenKind::KwIn || !f->is_method() {
            return false
        }

        for var i: usize = 0; i < f->params.size(); ++i {
            if f->params[i] != &null && !f->params[i]->is_self {
                return false
            }
        }

        return true
    }

    /// `op []=`: a write form of the subscript, three tokens (`[` `]` `=`,
    /// the `=` touching the `]`; DeclParse): the place form, or the setter
    /// (is_subscript_setter). Keyed apart from `op []`
    /// (DeclName::op_name_of), so a lookup of one never finds the other.
    pub static fn is_subscript_set(f: unsafe *FunctionDecl) -> bool {
        if f == &null {
            return false
        }

        var i = OperatorFacts::_first(f)
        return f->op_token.size() == i + 3
            && OperatorFacts::_kind_at(f, i) == TokenKind::OpLSquare
            && OperatorFacts::_kind_at(f, i + 1) == TokenKind::OpRSquare
            && OperatorFacts::_kind_at(f, i + 2) == TokenKind::OpEqual
    }

    /// `op []=` with no return type: the setter form, `fn op []= (self, k:
    /// K, v: V)`, which a plain `x[k] = v` statement calls with the value.
    /// An `op []=` that declares a return type is the place form. The two
    /// share one name (DeclName::subscript_set_name), so a lookup finds both
    /// and every reader tells them apart here.
    pub static fn is_subscript_setter(f: unsafe *FunctionDecl) -> bool {
        return OperatorFacts::is_subscript_set(f) && f->return_type == &null
    }

    /// `f` is the read form of a type whose `op []=` is only the setter
    /// form: no use of its element is a place.
    pub static fn reads_setter_only(f: unsafe *FunctionDecl) -> bool {
        if f == &null || !OperatorFacts::is_subscript(f) {
            return false
        }

        var unsafe *dc = f->semantic_dc
        if dc == &null || !dc->is_type_scope() {
            dc = f->lexical_dc
        }

        if dc == &null {
            return false
        }

        var unsafe *cell = dc->lookup_symbol(DeclName::subscript_set_name())
        if cell == &null || cell->size() == 0 {
            return false
        }

        for var i: usize = 0; i < cell->size(); ++i {
            var unsafe *g = dyn_cast<FunctionDecl>(cell->get(i))
            if g != &null && !OperatorFacts::is_subscript_setter(g) {
                return false
            }
        }

        return true
    }

    /// The record whose member `f` is declares an `op []=`: its subscript
    /// is split, and `op []` there is the read form only. A record
    /// with none keeps today's single `op []`, place or value by its return.
    /// By the record's own table: `op []=` is member-only, so it is always
    /// declared in the body the lookup scope is.
    pub static fn in_split_subscript(f: unsafe *FunctionDecl) -> bool {
        if f == &null || !f->is_operator {
            return false
        }

        if OperatorFacts::is_subscript_set(f) {
            return true
        }

        if !OperatorFacts::is_subscript(f) {
            return false
        }

        return OperatorFacts::declares_subscript_set(f->semantic_dc)
            || OperatorFacts::declares_subscript_set(f->lexical_dc)
    }

    /// `dc`'s own table holds an `op []=`.
    pub static fn declares_subscript_set(dc: unsafe *DeclContext) -> bool {
        if dc == &null || !dc->is_type_scope() {
            return false
        }

        var unsafe *cell = dc->lookup_symbol(DeclName::subscript_set_name())
        return cell != &null && cell->size() > 0
    }

    /// Token `i`'s kind, through a macro expansion. DeclParse stores an
    /// operator's tokens unwrapped (DeclParse::_stored_op_token),
    /// so this is a backstop for a declaration built any other way, where
    /// symbol() would spell through the wrapper and the kind must agree.
    priv static fn _kind_at(f: unsafe *FunctionDecl, i: usize) -> TokenKind {
        var t = f->op_token[i]
        if t.kind != TokenKind::TkMacroExpand {
            return t.kind
        }

        var unsafe *c = OperatorFacts::_ctx(f)
        if c == &null {
            return t.kind
        }

        return c->unwrap_token(t).kind
    }

    /// The operator's kind when it is one token after the l/r marker (`+`,
    /// `and`, `as`, `finally`, a marked `++`); TkUnknown for `[]` / `()`.
    /// Each kind has one spelling, so comparing it is comparing symbol()
    /// without building the string. A minted `op delete` token is KwFinally.
    pub static fn single_kind(f: unsafe *FunctionDecl) -> TokenKind {
        if f == &null {
            return TokenKind::TkUnknown
        }

        var i = OperatorFacts::_first(f)
        if f->op_token.size() != i + 1 {
            return TokenKind::TkUnknown
        }

        return OperatorFacts::_kind_at(f, i)
    }

    /// Operators a declaration may not overload at all (beyond `=` and
    /// `===`, which OperatorSignatureCheck explains each in its own words).
    /// The keyword spellings are listed apart from their symbols: `and` is
    /// its own token, not `&&`.
    pub static fn is_not_overloadable(k: TokenKind) -> bool {
        return k == TokenKind::OpAmpAmp
            || k == TokenKind::OpPipePipe
            || k == TokenKind::OpExclaim
            || k == TokenKind::KwAnd
            || k == TokenKind::KwOr
            || k == TokenKind::KwNot
            || k == TokenKind::OpDot
            || k == TokenKind::OpColonColon
            || k == TokenKind::OpRange
            || k == TokenKind::OpRangeEqual
    }

    /// Operators with no operand besides the receiver.
    pub static fn is_unary_only(k: TokenKind) -> bool {
        var unsafe *r = operator_row(k)
        return r != &null && r->unary_only
    }

    /// Comparisons, which must return bool (`in` too, with an operand: see
    /// OperatorSignatureCheck).
    pub static fn returns_bool(k: TokenKind) -> bool {
        var unsafe *r = operator_row(k)
        return r != &null && r->returns_bool
    }

    /// The C++ spelling of operator token kind `k`: a keyword form's is
    /// its symbol (`and` is `&&`, `xor_eq` is `^=`). "" for a kind with no
    /// row and for an operator C++ does not spell (`as`, `await`).
    pub static fn cxx_symbol(k: TokenKind) -> string {
        var unsafe *r = operator_row(k)
        if r == &null {
            return ""
        }

        return r->cxx.copy()
    }

    /// `[]` returning a safe `*T` / `*const T`: a place into `self`,
    /// which C++ receives as `T&` / `const T&`. The kind alone does not decide:
    /// `op [] -> [T;]` (slicing) is a value operator. `->` is never a place.
    /// A null canonical (no return type, or unresolved) is not a place.
    /// returns_place: that, or a `cxx_ref_return` function (the same C++ shape).
    /// `kairo_ret` (a Kairo definition's return type) is `*T` / `*const T`,
    /// raw or safe, and `cxx_ret` (the C++ declaration's) is `T&` / `const
    /// T&` of the same T: the definition implements the reference return
    /// (FunctionDecl::cxx_ref_return).
    pub static fn ptr_implements_lref(kairo_ret: unsafe *Type, cxx_ret: unsafe *Type) -> bool {
        var unsafe *pc = canon_unqual(kairo_ret)
        var unsafe *lc = canon_unqual(cxx_ret)
        if pc == &null || lc == &null || (!isa<PointerType>(pc)) || !isa<CXXLValueRefType>(lc) {
            return false
        }

        var unsafe *a = cast<PointerType>(pc)->pointee
        var unsafe *b = cast<CXXLValueRefType>(lc)->referee
        if a == &null || b == &null {
            return false
        }

        var unsafe *ac = if (a->canonical != &null) => (a->canonical) else => a
        var unsafe *bc = if (b->canonical != &null) => (b->canonical) else => b
        return ac == bc
    }

    pub static fn returns_place(f: unsafe *FunctionDecl) -> bool {
        return f != &null && (f->cxx_ref_return || OperatorFacts::is_place(f))
    }

    pub static fn is_place(f: unsafe *FunctionDecl) -> bool {
        if !OperatorFacts::is_place_kind(f) {
            return false
        }

        if f->return_type == &null || f->return_type->canonical == &null {
            return false
        }

        var unsafe *c = canon_unqual(f->return_type->canonical)
        return c != &null && isa<PointerType>(c) && !cast<PointerType>(c)->is_unsafe
    }

    /// `@implicit fn op as (self) -> T`: a conversion the compiler may apply
    /// without an `as` (Conversion::implicit's user rung). Probed in the
    /// DECL'S OWN imm table: attribute names are per-fid imms, and the
    /// operator is usually declared in another TU (Lib/builtin). Never
    /// interned: a name its file never spelled is on no decl there.
    pub static fn is_implicit_conv(f: unsafe *FunctionDecl) -> bool {
        if f == &null || !f->is_operator || !f->is_method() {
            return false
        }

        if OperatorFacts::op_kind(f) != TokenKind::KwAs {
            return false
        }

        return OperatorFacts::has_implicit_attr(f)
    }

    /// `@implicit` written on `f`, whatever `f` is. OperatorSignatureCheck
    /// rejects it everywhere but on a member `op as`.
    pub static fn has_implicit_attr(f: unsafe *FunctionDecl) -> bool {
        if f == &null {
            return false
        }

        var unsafe *c = OperatorFacts::_ctx(f)
        if c == &null || c->get_imm_table() == &null {
            return false
        }

        var k = c->get_imm_table()->find_ident(LangAttrs::implicit_conversion())
        if k == u32::MAX {
            return false
        }

        return f->has_attribute_named(k)
    }

    /// Parameters after `self`.
    pub static fn arity(f: unsafe *FunctionDecl) -> usize {
        var n: usize = 0
        for var i: usize = 0; i < f->params.size(); ++i {
            var unsafe *p = f->params[i]
            if p == &null || p->is_self {
                continue
            }

            n += 1
        }

        return n
    }

    /// The binary operator a compound assignment is built from, or TkUnknown.
    pub static fn compound_base(k: TokenKind) -> TokenKind {
        var unsafe *r = operator_row(k)
        if r == &null {
            return TokenKind::TkUnknown
        }

        return r->base
    }

    /// The compound assignment built from a binary operator, or TkUnknown.
    pub static fn compound_of(k: TokenKind) -> TokenKind {
        var unsafe *r = operator_row(k)
        if r == &null {
            return TokenKind::TkUnknown
        }

        return r->compound
    }

    pub static fn is_compound(k: TokenKind) -> bool {
        return OperatorFacts::compound_base(k) != TokenKind::TkUnknown
    }
}
