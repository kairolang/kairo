/// --- The Kairo Project ------------ Compiler/Options/LinkerOptions.k ----- ///
///
///   Linker, platform-specific, and embedded target options.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://kairo-lang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Kairo Software Foundation
///
/// ------------------------------------------------------------------------ ///

import Command::ParsedArgs::*;

///
/// \class LinkerOptions
///
/// \brief Linker behaviour, ELF/Mach-O/PE/WASM platform flags, and embedded
///        target settings.
///
/// All linking, platform-specific, and bare-metal flags live here so
/// CompilerInvocation can pass this directly to kld without the linker
/// driver having to pick through unrelated option structs.
///
class LinkerOptions {

    // -- general linking ---------------------------------------------------
    pub var linker_script:     string = "";
    pub var version_script:    string = "";
    pub var map_file:          string = "";
    pub var build_id:          string = "fast";
    pub var hash_style:        string = "gnu";
    pub var dynamic_linker:    string = "";
    pub var emulation:         string = "";
    pub var compress_debug:    string = "none";
    pub var rpath:             vec::<string>;       ///< --rpath (repeatable)
    pub var rpath_link:        vec::<string>;       ///< --rpath-link (repeatable)
    pub var ld_flags:          vec::<string>;       ///< --ld-flags (repeatable)
    pub var cxx_flags:         vec::<string>;       ///< --cxx-flags (repeatable)
    pub var export_dynamic:    bool   = false;
    pub var now:               bool   = false;      ///< -z now (full RELRO)
    pub var z_noexecstack:     bool   = false;

    // -- ELF/Linux feature toggles -----------------------------------------
    pub var f_relro:           i32 = -1;
    pub var f_eh_frame_hdr:    i32 = -1;
    pub var f_gc_sections:     i32 = -1;

    // -- macOS / Darwin ----------------------------------------------------
    pub var macos_version_min: string = "";
    pub var ios_version_min:   string = "";
    pub var macos_sdk:         string = "";
    pub var install_name:      string = "";
    pub var rpath_origin:      string = "";
    pub var force_load:        vec::<string>;       ///< --force-load (repeatable)
    pub var headerpad:         i32    = 0;
    pub var f_dead_strip:      i32 = -1;
    pub var f_bitcode:         i32 = -1;

    // -- Windows / PE-COFF -------------------------------------------------
    pub var subsystem:         string = "console";
    pub var pdb:               string = "";
    pub var def:               string = "";
    pub var implib:            string = "";
    pub var manifest_file:     string = "";
    pub var manifest:          bool   = false;
    pub var kill_at:           bool   = false;
    pub var stack_size:        i32    = 0;
    pub var heap_size:         i32    = 0;
    pub var f_high_entropy_va: i32 = -1;
    pub var f_dynamicbase:     i32 = -1;
    pub var f_nxcompat:        i32 = -1;
    pub var f_guard_cf:        i32 = -1;
    pub var f_tsaware:         i32 = -1;

    // -- WASM / WASI -------------------------------------------------------
    pub var wasm_exec_model:   string = "command";
    pub var wasi_version:      string = "preview1";
    pub var wasm_export:       vec::<string>;       ///< --wasm-export (repeatable)
    pub var wasm_import_memory:  bool = false;
    pub var wasm_export_memory:  bool = false;
    pub var wasm_max_memory:     i32  = 0;
    pub var wasm_initial_memory: i32  = 65536;
    pub var wasm_stack_size:     i32  = 65536;
    pub var wasi:                bool = false;
    pub var f_wasm_bulk_memory:      i32 = -1;
    pub var f_wasm_threads:          i32 = -1;
    pub var f_wasm_tail_calls:       i32 = -1;
    pub var f_wasm_simd:             i32 = -1;
    pub var f_wasm_sign_ext:         i32 = -1;
    pub var f_wasm_reference_types:  i32 = -1;
    pub var f_wasm_exceptions:       i32 = -1;

    // -- embedded / bare metal ---------------------------------------------
    pub var no_stack_check:    bool = false;
    pub var fixed_stack_size:  i32  = 0;

    static fn from_args(args: ref!(ParsedArgs)) -> LinkerOptions {
        var o = LinkerOptions();

        // -- general linking -----------------------------------------------
        (o.linker_script)   = args.get_string("linker-script");
        (o.version_script)  = args.get_string("version-script");
        (o.map_file)        = args.get_string("map-file");
        (o.build_id)        = args.get_string("build-id");
        (o.hash_style)      = args.get_string("hash-style");
        (o.dynamic_linker)  = args.get_string("dynamic-linker");
        (o.emulation)       = args.get_string("emulation");
        (o.compress_debug)  = args.get_string("compress-debug");
        (o.export_dynamic)  = args.get_bool("export-dynamic");
        (o.now)             = args.get_bool("now");
        (o.z_noexecstack)   = args.get_bool("z-noexecstack");
        for s in args.get_list("rpath")      { o.rpath.push_back(s);      }
        for s in args.get_list("rpath-link") { o.rpath_link.push_back(s); }
        for s in args.get_list("ld-flags")   { o.ld_flags.push_back(s);   }
        for s in args.get_list("cxx-flags")  { o.cxx_flags.push_back(s);  }

        // -- ELF/Linux feature toggles -------------------------------------
        (o.f_relro)          = args.get_feature("relro");
        (o.f_eh_frame_hdr)   = args.get_feature("eh-frame-hdr");
        (o.f_gc_sections)    = args.get_feature("gc-sections");

        // -- macOS / Darwin ------------------------------------------------
        (o.macos_version_min) = args.get_string("macos-version-min");
        (o.ios_version_min)   = args.get_string("ios-version-min");
        (o.macos_sdk)         = args.get_string("macos-sdk");
        (o.install_name)      = args.get_string("install-name");
        (o.rpath_origin)      = args.get_string("rpath-origin");
        (o.headerpad)         = args.get_i32("headerpad");
        (o.f_dead_strip)      = args.get_feature("dead-strip");
        (o.f_bitcode)         = args.get_feature("bitcode");
        for s in args.get_list("force-load") { o.force_load.push_back(s); }

        // -- Windows / PE-COFF ---------------------------------------------
        (o.subsystem)         = args.get_string("subsystem");
        (o.pdb)               = args.get_string("pdb");
        (o.def)               = args.get_string("def");
        (o.implib)            = args.get_string("implib");
        (o.manifest)          = args.get_bool("manifest");
        (o.manifest_file)     = args.get_string("manifest-file");
        (o.kill_at)           = args.get_bool("kill-at");
        (o.stack_size)        = args.get_i32("stack-size");
        (o.heap_size)         = args.get_i32("heap-size");
        (o.f_high_entropy_va) = args.get_feature("high-entropy-va");
        (o.f_dynamicbase)     = args.get_feature("dynamicbase");
        (o.f_nxcompat)        = args.get_feature("nxcompat");
        (o.f_guard_cf)        = args.get_feature("guard-cf");
        (o.f_tsaware)         = args.get_feature("tsaware");

        // -- WASM / WASI --------------------------------------------------
        (o.wasm_exec_model)     = args.get_string("wasm-exec-model");
        (o.wasi_version)        = args.get_string("wasi-version");
        (o.wasm_import_memory)  = args.get_bool("wasm-import-memory");
        (o.wasm_export_memory)  = args.get_bool("wasm-export-memory");
        (o.wasm_max_memory)     = args.get_i32("wasm-max-memory");
        (o.wasm_initial_memory) = args.get_i32("wasm-initial-memory");
        (o.wasm_stack_size)     = args.get_i32("wasm-stack-size");
        (o.wasi)                = args.get_bool("wasi");
        for s in args.get_list("wasm-export") { o.wasm_export.push_back(s); }
        (o.f_wasm_bulk_memory)     = args.get_feature("wasm-bulk-memory");
        (o.f_wasm_threads)         = args.get_feature("wasm-threads");
        (o.f_wasm_tail_calls)      = args.get_feature("wasm-tail-calls");
        (o.f_wasm_simd)            = args.get_feature("wasm-simd");
        (o.f_wasm_sign_ext)        = args.get_feature("wasm-sign-ext");
        (o.f_wasm_reference_types) = args.get_feature("wasm-reference-types");
        (o.f_wasm_exceptions)      = args.get_feature("wasm-exceptions");

        // -- embedded / bare metal -----------------------------------------
        (o.no_stack_check)    = args.get_bool("no-stack-check");
        (o.fixed_stack_size)  = args.get_i32("fixed-stack-size");

        return o;
    }
}