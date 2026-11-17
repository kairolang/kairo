/// --- The Kairo Project --------------------------- Support/EvalHash.k --- ///
///
///   The 64-bit string hash and its 32-bit fold, usable at compile time.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "llvm/Support/FormatVariadic.h"
ffi "c++" import "Native/Types.hh"
ffi "c++" import "array"

pub
const FNV_OFFSET_BASIS: u64 = 0x14650FB0739D0383
/// `eval` (see FNV1A64_OFFSET below): also splitmix64's increment, used by
/// the hash mixers in other modules.
pub
eval GOLDEN_RATIO_MIX: u64 = 0x9e3779b97f4a7c15
pub
const RESERVED_LOW: u64 = 0x00000000000000FF
pub
const FNV_PRIME: u64 = 0x00000100000001b3
pub
const HASH_MAX: u64 = u64::MAX

/// Standard FNV-1a, for the hashes that are not the token/DiagID hash above
/// (FNV_OFFSET_BASIS is Kairo's own basis, pinned by eval_hash.py; these are
/// the published ones). `eval`, not `const`: an imported `const` reaches the
/// importing C++ unit as an extern load, an `eval` as the literal itself,
/// and these sit in per-byte loops.
pub
eval FNV1A64_OFFSET: u64 = 0xcbf29ce484222325
pub
eval FNV1A64_PRIME: u64 = 0x100000001b3
pub
eval FNV1A32_OFFSET: u32 = 0x811C9DC5
pub
eval FNV1A32_PRIME: u32 = 0x01000193

/// splitmix64's finalizer multipliers; its increment is GOLDEN_RATIO_MIX.
pub
eval SPLITMIX64_MUL1: u64 = 0xBF58476D1CE4E5B9
pub
eval SPLITMIX64_MUL2: u64 = 0x94D049BB133111EB


/// Converts a usize value to a hexadecimal string.
pub inline fn to_hex_string(const value: usize) -> string {
    return string(
        unsafe ((llvm::formatv(r"{0:x-}", value).str().c_str() as unsafe *const u8) as *const u8),
    )
}


/// Fold a 64-bit hash into a 32-bit hash.
/// This is useful for reducing the size of the hash for storage
/// or comparison.
///
/// ### Parameters
/// - `hash64`: The 64-bit hash value to fold.
///
/// ### Returns
/// A 32-bit hash value.
pub fn fold_hash(const hash64: u64) -> u32 {
    return (hash64 >> 32 ^ hash64) as u32
}


/// FNV-1a hash step with optional position mixing.
/// Inlined directly into loops to avoid call overhead.
///
/// ### Parameters
/// - `chr`: The character to mix into the hash.
/// - `hash`: The current hash value.
/// - `pos`: The position of the character in the string (0-based).
///
/// ### Returns
/// The updated hash value after mixing in the character.
pub fn mix_char(chr: u8, hash: u64, pos: usize) -> u64 {
    var h: u64 = hash ^ (chr as u64)
    h *= FNV_PRIME
    h ^= (pos as u64) // TODO: benchmark if this helps or hurts
    return h
}


/// The spelling hash of the bytes [`str`, `str` + `len`): FNV-1a
/// with position mixing, folded to 32 bits (fold_hash). A word
/// token's kind is this value of its spelling.
///
/// ### Returns
/// The folded hash, or u32::MAX for an empty spelling.
///
/// **Note:** No length cap: the lexer's HashState hashes identifiers of any
/// length, and this must agree with it for the same spelling (C++
/// headers carry identifiers well past 255 chars).
pub fn compute_hash(str: unsafe *const u8, const len: usize) -> u32 {
    if len == 0 {
        return u32::MAX
    }

    var hash: u64 = FNV_OFFSET_BASIS

    for var i: usize = 0; i < len; ++i {
        hash = mix_char(str[i], hash, i)
    }

    return fold_hash(
        (hash ^ (len as u64) * GOLDEN_RATIO_MIX) + RESERVED_LOW & HASH_MAX,
    )
}

/// compute_hash of the bytes of `str`; u32::MAX for a null or empty
/// string.
pub fn compute_hash(str: unsafe *const string) -> u32 {
    if str == &null {
        return u32::MAX
    }

    return compute_hash(unsafe (str->data() as unsafe *const u8), str->size())
}


/// Stateful incremental hasher compatible with compute_hash.
/// Can be reused to hash multiple tokens in sequence.
pub class HashState {
    var value: u64   = FNV_OFFSET_BASIS
    var index: usize = 1

    /// Mix a single character into the hash state.
    pub inline fn mix(self, chr: u8) {
        self.value = mix_char(chr, self.value, self.index - 1)
        ++self.index
    }

    /// Mix a buffer of chars (1-255 chars).
    inline fn mix_buffer(self, buf: unsafe *const u8, const len: usize) {
        if len == 0 || len >= 256 || len + self.index > 256 {
            kairo::std::ice_fail("Buffer too long for hashing (max 255 chars)")
        }

        for var i: usize = 0; i < len; ++i {
            self.mix(buf[i])
        }
    }

    /// Finalize the hash into a folded 32-bit value.
    pub inline fn finalize(self) -> u64 {
        return fold_hash(
            (self.value ^ ((self.index - 1) as u64) * GOLDEN_RATIO_MIX) + RESERVED_LOW & HASH_MAX,
        )
    }

    /// Reset the hash state for reuse.
    inline fn reset(self) {
        self.value = FNV_OFFSET_BASIS
        self.index = 1
    }

    pub inline fn copy(self) -> HashState {
        var new_state: HashState
        new_state.value = self.value
        new_state.index = self.index

        return new_state
    }
}

// fn Test() -> i32 {
//     // --- eval-time string literal hashes ---
//     print(f"hash<\"inline\">\t= 0x{to_hex_string(compute_hash::<r"inline">())}");
//     print(f"hash<\"fn\">    \t= 0x{to_hex_string(compute_hash::<r"fn">())}");
//     print(f"hash<\"var\">   \t= 0x{to_hex_string(compute_hash::<r"var">())}");
//     print(f"hash<\"class\"> \t= 0x{to_hex_string(compute_hash::<r"class">())}");
//     print(f"hash<\"return\">\t= 0x{to_hex_string(compute_hash::<r"return">())}");
//     print(f"hash<\"if\">    \t= 0x{to_hex_string(compute_hash::<r"if">())}");
//     print(f"hash<\"else\">  \t= 0x{to_hex_string(compute_hash::<r"else">())}");
//     print(f"hash<\"while\"> \t= 0x{to_hex_string(compute_hash::<r"while">())}");
//     print(f"hash<\"for\">   \t= 0x{to_hex_string(compute_hash::<r"for">())}");
//     print(f"hash<\"match\"> \t= 0x{to_hex_string(compute_hash::<r"match">())}");

//     // --- runtime string hashing ---
//     var s: string = "inline";
//     print(f"hash(\"inline\")\t= 0x{to_hex_string(compute_hash(&s))}");

//     s = "fn";
//     print(f"hash(\"fn\")\t= 0x{to_hex_string(compute_hash(&s))}");

//     s = "var";
//     print(f"hash(\"var\")\t= 0x{to_hex_string(compute_hash(&s))}");

//     // --- empty string case ---
//     var empty: string = "";
//     print(f"hash(\"\")\t= 0x{to_hex_string(compute_hash(&empty))}");
//     print(f"hash<\"\">\t= 0x{to_hex_string(compute_hash::<r"\"">())}");

//     // --- long string (to trigger runtime error path if ≥ 256) ---
//     // note: runtime will throw, so just demo eval-time length guard
//     try {
//         var long_str = string(300, 'a');
//         print(f"hash(long string 300a)\t= 0x{to_hex_string(compute_hash(&long_str))}");
//     } catch (e: libcxx::exception) {
//         libcxx::cout << r"runtime error (expected for long string): " << e.what() << libcxx::endl;
//     }

//     // Case sensitivity
//     print(f"hash<\"fn\">\t= 0x{to_hex_string(compute_hash::<r"fn">())}");
//     print(f"hash<\"Fn\">\t= 0x{to_hex_string(compute_hash::<r"Fn">())}");
//     print(f"hash<\"fN\">\t= 0x{to_hex_string(compute_hash::<r"fN">())}");
//     print(f"hash<\"FN\">\t= 0x{to_hex_string(compute_hash::<r"FN">())}");

//     // Single chars
//     print(f"hash<\"a\">\t= 0x{to_hex_string(compute_hash::<r"a">())}");
//     print(f"hash<\"A\">\t= 0x{to_hex_string(compute_hash::<r"A">())}");
//     print(f"hash<\"_\">\t= 0x{to_hex_string(compute_hash::<r"_">())}");
//     print(f"hash<\"$\">\t= 0x{to_hex_string(compute_hash::<r"$">())}");
//     print(f"hash<\"0\">\t= 0x{to_hex_string(compute_hash::<r"0">())}");

//     // Whitespace / escapes
//     print(f"hash<\" \">\t= 0x{to_hex_string(compute_hash::<r" ">())}");
//     print(f"hash<\"\\t\">\t= 0x{to_hex_string(compute_hash::<r"\\t">())}");
//     print(f"hash<\"\\n\">\t= 0x{to_hex_string(compute_hash::<r"\\n">())}");
//     // beware: embedded null can't be expressed in Kairo literal unless you support raw bytes

//     // Operators
//     print(f"hash<\"+\">\t= 0x{to_hex_string(compute_hash::<r"+">())}");
//     print(f"hash<\"==\">\t= 0x{to_hex_string(compute_hash::<r"==">())}");
//     print(f"hash<\"!=\">\t= 0x{to_hex_string(compute_hash::<r"!=">())}");
//     print(f"hash<\"=>\">\t= 0x{to_hex_string(compute_hash::<r"=>">())}");

//     // Unicode
//     var uni: string = "λ";
//     print(f"hash(\"λ\")\t= 0x{to_hex_string(compute_hash(&uni))}");

//     uni = "你好";
//     print(f"hash(\"你好\")\t= 0x{to_hex_string(compute_hash(&uni))}");

//     return 0;
// }
