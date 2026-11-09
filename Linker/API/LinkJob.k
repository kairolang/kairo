/// --- The Kairo Project -------------------------------- API/LinkJob.k --- ///
///
///   LinkJob: one link request, borrowing the driver's typed options.
///
///   It borrows the driver's TargetOptions and LinkerOptions instead of copying
///   them into a parallel config: the options are already typed, and a second
///   copy is a second place for a flag to be forgotten.
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

import Config::Linker::LinkerOptions
import Config::Target::TargetOptions

pub class LinkJob {
    pub var target:  *TargetOptions
    pub var opts:    *LinkerOptions
    pub var objects: cxx::std::vector<string> ///< objects and archives, link order
    /// Objects linked like archive members: only for what is still undefined
    /// (lld's --start-lib/--end-lib). The Kairo library (kairo --kairo-lib)
    /// is linked this way, so a run's own copy of builtin wins and an unused
    /// std module costs nothing. After `objects`.
    pub var lazy_objects: cxx::std::vector<string>
    /// The same objects as one archive, for a linker with no --start-lib
    /// (MinGW); "" when there is none.
    pub var lazy_archive: string
    pub var output:       string
    pub var threads:      u32    = 0 ///< lld --threads; 0 = lld's default
    pub var lto:          string = "off" ///< --lto: only gates lld's --lto-O<n>; off means no bitcode reaches the link
    pub var opt_level:    i32    = 0 ///< the -O level the objects were compiled at; lld's LTO must match it
    /// lld's ThinLTO cache. Kairo emits no bitcode, but the vendored LLVM's
    /// lld libraries (liblld*.a) ARE bitcode, so a program that links lld --
    /// the compiler itself -- ThinLTO-compiled all of lld at every link (~4 s
    /// on 16 threads). Cached per module by content; "" for none.
    pub var lto_cache_dir:  string = ""
    pub var kld_path:       string         ///< out-of-process fallback; "" disables it
    pub var out_of_process: bool   = false ///< force kld even when in-process is healthy
    /// Filled by the plan, read after the link (Link::execute): the shared
    /// libraries this link takes from outside the sysroot, and the sysroot's
    /// glibc ("floor" mode only; "" otherwise), which their GLIBC_ version
    /// needs are checked against.
    pub var host_shared: cxx::std::vector<string>
    pub var glibc_floor: string

    pub fn LinkJob(self, target: *TargetOptions, opts: *LinkerOptions) {
        self.target = target
        self.opts   = opts
    }

    /// Once per path: two inputs that share an import both emit its object
    /// to the same place.
    pub fn add_object(self, const path: string) {
        for var o: string in self.objects {
            if o == path {
                return
            }
        }

        self.objects.push_back(path)
    }
}
