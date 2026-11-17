/// --- The Kairo Project ------------ Lib/builtin/errors/panic_result.k --- ///
///
///   The Panic lang item: what a `panic` function returns. The file is not
///   `panic.k` because `panic` is a keyword.
///
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

/// What a `panic` function returns (PANIC.md §1.1): `Ok` with the declared
/// return type, else one `Err` per type in the function's panic set. The
/// compiler forms every instance (the set is deduplicated and sorted by type
/// id) and lays it out itself: each tag is a type id, word 0 holds the tag
/// and the panic site, and the payloads start at `max(8, alignof(...))`.
/// User code does not name it (SC116E).
pub enum <T, ...E> Panic {
    /// The function returned normally; `value` is its declared return value.
    Ok  { value: T },
    /// The function panicked with an error of one of the types in its panic set;
    /// one `Err` case exists per type in `E`.
    Err { error: E }...,
}
