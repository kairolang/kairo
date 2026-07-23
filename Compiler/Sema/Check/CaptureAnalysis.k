/// --- The Kairo Project ----------------------- Sema/CaptureAnalysis.k --- ///
///
///   \brief Compute closure capture lists (free-variable analysis).
///
///   \detail
///     MUST run AFTER MatchLowering / FinallyLowering / MacroExpansion, since
///     those SYNTHESIZE closures (match->IIFE, finally->lambda). Decides
///     by-value vs by-ref capture per variable.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ----------------------------------------------------------------- ///

class Base {
    fn base_method(self) { }        // Base's API
    virtual fn speak(self) { }      // overridable
}
class Derived derives Base {
    fn derived_only(self) { }       // NOT on Base
    override fn speak(self) { }      // overrides Base's
}

fn <T derives Base> foo(a: T) requires sizeof T impl Foo {
    a.base_method()   // (1) obviously legal on the bound
    a.speak()         // (2) which speak resolves? Base's or Derived's?
    a.derived_only()  // (3) legal or not? NOT on the bound
}