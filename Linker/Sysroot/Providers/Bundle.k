/// --- The Kairo Project --------------------------- Providers/Bundle.k --- ///
///
///   The bundle provider: a prebuilt base system copied as is (FreeBSD,
///   NetBSD, WASI). Stage libc-headers copies every [bundle_layout] entry
///   (input subdir -> root subdir), headers and libraries alike, symlinks
///   kept; stage libc-libs has nothing left to do (SysRoot.md 4.4, 4.6).
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

import API::FS::LinkFS
import Sysroot::Outcome::SysOutcome
import Sysroot::Provider::{
    StageCtx,
    SysrootProvider,
}

pub class BundleProvider derives SysrootProvider {
    pub fn BundleProvider(self) = default

    pub override fn id(self) -> string {
        return "bundle"
    }

    pub override fn headers(self,
                            ctx:        *StageCtx,
                            const dst:  string,
                            @inout out: SysOutcome) -> bool {
        if ctx->inputs.empty() {
            return out.refuse(
                f"the {ctx->target.recipe} recipe names no input to bundle",
                "",
            )
        }

        var base = ctx->inputs[0]
        var keys = ctx->recipe.keys_of("bundle_layout")
        if keys.empty() {
            return out.refuse(
                f"the {ctx->target.recipe} recipe has no [bundle_layout]",
                "",
            )
        }

        for var k: string in keys {
            var from = base + "/" + k
            var to   = dst + "/" + ctx->recipe.str("bundle_layout", k)
            if !LinkFS::is_dir(from) {
                return out.refuse(f"share input {from} missing", "")
            }

            if !ctx->materialise(from, to, &out) {
                return false
            }
        }

        return true
    }

    pub override fn libs(self, ctx: *StageCtx, const dst: string, @inout out: SysOutcome) -> bool {
        return LinkFS::make_dirs(dst) || out.fail(f"cannot create {dst}", "")
    }
}
