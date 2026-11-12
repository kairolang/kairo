/// --- The Kairo Project ------------------------------ Sysroot/Outcome.k --- ///
///
///   What a ksys operation ends in, for its caller to report: the ksys tool
///   renders it on stderr and exits with it, the kairo driver's hook reports
///   it through its own diagnostic engine. The library never prints a
///   refusal itself, so the two cannot word it differently.
///
///   Exit statuses (SysRoot.md section 8): 0 ok, 2 refusal (one actionable
///   line), 3 build or validation failure (stage and log path).
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

/// The two failure statuses, which are also ksys's exit codes and the kairo
/// driver's when its sysroot hook fails (SysRoot.md section 8).
pub
eval SYS_STATUS_REFUSED: i32 = 2 ///< refusal: one actionable line.
pub
eval SYS_STATUS_FAILED: i32 = 3 ///< build or validation failure: stage and log path.

pub class SysOutcome {
    pub var status:  i32    = 0
    pub var message: string     ///< the one line
    pub var note:    string     ///< what to do about it, "" for none

    pub fn ok(self) -> bool {
        return self.status == 0
    }

    /// Exit 2. Returns false, so `return out.refuse(...)` ends a step.
    pub fn refuse(self, const message: string, const note: string) -> bool {
        self.status  = SYS_STATUS_REFUSED
        self.message = message
        self.note    = note
        return false
    }

    /// Exit 3.
    pub fn fail(self, const message: string, const note: string) -> bool {
        self.status  = SYS_STATUS_FAILED
        self.message = message
        self.note    = note
        return false
    }
}
