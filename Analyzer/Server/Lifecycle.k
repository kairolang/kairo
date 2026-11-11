/// --- The Kairo Project ------------------- Analyzer/Server/Lifecycle.k --- ///
///
///   Session start and end: the project file, initialize and the capabilities it answers.
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
ffi "c++" import "llvm/ADT/StringRef.h"
ffi "c++" import "llvm/Support/Program.h"
ffi "c++" import "optional"
ffi "c++" import "string"
ffi "c++" import "llvm/ADT/SmallVector.h"
ffi "c++" import "chrono"

import API::FS::LinkFS
import DocumentStore::{
    DocumentStore,
    fnv1a,
    path_to_uri,
    uri_to_path,
}
import Index::Legend::*
import Index::Snapshot::*
import Protocol::*
import Tuning::*
import Json::{
    JSON_NONE,
    JsonDoc,
    JsonWriter,
}
import JsonRpc::Transport
import Support::FileIO::Path::Path
import TextScan::{
    InterfacePlan,
    Span,
    call_at,
    interface_for,
    spans,
}
import Workspace::CompileCommandsLoader::{
    Project,
    project_file_name,
}
import std::io
import Server::ClangdBridge::*
import Server::CodeActions::*
import Server::Completion::*
import Server::Diagnostics::*
import Server::Features::*
import Server::Formatting::*
import Server::Lookup::*
import Server::Navigation::*
import Server::Output::*
import Server::Scheduling::*
import Server::Server::*
import Server::SignatureHelp::*
import Server::Structure::*
import Server::TextUtil::*
import Server::Tokens::*
import Server::Workers::*

extend Server {
    /// (Re)reads the project file and rebuilds the entry list from it.
    fn load_project(self) {
        self.project.load(self.root)
        if !self.project.error.empty() {
            self.show(MSG_WARNING, self.project.error)
        }

        // Snapshots of the old list describe commands that may no longer
        // exist; start over. Anything parked is retried against the new list.
        for var i: usize = 0; i < self.entries.size(); ++i {
            self.clear_published_(i)
        }

        self.entries.clear()
        for var i: usize = 0; i < self.project.entries.size(); ++i {
            var e = Entry()
            e.entry      = self.project.entries[i].entry
            e.dir        = self.project.entries[i].dir
            e.args       = self.project.entries[i].args
            e.change_rev = self.rev
            // Not analysed until a buffer needs it (ensure_entry): a project
            // file may list a dozen entry points, each a whole compile.
            e.dirty = false
            self.entries.push_back(e)
        }
    }

    fn initialize(self, d: *const JsonDoc, params: u32, const id: string) {
        var root = d->get_str(params, "rootUri")
        var wf   = d->first(d->get(params, "workspaceFolders"))
        if wf != JSON_NONE() {
            root = d->get_str(wf, "uri")
        }

        if root.empty() {
            var rp = d->get_str(params, "rootPath")
            if !rp.empty() {
                root = path_to_uri(rp)
            }
        }

        if root.empty() {
            self.root = Path::cwd().full_path()
        } else {
            self.root = Path::real_path_of(uri_to_path(root))
        }

        self.project.dir = self.root

        var opts = d->get(params, "initializationOptions")
        var dms  = d->get_int(opts, "debounceMs")
        if d->is_number(d->get(opts, "debounceMs")) && (dms >= 0) && (dms <= MAX_DEBOUNCE_OPTION_MS) {
            self.debounce_ms = dms
        }

        var sms = d->get_int(opts, "syntaxDebounceMs")
        if d->is_number(d->get(opts, "syntaxDebounceMs")) && (sms >= 0) && (sms <= MAX_DEBOUNCE_OPTION_MS) {
            self.syntax_ms = sms
        }

        self.highlight_panics = d->get_bool(opts, "highlightPanics")
        self.progress_ok = d->get_bool(d->get(d->get(params, "capabilities"), "window"), "workDoneProgress")

        var mw = d->get_int(opts, "maxWorkers")
        if d->is_number(d->get(opts, "maxWorkers")) && (mw >= 1) && (mw <= MAX_WORKERS_OPTION) {
            self.max_index = mw as usize
        }

        var ws = d->get(d->get(params, "capabilities"), "workspace")
        self.refresh_tokens = d->get_bool(d->get(ws, "semanticTokens"), "refreshSupport")
        self.refresh_inlays = d->get_bool(d->get(ws, "inlayHint"), "refreshSupport")

        var w = JsonWriter()
        w.begin_object()
        w.key("capabilities")
        w.begin_object()
        // UTF-16 is the encoding every client speaks; none is negotiated.
        w.field("positionEncoding", "utf-16")
        w.key("textDocumentSync")
        w.begin_object()
        w.field_bool("openClose", true)
        w.field_int("change", 2)
        w.field_raw("save", "{\"includeText\":false}")
        w.end_object()
        w.key("semanticTokensProvider")
        w.begin_object()
        w.key("legend")
        w.begin_object()
        w.field_raw("tokenTypes", token_type_names())
        w.field_raw("tokenModifiers", token_modifier_names())
        w.end_object()
        w.field_raw("full", "{\"delta\":true}")
        w.field_bool("range", true)
        w.end_object()
        w.field_bool("definitionProvider", true)
        w.field_bool("hoverProvider", true)
        w.field_bool("documentHighlightProvider", true)
        w.field_bool("referencesProvider", true)
        w.field_raw("renameProvider", "{\"prepareProvider\":true}")
        w.field_bool("typeDefinitionProvider", true)
        w.field_bool("declarationProvider", true)
        w.field_bool("workspaceSymbolProvider", true)
        w.field_bool("foldingRangeProvider", true)
        w.field_bool("selectionRangeProvider", true)
        w.field_raw("documentLinkProvider", "{\"resolveProvider\":false}")
        w.field_raw("signatureHelpProvider", "{\"triggerCharacters\":[\"(\",\",\"]}")
        w.field_bool("implementationProvider", true)
        w.field_bool("callHierarchyProvider", true)
        w.field_bool("typeHierarchyProvider", true)
        w.field_bool("documentRangeFormattingProvider", true)
        w.field_raw("codeLensProvider", "{\"resolveProvider\":false}")
        w.field_bool("documentSymbolProvider", true)
        w.field_bool("documentFormattingProvider", true)
        // The object form, not `true`: both are valid, and a client that
        // only looks for the options object then still sees the capability.
        w.field_raw("inlayHintProvider", "{\"resolveProvider\":false}")
        w.field_raw("codeActionProvider", "{\"codeActionKinds\":[\"" + KIND_QUICKFIX + "\",\"" + KIND_REFACTOR_INLINE + "\",\"" + KIND_REFACTOR_EXTRACT + "\"]}")
        w.field_raw("completionProvider", "{\"triggerCharacters\":[\".\",\":\",\">\"],\"resolveProvider\":true}")
        w.field_raw("documentOnTypeFormattingProvider", "{\"firstTriggerCharacter\":\"}\"}")
        w.end_object()
        w.key("serverInfo")
        w.begin_object()
        w.field("name", "kals")
        w.end_object()
        w.end_object()
        self.respond(id, w.out)
    }
}
