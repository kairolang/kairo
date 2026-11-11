/// --- The Kairo Project ---------------------- Tooling/SemaObserver.k --- ///
///
///   A tool's view of Sema while it is still alive.
///
///   ParseAPI hands back a tree AFTER the whole schedule has run: user
///   operators are calls by then, `where` groups are folded, list literals
///   are constructor calls, and the SemaContext that could print a type is
///   destroyed. A source tool needs the tree the user wrote, with its names
///   and types resolved, which exists at exactly one point: SemaPhase::Checked,
///   where --print-sema dumps. This is the hook for that point.
///
///   Set it on the invocation before parsing:
///
///       inv.frontend.sema_observer = unsafe (my_observer as unsafe *void)
///
///   and FrontendAction calls on_checked() once per Kairo TU of the graph.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import Sema::SemaContext::SemaContext

pub class SemaObserver {
    pub fn SemaObserver(self) = default

    pub virtual fn op finally(self) { }

    /// \p sc is this TU's context: `sc->ctx`, `sc->tu`, `sc->phase`. Valid
    /// only for the duration of the call.
    ///
    /// \warning Under parallel Sema this runs on a worker thread, and several
    ///          TUs' calls overlap. An observer that collects into shared
    ///          state locks it.
    ///
    /// \warning The TU may have stopped before Checked (a hard stop in name
    ///          or type resolution): check `sc->phase` before trusting types.
    pub virtual fn on_checked(self, sc: unsafe *SemaContext) {
        0
    }

    /// The same TU once the rest of the schedule has run on it (lowering
    /// and mono), on the same thread and right after on_checked. Called for
    /// every TU on_checked saw, including one that never reached lowering
    /// (`sc->phase` says how far it got). For the facts only a lowering
    /// writes -- an ADT's layout record (EnumLayoutLowering), a `T?`'s
    /// lowered type -- which a layout query needs and the checked tree does
    /// not have yet. The tree is the lowered one: read declarations an
    /// earlier call recorded, never walk it as the user's text.
    pub virtual fn on_lowered(self, sc: unsafe *SemaContext) {
        0
    }
}
