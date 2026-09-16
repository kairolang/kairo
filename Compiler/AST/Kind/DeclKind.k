/// --- The Kairo Project -------------------------- AST/Kind/DeclKind.k --- ///
///
///   <short description>
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///
///
///   DeclKind
///
///   Ranges:
///     [0]        Error sentinel
///     [1 .. 2]   Callable declarations
///     [3 .. 7]   Type declarations
///     [8 .. 9]   Alias / module declarations
///     [10 .. 12] Meta / tooling declarations
///
enum DeclKind derives u8 {
    // -----------------------------------------------------------------------
    //  Sentinel
    // -----------------------------------------------------------------------

    /// Parser error sentinel.
    RecoveryDecl = 0,

    // -----------------------------------------------------------------------
    //  Callable / binding declarations
    // -----------------------------------------------------------------------

    /// fn foo(...) -> T { } | fn op+(...) | override fn bar()
    /// Out-of-line defs (fn Class::method) are still FunctionDecl.
    FunctionDecl,

    /// var/const/static/eval binding at local or namespace scope.
    /// NOT class/struct members (see FieldDecl).
    VariableDecl,

    /// Class/struct/union member: var/const/static/eval, may be `mutable`.
    /// Distinct from VariableDecl: lives in a type scope, has at-decl
    /// default semantics, carries `mutable`.
    FieldDecl,

    /// A single function/closure parameter: `name: Type = default`.
    /// Owns its type, optional default expr, and binding shorthand.
    ParamDecl,

    /// A generic parameter: `<T>`, `<T impl Foo>`, `<T derives Base>`,
    /// `<T: class>`, `<const N: i32>`, `<...T>`. Carries impl + derives
    /// bounds (kept separate), kind constraint, pack flag, and optional default.
    GenericParamDecl,

    // -----------------------------------------------------------------------
    //  Type declarations
    // -----------------------------------------------------------------------

    /// struct Foo<T> impl Bar { }
    StructDecl,

    /// class Foo<T> derives Bar impl Baz { }
    ClassDecl,

    /// interface Printable<T> { }
    InterfaceDecl,

    /// extend Foo<T> impl Bar { }  (adds methods/conformance)
    ExtensionDecl,

    /// enum Direction derives u8 { } | enum <T> Result { Ok { value: T } }
    EnumDecl,

    /// A single enum variant (plain or ADT-payload).
    /// EnumDecl owns a list of these.
    EnumVariantDecl,

    /// union Foo { } (unsafe by default, C++ FFI)
    UnionDecl,

    // -----------------------------------------------------------------------
    //  Alias / module / import declarations
    // -----------------------------------------------------------------------

    /// type Meters<T> = Vec<T>
    TypeAliasDecl,

    /// module Foo { } | inline module Foo { } | anonymous module { }
    ModuleDecl,

    /// import a::b::c | import x as y | ffi "c++" import "h.hh" as z
    ImportDecl,

    // -----------------------------------------------------------------------
    //  Grouping declarations
    // -----------------------------------------------------------------------

    /// pub { fn foo() {} fn bar() {} } visibility group at decl scope.
    VisibilityGroupDecl,

    /// ffi "lang" { decl* } FFI block.
    FFIBlockDecl,

    /// eval { decl* } decl-only compile-time block at namespace/type scope.
    /// (The stmt-position eval block is StmtKind::EvalBlockStmt.)
    EvalBlockDecl,

    // -----------------------------------------------------------------------
    //  Meta / tooling declarations
    // -----------------------------------------------------------------------

    /// test "name" { }
    TestDecl,

    /// macro foo!(x) { }
    MacroDecl,

    /// macro @derive(...) { } procedural / attribute macro.
    ProcedureMacroDecl,

    // -----------------------------------------------------------------------
    //  Marker
    // -----------------------------------------------------------------------
    DeclKindCount,
}

fn to_string(dk: DeclKind) -> string {
    switch dk {
        case DeclKind::RecoveryDecl { return "RecoveryDecl"; }
        case DeclKind::FunctionDecl { return "FunctionDecl"; }
        case DeclKind::VariableDecl { return "VariableDecl"; }
        case DeclKind::FieldDecl { return "FieldDecl"; }
        case DeclKind::ParamDecl { return "ParamDecl"; }
        case DeclKind::GenericParamDecl { return "GenericParamDecl"; }
        case DeclKind::StructDecl { return "StructDecl"; }
        case DeclKind::ClassDecl { return "ClassDecl"; }
        case DeclKind::InterfaceDecl { return "InterfaceDecl"; }
        case DeclKind::ExtensionDecl { return "ExtensionDecl"; }
        case DeclKind::EnumDecl { return "EnumDecl"; }
        case DeclKind::EnumVariantDecl { return "EnumVariantDecl"; }
        case DeclKind::UnionDecl { return "UnionDecl"; }
        case DeclKind::TypeAliasDecl { return "TypeAliasDecl"; }
        case DeclKind::ModuleDecl { return "ModuleDecl"; }
        case DeclKind::ImportDecl { return "ImportDecl"; }
        case DeclKind::VisibilityGroupDecl { return "VisibilityGroupDecl"; }
        case DeclKind::FFIBlockDecl { return "FFIBlockDecl"; }
        case DeclKind::EvalBlockDecl { return "EvalBlockDecl"; }
        case DeclKind::TestDecl { return "TestDecl"; }
        case DeclKind::MacroDecl { return "MacroDecl"; }
        case DeclKind::ProcedureMacroDecl { return "ProcedureMacroDecl"; }
        case DeclKind::DeclKindCount { return "DeclKindCount"; }
    }
}