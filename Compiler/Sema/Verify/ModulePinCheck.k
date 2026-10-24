/// --- The Kairo Project ----------------- Sema/Verify/ModulePinCheck.k --- ///
///
///   \brief Verify that a bare `module a::b` declaration (a pin) sits where
///          it means something.
///
///   \detail
///     In a module.k the pin names its directory as library `a::b`; the
///     resolver reads that from the file itself, before any parse
///     (SearchRoot.k read_module_pin), and only from its FIRST declaration;
///     this pass checks the parsed pin is that one (pin_counts). Anywhere
///     else the parser still accepts the form and records it on
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
import Resolution::SearchRoot::*;

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

    /// \brief whether \p tu's pin is the one the resolver reads: in a file
    ///        where pin_allowed holds, the parser accepts a pin at ANY
    ///        top-level position, but the resolver takes only the file's
    ///        FIRST declaration (read_module_pin), before any parse.
    ///
    /// \details Answered by running that very scanner over the file, not by
    ///          re-deriving its rule from the tree -- the PP has already
    ///          removed the imports a pin may follow, and a second copy of
    ///          "what counts as first" is how the two came to disagree. A pin
    ///          after `import y` or a `fn` was accepted here and ignored there:
    ///          the directory kept its folder name with nothing said.
    static fn pin_counts(tu: *TranslationUnit) -> bool {
        if tu->pin_segments.size() == 0 { return true; }
        if (tu->ctx == &null) || (tu->ctx->sm == &null) { return true; }
        var read = read_module_pin(tu->ctx->sm->get_filename(tu->fid));
        if read.size() != tu->pin_segments.size() { return false; }
        for var i: usize = 0; i < read.size(); ++i {
            if read[i] != tu->ctx->get_spelling(*(tu->pin_segments.get(i))) { return false; }
        }
        return true;
    }

    fn run(self) {
        var tu = self.sc->tu;
        if tu == &null { return; }
        if tu->pin_segments.size() == 0 { return; }

        // A second pin: the parser kept the first, and the second would
        // otherwise vanish. Placeholder code, as below.
        if tu->pin_extra_range.is_valid() {
            var x = self.sc->diag->report(DiagID::R001E, tu->pin_extra_range.start,
                "a second bare `module` declaration; a file names at most one library, with its first declaration");
            x.first(tu->pin_extra_range, "second pin");
            x.note(tu->pin_range.start, "the first pin is here");
            x.remove(tu->pin_extra_range, "remove the second pin");
            x.emit();
        }

        if ModulePinCheck::pin_allowed(tu) {
            if ModulePinCheck::pin_counts(tu) { return; }
            var pname = "";
            for var i: usize = 0; i < tu->pin_segments.size(); ++i {
                if i > 0 { pname += "::"; }
                pname += tu->ctx->get_spelling(*(tu->pin_segments.get(i)));
            }
            var m = self.sc->diag->report(DiagID::R001E, tu->pin_range.start,
                f"`module {pname}` is not the first declaration of this module.k, so it does not name the directory; a library\x27s name is read from the first declaration only");
            m.first(tu->pin_range, "not the first declaration");
            m.note("move it above every import and declaration in the file");
            m.emit();
            return;
        }

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
