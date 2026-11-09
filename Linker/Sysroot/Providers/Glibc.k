/// --- The Kairo Project ---------------------------- Providers/Glibc.k --- ///
///
///   The glibc provider: glibc headers per version and arch, and link stubs generated from abilists (4.4, 4.6).
///
///   A stub until SysRoot.md section 11 step 7: every stage refuses (exit 2),
///   so `ksys ensure` and the driver hook stop with a clear reason instead
///   of a half-built root.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import Sysroot::Outcome::SysOutcome
import Sysroot::Provider::{
    StageCtx,
    SysrootProvider,
}

pub class GlibcProvider derives SysrootProvider {
    pub fn GlibcProvider(self) = default

    pub override fn id(self) -> string {
        return "glibc"
    }

    pub override fn headers(self,
                            ctx:        *StageCtx,
                            const dst:  string,
                            @inout out: SysOutcome) -> bool {
        return out.refuse(
            f"the glibc provider is not implemented yet: cannot build {ctx->target.name}",
            "SysRoot.md section 11 step 7",
        )
    }

    pub override fn libs(self, ctx: *StageCtx, const dst: string, @inout out: SysOutcome) -> bool {
        return out.refuse(
            f"the glibc provider is not implemented yet: cannot build {ctx->target.name}",
            "SysRoot.md section 11 step 7",
        )
    }
}
