/// --- The Kairo Project ------------------------ Providers/ProviderSet.k --- ///
///
///   Provider id -> provider. The only file that knows every provider.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "Native/Types.hh"

import Sysroot::Provider::SysrootProvider
import Sysroot::Providers::Bundle::BundleProvider
import Sysroot::Providers::Glibc::GlibcProvider
import Sysroot::Providers::Mingw::MingwProvider
import Sysroot::Providers::Musl::MuslProvider
import Sysroot::Providers::User::UserProvider
import Sysroot::Providers::Wasi::WasiProvider

pub class ProviderSet {
    /// A new provider for `id` (the caller destroys it); null for an
    /// unknown id. `input` is --input, which only the user provider reads.
    pub static fn make(const id: string, const input: string) -> unsafe *SysrootProvider {
        if id == "musl" {
            return unsafe (@create MuslProvider() as unsafe *SysrootProvider)
        }

        if id == "glibc" {
            return unsafe (@create GlibcProvider() as unsafe *SysrootProvider)
        }

        if id == "mingw" {
            return unsafe (@create MingwProvider() as unsafe *SysrootProvider)
        }

        if id == "wasi" {
            return unsafe (@create WasiProvider() as unsafe *SysrootProvider)
        }

        if id == "bundle" {
            return unsafe (@create BundleProvider() as unsafe *SysrootProvider)
        }

        if id == "user" {
            return unsafe (@create UserProvider(input.copy()) as unsafe *SysrootProvider)
        }

        return &null
    }
}
