/// --- The Kairo Project ------------------------------- Providers/User.k --- ///
///
///   The user provider: an SDK the user supplies with --input DIR, never
///   shipped or generated (SysRoot.md 4.4: msvc splat as msvc.sh's
///   stage_msvc; darwin SDK as darwin.sh's stage_sdk). Darwin builds only on
///   a macOS host.
///
///   supports() is real: it is what tells a user which directory to pass.
///   The stages are stubs until SysRoot.md section 11 step 8.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import API::FS::LinkFS
import API::Text::LinkText
import Sysroot::Names::SysTarget
import Sysroot::Outcome::SysOutcome
import Sysroot::Provider::{
    StageCtx,
    SysrootProvider,
}
import Sysroot::Share::SysRecipe

pub class UserProvider derives SysrootProvider {
    pub var input: string ///< --input DIR

    pub fn UserProvider(self, const input: string) {
        self.input = input
    }

    pub override fn id(self) -> string {
        return "user"
    }

    /// The file an --input must hold for \p t: proof it is the SDK the
    /// family needs, not some other directory.
    pub static fn marker(t: *SysTarget) -> string {
        if t->family == "darwin" {
            return "SDKSettings.json"
        }

        return "crt/include/vcruntime.h"
    }

    pub override fn supports(self, t: *SysTarget, r: *SysRecipe, @inout out: SysOutcome) -> bool {
        if t->host_only {
            var mac = false
            eval if defined!(__APPLE__) {
                mac = true
            }

            if !mac {
                return out.refuse(
                    "darwin sysroots can only be built on a macOS host",
                    "elsewhere pass --sysroot naming an SDK you have, or run scripts/darwin-sysroot.sh on a Mac",
                )
            }
        }

        var what = if (t->family == "darwin") => ("a macOS SDK, as xcrun --show-sdk-path names")
                   else => "an MSVC + Windows SDK splat, as xwin or scripts/msvc-sysroot.sh lays out"
        var mark = UserProvider::marker(t)
        if self.input.empty() || !LinkFS::is_file(LinkText::join(self.input, mark)) {
            return out.refuse(
                f"{t->family} needs --input DIR ({what}); marker {mark} not found",
                "",
            )
        }

        return true
    }

    pub override fn headers(self,
                            ctx:        *StageCtx,
                            const dst:  string,
                            @inout out: SysOutcome) -> bool {
        return out.refuse(
            f"the user provider is not implemented yet: cannot build {ctx->target.name}",
            "SysRoot.md section 11 step 8",
        )
    }
}
