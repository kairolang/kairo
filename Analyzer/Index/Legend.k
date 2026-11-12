/// --- The Kairo Project ----------------------- Analyzer/Index/Legend.k --- ///
///
///   The semantic-token legend: token types and modifiers, their positions and the names the server advertises.
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
import AST::Context::DeclContext::{
    DeclContext,
    DeclContextKind,
}
import AST::Context::ImportOverlay::{
    ImportOverlay,
    OverlayVisibility,
}
import AST::Context::SymbolTable::{
    DeclName,
    OverloadCell,
    SymbolTable,
}
import AST::Context::TranslationUnit::TranslationUnit
import AST::DeclFacts::{
    decl_extension_of,
    decl_is_ffi,
    decl_name_tok,
    decl_requires_clause,
}
import AST::Node::Base::{
    Decl,
    Expr,
    Type,
}
import AST::Node::CanonicalNodes::{
    RecordType,
    canon_unqual,
}
import AST::Node::Casting::{
    cast,
    isa,
}
import AST::Node::Declarations
import AST::Node::Expressions
import AST::Node::PrimaryExpressions::{
    ChainExpr,
    NamedIdentExpr,
}
import AST::Node::Program::TopLevelKind
import AST::Node::Types
import AST::Visitor::RecursiveASTVisitor::RecursiveASTVisitor
import Diagnostic::Engine::DiagEngine
import DocumentStore::LineMap
import Index::Bases::*
import Index::CompletionItems::*
import Index::Hovers::*
import Index::Indexer::*
import Index::Inlays::*
import Index::Macros::*
import Index::Refs::*
import Index::Snapshot::*
import Index::Tokens::*
import Index::Writer::*
import Json::JsonWriter
import Lexer::Immediate::ImmediateTable
import Lexer::Lexer::Lexer
import Location::SourceLocation::SourceLocation
import Location::SourceManager::SourceManager
import Location::SourceRange::SourceRange
import Sema::Resolve::NameLookup::NameLookup
import Sema::SemaContext::{
    SemaContext,
    SemaPhase,
}
import Sema::SemaDump::sema_dump_decl_name
import Sema::Type::TypeUtil::TypeUtil
import Token::Token::Token
import Token::TokenKind::{
    TokenKind,
    is_keyword,
}
import Token::TokenText::TokenText

// --- the legend -------------------------------------------------------------
//
// Index = position in the `tokenTypes` / `tokenModifiers` arrays the server
// advertises at initialize (Server.k writes them from token_type_names() and
// token_modifier_names(), so the two cannot drift apart).
pub fn TT_NAMESPACE()  -> u32 {
    return 0
}

pub fn TT_TYPE()       -> u32 {
    return 1
}

pub fn TT_CLASS()      -> u32 {
    return 2
}

pub fn TT_ENUM()       -> u32 {
    return 3
}

pub fn TT_INTERFACE()  -> u32 {
    return 4
}

pub fn TT_STRUCT()     -> u32 {
    return 5
}

pub fn TT_TYPE_PARAM() -> u32 {
    return 6
}

pub fn TT_PARAMETER()  -> u32 {
    return 7
}

pub fn TT_VARIABLE()   -> u32 {
    return 8
}

pub fn TT_PROPERTY()   -> u32 {
    return 9
}

pub fn TT_ENUM_MEMBER() -> u32 {
    return 10
}

pub fn TT_FUNCTION()   -> u32 {
    return 11
}

pub fn TT_METHOD()     -> u32 {
    return 12
}

pub fn TT_MACRO()      -> u32 {
    return 13
}

pub fn TT_KEYWORD()    -> u32 {
    return 14
}

pub fn TT_COMMENT()    -> u32 {
    return 15
}

pub fn TT_STRING()     -> u32 {
    return 16
}

pub fn TT_NUMBER()     -> u32 {
    return 17
}

pub fn TT_OPERATOR()   -> u32 {
    return 18
}

pub fn TT_SELF()       -> u32 {
    return 19
}

pub fn TT_BUILTIN()    -> u32 {
    return 20
}

pub fn TT_TYPE_ALIAS() -> u32 {
    return 21
}

pub fn TT_UNION()      -> u32 {
    return 22
}

pub fn TT_NONE()       -> u32 {
    return 255
}

pub fn token_type_names() -> string {
    return "[\"namespace\",\"type\",\"class\",\"enum\",\"interface\",\"struct\",\"typeParameter\",\"parameter\"," + "\"variable\",\"property\",\"enumMember\",\"function\",\"method\",\"macro\",\"keyword\",\"comment\"," + "\"string\",\"number\",\"operator\",\"selfKeyword\",\"builtinType\",\"typeAlias\",\"union\"]"
}

pub fn TM_DECLARATION() -> u32 {
    return 1 << 0
}

pub fn TM_DEFINITION()  -> u32 {
    return 1 << 1
}

pub fn TM_READONLY()    -> u32 {
    return 1 << 2
}

pub fn TM_STATIC()      -> u32 {
    return 1 << 3
}

pub fn TM_DEPRECATED()  -> u32 {
    return 1 << 4
}

pub fn TM_ABSTRACT()    -> u32 {
    return 1 << 5
}

pub fn TM_ASYNC()       -> u32 {
    return 1 << 6
}

pub fn TM_MODIFICATION() -> u32 {
    return 1 << 7
}

pub fn TM_DOCUMENTATION() -> u32 {
    return 1 << 8
}

pub fn TM_DEFAULT_LIB() -> u32 {
    return 1 << 9
}

/// The callee was picked from an overload set, or is a user `op`.
pub fn TM_OVERLOADED()  -> u32 {
    return 1 << 10
}

/// The callee dispatches at run time through `where` guards.
pub fn TM_DISPATCHED()  -> u32 {
    return 1 << 11
}

pub fn TM_UNSAFE()      -> u32 {
    return 1 << 12
}

/// Declared in C or C++ and reached through `ffi`.
pub fn TM_FFI()         -> u32 {
    return 1 << 13
}

pub fn TM_CONSTANT()    -> u32 {
    return 1 << 14
}

pub fn TM_CONSTRUCTOR() -> u32 {
    return 1 << 15
}

/// The callee is declared in an `extend` block, not in the type itself.
pub fn TM_EXTENSION()   -> u32 {
    return 1 << 16
}

/// The `&` of `f(&x)` when the call may mutate `x`: an `@inout` marker, or
/// the address of a mutable passed to a pointer parameter (style table).
pub fn TM_MUTATES()     -> u32 {
    return 1 << 17
}

/// A `var` binding and its uses, against `const` / immutable ones.
pub fn TM_MUTABLE()     -> u32 {
    return 1 << 18
}

/// A call to a function declared `panic`. Sent only when the client asked
/// (initializationOptions.highlightPanics); the server masks it otherwise.
pub fn TM_PANICS()      -> u32 {
    return 1 << 19
}

pub fn token_modifier_names() -> string {
    return "[\"declaration\",\"definition\",\"readonly\",\"static\",\"deprecated\",\"abstract\",\"async\"," + "\"modification\",\"documentation\",\"defaultLibrary\",\"overloaded\",\"dispatched\",\"unsafe\"," + "\"ffi\",\"constant\",\"constructor\",\"extension\",\"mutates\",\"mutable\",\"panics\"]"
}
