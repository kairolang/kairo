/// --- The Kairo Project ---------------- Diagnostic/FileDiagnostics.k --- ///
///
///   \brief Diagnostics kept per file, as objects
///          (Compiler/Spec/IncrementalSema.md, change 4): every diagnostic the
///          engine delivers, with the file whose check produced it.
///
///   The owner is the TU whose sink was being drained when the diagnostic
///   arrived (the driver sets \c current around each drain), so an
///   instance's diagnostic belongs to the file that checked the instance,
///   and one the driver reports itself has no owner (""). The objects are
///   the engine's: valid until it frees them (clear_retained, or the
///   CompilerInstance's end). A tool that re-checks one file replaces that
///   file's entries and keeps the rest; in delivery order they are the
///   order a run prints.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "vector"

import Diagnostic::Consumer::DiagConsumer
import Diagnostic::Diagnostic::Diagnostic

pub class FileDiagConsumer derives DiagConsumer {
    pub var diags:  cxx::std::vector<unsafe *Diagnostic>
    pub var owners: cxx::std::vector<string> ///< parallel: the owning file's path, "" for the driver
    /// The file whose sink is being drained; "" between drains.
    pub var current: string = ""
    /// The files in the order their sinks were first drained: the order a
    /// run prints them in, which a later re-check of some of them keeps
    /// (the import graph, which decides it, is the same).
    pub var order: cxx::std::vector<string>

    pub fn FileDiagConsumer(self) = default

    /* OVERRIDE */
    fn handle(self, diag: unsafe *Diagnostic) {
        if diag == &null {
            return
        }

        self.diags.push_back(diag)
        self.owners.push_back(self.current)
    }

    /// The driver is about to drain \p path's sink.
    pub fn enter(self, const path: string) {
        self.current = path
        for var i: usize = 0; i < self.order.size(); ++i {
            if self.order[i] == path {
                return
            }
        }

        self.order.push_back(path)
    }

    /// The diagnostics \p path owns, in delivery order.
    pub fn of(self, const path: string) -> cxx::std::vector<unsafe *Diagnostic> {
        var out = cxx::std::vector<unsafe *Diagnostic>()
        for var i: usize = 0; i < self.diags.size(); ++i {
            if self.owners[i] == path {
                out.push_back(self.diags[i])
            }
        }

        return out
    }

    pub fn clear(self) {
        self.diags.clear()
        self.owners.clear()
        self.order.clear()
        self.current = ""
    }
}
