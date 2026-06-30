/// --- The Kairo Project ------------------- AST/Mixin/TemplateParams.k --- ///
///
///   CRTP mixin for declarations that introduce generic parameters:
///   functions, classes, structs, enums, interfaces, extensions, unions,
///   type aliases. Holds a frozen list of GenericParamDecl plus an optional
///   `where`/`requires` constraint expression.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

// needs a fwd decl from node, stage0 limitation (once stage1 is selfhosting move the code into here)