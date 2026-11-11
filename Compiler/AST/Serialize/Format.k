/// --- The Kairo Project ----------------------- AST/Serialize/Format.k --- ///
///
///   The constants of the serialized-AST format. Compiler/Spec/Serialization.md
///   is the layout these number; a change to either is a change to both.
///
///   AST_FORMAT_VERSION is bumped by ANY change to what is written: a field
///   added to a node, a kind enum renumbered, an encoding changed. A reader
///   accepts exactly its own version; an old file is a miss, never a guess.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

/// "KAST" read as a little-endian u32.
pub const AST_MAGIC: u32 = 0x5453414B

pub const AST_FORMAT_VERSION: u32 = 1

/// Section ids. A reader skips an id it does not know by its length, which
/// is how a later version appends a section (Sema facts) without touching
/// the ones before it.
pub const SEC_FILES:    u8 = 1
pub const SEC_STRINGS:  u8 = 2
pub const SEC_PAYLOADS: u8 = 3
pub const SEC_TREE:     u8 = 4
pub const SEC_END:      u8 = 0

/// Node families: which base class a node id's pointer is.
pub const CAT_DECL:    u8 = 1
pub const CAT_EXPR:    u8 = 2
pub const CAT_STMT:    u8 = 3
pub const CAT_TYPE:    u8 = 4
pub const CAT_PATTERN: u8 = 5

/// Token payload records (SEC_PAYLOADS), one per literal slot or macro
/// expansion record a token of the tree reaches.
pub const PAY_INT:       u8 = 1
pub const PAY_FLOAT:     u8 = 2
pub const PAY_STRING:    u8 = 3
pub const PAY_CHAR:      u8 = 4
pub const PAY_EXPANSION: u8 = 5

/// What follows a token's kind and range.
pub const TOK_NONE:     u8 = 0 ///< no immediate.
pub const TOK_SENTINEL: u8 = 1 ///< a MacroSentinel constant, not a record.
pub const TOK_EXPANDED: u8 = 2 ///< payload index of its expansion record.
pub const TOK_IDENT:    u8 = 3 ///< string index of its spelling.
pub const TOK_LITERAL:  u8 = 4 ///< payload index of its literal slot.
pub const TOK_NUMBER:   u8 = 5 ///< a plain number: the imm of a kind that indexes no table (an error token's expected kind, a zeroed token's 0).
