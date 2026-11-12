/// --- The Kairo Project ------------------------- Driver/CacheFormat.k --- ///
///
///   \brief The words the object cache (ObjectCache.k) and the incremental
///          Sema records (ModuleRecords.k) share under --cache-dir: the two
///          schema numbers, the versioned directory both write into, the
///          run manifest's header, and the fingerprint keys both spell.
///
///   One home because the two writers live in two files and a reader of
///   either is a later compiler: a word spelled differently on one side
///   would split the store or turn every record into a miss with no
///   message naming the cause. Keys only one format writes and reads stay
///   beside that format's writer/reader pair.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

/// Bumped by any change to the object record or to how a key is computed,
/// and by any change that alters emitted objects without a version bump
/// (Compiler/Spec/Incremental.md#development-builds).
pub
const CACHE_SCHEMA: u32 = 2

/// Bumped by any change to the incremental Sema manifest or record format,
/// or to what the hit decision compares. 3: f.env keys the cache-root
/// chain.
pub
const INCR_SEMA_SCHEMA: u32 = 3

/// <cache-dir>/<this>: the object store (<F>/objects) and the incremental
/// records (mod/) of one CACHE_SCHEMA. A schema bump moves both, so no
/// compiler ever reads another schema's files.
pub fn cache_dir_name() -> string {
    return f"kairo-cache-v{CACHE_SCHEMA}"
}

/// The first line of an incremental run manifest; a manifest that does not
/// start with it is another schema's.
pub fn incr_run_header() -> string {
    return f"kairo-incr-run {INCR_SEMA_SCHEMA}"
}

/// Every fingerprint line starts with this; a record's fingerprint is the
/// set of its lines that do.
pub fn fingerprint_prefix() -> string {
    return "f."
}

/// `f.schema <n>`: the schema the fingerprint was made under.
pub fn fingerprint_schema_key() -> string {
    return "f.schema"
}

/// `f.version <v>`: the compiler's version, cleaned (ObjectCache::clean)
/// or cut to its core (ObjectCache::_version_core).
pub fn fingerprint_version_key() -> string {
    return "f.version"
}
