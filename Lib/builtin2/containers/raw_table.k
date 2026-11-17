/// builtin/containers/raw_table.k

import base::cmp::*
import base::hash::*
import base::intrinsics::*

prot eval NO_ENTRY: usize = usize::MAX

/// The storage behind HashMap and HashSet. Insertion-ordered: a dense entry
/// array plus an index table of (entry index, cached hash) slots. One block:
///   [cap][shift][seed]  header
///   [slot; index_cap]   index table
///   [entry; cap]        entries, in insertion order
/// Not generic: it moves entries as bytes and rebuckets from the cached
/// hashes, so no key is rehashed on growth and every element type shares
/// this code. Entries must be relocatable. The owner constructs and destroys
/// them; this class never runs an element's constructor or destructor.
/// An empty table points at a shared static block, so a lookup needs no
/// null check.
@relocatable
prot class RawTable {
    priv var block: *u8?
    priv var len:   usize

    prot fn RawTable(self) {
        __builtin_trap() // BODY-TODO
    }

    @move prot fn RawTable(self, other: Self) { // bitwise; other becomes empty
        __builtin_trap() // BODY-TODO
    }

    prot fn size(const self) -> usize {
        __builtin_trap() // BODY-TODO
    }

    prot fn capacity(const self) -> usize {
        __builtin_trap() // BODY-TODO
    }

    prot fn seed(const self) -> u64 {
        __builtin_trap() // BODY-TODO
    }

    prot fn entries(const self) -> *u8? { // entry 0
        __builtin_trap() // BODY-TODO
    }

    // probing, for the generic lookup below
    prot fn first_slot(const self, hash: u64) -> usize {
        __builtin_trap() // BODY-TODO
    }

    prot fn next_slot(const self, slot: usize) -> usize {
        __builtin_trap() // BODY-TODO
    }

    prot fn slot_entry(const self, slot: usize) -> usize { // NO_ENTRY: the probe ends here
        __builtin_trap() // BODY-TODO
    }

    prot fn slot_matches(const self, slot: usize, hash: u64) -> bool { // cached hash bits agree
        __builtin_trap() // BODY-TODO
    }

    // mutation; sizes are the entry's
    prot fn reserve(self, n: usize, entry_size: usize, entry_align: usize) {
        __builtin_trap() // BODY-TODO
    }

    prot fn claim(self, hash: u64, entry_size: usize, entry_align: usize) -> usize { // index of a new, unconstructed entry at the end
        __builtin_trap() // BODY-TODO
    }

    prot fn unlink_swap(self, entry: usize, entry_size: usize) { // last entry's bytes move into the hole
        __builtin_trap() // BODY-TODO
    }

    prot fn unlink_shift(self, entry: usize, entry_size: usize) { // later entries shift down
        __builtin_trap() // BODY-TODO
    }

    prot fn unlink_last(self) {
        __builtin_trap() // BODY-TODO
    }

    prot fn clear_index(self) { // after the owner destroyed every entry
        __builtin_trap() // BODY-TODO
    }

    prot fn shrink(self, entry_size: usize, entry_align: usize) {
        __builtin_trap() // BODY-TODO
    }

    prot fn release(self, entry_size: usize, entry_align: usize) { // frees the block
        __builtin_trap() // BODY-TODO
    }

    eval if defined!(__x86_64__) || defined!(__aarch64__) {
        @cold_path @preserve_most @no_inline
        priv fn grow(self, need: usize, entry_size: usize, entry_align: usize) {
            __builtin_trap() // BODY-TODO
        }
    } else {
        @cold_path @no_inline
        priv fn grow(self, need: usize, entry_size: usize, entry_align: usize) {
            __builtin_trap() // BODY-TODO
        }
    }
}

prot fn <K impl Hash> hash_of(const t: RawTable, const k: K) -> u64 {
    __builtin_trap() // BODY-TODO
}

/// Entry index of `k`, or NO_ENTRY. The key is at offset 0 of each entry;
/// `stride` is the entry size. One instance per key type, shared by
/// HashSet<K> and every HashMap<K, V>.
@hot_path
prot fn <K impl Hash> raw_find(const t: RawTable, const k: K, hash: u64, stride: usize) -> usize {
    __builtin_trap() // BODY-TODO
}
