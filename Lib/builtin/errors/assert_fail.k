/// --- The Kairo Project ------------- Lib/builtin/errors/assert_fail.k --- ///
///
///   The AssertFail lang item. The file is not `assert.k` because `assert`
///   is a keyword.
///
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import string::*

pub struct AssertFail { var message: string }
