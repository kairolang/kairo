/// --- The Kairo Project ----------------- Sema/Verify/ModulePinCheck.k --- ///
///
///   \brief Verify that a bare `module a::b` declaration (a pin) sits where
///          it means something.
///
///   \detail
///     In a module.k the pin names its directory as library `a::b`; the
///     resolver reads that from the file itself, before any parse
///     (ImportProbe::read_module_pin), and this pass has nothing to say about
///     it. Anywhere else the parser still accepts the form and records it on
///     TranslationUnit::pin_segments, and THIS pass decides whether that is
///     allowed. The decision is one function, pin_allowed, so the parser and
///     the resolver stay out of it (PLAN-module-pinning.md, decision A).
///
///   Phase: VERIFY (pre-N)
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import Sema::SemaContext::*;
import AST::Context::ASTContext::*;
import AST::Context::TranslationUnit::*;
import Support::FileIO::Path::*;
import Diagnostic::Registry::*;

class ModulePinCheck {
    pub var sc: *SemaContext;

    fn ModulePinCheck(self, sc: *SemaContext) {
        self.sc = sc;
    }

    /// \brief whether \p tu may carry its bare `module a::b` pin.
    ///
    /// \details THE rule, and its only home. Today: in a module.k only, the
    ///          one file whose pin has a meaning (it names the directory as a
    ///          library). Elsewhere the meaning is undecided, and an error
    ///          now keeps every choice open, where accepting it silently
    ///          would make "does nothing" the meaning code starts relying on.
    ///          The alternatives the user may pick later, each a change to
    ///          this function and the diagnostic in run() alone:
    ///            (b) the pin names the FILE itself: `utils/strings.k` saying
    ///                `module text` is `utils::text`. Return true here, and
    ///                canonical_module_path reads the pin for the leaf.
    ///            (c) it wraps the rest of the file: `module foo` means
    ///                `module foo { <the rest> }`. Return true here, and the
    ///                parser opens the block where it records the pin.
    ///          Keyed on the file NAME, as read_module_pin is (module.k
    ///          exactly), so the two can never disagree about which file a
    ///          pin counts in.
    static fn pin_allowed(tu: *TranslationUnit) -> bool {
        if tu->pin_segments.size() == 0 { return true; }
        if (tu->ctx == &null) || (tu->ctx->sm == &null) { return true; }
        return Path::filename_of(tu->ctx->sm->get_filename(tu->fid)) == "module.k";
    }

    fn run(self) {
        var tu = self.sc->tu;
        if tu == &null { return; }
        if ModulePinCheck::pin_allowed(tu) { return; }

        var name = "";
        for var i: usize = 0; i < tu->pin_segments.size(); ++i {
            if i > 0 { name += "::"; }
            name += tu->ctx->get_spelling(*(tu->pin_segments.get(i)));
        }
        // Placeholder code: no real code covers where a declaration may
        // appear by file (verified against Resolution.diag.toml).
        var b = self.sc->diag->report(DiagID::R001E, tu->pin_range.start,
            f"a bare `module {name}` is only allowed in a module.k, where it names the directory as a library");
        b.first(tu->pin_range, "not a module.k");
        // Concatenated, not an f-string: the braces are the block form's.
        b.note("to declare a module here, use the block form `module " + name + " { ... }`");
        b.insert(tu->pin_range.end, " { }", "open the block form, and move what the module holds into it");
        b.emit();
    }
}
