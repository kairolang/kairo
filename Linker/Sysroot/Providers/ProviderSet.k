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

pub class ProviderSet {
    /// A new provider for \p id (the caller destroys it); null for an
    /// unknown id. \p input is --input, which only the user provider reads.
    pub static fn make(const id: string, const input: string) -> unsafe *SysrootProvider {
        if id == "musl" {
            return unsafe (kairo::std::create<MuslProvider>() as unsafe *SysrootProvider)
        }

        if id == "glibc" {
            return unsafe (kairo::std::create<GlibcProvider>() as unsafe *SysrootProvider)
        }

        if id == "mingw" {
            return unsafe (kairo::std::create<MingwProvider>() as unsafe *SysrootProvider)
        }

        if id == "bundle" {
            return unsafe (kairo::std::create<BundleProvider>() as unsafe *SysrootProvider)
        }

        if id == "user" {
            return unsafe (kairo::std::create<UserProvider>(input) as unsafe *SysrootProvider)
        }

        return &null
    }
}
