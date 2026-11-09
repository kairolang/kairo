/// --- The Kairo Project ----------------------------- Providers/Musl.k --- ///
///
///   The musl provider: musl from the shipped source (4.4 install-headers + UAPI; 4.6 configure + make).
///
///   A stub until SysRoot.md section 11 step 5: every stage refuses (exit 2),
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

pub class MuslProvider derives SysrootProvider {
    pub fn MuslProvider(self) = default

    pub override fn id(self) -> string {
        return "musl"
    }

    pub override fn headers(self,
                            ctx:        *StageCtx,
                            const dst:  string,
                            @inout out: SysOutcome) -> bool {
        return out.refuse(
            f"the musl provider is not implemented yet: cannot build {ctx->target.name}",
            "SysRoot.md section 11 step 5",
        )
    }

    pub override fn libs(self, ctx: *StageCtx, const dst: string, @inout out: SysOutcome) -> bool {
        return out.refuse(
            f"the musl provider is not implemented yet: cannot build {ctx->target.name}",
            "SysRoot.md section 11 step 5",
        )
    }
}
