/// --- The Kairo Project --------------------------- Native/SharedVFS.k --- ///
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
///   assigned from every worker at once, which corrupts the heap.
///
///   So each TU pushes this proxy instead of the layer itself. It forwards
///   every read and drops the working-directory write. The layer's own
///   working directory is set once, before the fan-out, to the value
///   pushOverlay would have copied (shared_layer_sync_cwd), so a relative
///   lookup resolves exactly as it would with one layer per TU. Nothing in
///   the codegen path changes the working directory after that: the real
///   file system below would move the whole process if it did.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "Native/Types.hh" // create
ffi "c++" import "llvm/ADT/IntrusiveRefCntPtr.h"
ffi "c++" import "llvm/ADT/Twine.h"
ffi "c++" import "llvm/Support/VirtualFileSystem.h"
ffi "c++" import "system_error"

/// Forwards everything to the shared layer except the working-directory
/// write, which every pushOverlay makes and no TU may make on shared state.
pub final class KSharedLayerFS derives llvm::vfs::ProxyFileSystem {
    pub fn KSharedLayerFS(self, layer: llvm::IntrusiveRefCntPtr<llvm::vfs::FileSystem>) {
        llvm::vfs::ProxyFileSystem::ProxyFileSystem(self, layer)
    }

    override fn setCurrentWorkingDirectory(self, const path: llvm::Twine) -> cxx::std::error_code {
        return cxx::std::error_code()
    }
}

/// A TU's view of `layer`, to push onto its own OverlayFileSystem.
pub fn shared_layer_view(layer: llvm::IntrusiveRefCntPtr<llvm::vfs::InMemoryFileSystem>)
    -> llvm::IntrusiveRefCntPtr<llvm::vfs::FileSystem> {
    return llvm::IntrusiveRefCntPtr<llvm::vfs::FileSystem>(
        kairo::std::create<KSharedLayerFS>(
            llvm::IntrusiveRefCntPtr<llvm::vfs::FileSystem>(layer),
        ),
    )
}

/// Gives `layer` the working directory of `base`, as pushOverlay would.
/// Once, on the driver thread, before any TU reads the layer.
pub fn shared_layer_sync_cwd(layer: llvm::IntrusiveRefCntPtr<llvm::vfs::InMemoryFileSystem>,
                             base:  llvm::IntrusiveRefCntPtr<llvm::vfs::FileSystem>) {
    if !(layer as bool) || !(base as bool) {
        return
    }

    var cwd = base->getCurrentWorkingDirectory()
    if cwd.getError().value() == 0 {
        layer->setCurrentWorkingDirectory(llvm::Twine(cwd.get()))
    }
}
