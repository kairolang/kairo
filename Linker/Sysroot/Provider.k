/// --- The Kairo Project ----------------------------- Sysroot/Provider.k --- ///
///
///   SysrootProvider (SysRoot.md section 5): the C library half of a
///   sysroot. A provider puts the libc headers in place (stage
///   libc-headers, 4.4) and the libc libraries and crt objects (stage
///   libc-libs, 4.6). It never runs CMake: builtins (4.5) and runtimes
///   (4.7) are generic stages that read the recipe.
///
///   One file per provider under Providers/; ProviderSet.k maps an id to
///   one. The generator owns the stage dirs: a provider writes only under
///   the `dst` it is given and logs under ctx->log_dir.
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

import Sysroot::Names::SysTarget
import Sysroot::Outcome::SysOutcome
import Sysroot::Share::{
    SysQuirk,
    SysRecipe,
}
import Sysroot::SysUtil::SysUtil

/// What a stage hands a provider.
pub class StageCtx {
    pub var target:  SysTarget
    pub var recipe:  SysRecipe
    pub var quirks:  cxx::std::vector<SysQuirk> ///< the quirks that matched the target
    pub var share:   string                     ///< the share tree root
    pub var inputs:  cxx::std::vector<string>   ///< the recipe's input dirs, absolute, verified
    pub var input:   string                     ///< --input DIR (user provider), "" otherwise
    pub var stage:   string                     ///< the stage dir being written (<dir>.tmp)
    pub var log_dir: string
    pub var tools:   string                     ///< the dir kcc, kld and llvm-ar were found in
    /// The stages that ran before this one: names and their committed dirs,
    /// each holding its product under out/.
    pub var done_names: cxx::std::vector<string>
    pub var done_dirs:  cxx::std::vector<string>

    /// The product dir (out/) of the earlier stage \p name; "" if it has not run.
    pub fn product(self, const name: string) -> string {
        for var i: usize = 0; i < self.done_names.size(); ++i {
            if self.done_names[i] == name {
                return self.done_dirs[i] + "/out"
            }
        }

        return ""
    }

    /// The absolute share path of the recipe template \p tmpl (a [libc]
    /// value such as "glibc/{libc_version}/{arch}/crt"), expanded.
    pub fn share_path(self, const tmpl: string) -> string {
        return self.share + "/" + self.recipe.expand(tmpl, &self.target)
    }

    /// The toolchain binary \p name (kcc, kld) beside the others.
    pub fn tool(self, const name: string) -> string {
        var exe = self.tools + "/" + name
        eval if defined!(_WIN32) {
            exe = exe + ".exe"
        }

        return exe
    }

    /// kcc, as every stage spawns it: always with --sysroot, so its own
    /// sysroot hook never re-enters ksys for the target being built.
    pub fn kcc(self, const sysroot: string) -> cxx::std::vector<string> {
        var a = cxx::std::vector<string>()
        a.push_back(self.tool("kcc"))
        a.push_back("--target=" + self.target.clang_triple)
        a.push_back("--sysroot=" + sysroot)
        return a
    }
}

pub class SysrootProvider {
    pub fn SysrootProvider(self) = default

    pub @move fn SysrootProvider(self, other: Self) = default

    virtual fn op finally(self) { }

    /// "musl" | "glibc" | "mingw" | "bundle" | "user"
    pub virtual fn id(self) -> string {
        return ""
    }

    /// Whether this provider can build \p t from \p r. The default is the
    /// recipe's arch list; a provider with more to check (an --input, the
    /// host) refines it. False sets \p out to the refusal.
    pub virtual fn supports(self, t: *SysTarget, r: *SysRecipe, @inout out: SysOutcome) -> bool {
        if !r->arches.empty() && !SysUtil::contains(&r->arches, t->arch) {
            return out.refuse(f"{t->family} has no port for {t->arch}", "")
        }

        return true
    }

    /// Stage libc-headers: the C library's headers into \p dst.
    pub virtual fn headers(self,
                           ctx:        *StageCtx,
                           const dst:  string,
                           @inout out: SysOutcome) -> bool {
        return out.refuse(f"the {self.id()} provider cannot build headers yet", "")
    }

    /// Stage libc-libs: libc, crt objects and import libraries into \p dst.
    pub virtual fn libs(self, ctx: *StageCtx, const dst: string, @inout out: SysOutcome) -> bool {
        return out.refuse(f"the {self.id()} provider cannot build libraries yet", "")
    }

    /// Anything besides the recipe, inputs and quirks that changes this
    /// provider's output, so it must enter the stage keys.
    pub virtual fn key_extra(self, t: *SysTarget) -> cxx::std::vector<string> {
        return cxx::std::vector<string>()
    }
}
