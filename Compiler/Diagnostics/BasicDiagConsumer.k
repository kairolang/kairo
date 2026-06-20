/// --- The Kairo Project -- Compiler/DiagConsumer/BasicDiagConsumer.k ----- ///
///
///   Machine-readable single-line-per-diagnostic consumer.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///
///
///   Output format (one line per diagnostic, children included):
///
///     <file>:<line>:<col>: <severity> [<code>]: <message>
///
///   When no source location is available:
///
///     <severity> [<code>]: <message>
///
///   No color, no snippets, no underlines. Parseable by make, grep, editors,
///   and FileCheck. For human output use PrettyDiagConsumer. For structured
///   output use JsonDiagConsumer (not yet implemented).
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "Include/Types.hh";

import Diagnostics::Diagnostic::*;
import Diagnostics::DiagConsumer::*;
import Source::SourceManager::*;

/// Plain-text diagnostic consumer no color, no ANSI codes.
///
/// Buffers all received \c Diagnostic pointers and renders them on demand
/// via one of the \c finalize_* methods. The consumer does not own the
/// diagnostics; lifetime is managed by \c DiagEngine.
///
/// \c _sm may be null. When null, source snippets and \c --> location lines
/// are omitted from output.
///
/// \par Output format
/// \code
///   error [SC041E]: message
///     --> file.k:10:5
///     10 | <source line>
///            ^^^ label text
///      > fix: suggestion
///      > note [SC021N]: child message
///         --> file.k:8:1
/// \endcode
class BasicDiagConsumer derives DiagConsumer {
    priv var _diags: vec::<obs::<Diagnostic>>;
    priv var _sm:    opt::<SourceManager>;

    fn BasicDiagConsumer(self, sm: *SourceManager) {
        self._diags.reserve(32);
        self._sm = sm;
    }

    /// Constructs without a \c SourceManager. Source snippets will be omitted.
    fn BasicDiagConsumer(self) {
        self._diags.reserve(32);
        self._sm = &null;
    }

    // --- DiagConsumer interface ----------------------------------------------

    fn handle(self, diag: *Diagnostic) {
        self._diags.push_back(diag);
    }

    fn attach_source_manager(self, sm: *SourceManager) {
        self._sm = sm;
    }

    fn finalize_to_stderr(self) {
        for var i: usize = 0; i < self._diags.size(); ++i {
            self.emit_diag(self._diags[i]);
        }
    }

    fn finalize_to_stdout(self) {
        for var i: usize = 0; i < self._diags.size(); ++i {
            std::print(self.render_diag(self._diags[i]));
        }
    }

    fn finalize_to_file(self, path: string) {
        var out: string;
        for var i: usize = 0; i < self._diags.size(); ++i {
            out += self.render_diag(self._diags[i]);
        }
        var f = libcxx::wofstream(libcxx::filesystem::path(path.raw()));
        f << out.raw();
        f.close();
    }

    fn finalize_to_string(self) -> string {
        var out: string;
        for var i: usize = 0; i < self._diags.size(); ++i {
            out += self.render_diag(self._diags[i]);
        }
        return out;
    }

    // --- Rendering -----------------------------------------------------------

    priv fn format_loc(self, loc: SourceLocation) -> string {
        if self._sm == &null { return ""; }
        var sm       = self._sm;
        var loc_info = sm->get_line_col(loc);
        var filename = sm->get_filename(loc);
        return f"{filename}:{loc_info.line}:{loc_info.column}: ";
    }

    priv fn severity_string(self, sev: DiagSeverity) -> string {
        switch sev {
        case DiagSeverity::Fatal   { return "fatal";   }
        case DiagSeverity::Error   { return "error";   }
        case DiagSeverity::Warning { return "warning"; }
        case DiagSeverity::Note    { return "note";    }
        case DiagSeverity::Remark  { return "remark";  }
        case DiagSeverity::Debug   { return "debug";   }
        case DiagSeverity::Verbose { return "verbose"; }
        case DiagSeverity::Ignored { return "ignored"; }
        default                    { return "unknown"; }
        }
    }

    priv fn render_one(self, diag: *Diagnostic) -> string {
        var loc_prefix = (self.format_loc(diag->loc)) if diag->has_loc else "";
        var sev        = self.severity_string(diag->code.severity());
        var code       = (diag->code) as string;
        return f"{loc_prefix}{sev} [{code}]: {diag->message}\n";
    }

    /// Renders a diagnostic and all its children, one line each.
    priv fn render_diag(self, diag: *Diagnostic) -> string {
        var out = self.render_one(diag);
        for var i: usize = 0; i < diag->children.size(); ++i {
            out += self.render_one(diag->children[i]);
        }
        return out;
    }

    priv fn emit_diag(self, diag: *Diagnostic) {
        std::eprint(self.render_one(diag));
        for var i: usize = 0; i < diag->children.size(); ++i {
            std::eprint(self.render_one(diag->children[i]));
        }
    }
}