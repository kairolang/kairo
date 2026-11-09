/// --- The Kairo Project ------------------------ Diagnostic/DiagSink.k --- ///
///
///   DiagEngineVBase: where a DiagBuilder sends what it built. DiagEngine is
///   one implementor, BufferedDiagSink another.
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

import Diagnostic::Code::DiagCode
import Diagnostic::Diagnostic::Diagnostic

pub class DiagEngineVBase {
    virtual fn emit(self, diag: unsafe *Diagnostic) { }
    fn DiagEngineVBase(self) = default

    // Polymorphic base whose destructor owns nothing; moving it is memberwise.
    @move fn DiagEngineVBase(self, other: Self) = default

    virtual fn op finally (self) { }
    /// True when a diagnostic with \p code would be dropped at emit no matter
    /// what is attached to it. DiagBuilder asks before allocating the
    /// Diagnostic, so a suppressed warning costs no heap, labels or children.
    virtual fn drops(self, const code: DiagCode) -> bool {
        return false
    }
}
