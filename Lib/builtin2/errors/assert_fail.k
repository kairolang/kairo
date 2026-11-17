/// --- The Kairo Project ------------- Lib/builtin/errors/assert_fail.k --- ///
///
///   The AssertFail lang item: the record of a failed `assert`. The file is
///   not `assert.k` because `assert` is a keyword.
///
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import string::*

/// The `assert` failure record: PanicLowering's entry point for a failed `assert`.
///
/// Compiler-facing lang item; user code does not name it. The file is `assert_fail.k` because
/// `assert` is a keyword.
pub struct AssertFail { var message: string }
