/// --- The Kairo Project --------------------- Analyzer/Driver/kals.k ----- ///
///
///   Kairo Language Server Driver - speaks LSP with stdio
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///
///
/// KLSP - Kairo Language Server Protocol Driver THIS is everything thats needed to run the LSP server:
/// ==============================================
///
/// Transport: JSON-RPC 2.0 over stdio (Content-Length framed)
///
///   stdin  <- editor sends requests/notifications
///   stdout -> klsp sends responses/notifications
///   stderr -> internal diagnostics/logging only (never touches LSP stream)
///
/// Wire Format
/// -----------
///   Request (editor -> klsp):
///     Content-Length: <n>\r\n
///     \r\n
///     {"jsonrpc":"2.0","id":1,"method":"textDocument/hover","params":{...}}
///
///   Response (klsp -> editor):
///     Content-Length: <n>\r\n
///     \r\n
///     {"jsonrpc":"2.0","id":1,"result":{...}}
///
///   Notification (no id, no response expected):
///     Content-Length: <n>\r\n
///     \r\n
///     {"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{...}}
///
///   Error response:
///     Content-Length: <n>\r\n
///     \r\n
///     {"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"method not found"}}
///
/// Lifecycle
/// ---------
///   initialize -> initialized -> [requests] -> shutdown -> exit
///
///   initialize params:  { processId, clientInfo, capabilities, rootUri }
///   initialize result:  { capabilities: { textDocumentSync, hoverProvider,
///                           definitionProvider, completionProvider, ... } }
///
/// Document Sync
/// -------------
///   textDocument/didOpen
///     in:  { textDocument: { uri, languageId, version, text } }
///
///   textDocument/didChange
///     in:  { textDocument: { uri, version },
///            contentChanges: [{ range?, text }] }
///
///   textDocument/didClose
///     in:  { textDocument: { uri } }
///
/// Language Features
/// -----------------
///   textDocument/publishDiagnostics  (klsp -> editor, notification)
///     out: { uri, diagnostics: [{ range, severity, code, message, source }] }
///
///   textDocument/hover
///     in:  { textDocument: { uri }, position: { line, character } }
///     out: { contents: { kind: "markdown", value: "..." }, range }
///
///   textDocument/definition
///     in:  { textDocument: { uri }, position: { line, character } }
///     out: { uri, range } | [{ uri, range }]
///
///   textDocument/references
///     in:  { textDocument: { uri }, position, context: { includeDeclaration } }
///     out: [{ uri, range }]
///
///   textDocument/rename
///     in:  { textDocument: { uri }, position, newName }
///     out: { changes: { <uri>: [{ range, newText }] } }
///
///   textDocument/prepareRename
///     in:  { textDocument: { uri }, position }
///     out: { range, placeholder }
///
///   textDocument/completion
///     in:  { textDocument: { uri }, position,
///            context: { triggerKind, triggerCharacter } }
///     out: { isIncomplete, items: [{ label, kind, detail, insertText, ... }] }
///
///   completionItem/resolve
///     in:  { ...completionItem }
///     out: { ...completionItem, documentation }
///
///   textDocument/signatureHelp
///     in:  { textDocument: { uri }, position,
///            context: { triggerKind, triggerCharacter, activeSignatureHelp } }
///     out: { signatures: [{ label, parameters: [{ label }] }],
///            activeSignature, activeParameter }
///
///   textDocument/documentHighlight
///     in:  { textDocument: { uri }, position }
///     out: [{ range, kind }]   // kind: 1=text 2=read 3=write
///
///   textDocument/documentSymbol
///     in:  { textDocument: { uri } }
///     out: [{ name, kind, range, selectionRange, children }]
///
///   textDocument/inlayHint
///     in:  { textDocument: { uri }, range }
///     out: [{ position, label, kind }]  // kind: 1=type 2=parameter
///
///   textDocument/semanticTokens/full
///     in:  { textDocument: { uri } }
///     out: { data: [deltaLine, deltaChar, length, tokenType, tokenModifiers] }
///
///   textDocument/codeAction
///     in:  { textDocument: { uri }, range,
///            context: { diagnostics, only? } }
///     out: [{ title, kind, diagnostics, edit: { changes } }]
///
///   textDocument/formatting
///     in:  { textDocument: { uri }, options: { tabSize, insertSpaces } }
///     out: [{ range, newText }]
///
///   textDocument/rangeFormatting
///     in:  { textDocument: { uri }, range, options }
///     out: [{ range, newText }]
///
///   textDocument/codeLens
///     in:  { textDocument: { uri } }
///     out: [{ range, command?: { title, command, arguments } }]
///
/// Workspace
/// ---------
///   workspace/symbol
///     in:  { query }
///     out: [{ name, kind, location: { uri, range } }]
///
///   workspace/didChangeWatchedFiles
///     in:  { changes: [{ uri, type }] }  // type: 1=created 2=changed 3=deleted
///
/// Plumbing
/// --------
///   $/cancelRequest
///     in:  { id }
///
///   window/showMessage
///     out: { type, message }  // type: 1=error 2=warn 3=info 4=log
///
///   window/logMessage
///     out: { type, message }

ffi "c++" import "Native/GlobalRecycler.hh"
ffi "c++" import "Native/KLocale.hh" // init_process_locale
ffi "c++" import "Native/KLog.hh"
ffi "c++" import "Native/Types.hh"
ffi "c++" import "cstring"
ffi "c++" import "llvm/Support/InitLLVM.h"
ffi "c++" import "llvm/Support/TargetSelect.h"
ffi "c++" import "locale"
ffi "c++" import "sstream"

import Index::Worker::worker_main
import Server::server_main
import std::c_char
import std::env
import std::io

/// The same process setup `kairo` and `kfmt` do: the worker IS the compiler,
/// and clang needs its targets registered before the first header is read.
fn init_runtime(argc: i32, argv: unsafe *(unsafe *c_char)) -> unsafe *llvm::InitLLVM {
    var unsafe *init_llvm = kairo::std::create<llvm::InitLLVM>(argc, argv)
    llvm::InitializeAllTargetInfos()
    llvm::InitializeAllTargets()
    llvm::InitializeAllTargetMCs()
    llvm::InitializeAllAsmParsers()
    llvm::InitializeAllAsmPrinters()

    kairo::init_process_locale()

    cxx::std::use_facet<cxx::std::num_put<c_char>>(cxx::std::locale())
    cxx::std::use_facet<cxx::std::num_get<c_char>>(cxx::std::locale())

    { // Force narrow char locale facets used by stringstream/to_string
        var oss: cxx::std::ostringstream
        // i32 and f32, as in Compiler/Driver/Runtime.k: usize and f64 each
        // match two operator<< on targets where the C++ types coincide.
        oss << (1 as i32) << (1.0 as f32)
        oss.str()
    }

    return init_llvm
}

fn usage() {
    io::eprintln("Usage: kals [--stdio]            run the language server on stdin/stdout")
    io::eprintln("       kals --version")
    io::eprintln("       kals --worker <out.json> [--root <dir>] [--overlay <real> <tmp>]... -- <kairo args>")
}

pub fn main(argc: i32, argv: unsafe *(unsafe *c_char)) -> i32 {
    var args: [string]
    for var i: i32 = 1; i < argc; ++i {
        args.push_back(string(
            unsafe ((argv[i] as unsafe *const u8) as *const u8),
            cxx::std::strlen(argv[i]),
        ))
    }

    if (args.size() > 0) && ((args[0] == "--help") || (args[0] == "-h")) {
        usage()
        return 0
    }

    if (args.size() > 0) && (args[0] == "--version") {
        io::println("kals (Kairo language server)")
        return 0
    }

    // Workers are this same binary; argv[0] may be a bare name found on
    // PATH, which a child process cannot be started from.
    var self_path = env::exe_path()
    if self_path.empty() {
        self_path = string(
            unsafe ((argv[0] as unsafe *const u8) as *const u8),
            cxx::std::strlen(argv[0]),
        )
    }

    if (args.size() > 0) && (args[0] == "--worker") {
        kairo::Logger::init(kairo::Logger::Level::Warn)
        var unsafe *llvm_init = init_runtime(argc, argv)
        finally {
            kairo::Logger::shutdown()
            kairo::GlobalRecycler::shutdown_allocator_runtime()
            kairo::std::destroy(llvm_init)
        }

        var rest: [string]
        for var i: usize = 1; i < args.size(); ++i {
            rest.push_back(args[i])
        }

        return worker_main(&rest)
    }

    // The server itself never touches the compiler: it frames messages,
    // keeps buffers, and starts workers.
    return server_main(self_path)
}
