/// --- The Kairo Project --------- Compiler/ASTNode/PrimaryExpressions.k ----- ///
///
///   Primary expression AST nodes. These depend only on Base and ASTContext,
///   never on Type nodes or other expression nodes. Safe to import from
///   Types.k without cycles.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// -------------------------------------------------------------------------- ///

import ASTNode::Base::*;
import AST::ASTContext::*;
import AST::Support::*;

class NamedIdentExpr; // forward decl for ChainType segments

/// ============================================================================
///  ChainType
///  i32 | Foo | Foo::Bar | ::std::String | Foo<i32>::slice::Underlying
///
///  Unified type path node. Replaces NamedType, DependentNameType, and
///  GenericInstanceType. A single unqualified name like `i32` is a one-segment
///  chain   use is_simple() to fast-path that case in sema.
///
///  examples:
///    var foo: Foo::ISomething              2 segments, no generics
///    var foo: Foo<i32>::slice              2 segments, first has generic args
///    var bar: Foo<i32>::slice::Underlying   3 segments
///    var str: std::bad::string             3 segments
///    var x:   ::GlobalType                 1 segment, sep = ColonColon
///    var y:   i32                          1 segment, is_simple() = true
/// ============================================================================
class ChainType derives Type {
    /// \enum SegmentSeparator
    /// \brief the operator prefixing a segment in the type path.
    enum SegmentSeparator derives u8 {
        None = 0,    ///< first segment in the chain.
        ColonColon,  ///< `::` scope resolution.
    }

    /// \enum SegmentKind
    /// \brief cached categorization of the segment's type node.
    enum SegmentKind derives u8 {
        Named = 0,   ///< simple identifier (`string`, `Underlying`).
        GenericApp,  ///< generic instantiation (`Foo<i32>`, `Map<K, V>`).
        Dependent,   ///< dependent type requiring deferred resolution after
                     ///  template instantiation.
    }

    /// \struct GenericArg
    /// \brief a single argument in a generic argument list, optionally named.
    ///
    /// positional: `Vec<i32>`       -> name = null, type = i32
    /// named:      `Map<Key: str>`  -> name = "Key", type = str
    struct GenericArg {
        var name:       *NamedIdentExpr;  ///< set by sema for positional args.
        var name_range: SourceRange;      ///< range of the name token, invalid if positional.
        var ty:         *Type;            ///< the type argument.
    }

    /// \struct ChainSegment
    /// \brief a single component in the type path.
    struct ChainSegment {
        var name:          *NamedIdentExpr;          ///< the identifier for this segment.
        var generic_args:  FrozenList::<GenericArg>; ///< generic arguments, empty if non-generic.
        var resolved_type: *Type;                    ///< resolved type after sema, null before.
        var resolved_decl: *Decl;                    ///< resolved declaration (TypeAlias, Class,
                                                     ///  Enum, etc.).
        var range:         SourceRange;              ///< range covering the separator and segment.
        var sep:           SegmentSeparator;         ///< operator used to reach this segment.
        var seg_kind:      SegmentKind;              ///< semantic role of this segment.
    }

    pub var segments: FrozenList::<ChainSegment>;

    /// \brief allocates a new ChainType from a temporary vector of segments.
    static fn create(
        ctx:      *ASTContext,
        range:    SourceRange
    ) -> *ChainType {
        var node   = ctx->alloc::<ChainType>();
        node->kind  = TypeKind::ChainType;
        node->range = range;
        node->annotations.set_allocator(&(ctx->nodes));
        node->init_spans(&(ctx->nodes));
        return node;
    }

    /// \brief creates a ChainType node tagged as a RecoveryType for error
    ///        resilience.
    static fn create_error(
        ctx:   *ASTContext,
        range: SourceRange
    ) -> *ChainType {
        var node            = ctx->alloc::<ChainType>();
        node->kind          = TypeKind::RecoveryType;
        node->recovery_kind = TypeKind::ChainType;
        node->range         = range;
        node->annotations.set_allocator(&(ctx->nodes));
        node->init_spans(&(ctx->nodes));
        return node;
    }

    /* OVERRIDE */ static fn classof(ptr: *Type) -> bool {
        return ptr->kind == TypeKind::ChainType;
    }

    /* OVERRIDE */ static fn type_kind() -> TypeKind {
        return TypeKind::ChainType;
    }

    fn get_segments(self) -> FrozenList::<ChainSegment> {
        return self.segments;
    }

    fn size(self) -> usize {
        return self.segments.size();
    }

    fn last(self) -> *ChainSegment {
        if (self.segments.is_empty()) {
            return &null;
        }

        return self.segments.get(self.segments.size() - 1);
    }

    fn first(self) -> *ChainSegment {
        if (self.segments.is_empty()) {
            return &null;
        }

        return self.segments.get(0);
    }

    /// \brief returns true if the chain starts with a leading `::`.
    fn accesses_global_scope(self) -> bool {
        if (self.segments.is_empty()) {
            return false;
        }

        return (self.segments[0].sep) == SegmentSeparator::ColonColon;
    }

    /// \brief returns true if any segment carries generic arguments.
    fn has_generic_args(self) -> bool {
        return self.segments.any(fn(x: *ChainSegment) -> bool {
            return !x->generic_args.is_empty();
        });
    }

    /// \brief returns true if any segment is marked dependent.
    fn has_dependent_segments(self) -> bool {
        return self.segments.any(fn(x: *ChainSegment) -> bool {
            return x->seg_kind == SegmentKind::Dependent;
        });
    }

    /// \brief returns true if this is a single unqualified name with no
    ///        generics (e.g., just `i32` or `Foo`). fast path for sema.
    fn is_simple(self) -> bool {
        return self.segments.size() == 1
            && self.segments[0].sep == SegmentSeparator::None
            && self.segments[0].generic_args.is_empty();
    }

    /// \brief returns true if this is a single name with generic args
    ///        (e.g., `Vec<i32>`). replaces GenericInstanceType check.
    fn is_generic_instance(self) -> bool {
        return self.segments.size() == 1
            && self.segments[0].sep == SegmentSeparator::None
            && !self.segments[0].generic_args.is_empty();
    }

    /// \brief returns the identifier of the final segment.
    ///        this is the actual type name in most resolution paths.
    fn trailing_name(self) -> *NamedIdentExpr {
        var seg = self.last();
        if seg == &null {
            return &null;
        }
        return seg->name;
    }
}

/// ============================================================================
///  NamedIdentExpr
///  A single identifier in expression position, optionally carrying generic
///  arguments for bare generic usage like `Bar<i32>(x)`.
///
///  `self` is represented as a NamedIdentExpr   sema identifies it by name.
///
///  examples:
///    foo            bare identifier, no generics
///    Bar<i32>       generic instantiation on a bare name
///    self           self reference, sema resolves contextually
/// ============================================================================
class NamedIdentExpr derives Expr {
    pub var name: Token;
    pub var generic_args: FrozenList::<ChainType::GenericArg>;
    pub var ctx: *ASTContext; ///< for TokenText::get_name()

    static fn create(
        ctx:   *ASTContext,
        range: SourceRange,
        name:  Token
    ) -> *NamedIdentExpr {
        var node    = ctx->alloc::<NamedIdentExpr>();
        node->kind  = ExprKind::NamedIdentExpr;
        node->range = range;
        node->name  = name;
        node->ctx   = ctx;
        node->annotations.set_allocator(&(ctx->nodes));
        return node;
    }

    static fn create_error(
        ctx:   *ASTContext,
        range: SourceRange,
        name:  Token
    ) -> *NamedIdentExpr {
        var node            = create(ctx, range, name);
        node->kind          = ExprKind::RecoveryExpr;
        node->recovery_kind = ExprKind::NamedIdentExpr;
        return node;
    }

    static fn classof(ptr: *Expr) -> bool {
        return ptr->kind == ExprKind::NamedIdentExpr;
    }

    static fn expr_kind() -> ExprKind {
        return ExprKind::NamedIdentExpr;
    }

    fn get_name(self) -> TokenText {
        return TokenText::from_token(self.name, self.ctx);
    }
}

/// ============================================================================
///  IntegerLiteralExpr
///  42 | 0xFF | 0b1010 | 0o77 | 1_000_000
/// ============================================================================
class IntegerLiteralExpr derives Expr {
    pub var token: Token;
    pub var imm: *Immediate::IntData = &null; ///< pointer to the immediate table entry
    pub var ctx: *ASTContext;
    
    static fn create(
        ctx:   *ASTContext,
        range: SourceRange,
        token: Token
    ) -> *IntegerLiteralExpr {
        var node    = ctx->alloc::<IntegerLiteralExpr>();
        node->kind  = ExprKind::IntegerLiteralExpr;
        node->range = range;
        node->token = token;
        node->ctx   = ctx;
        node->imm   = ctx->get_imm_table()->get::<Immediate::IntData>(token.imm);
        node->annotations.set_allocator(&(ctx->nodes));
        return node;
    }

    static fn create_error(
        ctx:   *ASTContext,
        range: SourceRange
    ) -> *IntegerLiteralExpr {
        var node            = ctx->alloc::<IntegerLiteralExpr>();
        node->kind          = ExprKind::RecoveryExpr;
        node->recovery_kind = ExprKind::IntegerLiteralExpr;
        node->range         = range;
        node->annotations.set_allocator(&(ctx->nodes));
        return node;
    }

    static fn classof(ptr: *Expr) -> bool {
        return ptr->kind == ExprKind::IntegerLiteralExpr;
    }

    static fn expr_kind() -> ExprKind {
        return ExprKind::IntegerLiteralExpr;
    }

    fn get_text(self) -> string {
        return TokenText::from_token(self.token, self.ctx).get_text();
    }

    fn get_body_range(self) -> SourceRange {
        assert((self.imm != &null) && r"IntegerLiteralExpr::get_body_range: imm pointer is null");
        return self.imm->body;
    }
    
    fn get_prefix_range(self) -> SourceRange {
        assert((self.imm != &null) && r"IntegerLiteralExpr::get_prefix_range: imm pointer is null");
        return self.imm->prefix;
    }
    
    fn get_suffix_range(self) -> SourceRange {
        assert((self.imm != &null) && r"IntegerLiteralExpr::get_suffix_range: imm pointer is null");
        return self.imm->suffix;
    }
    
    fn get_body_text(self) -> string {
        assert((self.imm != &null) && r"IntegerLiteralExpr::get_body_text: imm pointer is null");
        return TokenText::from_range(self.get_body_range(), self.ctx).get_text();
    }
    
    fn get_prefix_text(self) -> string {
        assert((self.imm != &null) && r"IntegerLiteralExpr::get_prefix_text: imm pointer is null");
        return TokenText::from_range(self.get_prefix_range(), self.ctx).get_text();
    }
    
    fn get_suffix_text(self) -> string {
        assert((self.imm != &null) && r"IntegerLiteralExpr::get_suffix_text: imm pointer is null");
        return TokenText::from_range(self.get_suffix_range(), self.ctx).get_text();
    }
    
    fn get_value_lo(self) -> u64 {
        assert((self.imm != &null) && r"IntegerLiteralExpr::get_value_lo: imm pointer is null");
        return self.imm->value_lo;
    }

    fn get_value_hi(self) -> u64 {
        assert((self.imm != &null) && r"IntegerLiteralExpr::get_value_hi: imm pointer is null");
        return self.imm->value_hi;
    }

    fn get_big(self) -> *BigInt {
        assert((self.imm != &null) && r"IntegerLiteralExpr::get_big: imm pointer is null");
        return self.imm->big;
    }

    fn get_bits(self) -> u16 {
        assert((self.imm != &null) && r"IntegerLiteralExpr::get_bits: imm pointer is null");
        return self.imm->bits;
    }

    fn get_base(self) -> u8 {
        assert((self.imm != &null) && r"IntegerLiteralExpr::get_base: imm pointer is null");
        return self.imm->base;
    }

    fn is_unsigned(self) -> bool {
        assert((self.imm != &null) && r"IntegerLiteralExpr::is_unsigned: imm pointer is null");
        return ((self.imm->flags) & 0b00000001) != 0;
    }

    fn is_negative(self) -> bool {
        assert((self.imm != &null) && r"IntegerLiteralExpr::is_negative: imm pointer is null");
        return ((self.imm->flags) & 0b00000010) != 0;
    }

    fn is_big(self) -> bool {
        assert((self.imm != &null) && r"IntegerLiteralExpr::is_big: imm pointer is null");
        return ((self.imm->flags) & 0b00000100) != 0;
    }

    fn has_suffix(self) -> bool {
        assert((self.imm != &null) && r"IntegerLiteralExpr::has_suffix: imm pointer is null");
        return ((self.imm->flags) & 0b00001000) != 0;
    }

    fn has_prefix(self) -> bool {
        assert((self.imm != &null) && r"IntegerLiteralExpr::has_prefix: imm pointer is null");
        return ((self.imm->flags) & 0b00010000) != 0;
    }
}

/// ============================================================================
///  FloatingLiteralExpr
///  1.2 | 1.2e-3 | 0x1.8p+1 | .5f32
/// ============================================================================
class FloatingLiteralExpr derives Expr {
    pub var token: Token;
    pub var ctx: *ASTContext; ///< for TokenText::get_name()
    pub var imm: *Immediate::FloatData = &null; ///< pointer to the immediate table entry

    static fn create(
        ctx:   *ASTContext,
        range: SourceRange,
        token: Token
    ) -> *FloatingLiteralExpr {
        var node    = ctx->alloc::<FloatingLiteralExpr>();
        node->kind  = ExprKind::FloatingLiteralExpr;
        node->range = range;
        node->token = token;
        node->ctx   = ctx;
        node->annotations.set_allocator(&(ctx->nodes));
        return node;
    }

    static fn create_error(
        ctx:   *ASTContext,
        range: SourceRange
    ) -> *FloatingLiteralExpr {
        var node            = ctx->alloc::<FloatingLiteralExpr>();
        node->kind          = ExprKind::RecoveryExpr;
        node->recovery_kind = ExprKind::FloatingLiteralExpr;
        node->range         = range;
        node->ctx           = ctx;
        node->annotations.set_allocator(&(ctx->nodes));
        return node;
    }

    static fn classof(ptr: *Expr) -> bool {
        return ptr->kind == ExprKind::FloatingLiteralExpr;
    }

    static fn expr_kind() -> ExprKind {
        return ExprKind::FloatingLiteralExpr;
    }

    fn get_text(self) -> string {
        return TokenText::from_token(self.token, self.ctx).get_text();
    }

    fn get_body_range(self) -> SourceRange {
        assert((self.imm != &null) && r"FloatingLiteralExpr::get_body_range: imm pointer is null");
        return self.imm->body;
    }
    
    fn get_prefix_range(self) -> SourceRange {
        assert((self.imm != &null) && r"FloatingLiteralExpr::get_prefix_range: imm pointer is null");
        return self.imm->prefix;
    }
    
    fn get_suffix_range(self) -> SourceRange {
        assert((self.imm != &null) && r"FloatingLiteralExpr::get_suffix_range: imm pointer is null");
        return self.imm->suffix;
    }
    
    fn get_body_text(self) -> string {
        assert((self.imm != &null) && r"FloatingLiteralExpr::get_body_text: imm pointer is null");
        return TokenText::from_range(self.get_body_range(), self.ctx).get_text();
    }
    
    fn get_prefix_text(self) -> string {
        assert((self.imm != &null) && r"FloatingLiteralExpr::get_prefix_text: imm pointer is null");
        return TokenText::from_range(self.get_prefix_range(), self.ctx).get_text();
    }
    
    fn get_suffix_text(self) -> string {
        assert((self.imm != &null) && r"FloatingLiteralExpr::get_suffix_text: imm pointer is null");
        return TokenText::from_range(self.get_suffix_range(), self.ctx).get_text();
    }
    
    fn get_bits(self) -> u32 {
        assert((self.imm != &null) && r"FloatingLiteralExpr::get_bits: imm pointer is null");
        return self.imm->bits;
    }
    
    fn get_base(self) -> u8 {
        assert((self.imm != &null) && r"FloatingLiteralExpr::get_base: imm pointer is null");
        return self.imm->base;
    }
    
    fn get_value_ieee(self) -> f80 {
        assert((self.imm != &null) && r"FloatingLiteralExpr::get_value_ieee: imm pointer is null");
        return self.imm->value_ieee;
    }
    
    fn get_big_float(self) -> *BigFloat {
        assert((self.imm != &null) && r"FloatingLiteralExpr::get_big_float: imm pointer is null");
        return self.imm->big_float;
    }

    fn is_negative(self) -> bool {
        assert((self.imm != &null) && r"FloatingLiteralExpr::is_negative: imm pointer is null");
        return ((self.imm->flags) & 0b00000010) != 0;
    }

    fn is_hex(self) -> bool {
        assert((self.imm != &null) && r"FloatingLiteralExpr::is_hex: imm pointer is null");
        return ((self.imm->flags) & 0b00000100) != 0;
    }
    
    fn is_big(self) -> bool {
        assert((self.imm != &null) && r"FloatingLiteralExpr::is_big: imm pointer is null");
        return ((self.imm->flags) & 0b00001000) != 0;
    }

    fn has_exponent(self) -> bool {
        assert((self.imm != &null) && r"FloatingLiteralExpr::has_exponent: imm pointer is null");
        return ((self.imm->flags) & 0b00000001) != 0;
    }
    
    fn has_suffix(self) -> bool {
        assert((self.imm != &null) && r"FloatingLiteralExpr::has_suffix: imm pointer is null");
        return ((self.imm->flags) & 0b00010000) != 0;
    }
}

/// ============================================================================
///  StringLiteralExpr
///  "hello" | r"raw \n" | f"hi {name}!"
/// ============================================================================
class StringLiteralExpr derives Expr {
    enum StringKind derives u8 {
        Plain,    ///< "hello"
        Raw,      ///< r"raw \n"
        Format,   ///< f"hi {name}!"
    }

    pub var token:       Token;
    pub var string_kind: StringKind;
    pub var parts:       FrozenList::<*Expr>; ///< interpolation exprs for Format strings, empty otherwise.
    pub var ctx:         *ASTContext;
    pub var imm:         *Immediate::StringData = &null; ///< pointer to the immediate table entry

    static fn create(
        ctx:         *ASTContext,
        range:       SourceRange,
        token:       Token,
        string_kind: StringKind
    ) -> *StringLiteralExpr {
        var node          = ctx->alloc::<StringLiteralExpr>();
        node->kind        = ExprKind::StringLiteralExpr;
        node->range       = range;
        node->token       = token;
        node->string_kind = string_kind;
        node->ctx         = ctx;
        node->annotations.set_allocator(&(ctx->nodes));
        return node;
    }

    static fn create_error(
        ctx:   *ASTContext,
        range: SourceRange
    ) -> *StringLiteralExpr {
        var node            = ctx->alloc::<StringLiteralExpr>();
        node->kind          = ExprKind::RecoveryExpr;
        node->recovery_kind = ExprKind::StringLiteralExpr;
        node->range         = range;
        node->ctx           = ctx;
        node->annotations.set_allocator(&(ctx->nodes));
        return node;
    }

    static fn classof(ptr: *Expr) -> bool {
        return ptr->kind == ExprKind::StringLiteralExpr;
    }

    static fn expr_kind() -> ExprKind {
        return ExprKind::StringLiteralExpr;
    }

    fn get_text(self) -> string {
        return TokenText::from_token(self.token, self.ctx).get_text();
    }

    fn get_body_range(self) -> SourceRange {
        assert((self.imm != &null) && r"StringLiteralExpr::get_body_range: imm pointer is null");
        return self.imm->body;
    }

    fn get_body_text(self) -> string {
        assert((self.imm != &null) && r"StringLiteralExpr::get_body_text: imm pointer is null");
        return TokenText::from_range(self.get_body_range(), self.ctx).get_text();
    }

    fn get_prefix(self) -> Token {
        assert((self.imm != &null) && r"StringLiteralExpr::get_prefix: imm pointer is null");
        return self.imm->prefix;
    }

    fn get_suffix(self) -> Token {
        assert((self.imm != &null) && r"StringLiteralExpr::get_suffix: imm pointer is null");
        return self.imm->suffix;
    }

    fn get_prefix_kind(self) -> Immediate::TextPrefixKind {
        assert((self.imm != &null) && r"StringLiteralExpr::get_prefix_kind: imm pointer is null");
        return self.imm->prefix_kind;
    }

    fn get_next(self) -> u32 {
        assert((self.imm != &null) && r"StringLiteralExpr::get_next: imm pointer is null");
        return self.imm->next;
    }

    fn has_next(self) -> bool {
        assert((self.imm != &null) && r"StringLiteralExpr::has_next: imm pointer is null");
        return self.imm->next != static_cast::<u32>(-1);
    }

    fn has_interpolation(self) -> bool {
        assert((self.imm != &null) && r"StringLiteralExpr::has_interpolation: imm pointer is null");
        return self.imm->exprs.size() > 0;
    }

    fn get_exprs(self) -> *libcxx::deque::<(*TokenBuffer::<16>, SourceRange)> {
        assert((self.imm != &null) && r"StringLiteralExpr::get_exprs: imm pointer is null");
        return &(self.imm->exprs);
    }

    fn interpolation_count(self) -> usize {
        assert((self.imm != &null) && r"StringLiteralExpr::interpolation_count: imm pointer is null");
        return self.imm->exprs.size();
    }

    fn is_format(self) -> bool {
        return self.string_kind == StringKind::Format;
    }

    fn is_raw(self) -> bool {
        return self.string_kind == StringKind::Raw;
    }

    fn is_plain(self) -> bool {
        return self.string_kind == StringKind::Plain;
    }

    fn is_byte_string(self) -> bool {
        assert((self.imm != &null) && r"StringLiteralExpr::is_byte_string: imm pointer is null");
        return (self.imm->prefix_kind == Immediate::TextPrefixKind::Bytes)
            || (self.imm->prefix_kind == Immediate::TextPrefixKind::BytesFormat);
    }
}

/// ============================================================================
///  CharacterLiteralExpr
///  'a' | '\n' | '\u{1F600}'
/// ============================================================================
class CharacterLiteralExpr derives Expr {
    pub var token: Token;
    pub var ctx: *ASTContext; ///< for TokenText::get_name()
    pub var imm: *Immediate::CharData = &null; ///< pointer to the immediate table entry

    static fn create(
        ctx:   *ASTContext,
        range: SourceRange,
        token: Token
    ) -> *CharacterLiteralExpr {
        var node    = ctx->alloc::<CharacterLiteralExpr>();
        node->kind  = ExprKind::CharacterLiteralExpr;
        node->range = range;
        node->token = token;
        node->ctx   = ctx;
        node->annotations.set_allocator(&(ctx->nodes));
        return node;
    }

    static fn create_error(
        ctx:   *ASTContext,
        range: SourceRange
    ) -> *CharacterLiteralExpr {
        var node            = ctx->alloc::<CharacterLiteralExpr>();
        node->kind          = ExprKind::RecoveryExpr;
        node->recovery_kind = ExprKind::CharacterLiteralExpr;
        node->range         = range;
        node->ctx           = ctx;
        node->annotations.set_allocator(&(ctx->nodes));
        return node;
    }

    static fn classof(ptr: *Expr) -> bool {
        return ptr->kind == ExprKind::CharacterLiteralExpr;
    }

    static fn expr_kind() -> ExprKind {
        return ExprKind::CharacterLiteralExpr;
    }

    fn get_text(self) -> string {
        return TokenText::from_token(self.token, self.ctx).get_text();
    }

    fn get_body_range(self) -> SourceRange {
        assert((self.imm != &null) && r"CharacterLiteralExpr::get_body_range: imm pointer is null");
        return self.imm->body;
    }

    fn get_body_text(self) -> string {
        assert((self.imm != &null) && r"CharacterLiteralExpr::get_body_text: imm pointer is null");
        return TokenText::from_range(self.get_body_range(), self.ctx).get_text();
    }

    fn get_prefix(self) -> Token {
        assert((self.imm != &null) && r"CharacterLiteralExpr::get_prefix: imm pointer is null");
        return self.imm->prefix;
    }

    fn get_suffix(self) -> Token {
        assert((self.imm != &null) && r"CharacterLiteralExpr::get_suffix: imm pointer is null");
        return self.imm->suffix;
    }

    fn get_prefix_kind(self) -> Immediate::TextPrefixKind {
        assert((self.imm != &null) && r"CharacterLiteralExpr::get_prefix_kind: imm pointer is null");
        return self.imm->prefix_kind;
    }

    fn get_next(self) -> u32 {
        assert((self.imm != &null) && r"CharacterLiteralExpr::get_next: imm pointer is null");
        return self.imm->next;
    }

    fn has_next(self) -> bool {
        assert((self.imm != &null) && r"CharacterLiteralExpr::has_next: imm pointer is null");
        return self.imm->next != static_cast::<u32>(-1);
    }

    fn has_interpolation(self) -> bool {
        assert((self.imm != &null) && r"CharacterLiteralExpr::has_interpolation: imm pointer is null");
        return self.imm->exprs.size() > 0;
    }

    fn get_exprs(self) -> *libcxx::deque::<(*TokenBuffer::<16>, SourceRange)> {
        assert((self.imm != &null) && r"CharacterLiteralExpr::get_exprs: imm pointer is null");
        return &(self.imm->exprs);
    }

    fn interpolation_count(self) -> usize {
        assert((self.imm != &null) && r"CharacterLiteralExpr::interpolation_count: imm pointer is null");
        return self.imm->exprs.size();
    }

    fn is_byte_char(self) -> bool {
        assert((self.imm != &null) && r"CharacterLiteralExpr::is_byte_char: imm pointer is null");
        return (self.imm->prefix_kind == Immediate::TextPrefixKind::Bytes)
            || (self.imm->prefix_kind == Immediate::TextPrefixKind::BytesFormat);
    }
}

/// ============================================================================
///  BooleanLiteralExpr
///  true | false
/// ============================================================================
class BooleanLiteralExpr derives Expr {
    pub var value: bool;

    static fn create(
        ctx:   *ASTContext,
        range: SourceRange,
        value: bool
    ) -> *BooleanLiteralExpr {
        var node    = ctx->alloc::<BooleanLiteralExpr>();
        node->kind  = ExprKind::BooleanLiteralExpr;
        node->range = range;
        node->value = value;
        node->annotations.set_allocator(&(ctx->nodes));
        return node;
    }

    static fn create_error(
        ctx:   *ASTContext,
        range: SourceRange
    ) -> *BooleanLiteralExpr {
        var node            = ctx->alloc::<BooleanLiteralExpr>();
        node->kind          = ExprKind::RecoveryExpr;
        node->recovery_kind = ExprKind::BooleanLiteralExpr;
        node->range         = range;
        node->annotations.set_allocator(&(ctx->nodes));
        return node;
    }

    static fn classof(ptr: *Expr) -> bool {
        return ptr->kind == ExprKind::BooleanLiteralExpr;
    }

    static fn expr_kind() -> ExprKind {
        return ExprKind::BooleanLiteralExpr;
    }
}

/// ============================================================================
///  NullLiteralExpr
///  null | &null
/// ============================================================================
class NullLiteralExpr derives Expr {
    pub var is_ref: bool; ///< true for &null (null pointer literal).

    static fn create(
        ctx:    *ASTContext,
        range:  SourceRange,
        is_ref: bool
    ) -> *NullLiteralExpr {
        var node     = ctx->alloc::<NullLiteralExpr>();
        node->kind   = ExprKind::NullLiteralExpr;
        node->range  = range;
        node->is_ref = is_ref;
        node->annotations.set_allocator(&(ctx->nodes));
        return node;
    }

    static fn create_error(
        ctx:   *ASTContext,
        range: SourceRange
    ) -> *NullLiteralExpr {
        var node            = ctx->alloc::<NullLiteralExpr>();
        node->kind          = ExprKind::RecoveryExpr;
        node->recovery_kind = ExprKind::NullLiteralExpr;
        node->range         = range;
        node->annotations.set_allocator(&(ctx->nodes));
        return node;
    }

    static fn classof(ptr: *Expr) -> bool {
        return ptr->kind == ExprKind::NullLiteralExpr;
    }

    static fn expr_kind() -> ExprKind {
        return ExprKind::NullLiteralExpr;
    }
}

/// ============================================================================
///  CompoundStmt
///  Grammar:  '{' stmt* '}'
///
///  Introduces a lexical scope. Destructors run at the closing brace in
///  reverse declaration order. `body` is populated by the parser.
/// ============================================================================
class CompoundStmt derives Stmt {
    pub var body: FrozenList::<*Stmt>;

    static fn create(ctx: *ASTContext, range: SourceRange) -> *CompoundStmt {
        var node   = ctx->alloc::<CompoundStmt>();
        node->kind  = StmtKind::CompoundStmt;
        node->range = range;
        node->annotations.set_allocator(&(ctx->nodes));
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *CompoundStmt {
        var node            = ctx->alloc::<CompoundStmt>();
        node->kind          = StmtKind::RecoveryStmt;
        node->recovery_kind = StmtKind::CompoundStmt;
        node->range         = range;
        node->annotations.set_allocator(&(ctx->nodes));
        return node;
    }

    /* OVERRIDE */ static fn classof(ptr: *Stmt) -> bool {
        return ptr->kind == StmtKind::CompoundStmt;
    }
    /* OVERRIDE */ static fn stmt_kind() -> StmtKind {
        return StmtKind::CompoundStmt;
    }
}
