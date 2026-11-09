/// --- The Kairo Project ------------------------- Native/KSharedVFS.hh --- ///
///
///   A codegen TU's view of the fan-out's one shared in-memory file layer.
///
///   The codegen fan-out builds the in-memory layer holding the PCH bytes and
///   wrapper headers once (CodegenMounts::freeze, Interop/Clang/
///   ClangBackend.k), and every TU's OverlayFileSystem stacks it over the
///   real file system. InMemoryFileSystem's reads are safe to share; its one
///   write a TU reaches is setCurrentWorkingDirectory, and it reaches it on
///   every TU: OverlayFileSystem::pushOverlay copies the overlay's working
///   directory into the layer it pushes. Shared, that is a std::string
///   assigned from every worker at once, which corrupted the heap (seen as
///   mimalloc free-list crashes and a PCH line table read forever in the
///   suite).
///
///   So each TU pushes this proxy instead of the layer itself. It forwards
///   every read and drops the working-directory write. The layer's own
///   working directory is set once, before the fan-out, to the value
///   pushOverlay would have copied (shared_layer_sync_cwd), so a relative
///   lookup resolves exactly as it did with one layer per TU. Nothing in the
///   codegen path changes the working directory after that: the real file
///   system below would move the whole process if it did.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

#ifndef __KAIRO_TOOLCHAIN_CORE_KSHAREDVFS_HH__
#define __KAIRO_TOOLCHAIN_CORE_KSHAREDVFS_HH__

#include <system_error>
#include <utility>

#include <llvm/ADT/IntrusiveRefCntPtr.h>
#include <llvm/ADT/Twine.h>
#include <llvm/Support/VirtualFileSystem.h>

namespace kairo {

/// Forwards everything to the shared layer except the working-directory
/// write, which every pushOverlay makes and no TU may make on shared state.
class KSharedLayerFS final : public llvm::vfs::ProxyFileSystem {
public:
    explicit KSharedLayerFS(llvm::IntrusiveRefCntPtr<llvm::vfs::FileSystem> layer)
        : ProxyFileSystem(::std::move(layer)) {}

    ::std::error_code setCurrentWorkingDirectory(const llvm::Twine &) override { return {}; }
};

/// A TU's view of \p layer, to push onto its own OverlayFileSystem.
inline llvm::IntrusiveRefCntPtr<llvm::vfs::FileSystem>
shared_layer_view(llvm::IntrusiveRefCntPtr<llvm::vfs::InMemoryFileSystem> layer) {
    return llvm::makeIntrusiveRefCnt<KSharedLayerFS>(
        llvm::IntrusiveRefCntPtr<llvm::vfs::FileSystem>(::std::move(layer)));
}

/// Gives \p layer the working directory of \p base, as pushOverlay would.
/// Once, on the driver thread, before any TU reads the layer.
inline void shared_layer_sync_cwd(llvm::IntrusiveRefCntPtr<llvm::vfs::InMemoryFileSystem> layer,
                                  llvm::IntrusiveRefCntPtr<llvm::vfs::FileSystem> base) {
    if (!layer || !base) { return; }
    llvm::ErrorOr<::std::string> cwd = base->getCurrentWorkingDirectory();
    if (cwd) { layer->setCurrentWorkingDirectory(*cwd); }
}

} // namespace kairo

#endif // __KAIRO_TOOLCHAIN_CORE_KSHAREDVFS_HH__
