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

pub import containers::*
pub import string::*
pub import lang::*
pub import fmt::*
pub import __lang::Yield::*
pub import __lang::Range::*
pub import __lang::Byte::*
pub import __lang::Ordering::*
pub import __lang::Future::*
pub import __lang::Null::*
pub import __lang::BigInt::*
pub import __lang::BigFloat::*
pub import __lang::AssertFail::*