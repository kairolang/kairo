/// --- The Kairo Project ------------------------- AST/Mixin/TypeQual.k --- ///
///
///   Type qualifier storage used by Type. Carries a small bitfield of
///   qualifier flags, optional extended qualifiers (address space), and
///   per-qualifier source ranges for diagnostics and fix-its.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "Native/Types.hh"

import Location::SourceRange::SourceRange
import Memory::ArenaAllocator::ArenaAllocator
import Memory::ArenaList::ArenaList
import Support::FlagSet::{
    FlagBit,
    FlagSet,
}

/// Represents the address space of a type when HasAddressSpace is set.
/// Stored in ExtQuals, not directly in TypeQual.
pub enum AddressSpace derives u32 {
    /// Default address space for conventional targets.
    Generic = 0,
    /// GPU global memory (OpenCL/CUDA).
    Global = 1,
    /// GPU local/shared memory (OpenCL local, CUDA shared).
    Local = 2,
    /// GPU private memory (OpenCL private).
    Private = 3,
    /// GPU constant memory.
    Constant = 4,
}

/// Extended qualifiers node. Only allocated when an extended qualifier is
/// active (currently: address space). Kept out of TypeQual's inline storage
/// to avoid bloating the common case.
///
/// ArenaAllocator-allocated from ASTContext::nodes.
pub class ExtQuals {
    pub var address_space:       AddressSpace = AddressSpace::Generic
    pub var address_space_range: SourceRange  = SourceRange::invalid()

    fn ExtQuals(self) { }

    fn ExtQuals(self, space: AddressSpace, range: SourceRange) {
        self.address_space       = space
        self.address_space_range = range
    }
}

/// Per-qualifier source location. Populated by the parser when a qualifier
/// keyword is consumed. Diagnostics use these to point at the exact keyword
/// and emit fix-its that remove a single qualifier.
///
/// Stored in a small ArenaList on TypeQual. For types with no qualifiers,
/// the list is empty and costs only the list header (24 bytes).
pub class QualSpan {
    pub var qual_flag: u16         // which flag this span belongs to
    pub var range:     SourceRange

    fn QualSpan(self) { }

    pub fn QualSpan(self, f: u16, r: SourceRange) {
        self.qual_flag = f
        self.range     = r
    }
}

/// Qualifier bits of a TypeQual (TypeQual<T>::Flags). One type for every T.
/// A type's qualifiers are a FlagSet<TypeQualFlags, u16> of them
/// (TypeQual<T>::flags, Support/FlagSet.k), empty for none. The masks below are variants too: a
/// FlagSet tests (`has`: any of them) and clears (`clear`) a mask the way it
/// does a bit, and the enum stays closed because no combination is ever
/// cast back into it.
pub enum TypeQualFlags derives u16 {
    /// ## Data qualifiers

    /// Immutable binding. Prevents mutation of the qualified type after
    /// initialization. Type-level const (binding-level const lives on
    /// Decl).
    IsConst = 1 << 0,

    /// Volatile access every read/write goes to memory, no caching or
    /// reordering. Required for memory-mapped I/O and signal handlers.
    IsVolatile = 1 << 1,

    /// No-alias hint the compiler may assume no other pointer aliases
    /// this memory. Equivalent to C99 restrict.
    IsRestrict = 1 << 2,

    /// Atomic access. All reads/writes indivisible. Lowered to LLVM
    /// atomic IR. Sema validates layout before codegen.
    IsAtomic = 1 << 3,

    /// Unsafe qualifier. Applies to any type (Kairo has unsafe
    /// overloading). On pointer types it selects the raw-pointer
    /// representation; on other types it permits otherwise-restricted
    /// operations. Treated as a regular qualifier for equality and
    /// merging; semantic meaning is type-kind specific.
    IsUnsafe = 1 << 4,

    /// ## Compile-time qualifier

    /// Compile-time evaluation required. The qualified value must be
    /// fully known at compile time. Set by the `eval` keyword.
    IsEval = 1 << 5,

    /// ## Effect qualifiers (preserved through sema, desugared at codegen into Future<T> / Generator<T> / similar)

    /// Async effect function returning a value via await. Desugars to
    /// Future<T> at codegen. Primarily valid on function return types.
    IsAsync = 1 << 6,

    /// Yield effect function returning a value via yield. Desugars to
    /// Generator<T> / Iterator<T> at codegen. Primarily valid on
    /// function return types.
    IsYield = 1 << 7,

    /// Panic effect function that changes return type, to allow flow
    /// control constructs like try blocks. Desugars to a tagged union at
    /// codegen. Primarily valid on function return types.
    IsPanic = 1 << 8,

    /// ## Extended-qualifier presence bit

    /// An ExtQuals node is attached. Currently only used for address
    /// space; leaves room for future extended qualifiers.
    HasExtQuals = 1 << 14,

    /// ## Masks

    /// Data qualifiers only (properties of the value's representation):
    /// IsConst | IsVolatile | IsRestrict | IsAtomic | IsUnsafe.
    DataMask   = (1 << 0) | (1 << 1) | (1 << 2) | (1 << 3) | (1 << 4),

    /// C-style CVR subset, IsConst | IsVolatile | IsRestrict. For remove_cvr.
    CVRMask    = (1 << 0) | (1 << 1) | (1 << 2),

    /// Effect qualifiers only: IsAsync | IsYield | IsPanic.
    EffectMask = (1 << 6) | (1 << 7) | (1 << 8),
}

// The enum lives here at module scope, and TypeQual<T>::Flags names it: an
// extension needs a type it can name, and an enum nested in the class
// template TypeQual<T> is not one.
/// TypeQualFlags' variants are its FlagSet's bits (Support/FlagSet.k).
extend TypeQualFlags impl FlagBit<u16> {
    inline fn bit(const self) -> u16 {
        return self as u16
    }
}



/// CRTP mixin: concrete Type nodes derive TypeQual::<SelfType> to get
/// inline qualifier storage + flag/span APIs.
pub class <T> TypeQual {
    /// The qualifier bits; see TypeQualFlags above.
    pub type Flags = TypeQualFlags

    pub var flags: FlagSet<TypeQualFlags, u16>
    pub var ext:   unsafe *ExtQuals            = &null // null unless HasExtQuals set
    pub var spans: ArenaList<QualSpan>                 // per-qualifier source ranges

    /// # Construction

    fn TypeQual(self) { }

    fn TypeQual(self, f: FlagSet<TypeQualFlags, u16>) {
        self.flags = f
    }

    fn TypeQual(self,
                f:           FlagSet<TypeQualFlags, u16>,
                space:       AddressSpace,
                space_range: SourceRange) {
        self.flags = f.plus(Self::Flags::HasExtQuals)
    }

    /// Called once by the owning Type to attach the spans ArenaList to the
    /// context's node arena. Required before any add_* call that records a
    /// source range. Skip if this TypeQual will never track ranges (rare).
    fn init_spans(self, allocator: unsafe *ArenaAllocator) {
        self.spans.set_allocator(allocator, 2)
    }

    /// # Flag queries

    pub fn is_const(const self) -> bool {
        return self.flags.has(Self::Flags::IsConst)
    }

    pub fn is_volatile(const self) -> bool {
        return self.flags.has(Self::Flags::IsVolatile)
    }

    fn is_restrict(const self) -> bool {
        return self.flags.has(Self::Flags::IsRestrict)
    }

    fn is_atomic(const self) -> bool {
        return self.flags.has(Self::Flags::IsAtomic)
    }

    pub fn is_unsafe(const self) -> bool {
        return self.flags.has(Self::Flags::IsUnsafe)
    }

    fn is_eval(const self) -> bool {
        return self.flags.has(Self::Flags::IsEval)
    }

    pub fn is_async(const self) -> bool {
        return self.flags.has(Self::Flags::IsAsync)
    }

    pub fn is_yield(const self) -> bool {
        return self.flags.has(Self::Flags::IsYield)
    }

    pub fn is_panic(const self) -> bool {
        return self.flags.has(Self::Flags::IsPanic)
    }

    fn has_ext_quals(const self) -> bool {
        return self.flags.has(Self::Flags::HasExtQuals)
    }

    fn has_address_space(const self) -> bool {
        return self.has_ext_quals() && self.ext != &null
    }

    fn has_any_qualifiers(const self) -> bool {
        return !self.flags.empty()
    }

    fn has_any_data(const self) -> bool {
        return self.flags.has(Self::Flags::DataMask)
    }

    fn has_any_effect(const self) -> bool {
        return self.flags.has(Self::Flags::EffectMask)
    }

    fn address_space(const self) -> AddressSpace {
        eval if defined!(DEBUG) {
            if !self.has_address_space() {
                kairo::std::ice_fail(r"address_space() called on TypeQual without address space")
            }
        }

        return self.ext->address_space
    }

    /// # Source-range queries

    /// Returns the source range where `flag` was written, or invalid range
    /// if not found. Use for precise diagnostics and fix-its.
    pub fn qual_range(self, flag: Self::Flags) -> SourceRange {
        for var i: usize = 0; i < self.spans.size(); ++i {
            var unsafe *span = self.spans.get(i)
            if (span->qual_flag & (flag as u16)) != 0 {
                return span->range
            }
        }

        return SourceRange::invalid()
    }

    fn address_space_range(const self) -> SourceRange {
        if !self.has_address_space() {
            return SourceRange::invalid()
        }

        return self.ext->address_space_range
    }

    /// # Flag mutation with source range tracking
    ///
    /// The range-taking overloads record the source range of the qualifier
    /// keyword for diagnostics. The no-range overloads are for programmatic
    /// additions (e.g., sema inferring `const` on an immutable binding)
    /// where no source-level keyword exists.

    fn add_const(self, range: SourceRange) {
        self.flags.set(Self::Flags::IsConst)
        self.spans.push(QualSpan(Self::Flags::IsConst as u16, range))
    }

    fn add_const(self) {
        self.flags.set(Self::Flags::IsConst)
    }

    fn add_volatile(self, range: SourceRange) {
        self.flags.set(Self::Flags::IsVolatile)
        self.spans.push(QualSpan(Self::Flags::IsVolatile as u16, range))
    }

    fn add_volatile(self) {
        self.flags.set(Self::Flags::IsVolatile)
    }

    fn add_restrict(self, range: SourceRange) {
        self.flags.set(Self::Flags::IsRestrict)
        self.spans.push(QualSpan(Self::Flags::IsRestrict as u16, range))
    }

    fn add_restrict(self) {
        self.flags.set(Self::Flags::IsRestrict)
    }

    fn add_atomic(self, range: SourceRange) {
        self.flags.set(Self::Flags::IsAtomic)
        self.spans.push(QualSpan(Self::Flags::IsAtomic as u16, range))
    }

    fn add_atomic(self) {
        self.flags.set(Self::Flags::IsAtomic)
    }

    fn add_unsafe(self, range: SourceRange) {
        self.flags.set(Self::Flags::IsUnsafe)
        self.spans.push(QualSpan(Self::Flags::IsUnsafe as u16, range))
    }

    fn add_unsafe(self) {
        self.flags.set(Self::Flags::IsUnsafe)
    }

    fn add_eval(self, range: SourceRange) {
        self.flags.set(Self::Flags::IsEval)
        self.spans.push(QualSpan(Self::Flags::IsEval as u16, range))
    }

    fn add_eval(self) {
        self.flags.set(Self::Flags::IsEval)
    }

    fn add_async(self, range: SourceRange) {
        self.flags.set(Self::Flags::IsAsync)
        self.spans.push(QualSpan(Self::Flags::IsAsync as u16, range))
    }

    fn add_async(self) {
        self.flags.set(Self::Flags::IsAsync)
    }

    fn add_yield(self, range: SourceRange) {
        self.flags.set(Self::Flags::IsYield)
        self.spans.push(QualSpan(Self::Flags::IsYield as u16, range))
    }

    fn add_yield(self) {
        self.flags.set(Self::Flags::IsYield)
    }

    fn add_panic(self, range: SourceRange) {
        self.flags.set(Self::Flags::IsPanic)
        self.spans.push(QualSpan(Self::Flags::IsPanic as u16, range))
    }

    fn add_panic(self) {
        self.flags.set(Self::Flags::IsPanic)
    }

    /// ## Removal (spans are not removed from the list; queries just skip entries whose flag is no longer set)

    fn remove_const(self) {
        self.flags.clear(Self::Flags::IsConst)
    }

    fn remove_volatile(self) {
        self.flags.clear(Self::Flags::IsVolatile)
    }

    fn remove_restrict(self) {
        self.flags.clear(Self::Flags::IsRestrict)
    }

    fn remove_atomic(self) {
        self.flags.clear(Self::Flags::IsAtomic)
    }

    fn remove_unsafe(self) {
        self.flags.clear(Self::Flags::IsUnsafe)
    }

    fn remove_eval(self) {
        self.flags.clear(Self::Flags::IsEval)
    }

    fn remove_async(self) {
        self.flags.clear(Self::Flags::IsAsync)
    }

    fn remove_yield(self) {
        self.flags.clear(Self::Flags::IsYield)
    }

    fn remove_panic(self) {
        self.flags.clear(Self::Flags::IsPanic)
    }

    /// Set or replace the address space. Allocates ExtQuals if needed.
    fn set_address_space(self, space: AddressSpace, range: SourceRange, new_ext: unsafe *ExtQuals) {
        if self.ext == &null {
            eval if defined!(DEBUG) {
                if !(new_ext != &null) {
                    kairo::std::ice_fail(r"Must provide ExtQuals node for initial assignment")
                }
            }

            self.ext                      = new_ext
            self.ext->address_space       = space
            self.ext->address_space_range = range
        } else {
            self.ext->address_space       = space
            self.ext->address_space_range = range
        }

        self.flags.set(Self::Flags::HasExtQuals)
    }

    /// Remove the address space qualifier. ExtQuals is abandoned (arena
    /// reclaims on TU reset); pointer is nulled so queries stay consistent.
    fn remove_address_space(self) {
        self.ext = &null
        self.flags.clear(Self::Flags::HasExtQuals)
    }

    /// Strip C-style CVR (const, volatile, restrict). Preserves atomic,
    /// unsafe, effects, address space.
    fn remove_cvr(self) {
        self.flags.clear(Self::Flags::CVRMask)
    }

    /// Strip all data qualifiers. Preserves effects, address space.
    fn remove_data(self) {
        self.flags.clear(Self::Flags::DataMask)
    }

    /// Strip effect qualifiers. Preserves data, address space.
    fn remove_effects(self) {
        self.flags.clear(Self::Flags::EffectMask)
    }

    /// Strip everything including address space. Span list is cleared too.
    fn remove_all(self) {
        self.flags = FlagSet<TypeQualFlags, u16>()
        self.ext   = &null
        self.spans.clear()
    }

    /// # Comparison

    /// True if self has at least all the qualifiers of other. If other has
    /// an address space, self must have the same address space.
    fn is_superset_of(const self, const other: TypeQual<T>) -> bool {
        if !self.flags.has_all(other.flags) {
            return false
        }

        if other.has_address_space() {
            if !self.has_address_space() {
                return false
            }

            if self.ext->address_space != other.ext->address_space {
                return false
            }
        }

        return true
    }

    fn op == (const self, const other: TypeQual<T>) -> bool {
        if !self.flags.equals(other.flags) {
            return false
        }

        if self.has_address_space() {
            return self.ext->address_space == other.ext->address_space
        }

        return true
    }

    fn op != (const self, const other: TypeQual<T>) -> bool {
        return !(self == other)
    }

    /// # Merging
    ///
    /// NOTE: merging does NOT copy source spans. If you need precise spans
    ///       on a merged result, call add_*(range) explicitly after merging,
    ///       or use merge_with_spans() which preserves both sets.


    fn op | (const self, const other: TypeQual<T>) -> TypeQual<T> {
        eval if defined!(DEBUG) {
            if !(!self.has_ext_quals() && !other.has_ext_quals()) {
                kairo::std::ice_fail(r"use merge_with() when address spaces may be involved")
            }
        }

        var both = self.flags
        both.add_all(other.flags)
        var result = TypeQual<T>(both)
        return result
    }

    /// Full merge including address space. If both have one, self's wins.
    /// Does not merge spans.
    fn merge_with(self, const other: TypeQual<T>, allocator: *ArenaAllocator) {
        var add = other.flags
        add.clear(Self::Flags::HasExtQuals)
        self.flags.add_all(add)

        if other.has_address_space() && !self.has_address_space() {
            // Decoupled allocation:
            var unsafe *new_ext = allocator->alloc_init<ExtQuals>(
                other.ext->address_space,
                other.ext->address_space_range,
            )

            self.ext = new_ext
            self.flags.set(Self::Flags::HasExtQuals)
        }
    }

    /// Full merge including spans.
    fn merge_with_spans(self, const other: TypeQual<T>, allocator: *ArenaAllocator) {
        self.merge_with(other, allocator)
        for var i: usize = 0; i < other.spans.size(); ++i {
            self.spans.push(*other.spans.get(i))
        }
    }
}
