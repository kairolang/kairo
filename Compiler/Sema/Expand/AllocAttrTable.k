/// --- The Kairo Project ----------------- Sema/Expand/AllocAttrTable.k --- ///
///
/// The allocation attributes as overload sets: one row per
/// overload, and the matcher that picks the row a use was
/// written for.
///
///   \detail
///     An allocation attribute is an AST attribute (attributes.mdx): one
///     entry point per name, overloaded by the node it applies to and by
///     its arguments, which are keyword arguments and may take a type. The
///     compiler has no attribute macros yet, so each overload is a row
///     here, and a row says everything its macro would:
///
///         macro @alloc(node: *AST::Type, count: usize)            // a row
///         macro @alloc(node: *AST::Type, count: usize, in: type)  // the same row, `in:` given
///
///     - `attr`: the name after `@`.
///     - `node`: what the first parameter is (AllocNode): nothing, a type,
///       a construction, or any expression.
///     - `kws`: the keyword arguments the overload requires, a set of
///       AllocKw bits. `in: A`, the allocator, is optional on every row and
///       is not in the set.
///     - `target` / `target_in`: the alloc.k function the overload expands
///       to, without and with `in:` (AllocFn).
///
///     The expansion is the same for every row, so it is not stored:
///
///         target<T?, A?>(operand?, size?, new_size?, align?, count?)
///
///     T is the node's type (a Type or Construction node), A the `in:`
///     type, the operand a Value node (a Construction passes its
///     constructor arguments, or its initializer, instead), and the keyword
///     values follow in that fixed order, which is the parameter order of
///     every alloc.k function a row names. Moving an attribute into the
///     library is then one `macro` per row whose body builds that call.
///
///     Rows (the `in:` form of each in brackets):
///
///       @create T(args) | T { f: v }       create<T>(...)          [create_in<T, A>]
///       @try_create T(args) | T { f: v }   try_create<T>(...)      [try_create_in<T, A>]
///       @destroy p                         destroy(p)              [destroy_with<A>]
///       @alloc T                           alloc_storage<T>()      [alloc_in<T, A>]
///       @alloc(count: n) T                 create_slice<T>(n)      [create_slice_in<T, A>]
///       @alloc(size: n, align: a)          alloc_raw(n, a)         [alloc_bytes<A>]
///       @alloc_zeroed(size: n, align: a)   alloc_raw_zeroed(n, a)  [alloc_zeroed<A>]
///       @free p                            free_storage(p)         [free_storage_with<A>]
///       @free(size: n, align: a) p         free_raw(p, n, a)       [free_bytes<A>]
///       @resize(size: o, new_size: n, align: a) p
///                                          resize_raw(p, o, n, a)  [resize_bytes<A>]
///       @try_resize(size: o, new_size: n, align: a) p
///                                          resize_raw_in_place(p, o, n, a)
///                                                                  [try_resize_in_place<A>]
///
///     Overloading by the operand's TYPE (`@free p` for a `*T`, an
///     Uninitialized<T> or an UninitializedSlice<T>) is not a row: the
///     target is an overload set in alloc.k and the call typer chooses.
///
///     A type is read from an expression (Parser::DeclParse::expr_as_type):
///     a name, a `::` path or a generic application. Any other type is
///     named through an alias.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import AST::Context::ASTContext::ASTContext
import AST::LangItems::{
    AllocFn,
    LangAttrs,
}
import AST::Node::Base::{
    Expr,
    Type,
}
import AST::Node::Casting::{
    cast,
    isa,
}
import AST::Node::Expressions::{
    AttributedExpr,
    CallExpr,
    NamedArgExpr,
    NamedInitializerExpr,
}
import Parser::DeclParse::expr_as_type

/// The attribute a row belongs to.
pub enum AllocAttr derives u8 {
    Create = 0,
    TryCreate,
    Destroy,
    Alloc,
    AllocZeroed,
    Free,
    Resize,
    TryResize,
    COUNT, ///< not an allocation attribute.
}

/// What an overload's first parameter, the node, is.
pub enum AllocNode derives u8 {
    None = 0,     ///< nothing follows the attribute.
    Type,         ///< a type: `T`.
    Construction, ///< `T(args)` or `T { field: value }`.
    Value,        ///< any expression.
}

/// The keyword arguments, one bit each. The order of the bits is the order
/// the values are passed in.
pub
const ALLOC_KW_SIZE: u8 = 1
pub
const ALLOC_KW_NEW_SIZE: u8 = 2
pub
const ALLOC_KW_ALIGN: u8 = 4
pub
const ALLOC_KW_COUNT: u8 = 8
pub
const ALLOC_KW_IN: u8 = 16

/// How many value keywords there are (every bit but ALLOC_KW_IN).
pub
const ALLOC_KW_VALUES: usize = 4

/// One overload of one allocation attribute.
pub struct AllocAttrRow {
    pub var attr:      AllocAttr = AllocAttr::COUNT
    pub var node:      AllocNode = AllocNode::None
    pub var kws:       u8        = 0
    pub var target:    AllocFn   = AllocFn::COUNT
    pub var target_in: AllocFn   = AllocFn::COUNT
}

/// Why a use matches no row, most specific first.
pub enum AllocMismatch derives u8 {
    Ok = 0,
    Positional, ///< an argument with no keyword: `positional`.
    UnknownKw,  ///< a keyword no row of the attribute takes: `unknown`.
    RepeatedKw, ///< a keyword given twice: `repeated`, `repeated_first`.
    InNotType,  ///< `in:` with a value that names no type.
    MissingKw,  ///< a row takes these keywords and more: `missing`.
    ExtraKw,    ///< no row takes these keywords together: `extra`.
    Node,       ///< the keywords pick a row whose node is another kind.
}

/// One written use, read against the table.
pub struct AllocAttrUse {
    pub var attr: AllocAttr     = AllocAttr::COUNT
    pub var why:  AllocMismatch = AllocMismatch::Ok
    /// The row the keywords pick; the matched row when `why` is Ok, the
    /// nearest one for MissingKw / Node, -1 when none is near.
    pub var row: i32 = -1
    pub var kws: u8  = 0
    /// The value keywords as written, indexed by bit position.
    pub var values: [unsafe *NamedArgExpr; 4]
    pub var kw_in:  unsafe *NamedArgExpr      = &null
    pub var in_ty:  unsafe *Type              = &null
    /// T, for a row whose node is a Type or a Construction.
    pub var ty:             unsafe *Type         = &null
    pub var positional:     unsafe *Expr         = &null
    pub var unknown:        unsafe *NamedArgExpr = &null
    pub var repeated:       unsafe *NamedArgExpr = &null
    pub var repeated_first: unsafe *NamedArgExpr = &null
    pub var missing:        u8                   = 0
    pub var extra:          u8                   = 0
}

pub class AllocAttrTable {
    pub static fn attr_of(const word: string) -> AllocAttr {
        if word == LangAttrs::create() {
            return AllocAttr::Create
        }

        if word == LangAttrs::try_create() {
            return AllocAttr::TryCreate
        }

        if word == LangAttrs::destroy() {
            return AllocAttr::Destroy
        }

        if word == LangAttrs::alloc() {
            return AllocAttr::Alloc
        }

        if word == LangAttrs::alloc_zeroed() {
            return AllocAttr::AllocZeroed
        }

        if word == LangAttrs::free() {
            return AllocAttr::Free
        }

        if word == LangAttrs::resize() {
            return AllocAttr::Resize
        }

        if word == LangAttrs::try_resize() {
            return AllocAttr::TryResize
        }

        return AllocAttr::COUNT
    }

    /// The keyword's bit, 0 for a word that is no keyword.
    pub static fn kw_of(const word: string) -> u8 {
        if word == LangAttrs::kw_size() {
            return ALLOC_KW_SIZE
        }

        if word == LangAttrs::kw_new_size() {
            return ALLOC_KW_NEW_SIZE
        }

        if word == LangAttrs::kw_align() {
            return ALLOC_KW_ALIGN
        }

        if word == LangAttrs::kw_count() {
            return ALLOC_KW_COUNT
        }

        if word == LangAttrs::kw_in() {
            return ALLOC_KW_IN
        }

        return 0
    }

    /// The keyword of one bit, as written.
    pub static fn kw_word(bit: u8) -> string {
        if bit == ALLOC_KW_SIZE {
            return LangAttrs::kw_size()
        }

        if bit == ALLOC_KW_NEW_SIZE {
            return LangAttrs::kw_new_size()
        }

        if bit == ALLOC_KW_ALIGN {
            return LangAttrs::kw_align()
        }

        if bit == ALLOC_KW_COUNT {
            return LangAttrs::kw_count()
        }

        if bit == ALLOC_KW_IN {
            return LangAttrs::kw_in()
        }

        return ""
    }

    /// The lowest set bit of `set`, 0 when it is empty.
    pub static fn first_kw(set: u8) -> u8 {
        for var b: u8 = 1; b != 0 && b <= ALLOC_KW_IN; b = b << 1 {
            if (set & b) != 0 {
                return b
            }
        }

        return 0
    }

    priv static fn _row(attr:      AllocAttr,
                        node:      AllocNode,
                        kws:       u8,
                        target:    AllocFn,
                        target_in: AllocFn) -> AllocAttrRow {
        var r = AllocAttrRow{}
        r.attr      = attr
        r.node      = node
        r.kws       = kws
        r.target    = target
        r.target_in = target_in
        return r
    }

    /// Row `i`; a row whose attr is COUNT ends the table.
    pub static fn row(i: usize) -> AllocAttrRow {
        match i {
            case 0 {
                return AllocAttrTable::_row(
                    AllocAttr::Create,
                    AllocNode::Construction,
                    0,
                    AllocFn::Create,
                    AllocFn::CreateIn,
                )
            } case 1 {
                return AllocAttrTable::_row(
                    AllocAttr::TryCreate,
                    AllocNode::Construction,
                    0,
                    AllocFn::TryCreate,
                    AllocFn::TryCreateIn,
                )
            } case 2 {
                return AllocAttrTable::_row(
                    AllocAttr::Destroy,
                    AllocNode::Value,
                    0,
                    AllocFn::Destroy,
                    AllocFn::DestroyWith,
                )
            } case 3 {
                return AllocAttrTable::_row(
                    AllocAttr::Alloc,
                    AllocNode::Type,
                    0,
                    AllocFn::AllocStorage,
                    AllocFn::AllocIn,
                )
            } case 4 {
                return AllocAttrTable::_row(
                    AllocAttr::Alloc,
                    AllocNode::Type,
                    ALLOC_KW_COUNT,
                    AllocFn::CreateSlice,
                    AllocFn::CreateSliceIn,
                )
            } case 5 {
                return AllocAttrTable::_row(
                    AllocAttr::Alloc,
                    AllocNode::None,
                    ALLOC_KW_SIZE | ALLOC_KW_ALIGN,
                    AllocFn::AllocRaw,
                    AllocFn::AllocBytes,
                )
            } case 6 {
                return AllocAttrTable::_row(
                    AllocAttr::AllocZeroed,
                    AllocNode::None,
                    ALLOC_KW_SIZE | ALLOC_KW_ALIGN,
                    AllocFn::AllocRawZeroed,
                    AllocFn::AllocZeroed,
                )
            } case 7 {
                return AllocAttrTable::_row(
                    AllocAttr::Free,
                    AllocNode::Value,
                    0,
                    AllocFn::FreeStorage,
                    AllocFn::FreeStorageWith,
                )
            } case 8 {
                return AllocAttrTable::_row(
                    AllocAttr::Free,
                    AllocNode::Value,
                    ALLOC_KW_SIZE | ALLOC_KW_ALIGN,
                    AllocFn::FreeRaw,
                    AllocFn::FreeBytes,
                )
            } case 9 {
                return AllocAttrTable::_row(
                    AllocAttr::Resize,
                    AllocNode::Value,
                    ALLOC_KW_SIZE | ALLOC_KW_NEW_SIZE | ALLOC_KW_ALIGN,
                    AllocFn::ResizeRaw,
                    AllocFn::ResizeBytes,
                )
            } case 10 {
                return AllocAttrTable::_row(
                    AllocAttr::TryResize,
                    AllocNode::Value,
                    ALLOC_KW_SIZE | ALLOC_KW_NEW_SIZE | ALLOC_KW_ALIGN,
                    AllocFn::ResizeRawInPlace,
                    AllocFn::TryResizeInPlace,
                )
            } default {
                return AllocAttrRow{}
            }
        }
    }

    /// Every value keyword some row of `attr` takes.
    pub static fn kws_of(attr: AllocAttr) -> u8 {
        var all: u8 = 0
        for var i: usize = 0; true; ++i {
            var r = AllocAttrTable::row(i)
            if r.attr == AllocAttr::COUNT {
                break
            }

            if r.attr == attr {
                all = all | r.kws
            }
        }

        return all
    }

    /// The type a Construction names: the callee of `T(args)`, the head of
    /// `T { field: value }`. Null for any other expression.
    pub static fn constructed_type(ctx: unsafe *ASTContext, e: unsafe *Expr) -> unsafe *Type {
        if e == &null {
            return &null
        }

        if isa<NamedInitializerExpr>(e) {
            var unsafe *ini = cast<NamedInitializerExpr>(e)
            if ini->is_dotted || ini->type_expr == &null {
                return &null
            }

            return expr_as_type(ctx, ini->type_expr)
        }

        if isa<CallExpr>(e) {
            var unsafe *c = cast<CallExpr>(e)
            if c->callee == &null {
                return &null
            }

            return expr_as_type(ctx, c->callee)
        }

        return &null
    }

    /// Reads the use `n` against the table. `n` is an AttributedExpr whose
    /// name is an allocation attribute.
    pub static fn classify(ctx: unsafe *ASTContext, n: unsafe *AttributedExpr) -> AllocAttrUse {
        var u = AllocAttrUse{}
        for var vi: usize = 0; vi < ALLOC_KW_VALUES; ++vi {
            u.values[vi] = &null
        }

        u.attr = AllocAttrTable::attr_of(ctx->get_spelling(n->name))
        if u.attr == AllocAttr::COUNT {
            return u
        }

        var allowed = AllocAttrTable::kws_of(u.attr) | ALLOC_KW_IN
        for var i: usize = 0; i < n->args.size(); ++i {
            var unsafe *a = n->args[i]
            if a == &null {
                continue
            }

            if !isa<NamedArgExpr>(a) {
                if u.positional == &null {
                    u.positional = a
                }

                continue
            }

            var unsafe *na = cast<NamedArgExpr>(a)
            var        bit = AllocAttrTable::kw_of(ctx->get_spelling(na->name))
            if bit == 0 || (allowed & bit) == 0 {
                if u.unknown == &null {
                    u.unknown = na
                }

                continue
            }

            if (u.kws & bit) != 0 {
                if u.repeated == &null {
                    u.repeated = na
                    if bit == ALLOC_KW_IN {
                        u.repeated_first = u.kw_in
                    } else {
                        u.repeated_first = u.values[AllocAttrTable::_slot(bit)]
                    }
                }

                continue
            }

            u.kws = u.kws | bit
            if bit == ALLOC_KW_IN {
                u.kw_in = na
                if na->value != &null {
                    u.in_ty = expr_as_type(ctx, na->value)
                }
            } else {
                u.values[AllocAttrTable::_slot(bit)] = na
            }
        }

        if u.positional != &null {
            u.why = AllocMismatch::Positional
            return u
        }

        if u.unknown != &null {
            u.why = AllocMismatch::UnknownKw
            return u
        }

        if u.repeated != &null {
            u.why = AllocMismatch::RepeatedKw
            return u
        }

        if u.kw_in != &null && u.in_ty == &null {
            u.why = AllocMismatch::InNotType
            return u
        }

        // The row whose keyword set is the one written; failing that, the
        // row that takes all of them and the fewest more.
        var want          = u.kws & ~ALLOC_KW_IN
        var near:     i32 = -1
        var near_more     = 0 as u8
        for var i: usize = 0; true; ++i {
            var r = AllocAttrTable::row(i)
            if r.attr == AllocAttr::COUNT {
                break
            }

            if r.attr != u.attr {
                continue
            }

            if r.kws == want {
                u.row = i as i32
                break
            }

            if (r.kws & want) == want {
                var more = r.kws & ~want
                if near < 0 || AllocAttrTable::_count(more) < AllocAttrTable::_count(near_more) {
                    near      = i as i32
                    near_more = more
                }
            }
        }

        if u.row < 0 {
            if near >= 0 {
                u.row     = near
                u.missing = near_more
                u.why     = AllocMismatch::MissingKw
                return u
            }

            u.extra = want
            u.why   = AllocMismatch::ExtraKw
            return u
        }

        var r = AllocAttrTable::row(u.row as usize)
        match r.node {
            case AllocNode::None {
                if n->operand != &null {
                    u.why = AllocMismatch::Node
                }
            } case AllocNode::Value {
                if n->operand == &null {
                    u.why = AllocMismatch::Node
                }
            } case AllocNode::Type {
                if n->operand != &null {
                    u.ty = expr_as_type(ctx, n->operand)
                }

                if u.ty == &null {
                    u.why = AllocMismatch::Node
                }
            } case AllocNode::Construction {
                u.ty = AllocAttrTable::constructed_type(ctx, n->operand)
                if u.ty == &null {
                    u.why = AllocMismatch::Node
                }
            }
        }

        return u
    }

    /// The index of a value keyword's bit in AllocAttrUse::values.
    priv static fn _slot(bit: u8) -> usize {
        if bit == ALLOC_KW_SIZE {
            return 0
        }

        if bit == ALLOC_KW_NEW_SIZE {
            return 1
        }

        if bit == ALLOC_KW_ALIGN {
            return 2
        }

        return 3
    }

    priv static fn _count(set: u8) -> u8 {
        var c: u8 = 0
        for var b: u8 = 1; b != 0 && b <= ALLOC_KW_IN; b = b << 1 {
            if (set & b) != 0 {
                c += 1
            }
        }

        return c
    }
}
