# Library Format (.klib)

Format version 1, draft. Not implemented: no code in `Compiler/` or `Linker/` reads or writes a `.klib`, and the producer flag (`kairo --lib`) does not exist. Parts of the AST are already shaped for it: `ImportDecl` nodes in the TU are the import authority a `.klib` would serialize (`Compiler/Preprocessor/Preprocessor.k`), and macro parameters are stored structurally so a `.klib` can rebuild them without source buffers (`MacroParamSpec`, `Compiler/AST/Node/Declarations.k`).

| Property | Value |
|---|---|
| Extension | `.klib` |
| Magic | `4B 41 49 52 4F 4B 4C 42` (`KAIROKLB`) |
| Byte order | little-endian for every multi-byte integer |
| Offsets | absolute from the start of the file unless stated |

## Overview

A `.klib` is a platform-agnostic distribution unit for one Kairo library: everything a consuming compiler needs to resolve names, type-check, borrow-check, re-lower to C++ and render diagnostics against the library's source, without the source tree or the build environment.

Producer (design intent; the flag does not exist):

```text
kairo --lib -o foo.klib src/foo.k [-I<dir> ...] [flags]
```

A consumer reads any `.klib` whose format version it supports ([Compatibility rules](#compatibility-rules)).

### Design properties

| Property | Meaning |
|---|---|
| Self-contained | One file; nothing external is needed to consume it. |
| Platform-agnostic | No target code. Target artifacts live in the per-machine cache ([Per-machine precompile cache](#per-machine-precompile-cache)). |
| Deterministic | The same source, flags and compiler version produce byte-identical output. |
| Versioned | Format version and language edition are tracked separately. |
| Verifiable | Hashes cover the header, the section directory and every payload. |
| Diagnostic-friendly | The source archive lets errors show the library's code. |
| Cache-friendly | The precompile cache is keyed by the content hash. |

### Non-goals

- Binary distribution: a `.klib` holds no object code.
- Source independence across compilers: the consumer's compiler must be compatible with the producer's.
- Security: a `.klib` is trusted input; distribution integrity is the registry's job ([Security considerations](#security-considerations)).

## File structure

```text
offset 0    Header (64 bytes)
offset 64   Section directory (section_dir_count x 48 bytes)
            Section payloads, in directory order
file_size-48  Trailer (48 bytes)
```

## Header

64 bytes at offset 0.

| Offset | Size | Field | Description |
|---|---|---|---|
| 0x00 | 8 | `magic` | `KAIROKLB` (`0x424C4B4F5249414B` read as LE u64) |
| 0x08 | 4 | `format_version` | u32, monotonic; currently 1 |
| 0x0C | 4 | `header_crc32` | CRC32 of bytes `[0x10, 0x40)` |
| 0x10 | 8 | `compiler_version` | u64, `major<<48 \| minor<<32 \| patch<<16 \| build` |
| 0x18 | 4 | `edition` | u32, the library's declared edition |
| 0x1C | 4 | `flags` | [Header flags](#header-flags) |
| 0x20 | 8 | `section_dir_offset` | u64 |
| 0x28 | 4 | `section_dir_count` | u32 |
| 0x2C | 4 | `section_dir_crc32` | CRC32 of the section directory |
| 0x30 | 8 | `payload_hash` | xxHash64 of every uncompressed payload, concatenated in directory order |
| 0x38 | 8 | `file_size` | u64, including the trailer |

### Header flags

| Bit | Name | Meaning |
|---|---|---|
| 0 | `HAS_SOURCE_ARCHIVE` | `SOURCE_ARCHIVE` present |
| 1 | `HAS_BCIR_SUMMARY` | `BCIR_SUMMARY` present |
| 2 | `HAS_MACROS` | `MACRO_DEFINITIONS` present |
| 3 | `HAS_DEBUG_INFO` | extended debug info (line tables) present |
| 4 | `COMPRESSED_PAYLOADS` | payloads use zstd |
| 5 | reserved | |
| 6 | `EXPORTS_MAIN` | the library provides `main` |
| 7 | `IS_SYSTEM_LIBRARY` | part of the Kairo distribution |
| 8-31 | reserved | zero |

## Section directory

`section_dir_count` entries of 48 bytes, sorted ascending by `section_id` so a consumer may binary-search it.

| Offset | Size | Field | Description |
|---|---|---|---|
| 0x00 | 4 | `section_id` | [Section IDs](#section-ids) |
| 0x04 | 4 | `flags` | section-specific |
| 0x08 | 8 | `uncompressed_size` | u64 |
| 0x10 | 8 | `on_disk_size` | u64 |
| 0x18 | 8 | `offset` | u64, absolute |
| 0x20 | 8 | `payload_xxhash64` | xxHash64 of the uncompressed payload |
| 0x28 | 8 | reserved | zero |

### Section IDs

| ID | Name | Required | Contents |
|---|---|---|---|
| 0x0001 | `METADATA` | yes | name, version, authors, license |
| 0x0002 | `DEPENDENCIES` | yes | required `.klib`s |
| 0x0003 | `BUILD_FLAGS` | yes | flags of the library build; layout not yet specified |
| 0x0004 | `STRING_TABLE` | yes | interned strings |
| 0x0005 | `SYMBOL_TABLE` | yes | exported symbols |
| 0x0006 | `SCOPE_TREE` | yes | declaration-context hierarchy |
| 0x0007 | `AST_NODES` | yes | serialized AST |
| 0x0008 | `TYPE_TABLE` | yes | deduplicated types |
| 0x0009 | `SOURCE_ARCHIVE` | no | original `.k` files |
| 0x000A | `SOURCE_MANIFEST` | with sources | file id to archive path |
| 0x000B | `BCIR_SUMMARY` | no | per-function borrow summaries |
| 0x000C | `BCIR_DETAIL` | no | full BCIR blobs, loaded lazily; layout not yet specified |
| 0x000D | `MACRO_DEFINITIONS` | no | macros; layout not yet specified |
| 0x000E | `DIAG_METADATA` | no | fix-it templates; layout not yet specified |
| 0x000F | `EXPORTED_ATTRIBUTES` | no | file-level attributes; layout not yet specified |
| 0x0010 | `LINE_TABLE` | no | source locations; layout not yet specified |
| 0x0020+ | extension sections | no | [Extensibility](#extensibility) |

An unknown ID below 0x0020 is a fatal load error; an unknown ID from 0x0020 up may be ignored.

## Metadata section

Section 0x0001. All `*_strref` fields are u32 indices into the [string table](#string-table-section).

| Offset | Size | Field |
|---|---|---|
| 0x00 | 4 | `name_strref` |
| 0x04 | 4 | `version_major` |
| 0x08 | 4 | `version_minor` |
| 0x0C | 4 | `version_patch` |
| 0x10 | 4 | `version_prerelease` (strref, `""` when stable) |
| 0x14 | 4 | `version_build` (strref) |
| 0x18 | 4 | `description_strref` |
| 0x1C | 4 | `license_spdx_strref` |
| 0x20 | 4 | `homepage_strref` |
| 0x24 | 4 | `repository_strref` |
| 0x28 | 4 | `author_count` |
| 0x2C | 4 x n | `authors` (strrefs) |
| | 4 | `keyword_count` |
| | 4 x n | `keywords` (strrefs) |
| | 8 | `build_timestamp` (i64, Unix seconds) |
| | 4 | `build_host_triple` (strref; diagnostics only, does not affect portability) |
| | 4 | reserved, zero |

## Dependencies section

Section 0x0002: `dep_count` (u32), then `dep_count` dependency entries.

### Dependency entry

64 bytes.

| Offset | Size | Field | Description |
|---|---|---|---|
| 0x00 | 4 | `name_strref` | dependency name |
| 0x04 | 4 | `version_req_strref` | semver range |
| 0x08 | 12 | `resolved_version_{major,minor,patch}` | three u32 |
| 0x14 | 4 | `flags` | [Dependency flags](#dependency-flags) |
| 0x18 | 8 | `expected_klib_hash` | xxHash64 of the `.klib` built against |
| 0x20 | 32 | reserved | zero |

### Dependency flags

| Bit | Name | Meaning |
|---|---|---|
| 0 | `OPTIONAL` | may be skipped when not found |
| 1 | `PUBLIC` | its types appear in this library's public API |
| 2 | `BUILD_ONLY` | needed to build, not to consume |
| 3 | `DEV_ONLY` | tests and examples only |

`expected_klib_hash` is advisory; the checks are in [Dependency version compatibility](#dependency-version-compatibility).

## String table section

Section 0x0004.

| Offset | Size | Field |
|---|---|---|
| 0x00 | 4 | `string_count` |
| 0x04 | 4 | reserved, zero |
| 0x08 | 4 x n | `offsets`, relative to the start of `blob` |
| | | `blob`: NUL-terminated UTF-8 strings |

String 0 is the empty string. `u32::MAX` means "no string". A v1 string cannot contain NUL.

## Symbol table section

Section 0x0005: `symbol_count` (u32), reserved u32, then the entries.

### Symbol entry

72 bytes.

| Offset | Size | Field | Description |
|---|---|---|---|
| 0x00 | 4 | `name_strref` | unqualified name |
| 0x04 | 4 | `qualified_name_strref` | e.g. `foo::bar::Baz` |
| 0x08 | 4 | `scope_node_id` | into `SCOPE_TREE` |
| 0x0C | 1 | `kind` | [Symbol kind](#symbol-kind) |
| 0x0D | 1 | `visibility` | [Visibility](#visibility) |
| 0x0E | 2 | `flags` | [Symbol flags](#symbol-flags) |
| 0x10 | 4 | `ast_node_id` | root of the declaration in `AST_NODES` |
| 0x14 | 4 | `type_id` | into `TYPE_TABLE`, when applicable |
| 0x18 | 4 | `bcir_summary_id` | into `BCIR_SUMMARY`, when applicable |
| 0x1C | 4 | `num_generic_params` | 0 when not generic |
| 0x20 | 4 | `num_overloads` | 1 when not overloaded |
| 0x24 | 4 | `overload_group_id` | groups an overload set |
| 0x28 | 4 | `source_file_strref` | for diagnostics |
| 0x2C | 4 | `source_line` | 1-based |
| 0x30 | 4 | `source_column` | 1-based |
| 0x34 | 4 | `attribute_set_id` | into `EXPORTED_ATTRIBUTES`, 0 for none |
| 0x38 | 16 | reserved | zero |

### Symbol kind

| Value | Kind | Value | Kind |
|---|---|---|---|
| 0x01 | `CLASS` | 0x09 | `VARIABLE` |
| 0x02 | `STRUCT` | 0x0A | `CONSTANT` |
| 0x03 | `ENUM` | 0x0B | `MODULE` |
| 0x04 | `UNION` | 0x0C | `PROC_MACRO` |
| 0x05 | `INTERFACE` | 0x0D | `BASIC_MACRO` |
| 0x06 | `TYPE_ALIAS` | 0x0E | `GENERIC_PARAM` |
| 0x07 | `FUNCTION` | 0x0F | `EXTENSION` |
| 0x08 | `OPERATOR` | | |

### Visibility

`0x01` `PUB`, `0x02` `PRIV`, `0x03` `PROT`. A normal build exports `PUB` symbols only; `PRIV` and `PROT` appear when a symbol takes part in the public API through inheritance.

### Symbol flags

| Bit | Name | Meaning |
|---|---|---|
| 0 | `IS_GENERIC` | has generic parameters |
| 1 | `IS_OVERLOADED` | part of an overload set |
| 2 | `IS_TEMPLATE` | lowered template (internal) |
| 3 | `IS_FOREIGN_CXX` | imported from C++ through ffi |
| 4 | `IS_EXTENSION` | added by an `extend` block |
| 5 | `IS_DEPRECATED` | `@deprecated` |
| 6 | `HAS_DEFAULT_ARGS` | |
| 7 | `IS_NOEXCEPT` | |
| 8 | `IS_CONSTEXPR` | evaluable at compile time |
| 9 | `IS_INLINE` | |
| 10 | `IS_STATIC` | |
| 11 | `IS_ABSTRACT` | interface method without a body |
| 12-15 | reserved | zero |

## Scope tree section

Section 0x0006: `node_count` (u32), `root_node_id` (u32, usually 0), then the nodes. It mirrors the compiler's `DeclContext` tree (`Compiler/AST/Context/DeclContext.k`) and lets a consumer resolve a qualified name in O(depth x log(siblings)) without loading the symbol table.

### Scope node

32 bytes, then `child_count` u32 child ids sorted by `name_strref`.

| Offset | Size | Field |
|---|---|---|
| 0x00 | 4 | `node_id` (self, for validation) |
| 0x04 | 4 | `parent_node_id` (`u32::MAX` for the root) |
| 0x08 | 4 | `name_strref` (`""` for the root) |
| 0x0C | 4 | `kind` (`DeclContextKind` value) |
| 0x10 | 4 | `entry_count`: symbols declared directly here |
| 0x14 | 4 | `child_count` |
| 0x18 | 4 | `first_entry_symbol_id` |
| 0x1C | 4 | `flags` |

## AST nodes section

Section 0x0007: the exported declarations as a flat array indexed by `ast_node_id`.

### Common node prefix

| Offset | Size | Field |
|---|---|---|
| 0x00 | 4 | `node_id` |
| 0x04 | 2 | `node_class` ([Node classes](#node-classes)) |
| 0x06 | 2 | `node_kind` |
| 0x08 | 4 | `source_range_id` (into `LINE_TABLE`) |
| 0x0C | 4 | `parent_node_id` (`u32::MAX` for roots) |

### Node classes

| Value | Class | `node_kind` enum (`Compiler/AST/Kind/`) |
|---|---|---|
| 0x0001 | Expr | `ExprKind` |
| 0x0002 | Stmt | `StmtKind` |
| 0x0003 | Decl | `DeclKind` |
| 0x0004 | Type | `TypeKind` |
| 0x0005 | Pattern | `PatternKind` |
| 0x0006 | Attribute | none yet: the compiler has no attribute-kind enum |

### Node bodies

A body follows the prefix, 4-byte aligned. Its length is fixed by `node_kind` and the format version; there is no length field. Within a format version, fields are only appended. Full layouts for every kind are not yet written. Three representative bodies, offsets from the node start:

FunctionDecl (variable):

| Offset | Size | Field |
|---|---|---|
| 0x10 | 4 | `name_strref` |
| 0x14 | 4 | `symbol_id` |
| 0x18 | 4 | `return_type_id` |
| 0x1C | 2 | `param_count` |
| 0x1E | 2 | `generic_param_count` |
| 0x20 | 4 | `body_ast_node_id` (`u32::MAX` without a body) |
| 0x24 | 4 | `attribute_set_id` |
| 0x28 | 4 x n | `param_node_ids`, then `generic_param_ids` |

CallExpr (20-byte body):

| Offset | Size | Field |
|---|---|---|
| 0x10 | 4 | `callee_ast_node_id` |
| 0x14 | 4 | `arg_count` |
| 0x18 | 4 | `first_arg_ast_node_id` (arguments are contiguous) |
| 0x1C | 4 | `resolved_symbol_id` (`u32::MAX` when unresolved) |
| 0x20 | 4 | `flags` (bit 0: UFCS-lowered) |

NameRefExpr (16-byte body):

| Offset | Size | Field |
|---|---|---|
| 0x10 | 4 | `source_name_strref` |
| 0x14 | 4 | `resolved_name_strref` |
| 0x18 | 4 | `resolved_symbol_id` (`u32::MAX` when unresolved) |
| 0x1C | 4 | `flags` (bit 0: aliased, bit 1: using) |

## Type table section

Section 0x0008: `type_count` (u32), reserved u32, then the entries.

### Type entry

At least 16 bytes.

| Offset | Size | Field |
|---|---|---|
| 0x00 | 4 | `type_id` |
| 0x04 | 2 | `type_kind` (`TypeKind` value) |
| 0x06 | 2 | `qualifier_bits` ([Qualifier bits](#qualifier-bits)) |
| 0x08 | 4 | `body_size` |
| 0x0C | 4 | `canonical_type_id` (self when canonical) |
| 0x10 | n | kind-specific body |

### Qualifier bits

| Bit | Name | Bit | Name |
|---|---|---|---|
| 0 | `CONST` | 6 | `REFERENCE` |
| 1 | `MUTABLE` | 7 | `MOVE_REF` |
| 2 | `VOLATILE` | 8 | `OBSERVE` |
| 3 | `RESTRICT` | 9 | `OWN` |
| 4 | `NOALIAS` | 10 | `UNIQUE` |
| 5 | `POINTER` | 11 | `ARRAY` |

Bits 12-15 are reserved.

### Type bodies

| Kind | Body |
|---|---|
| primitive | empty |
| pointer | pointee `type_id` |
| generic instantiation | template `type_id`, `arg_count`, `arg_count` x arg `type_id` |
| function | return `type_id`, `param_count`, `param_count` x param `type_id`, `flags` |

Layouts for the remaining kinds are not yet written.

## Source archive section

Section 0x0009, optional: the library's `.k` sources for diagnostics.

| Offset | Size | Field |
|---|---|---|
| 0x00 | 8 | `archive_size` |
| 0x08 | 4 | `file_count` |
| 0x0C | 4 | reserved, zero |
| 0x10 | n | zstd-compressed tar stream |

Entries are regular files named by module path (`foo/bar/baz.k`): no directories, symlinks or special files. Each file appears once however often it was imported. `SOURCE_MANIFEST` (0x000A, layout not yet specified) maps file ids to entry names.

## BCIR summary section

Section 0x000B, optional: per-function summaries for borrow-checking a consumer against the library. The compiler has no BCIR yet (its flags are unimplemented; [Driver.md](Driver.md#unimplemented-flags)), so nothing can produce this section.

Header: `summary_count` (u32), reserved u32, then the summaries.

### BCIR summary

40 bytes, then `param_count` x 8-byte [parameter borrows](#parameter-borrow).

| Offset | Size | Field |
|---|---|---|
| 0x00 | 4 | `symbol_id` |
| 0x04 | 4 | `param_count` (u16, then u16 padding) |
| 0x08 | 4 | `flags` ([Summary flags](#summary-flags)) |
| 0x0C | 4 | `return_lifetime_binding` ([Return lifetime binding](#return-lifetime-binding)) |
| 0x10 | 8 | `detail_offset` into `BCIR_DETAIL` (`u64::MAX` for none) |
| 0x18 | 8 | `detail_size` (compressed) |
| 0x20 | 4 | `effect_set` |
| 0x24 | 4 | `panic_flags` ([Panic flags](#panic-flags)) |

### Summary flags

| Bit | Name | Meaning |
|---|---|---|
| 0 | `IS_PURE` | no observable side effects |
| 1 | `MAY_ALIAS` | output may alias inputs |
| 2 | `MAY_PANIC` | |
| 3 | `IS_ASYNC` | returns a task or future |
| 4 | `CAPTURES_SELF` | `self` outlives the call |
| 5 | `HAS_DETAIL` | a `BCIR_DETAIL` entry exists |

### Return lifetime binding

`0xFFFFFFFF`: the return is owned. `0x0000`-`0xFFFF`: the return's lifetime is tied to the parameter at that index. Other values are reserved.

### Panic flags

| Bit | Name | Meaning |
|---|---|---|
| 0 | `ARITHMETIC` | division by zero, overflow |
| 1 | `BOUNDS` | array or slice bounds |
| 2 | `UNWRAP` | null unwrap |
| 3 | `ASSERTION` | a reachable `assert` |
| 4 | `EXPLICIT` | an explicit panic |
| 5 | `TRANSITIVE` | a callee can panic |

### Parameter borrow

| Offset | Size | Field |
|---|---|---|
| 0x00 | 1 | `kind`: 0 none (by value), 1 shared ref, 2 mutable ref, 3 owned move, 4 observed |
| 0x01 | 1 | `mutability`: 0 shared, 1 mutable |
| 0x02 | 2 | `flags` |
| 0x04 | 4 | `escape_path_id` (`u32::MAX` when it does not escape) |

## Compatibility rules

### Format version compatibility

A compiler supporting format version N reads versions up to N and rejects anything newer with a clear diagnostic. The supported range is to be queryable with `kairo --supported-klib-formats` (not implemented).

### Compatibility within a version

Within v1:

- new section IDs from 0x0020 may appear, and are ignored when not understood;
- fields may be appended to a fixed structure only where it is documented as extensible;
- values of `section_id`, symbol `kind`, `node_kind` and `type_kind` may be added; a consumer reports an unknown value as unsupported and does not crash;
- reserved flag bits may gain meaning; a consumer tolerates any bit pattern.

### Incompatible changes

A format version bump is required to change the header layout, remove a required section, change an existing field's encoding or an enum value's meaning, or drop an existing flag bit.

### Dependency version compatibility

When consuming a `.klib`, each dependency entry is checked against the resolved dependency:

| Resolved dependency | Result |
|---|---|
| same major version | proceed |
| same major, different `expected_klib_hash` | warn, proceed |
| different major | error |

### Edition compatibility

A consumer on another edition processes the library's AST and BCIR under the library's edition and its own code under its own. Symbols that do not depend on edition-specific semantics interoperate across editions. The compiler validates `--edition` but nothing reads it yet.

## Per-machine precompile cache

Design intent. A consumer builds target-specific static or dynamic libraries from a `.klib` and caches them per machine.

The draft placed the cache at `$HOME/.kairo/cache/`, overridable by `KAIRO_CACHE_DIR` or `--cache-dir`. Both overrides now have other meanings: `KAIRO_CACHE_DIR` selects the toolchain cache root that already holds the runtime objects and the Kairo library ([Driver.md](Driver.md#runtime-and-the-kairo-library)), and `--cache-dir` is the object directory. Where the precompile cache lives under that root is open.

### Cache key

```text
cache_key = xxHash64(
    payload_hash || compiler_version || target_triple || optimization_level ||
    link_mode (static, dynamic, LTO) || edition || canonical_flag_string ||
    transitive_dep_hashes)
```

### Cache layout

```text
<cache>/<target_triple>/<cache_key_hex>/
    manifest.toml             entry metadata
    artifact.{a,dylib,dll}    the built library
    diagnostics.log           build output
```

`manifest.toml` records `klib_path`, `klib_hash`, `compiler_version`, `target_triple`, `optimization`, `link_mode`, `edition`, `build_timestamp`, `artifact_hash` and `input_flags`.

### Cache invalidation

The entry is rebuilt when the artifact's hash does not match, when the compiler version changes, or when it is missing. Manual invalidation was specified as `kpkg cache clean [package|--all]`; `kpkg` does not exist.

### Parallel builds

Cache entries for several `.klib`s build in dependency waves, one `kairo --build-from-klib` process per `.klib` (not implemented). Wave 0 is every `.klib` with no unsatisfied dependency; wave N those whose dependencies were satisfied in waves 0 to N-1. Parallelism within a wave is bounded by `--jobs` or the core count.

## Trailer

48 bytes at `file_size - 48`, so a tool can check that a file is complete without parsing it.

| Offset | Size | Field |
|---|---|---|
| 0x00 | 8 | `magic_trailer`: `KLIBEND\0` (`0x00444E4542494C4B` as LE u64) |
| 0x08 | 8 | copy of `payload_hash` |
| 0x10 | 8 | copy of `file_size` |
| 0x18 | 8 | `header_offset`, 0 in v1 |
| 0x20 | 16 | reserved, zero |

## Construction algorithm

1. Lex, preprocess, parse and run Sema on the sources.
2. Collect the exported symbols by visibility.
3. Build the sections: `STRING_TABLE` (every string the others reference), `METADATA`, `DEPENDENCIES`, `BUILD_FLAGS`, `SYMBOL_TABLE`, `SCOPE_TREE`, `TYPE_TABLE`, `AST_NODES`, then when present `BCIR_SUMMARY`, `BCIR_DETAIL`, `MACRO_DEFINITIONS`, `SOURCE_ARCHIVE`, `SOURCE_MANIFEST`, `LINE_TABLE`, `DIAG_METADATA`, `EXPORTED_ATTRIBUTES`.
4. Hash each uncompressed payload into its directory entry.
5. Optionally compress each payload with zstd level 9.
6. Compute `payload_hash` over the uncompressed payloads in directory order.
7. Sort the directory by `section_id`.
8. Compute `header_crc32` over `[0x10, 0x40)` and `section_dir_crc32` over the directory.
9. Write header, directory, payloads, trailer.

## Consumption algorithm

1. Read the 64-byte header; reject a wrong magic, a wrong header CRC, or an unsupported format version (with an actionable message).
2. Read the directory and check `section_dir_crc32`.
3. Check the trailer's magic and its size against the header.
4. Load sections as needed: `STRING_TABLE`, `METADATA`, `DEPENDENCIES` and `SYMBOL_TABLE` at once; `SCOPE_TREE` and `TYPE_TABLE` at the first symbol resolution; `AST_NODES` per requested symbol; `BCIR_SUMMARY` at the first borrow-check query; `BCIR_DETAIL` only for deep inlining; `SOURCE_ARCHIVE` only for a diagnostic that shows source.
5. Check each loaded payload against its `payload_xxhash64`.

A consumer may mmap the file for uncompressed sections and decompress the others into an allocator that lives as long as the compilation.

## Extensibility

### Custom section IDs

IDs from 0x0020 belong to tooling. A consumer ignores one it does not recognize. Allocation:

| Range | Owner |
|---|---|
| 0x0020-0x002F | the Kairo toolchain (package manager, build tool, formatter) |
| 0x0030-0x00FF | reserved |
| 0x0100-0xFFFF | user tooling |

### Reserved flag bits

Reserved bits are zero in a v1 file. A consumer tolerates nonzero reserved bits in later versions.

## Security considerations

- A `.klib` is trusted input: a malicious one can make the compiler behave arbitrarily. Package registries own authenticity.
- Section hashes detect corruption, not a malicious producer.
- An archived source need not match any external tree.
- Macros from a `.klib` run in the consumer's compiler. Procedural macros need a sandbox design first and are not allowed in v1.

## Testing and conformance

A conformance suite is planned (none exists in `Tests/`): build, dump, re-parse and rebuild with byte equality; cross-version loading; corrupted files rejected cleanly; more than 100k symbols to exercise lazy loading; custom sections ignored.

## Hash and checksum algorithms

- xxHash64: seed 0, the reference algorithm (github.com/Cyan4973/xxHash).
- CRC32: polynomial `0xEDB88320`, initial value and final XOR `0xFFFFFFFF` (zlib's `crc32`).

## Change log

- v1: draft.
