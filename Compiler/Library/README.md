# Kairo Library Format (.klib) Specification

**Version:** Format v1
**Status:** Draft
**Applies to:** Kairo compiler and toolchain from Stage 1 onward
**File extension:** `.klib`
**Magic number:** `0x4B 0x41 0x49 0x52 0x4F 0x4B 0x4C 0x42` (ASCII: `KAIROKLB`)

---

## 1. Overview

A `.klib` file is a self-contained, platform-agnostic distribution unit for a Kairo library. It contains everything a consuming compiler needs to resolve names, typecheck, borrow-check, re-lower to C++, and produce clean diagnostics against the library's source without needing access to the original source tree or build environment.

A `.klib` is produced by invoking:

```
kairo --lib -o foo.klib src/foo.kro [-Iinclude_path ...] [other_flags]
```

A `.klib` is consumed by any Kairo compiler version that supports the format version declared in its header, subject to the compatibility rules in §14.

### 1.1 Design Properties

- **Self-contained**: one file, no external references needed for consumption.
- **Platform-agnostic**: no target-specific binary code. Runs on any target the consumer's compiler supports.
- **Deterministic**: two builds of the same source with the same compiler version and flags produce byte-identical `.klib` files.
- **Versioned**: format version is orthogonal to language edition; both are tracked.
- **Verifiable**: content hash covers the entire payload; consumer can detect corruption.
- **Diagnostic-friendly**: source archive included so error messages can show original code.
- **Cache-friendly**: per-machine precompile cache is keyed off the `.klib`'s content hash.

### 1.2 Non-Goals

- Not a binary distribution format. `.klib` does not contain compiled object code. Target-specific artifacts live in the per-machine cache (§15).
- Not a replacement for source code. Consuming `.klib` requires the consumer's compiler version to be compatible with the producer's.
- Not a security boundary. `.klib` files are trusted input; distribution integrity is the registry's job.

---

## 2. File Structure

A `.klib` file has the following top-level layout:

```
+-------------------------------+  offset 0
| Header (64 bytes)             |
+-------------------------------+  offset 64
| Section Directory (variable)  |
+-------------------------------+
| Section 0 payload             |
+-------------------------------+
| Section 1 payload             |
+-------------------------------+
| ...                           |
+-------------------------------+
| Section N payload             |
+-------------------------------+
| Trailer (48 bytes)            |
+-------------------------------+
```

All multi-byte integers are little-endian. All offsets are absolute from the start of the file unless otherwise noted.

---

## 3. Header (64 bytes)

```
Offset  Size  Field                   Description
------  ----  ----------------------  ----------------------------------------
0x00    8     magic                   "KAIROKLB" = 0x424C4B4F5249414B (LE read)
0x08    4     format_version          u32, monotonic. Current: 1
0x0C    4     header_crc32            u32, CRC32 of bytes [0x10, 0x40)
0x10    8     compiler_version        u64, packed as (major<<48|minor<<32|patch<<16|build)
0x18    4     edition                 u32, declared Kairo edition (e.g. 2027)
0x1C    4     flags                   u32, see §3.1
0x20    8     section_dir_offset      u64, offset to section directory
0x28    4     section_dir_count       u32, number of sections
0x2C    4     section_dir_crc32       u32, CRC32 of section directory
0x30    8     payload_hash            u64, xxHash64 of all section payloads concatenated
0x38    8     file_size               u64, total file size in bytes (including trailer)
```

### 3.1 Header Flags (u32 bitfield)

```
Bit  Name                    Meaning
---  ----------------------  -----------------------------------------------
0    HAS_SOURCE_ARCHIVE      Source archive section is present
1    HAS_BCIR_SUMMARY        BCIR summary section is present
2    HAS_MACROS              Macro definitions section is present
3    HAS_DEBUG_INFO          Extended debug info (line tables etc) present
4    COMPRESSED_PAYLOADS     Section payloads use zstd compression
5    RESERVED_0
6    EXPORTS_MAIN            This .klib provides a `main` entry point
7    IS_SYSTEM_LIBRARY       Part of the Kairo standard distribution
8-31 RESERVED                Must be zero
```

---

## 4. Section Directory

The section directory is an array of `section_dir_count` entries, each 48 bytes:

```
Offset  Size  Field                   Description
------  ----  ----------------------  ----------------------------------------
0x00    4     section_id              u32, section kind (see §4.1)
0x04    4     flags                   u32, section-specific flags
0x08    8     uncompressed_size       u64, size in bytes when decompressed
0x10    8     on_disk_size            u64, size in file (compressed or raw)
0x18    8     offset                  u64, absolute file offset to payload
0x20    8     payload_xxhash64        u64, xxHash64 of the uncompressed payload
0x28    8     reserved                must be zero
```

The section directory is itself sorted ascending by `section_id`. Consumers may binary-search by id.

### 4.1 Section IDs

```
ID      Name                    Required  Description
------  ----------------------  --------  ----------------------------------
0x0001  METADATA                Yes       Library name, version, authors, license
0x0002  DEPENDENCIES            Yes       Required .klib dependencies
0x0003  BUILD_FLAGS             Yes       Flags used during library build
0x0004  STRING_TABLE            Yes       Pooled interned strings
0x0005  SYMBOL_TABLE            Yes       Exported symbols
0x0006  SCOPE_TREE              Yes       HoistedScope hierarchy
0x0007  AST_NODES               Yes       Serialized AST
0x0008  TYPE_TABLE              Yes       Deduplicated Type instances
0x0009  SOURCE_ARCHIVE          No        Original .kro files (zstd tarball)
0x000A  SOURCE_MANIFEST         If src    Mapping of fid -> source path
0x000B  BCIR_SUMMARY            No        Per-function BCIR summaries
0x000C  BCIR_DETAIL             No        Full BCIR blobs (lazy-loaded)
0x000D  MACRO_DEFINITIONS       No        Serialized macro definitions
0x000E  DIAG_METADATA           No        Fix-hint templates for diagnostics
0x000F  EXPORTED_ATTRIBUTES     No        File-level attributes to preserve
0x0010  LINE_TABLE              No        Source location tables
0x0020  EXTENSION_SECTIONS      No        User-extensible (see §13)
```

Unknown section IDs below 0x0020 are fatal errors on load. Unknown section IDs ≥ 0x0020 may be ignored by the consumer if not understood.

---

## 5. Metadata Section (0x0001)

Required. Declares identifying information about the library.

```
Offset  Size  Field                   Description
------  ----  ----------------------  ----------------------------------------
0x00    4     name_strref             Interned string ID for library name
0x04    4     version_major           u32
0x08    4     version_minor           u32
0x0C    4     version_patch           u32
0x10    4     version_prerelease      Interned string ID ("" if stable)
0x14    4     version_build           Interned string ID (build metadata)
0x18    4     description_strref      Interned string ID
0x1C    4     license_spdx_strref     Interned string ID (SPDX identifier)
0x20    4     homepage_strref         Interned string ID
0x24    4     repository_strref       Interned string ID
0x28    4     author_count            u32
0x2C    ...   authors                 Array of author_count u32 strrefs
...     4     keyword_count           u32
...     ...   keywords                Array of u32 strrefs
...     8     build_timestamp         i64, Unix epoch seconds
...     4     build_host_triple       Interned string ID (for diagnostics only,
                                      does not affect portability)
...     4     reserved                Must be zero
```

All string references (`*_strref`) are u32 indices into the `STRING_TABLE` section (§7).

---

## 6. Dependencies Section (0x0002)

Required. Lists other `.klib` files this library depends on.

```
Offset  Size  Field                   Description
------  ----  ----------------------  ----------------------------------------
0x00    4     dep_count               u32
0x04    ...   dependencies            Array of DependencyEntry
```

### 6.1 DependencyEntry (64 bytes)

```
Offset  Size  Field                   Description
------  ----  ----------------------  ----------------------------------------
0x00    4     name_strref             Dependency library name
0x04    4     version_req_strref      Version requirement (semver range)
0x08    4     resolved_version_major  u32
0x0C    4     resolved_version_minor  u32
0x10    4     resolved_version_patch  u32
0x14    4     flags                   See §6.2
0x18    8     expected_klib_hash      xxHash64 of the .klib content this was built against
0x20    8     reserved_0              Must be zero
0x28    8     reserved_1              Must be zero
0x30    16    _padding                Must be zero
```

### 6.2 Dependency Flags

```
Bit  Name                    Meaning
---  ----------------------  -----------------------------------------------
0    OPTIONAL                Consumer may skip if not found
1    PUBLIC                  Types from this dep appear in our public API
2    BUILD_ONLY              Only needed for building, not for consuming
3    DEV_ONLY                Only needed for tests/examples
```

The `expected_klib_hash` is advisory the consumer should check whether the resolved dependency matches, and warn on mismatch within semver-compatible versions. Hard-fails on semver-incompatible mismatches.

---

## 7. String Table Section (0x0004)

Required. Pool of all interned strings referenced by other sections.

```
Offset  Size  Field                   Description
------  ----  ----------------------  ----------------------------------------
0x00    4     string_count            u32, total number of interned strings
0x04    4     reserved                Must be zero
0x08    ...   offsets                 Array of string_count u32 offsets into blob
...     ...   blob                    Concatenated UTF-8 strings, NUL-terminated
```

String with ID `0` is always the empty string (sentinel). String ID `u32::MAX` is reserved for "invalid string reference."

Offsets are relative to the start of `blob` (i.e., the end of the offsets array). Each offset points to the first byte of its string; the string extends to the NUL terminator.

Strings are UTF-8 encoded and MAY contain internal NUL bytes only if the string length is separately recorded (not the case in v1; NUL-terminated is the format).

---

## 8. Symbol Table Section (0x0005)

Required. All exported symbols from this library.

```
Offset  Size  Field                   Description
------  ----  ----------------------  ----------------------------------------
0x00    4     symbol_count            u32
0x04    4     reserved                Must be zero
0x08    ...   symbols                 Array of SymbolEntry
```

### 8.1 SymbolEntry (72 bytes)

```
Offset  Size  Field                   Description
------  ----  ----------------------  ----------------------------------------
0x00    4     name_strref             Symbol name (unqualified)
0x04    4     qualified_name_strref   Full qualified path (e.g. foo::bar::Baz)
0x08    4     scope_node_id           u32, ID into SCOPE_TREE
0x0C    1     kind                    u8, see §8.2
0x0D    1     visibility              u8, see §8.3
0x0E    2     flags                   u16, see §8.4
0x10    4     ast_node_id             u32, ID into AST_NODES (root of this decl)
0x14    4     type_id                 u32, ID into TYPE_TABLE (if applicable)
0x18    4     bcir_summary_id         u32, ID into BCIR_SUMMARY (if applicable)
0x1C    4     num_generic_params      u32, 0 if not generic
0x20    4     num_overloads           u32, 1 if not overloaded
0x24    4     overload_group_id       u32, groups overloaded symbols together
0x28    4     source_file_strref      Source file path (for diagnostics)
0x2C    4     source_line             u32, 1-based line number
0x30    4     source_column           u32, 1-based column number
0x34    4     attribute_set_id        u32, into EXPORTED_ATTRIBUTES (0 if none)
0x38    8     reserved                Must be zero
0x40    8     _padding                Must be zero
```

### 8.2 Symbol Kind (u8)

```
Value  Name
-----  --------------------
0x01   CLASS
0x02   STRUCT
0x03   ENUM
0x04   UNION
0x05   INTERFACE
0x06   TYPE_ALIAS
0x07   FUNCTION
0x08   OPERATOR
0x09   VARIABLE
0x0A   CONSTANT
0x0B   MODULE
0x0C   PROC_MACRO
0x0D   BASIC_MACRO
0x0E   GENERIC_PARAM
0x0F   EXTENSION
```

### 8.3 Visibility (u8)

```
Value  Name
-----  -------
0x01   PUB
0x02   PRIV
0x03   PROT
```

Only `PUB` symbols should appear in a `.klib`'s exported symbol table under normal builds. `PRIV` and `PROT` are permitted for symbols that participate in public API via inheritance or friend-like relationships.

### 8.4 Symbol Flags (u16 bitfield)

```
Bit   Name                    Meaning
----  ----------------------  ----------------------------------------------
0     IS_GENERIC              Has generic parameters
1     IS_OVERLOADED           Part of an overload set
2     IS_TEMPLATE             Lowered template (internal)
3     IS_FOREIGN_CXX          Imported from C++ via FFI
4     IS_EXTENSION            Added via `extend` block
5     IS_DEPRECATED           Has @deprecated attribute
6     HAS_DEFAULT_ARGS        Function has default parameter values
7     IS_NOEXCEPT             Function declared noexcept
8     IS_CONSTEXPR            Can be evaluated at compile time
9     IS_INLINE               inline keyword was specified
10    IS_STATIC               Static within its containing scope
11    IS_ABSTRACT             Interface method, no body
12    RESERVED_0
13    RESERVED_1
14    RESERVED_2
15    RESERVED_3
```

---

## 9. Scope Tree Section (0x0006)

Required. Hierarchical scope representation mirroring the `HoistedScope` trie used during compilation.

```
Offset  Size  Field                   Description
------  ----  ----------------------  ----------------------------------------
0x00    4     node_count              u32
0x04    4     root_node_id            u32, usually 0
0x08    ...   nodes                   Array of ScopeNode
```

### 9.1 ScopeNode (32 bytes + variable)

Each node's fixed portion:

```
Offset  Size  Field                   Description
------  ----  ----------------------  ----------------------------------------
0x00    4     node_id                 u32, self-referential for validation
0x04    4     parent_node_id          u32, u32::MAX if root
0x08    4     name_strref             Scope name ("" for root)
0x0C    4     kind                    u32, DeclContextKind enum value
0x10    4     entry_count             u32, symbols defined directly in this scope
0x14    4     child_count             u32, child scope node count
0x18    4     first_entry_symbol_id   u32, first symbol in SYMBOL_TABLE for this scope
0x1C    4     flags                   u32
```

Followed by:
- `child_count` × u32: child node IDs, sorted by name_strref for binary search.

The scope tree lets a consumer resolve qualified names in O(depth × log(siblings)) without loading the full symbol table.

---

## 10. AST Nodes Section (0x0007)

Required. Serialized AST of all exported declarations.

AST nodes are stored as a flat array, referenced by `ast_node_id` (a u32 index). Each node has a common prefix followed by kind-specific body.

### 10.1 Common Node Prefix (16 bytes)

```
Offset  Size  Field                   Description
------  ----  ----------------------  ----------------------------------------
0x00    4     node_id                 u32, self ID
0x04    2     node_class              u16, see §10.2
0x06    2     node_kind               u16, specific kind within class
0x08    4     source_range_id         u32, into LINE_TABLE
0x0C    4     parent_node_id          u32, u32::MAX for roots
```

### 10.2 Node Classes

```
Value  Name
-----  ---------
0x0001 Expr
0x0002 Stmt
0x0003 Decl
0x0004 Type
0x0005 Pattern
0x0006 Attribute
```

The `node_kind` field corresponds to values of `ExprKind`, `StmtKind`, `DeclKind`, `TypeKind`, `PatternKind`, or `AttributeKind` respectively.

### 10.3 Node Bodies

Each node class defines a set of body layouts indexed by `node_kind`. Bodies follow the common prefix directly, aligned to 4 bytes.

**Critical rule:** node bodies are forward-compatible within a format version. New fields are added at the end; old fields keep their offsets. A body's total length is determined by `node_kind` and the format version, not by reading a length field.

A few representative bodies:

#### 10.3.1 FunctionDecl (variable length)

```
Offset  Size  Field                   Description
------  ----  ----------------------  ----------------------------------------
0x10    4     name_strref             Function name
0x14    4     symbol_id               u32, back-ref to SYMBOL_TABLE
0x18    4     return_type_id          u32, into TYPE_TABLE
0x1C    2     param_count             u16
0x1E    2     generic_param_count     u16
0x20    4     body_ast_node_id        u32, BlockStmt ID (u32::MAX if no body)
0x24    4     attribute_set_id        u32
0x28    ...   param_node_ids          Array of param_count u32 AST node IDs (ParamDecls)
...     ...   generic_param_ids       Array of generic_param_count u32 AST node IDs
```

#### 10.3.2 CallExpr (20 bytes)

```
Offset  Size  Field                   Description
------  ----  ----------------------  ----------------------------------------
0x10    4     callee_ast_node_id      u32, AST node for the callee expression
0x14    4     arg_count               u32
0x18    4     first_arg_ast_node_id   u32, start of contiguous arg IDs
0x1C    4     resolved_symbol_id      u32, resolved callee symbol (u32::MAX if unresolved)
0x20    4     flags                   u32, bit 0 = is_ufcs_lowered
```

#### 10.3.3 NameRefExpr (16 bytes)

```
Offset  Size  Field                   Description
------  ----  ----------------------  ----------------------------------------
0x10    4     source_name_strref      Name as written in source
0x14    4     resolved_name_strref    Fully resolved qualified name
0x18    4     resolved_symbol_id      u32, SYMBOL_TABLE id (u32::MAX if unresolved)
0x1C    4     flags                   u32, bit 0 = is_aliased, bit 1 = is_using
```

Full body layouts for all node kinds are specified in a companion document,
[KLIB_AST_LAYOUTS.md](./KLIB_AST_LAYOUTS.md), which mirrors the enum
definitions in `Compiler/ASTKind/`.

---

## 11. Type Table Section (0x0008)

Required. Deduplicated type instances referenced by AST nodes and symbol entries.

```
Offset  Size  Field                   Description
------  ----  ----------------------  ----------------------------------------
0x00    4     type_count              u32
0x04    4     reserved                Must be zero
0x08    ...   types                   Array of TypeEntry
```

### 11.1 TypeEntry (variable, min 16 bytes)

```
Offset  Size  Field                   Description
------  ----  ----------------------  ----------------------------------------
0x00    4     type_id                 u32, self ID
0x04    2     type_kind               u16, TypeKind enum value
0x06    2     qualifier_bits          u16, see §11.2
0x08    4     body_size               u32, size of type-specific body
0x0C    4     canonical_type_id       u32, resolved canonical form (self-ref if already canonical)
0x10    ...   body                    Type-kind-specific data
```

### 11.2 Qualifier Bits (u16)

```
Bit   Name                Meaning
----  ------------------  ---------------------------------------------
0     CONST
1     MUTABLE             Explicit `mut`
2     VOLATILE
3     RESTRICT            Inferred by BCIR or explicit
4     NOALIAS             Inferred by BCIR or explicit
5     POINTER
6     REFERENCE
7     MOVE_REF            Kairo `mref!`
8     OBSERVE             `obs<T>`
9     OWN                 `own<T>`
10    UNIQUE              `unique<T>`
11    ARRAY
12-15 RESERVED
```

### 11.3 Type Kinds with Variable Bodies

Examples:

- **Primitive types**: body is empty; kind alone identifies them.
- **Pointer types**: body is a u32 pointee type_id.
- **Generic instantiation**: body is (u32 template type_id, u32 arg_count, arg_count × u32 arg type_ids).
- **Function types**: body is (u32 return_type_id, u32 param_count, param_count × u32 param type_ids, u32 flags).

Full layouts in `KLIB_TYPE_LAYOUTS.md`.

---

## 12. Source Archive Section (0x0009)

Optional. Contains original `.kro` source files for diagnostic reconstruction.

Format: a zstd-compressed tar stream. Each entry is named by its logical module path (e.g., `foo/bar/baz.kro`). Archive entries are regular files only; no symlinks, no directories explicit, no special files.

```
Offset  Size  Field                   Description
------  ----  ----------------------  ----------------------------------------
0x00    8     archive_size            u64, size of zstd payload
0x08    4     file_count              u32, number of files in archive
0x0C    4     reserved                Must be zero
0x10    ...   zstd_payload            Raw zstd-compressed tar stream
```

Sources are deduplicated: if the same file was imported multiple times, only one copy is archived.

The paired `SOURCE_MANIFEST` section (0x000A) maps internal fid values to archive entry names.

---

## 13. BCIR Summary Section (0x000B)

Optional. Per-function summaries for borrow-checking consumer code against this library.

```
Offset  Size  Field                   Description
------  ----  ----------------------  ----------------------------------------
0x00    4     summary_count           u32
0x04    4     reserved                Must be zero
0x08    ...   summaries               Array of BCIRSummary
```

### 13.1 BCIRSummary (40 bytes + variable)

```
Offset  Size  Field                   Description
------  ----  ----------------------  ----------------------------------------
0x00    4     symbol_id               u32, function this summarizes
0x04    4     param_count             u16 + u16 padding
0x08    4     flags                   u32, see §13.2
0x0C    4     return_lifetime_binding u32, see §13.3
0x10    8     detail_offset           u64, byte offset into BCIR_DETAIL (u64::MAX = none)
0x18    8     detail_size             u64, compressed size of detail blob
0x20    4     effect_set              u32, bitmask of EffectFlags
0x24    4     panic_flags             u32, see §13.4
0x28    ...   param_borrows           Array of param_count × ParamBorrow (8 bytes each)
```

### 13.2 Summary Flags

```
Bit  Name                Meaning
---  ------------------  -------------------------------------------------
0    IS_PURE             No observable side effects
1    MAY_ALIAS           Output may alias input(s)
2    MAY_PANIC           Can terminate via panic
3    IS_ASYNC            Returns a task/future
4    CAPTURES_SELF       Implicit 'self' is captured for longer than call
5    HAS_DETAIL          BCIR_DETAIL entry exists
```

### 13.3 Return Lifetime Binding

u32 encoding:
- `0xFFFFFFFF`: return is owned, no lifetime binding.
- `0x00000000..0x0000FFFF`: return lifetime tied to parameter at that index.
- Other values: reserved.

### 13.4 Panic Flags (u32)

```
Bit  Name                Meaning
---  ------------------  -------------------------------------------------
0    ARITHMETIC          Can panic on div-by-zero, overflow, etc.
1    BOUNDS              Can panic on array/slice bounds
2    UNWRAP              Can panic on null unwrap
3    ASSERTION           Contains assert() that can fire
4    EXPLICIT            Contains an explicit panic!() call
5    TRANSITIVE          Calls another function that can panic
```

### 13.5 ParamBorrow (8 bytes)

```
Offset  Size  Field                   Description
------  ----  ----------------------  ----------------------------------------
0x00    1     kind                    u8, see below
0x01    1     mutability              u8, 0=shared, 1=mutable
0x02    2     flags                   u16
0x04    4     escape_path_id          u32, reference into a path table (u32::MAX if no escape)
```

Kinds:
- `0x00` NONE (by value or copy)
- `0x01` SHARED_REF
- `0x02` MUTABLE_REF
- `0x03` OWNED_MOVE
- `0x04` OBSERVED

---

## 14. Compatibility Rules

### 14.1 Format Version Compatibility

- A compiler with format support version `N` CAN read `.klib` files with format version `≤ N`.
- A compiler with format support version `N` CANNOT read `.klib` files with format version `> N`. It must fail loading with a clear diagnostic.
- The compiler's supported format range is declared in its release notes and queryable via `kairo --supported-klib-formats`.

### 14.2 Backward-Compatibility Within a Format Version

Within format v1:
- New section IDs ≥ 0x0020 may appear; consumers that don't understand them ignore them.
- New fields may be appended to known fixed-layout structures only if documented as extensible.
- Enum values for `section_id`, `symbol.kind`, `node_kind`, `type_kind` may be added; consumers must tolerate unknown values by reporting "unsupported" without crashing.
- Reserved bits in flag words may be repurposed in later minor releases; consumers must tolerate any bit pattern without crashing.

### 14.3 Incompatibility Triggers

These require a format version bump:
- Changing the Header layout.
- Removing a required section.
- Changing the encoding of an existing field.
- Changing the interpretation of existing enum values.
- Removing compatibility with an existing flag bit.

### 14.4 Dependency Version Compatibility

When a `.klib` is consumed, the compiler verifies its `DependencyEntry` against resolved dependencies:

- If the resolved dependency's major version matches the declared requirement: proceed.
- If major version matches but `expected_klib_hash` differs: warn, proceed.
- If major version differs: hard error; user must reconcile.

### 14.5 Edition Compatibility

A consuming project MAY be on a different edition than the `.klib`'s build edition. The compiler uses the edition declared in the `.klib` metadata when processing the `.klib`'s AST and BCIR, and the consuming project's own edition for its own code.

Cross-edition interop is guaranteed for all symbols that do not depend on edition-specific semantics. The list of edition-sensitive constructs is maintained in the edition compatibility matrix (separate document).

---

## 15. Per-Machine Precompile Cache

The `.klib` itself contains no compiled binary code. Consumers produce target-specific static or dynamic libraries and cache them locally.

### 15.1 Cache Location

Default: `$HOME/.kairo/cache/`
Overridable via: `KAIRO_CACHE_DIR` environment variable, or `--cache-dir` flag.

### 15.2 Cache Key

```
cache_key = xxHash64(
    klib_content_hash          ||   // from the .klib's payload_hash
    compiler_version           ||
    target_triple              ||
    optimization_level         ||
    link_mode                  ||   // static, dynamic, LTO
    edition                    ||
    canonical_flag_string      ||
    transitive_dep_hashes      ||
)
```

### 15.3 Cache Layout

```
~/.kairo/cache/
  {target_triple}/
    {cache_key_hex}/
      manifest.toml            (cache entry metadata)
      artifact.{a,dylib,dll}   (the built library)
      diagnostics.log          (build output, for debugging cache misses)
```

### 15.4 Cache Entry Manifest

```toml
klib_path         = "/path/to/foo.klib"
klib_hash         = "0xABCDEF1234567890"
compiler_version  = "0.9.2"
target_triple     = "x86_64-linux-gnu"
optimization      = "O2"
link_mode         = "static"
edition           = "2027"
build_timestamp   = 1733000000
artifact_hash     = "0x1122334455667788"
input_flags       = "-I/path -DFOO=1 ..."
```

### 15.5 Cache Invalidation

- Content hash mismatch on `artifact` file: rebuild.
- Compiler version upgrade: rebuild.
- Missing cache entry: build.
- Manual invalidation: `kpkg cache clean [package-name|--all]`.

### 15.6 Parallel Build Dispatch

Building cache entries for multiple `.klib`s is parallelized by `kbld`. `kbld` dispatches one `kairo --build-from-klib` subprocess per `.klib`, respecting dependency order via wave execution:

- Wave 0: `.klib`s with no unsatisfied dependencies.
- Wave N: `.klib`s whose deps were satisfied in waves 0..N-1.
- Within each wave, parallelism is bounded by `--jobs` flag or core count.

---

## 16. Trailer (48 bytes)

Located at `file_size - 48`. Allows verification without parsing the full file.

```
Offset  Size  Field                   Description
------  ----  ----------------------  ----------------------------------------
0x00    8     magic_trailer           "KLIBEND\0" = 0x00444E4542494C4B (LE)
0x08    8     payload_hash_copy       Copy of header.payload_hash
0x10    8     file_size_copy          Copy of header.file_size
0x18    8     header_offset           Always 0 in v1
0x20    16    format_specific_data    Reserved; zeroed in v1
```

The trailer allows tools to quickly verify that a `.klib` is complete and uncorrupted by seeking to end-48 and checking the magic and size consistency.

---

## 17. Construction Algorithm

The canonical `.klib` is produced by this algorithm:

```
1. Compile source files: lex, index, parse, run available sema passes.
2. Collect all exported symbols, visible per visibility rules.
3. Emit sections in canonical order:
     - STRING_TABLE (intern all strings referenced by other sections)
     - METADATA
     - DEPENDENCIES
     - BUILD_FLAGS
     - SYMBOL_TABLE
     - SCOPE_TREE
     - TYPE_TABLE
     - AST_NODES
     - BCIR_SUMMARY (if produced)
     - BCIR_DETAIL (if produced)
     - MACRO_DEFINITIONS (if any)
     - SOURCE_ARCHIVE (if requested)
     - SOURCE_MANIFEST (if SOURCE_ARCHIVE present)
     - LINE_TABLE
     - DIAG_METADATA (if requested)
     - EXPORTED_ATTRIBUTES (if any)
4. Compute each section's uncompressed xxHash64 and store in section_dir.
5. Optionally compress each section payload with zstd level 9.
6. Compute payload_hash = xxHash64 of concatenation of uncompressed section payloads in directory order.
7. Build Section Directory, sorted by section_id.
8. Compute Header CRC32 over fields [0x10, 0x40).
9. Compute section_dir_crc32 over the directory bytes.
10. Write Header, Section Directory, all section payloads, Trailer.
```

The output is deterministic: identical inputs (source + flags + compiler version) produce byte-identical output.

---

## 18. Consumption Algorithm

```
1. Open file, read first 64 bytes as Header.
2. Verify magic bytes. Reject if mismatch.
3. Verify header CRC32. Reject if mismatch.
4. Verify format_version is supported. Reject with actionable error if not.
5. Read section directory at section_dir_offset.
6. Verify section_dir_crc32. Reject if mismatch.
7. Verify trailer: seek to file_size - 48, check magic and size consistency.
8. Lazily load sections on demand:
     - STRING_TABLE, METADATA, DEPENDENCIES, SYMBOL_TABLE: load immediately.
     - SCOPE_TREE, TYPE_TABLE: load on first symbol resolution.
     - AST_NODES: load on demand per requested symbol.
     - BCIR_SUMMARY: load on first borrow-check query.
     - BCIR_DETAIL: load only when deep inlining/optimization requires.
     - SOURCE_ARCHIVE: load only when producing a diagnostic that needs source text.
9. Verify each loaded section's payload_xxhash64 against its stored value.
```

The consumer MAY mmap the `.klib` file for zero-copy access to uncompressed sections. For compressed sections, decompress into an allocator that lives for the consumer's session.

---

## 19. Extensibility

### 19.1 Custom Section IDs

Section IDs ≥ `0x0020` are reserved for tooling extensions. Consumers that don't recognize a custom section ID MUST NOT fail; they ignore the section. Producers writing custom sections SHOULD document their section IDs in their tooling's own spec.

Suggested allocation:
- `0x0020-0x002F`: Kairo standard toolchain (kpkg, kbld, kfmt internals).
- `0x0030-0x00FF`: Reserved.
- `0x0100-0xFFFF`: User tooling.

### 19.2 Reserved Flag Bits

All reserved flag bits MUST be zero in a v1 `.klib`. Consumers MUST tolerate nonzero reserved bits in future format versions without error.

---

## 20. Security Considerations

- `.klib` is trusted input. A malicious `.klib` can cause the compiler to behave arbitrarily. Distribution channels (package registries) are responsible for authenticity.
- Consumers SHOULD verify section hashes on load to detect corruption, but this does not protect against malicious producers.
- Source archives contained in `.klib` files are included verbatim; consumers should not assume they match any external source tree.
- Macro definitions in `.klib`s are executed at compile time in the consumer's compiler process. Proc macros (once supported) will require a separate sandbox design; they are not permitted in v1 `.klib` format.

---

## 21. Testing and Conformance

A reference test suite is maintained at `Tests/KLibFormat/`. A compliant producer or consumer must pass:

- `roundtrip_*.kro`: build, dump, re-parse, re-build, bytewise equality.
- `cross_version_*.kro`: v1 producer, v1 consumer, cross-compiler-version loading.
- `corruption_*.klib`: deliberately corrupted files, must be rejected cleanly.
- `large_*.kro`: large symbol counts (>100k), verify lazy-load and performance.
- `extension_*.kro`: custom sections ignored correctly.

---

## 22. Appendix: xxHash64 and CRC32 Specifications

- **xxHash64**: uses seed `0`, standard xxHash64 algorithm as specified in the reference implementation at https://github.com/Cyan4973/xxHash.
- **CRC32**: standard CRC-32 polynomial `0xEDB88320`, initial value `0xFFFFFFFF`, final XOR `0xFFFFFFFF`. Produces the same output as `crc32` in zlib.

---

## 23. Change Log

- **v1 (draft)**: Initial specification.

---

*This specification is maintained in the Kairo source tree at `docs/KLIB_FORMAT.md`. Changes require a format version bump and documentation in §23.*