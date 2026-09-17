/// --- The Kairo Project ------------------------- Lib/builtin/module.k --- ///
///
///   The builtin root: every declaration sema binds as a lang item. Shipped
///   with the compiler, installed under <resource-dir>/builtin, imported
///   implicitly by every translation unit. Nothing here is user-visible by
///   any name but its own; `[T]`, `{K: V}` and `string` are sugar for it.
///
///   builtin DECLARES; std EXTENDS. A type sema needs a handle to goes here.
///   A method only users call goes in std.
///
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

module builtin;

pub import containers::*
pub import string::*
pub import lang::*
