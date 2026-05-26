/// --- The Kairo Project ----------------------------------- <filename> --- ///
///
///   <short description>
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://kairo-lang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Kairo Software Foundation
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
    //  Callable declarations  [1 .. 2]
    // -----------------------------------------------------------------------

    /// Function / method / operator declaration:
    ///   fn foo(x: i32) -> i32 { }
    ///   fn op+(self, other: Self) -> Self { }
    ///   override fn bar() { }
    /// Node: FunctionDecl params + return type + body (nullable for fwd decl).
    FunctionDecl,

    /// Variable / constant declaration:
    ///   var x: i32 = 1;
    ///   const PI: f64 = 3.14159;
    ///   static mut COUNTER: u64 = 0;
    /// Node: VariableDecl type (inferred if omitted) + init (nullable).
    VariableDecl,

    // -----------------------------------------------------------------------
    //  Type declarations  [3 .. 7]
    // -----------------------------------------------------------------------

    /// Struct declaration:  struct Foo<T> impl Bar { }
    /// Node: StructDecl generics + implements list + body.
    StructDecl,

    /// Class declaration:  class Foo<T> derives Bar impl Baz { }
    /// Node: ClassDecl generics + derives list + implements list + body.
    ClassDecl,

    /// Interface declaration:  interface Printable<T> { }
    /// Node: InterfaceDecl generics + implements list + body.
    InterfaceDecl,

    /// Extension declaration:  extend Foo<T> impl Bar derives Baz { }
    /// Adds methods / interface conformances to an existing type.
    /// Node: ExtensionDecl target type + implements + derives + body.
    ExtensionDecl,

    /// Enum declaration:  enum Direction derives u8 { North, South = 2 }
    /// Node: EnumDecl underlying type (nullable) + variant list.
    EnumDecl,

    // Union declaration: union Foo { x: i32, y: f32 }
    // Unsafe by default, needed for C++ FFI
    UnionDecl,

    // -----------------------------------------------------------------------
    //  Alias / module declarations  [8 .. 9]
    // -----------------------------------------------------------------------

    /// Type alias:  type Meters<T> = Vec<T>
    /// Node: TypeAliasDecl generics + aliased TypeRef.
    TypeAliasDecl,

    /// Module declaration:  module Foo { } | inline module Foo { }
    /// Node: ModuleDecl is_inline flag + body.
    ModuleDecl,

    // -----------------------------------------------------------------------
    //  Meta / tooling declarations  [10 .. 12]
    // -----------------------------------------------------------------------

    /// Test declaration:  test "should add correctly" { assert 1 + 1 == 2, ""; }
    /// Node: TestDecl label StringLiteralExpr* + body.
    TestDecl,

    /// Declarative macro:  macro foo!(x) { ... }
    /// Node: MacroDecl params + body.
    MacroDecl,

    /// Procedural macro:  macro @derive_debug(...) { ... }
    /// Node: ProcedureMacroDecl params + body.
    ProcedureMacroDecl,

    // Visibility group declaration (at decl scope)
    // pub { fn foo() {} fn bar() {} }
    VisibilityGroupDecl,

    // -----------------------------------------------------------------------
    //  Marker
    // -----------------------------------------------------------------------
    DeclKindCount,
}