/// --- The Kairo Project ----------------------- Linker/API/LinkJob.k ----- ///
///
///   \brief One link request. Borrows the driver's TargetOptions and
///          LinkerOptions instead of copying them into a parallel config:
///          the options are already typed, and a second copy is a second
///          place for a flag to be forgotten.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import Config::Target::*;
import Config::Linker::*;

class LinkJob {
    pub var target:         obs::<TargetOptions>;
    pub var opts:           obs::<LinkerOptions>;
    pub var objects:        vec::<string>;   ///< objects and archives, link order
    pub var output:         string;
    pub var threads:        u32  = 0;        ///< lld --threads; 0 = lld's default
    pub var kld_path:       string;          ///< out-of-process fallback; "" disables it
    pub var out_of_process: bool = false;    ///< force kld even when in-process is healthy

    fn LinkJob(self, target: *TargetOptions, opts: *LinkerOptions) {
        self.target = target;
        self.opts   = opts;
    }

    /// Once per path: two inputs that share an import both emit its object
    /// to the same place.
    fn add_object(self, path: string) {
        for o: string in self.objects { if o == path { return; } }
        self.objects.push_back(path);
    }
}