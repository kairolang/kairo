//===-- Linker/Driver/kld_drivers.h - LLD driver decls --------------------===//
//
// Part of the Kairo Project, under the Apache License v2.0 with the
// Kairo Runtime Library Exception.
// SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
// Copyright (c) 2026 Dhruvan Kartik
//
//===----------------------------------------------------------------------===//
//
// Global-scope home for the LLD_HAS_DRIVER expansions. These declare
// ::lld::{coff,elf,mingw,macho,wasm}::link. They MUST sit at global scope so
// the symbols resolve to real LLD, not kairo::...::lld. kld.k can't host them:
// stage0 wraps the file body in namespace kairo, so the macro would declare the
// wrong symbols. Hence this header.
//
// The driver table (LLD_ALL_DRIVERS) is an expression and stays in kld.k.
//
//===----------------------------------------------------------------------===//

#ifndef KAIRO_LINKER_DRIVER_KLD_DRIVERS_H
#define KAIRO_LINKER_DRIVER_KLD_DRIVERS_H

#include "lld/Common/Driver.h"

LLD_HAS_DRIVER(coff)
LLD_HAS_DRIVER(elf)
LLD_HAS_DRIVER(mingw)
LLD_HAS_DRIVER(macho)
LLD_HAS_DRIVER(wasm)

static const lld::DriverDef kld_drivers[] = LLD_ALL_DRIVERS;

/// The drivers as the ArrayRef lld::lldMain takes (Kairo cannot build one from the array).
inline llvm::ArrayRef<lld::DriverDef> kld_driver_list() { return llvm::ArrayRef<lld::DriverDef>(kld_drivers); }

#endif // KAIRO_LINKER_DRIVER_KLD_DRIVERS_H