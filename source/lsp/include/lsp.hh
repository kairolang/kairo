///--- The Kairo Project ------------------------------------------------------------------------///
///                                                                                              ///
///   Part of the Kairo Project, under the Attribution 4.0 International license (CC BY 4.0).    ///
///   You are allowed to use, modify, redistribute, and create derivative works, even for        ///
///   commercial purposes, provided that you give appropriate credit, and indicate if changes    ///
///   were made.                                                                                 ///
///                                                                                              ///
///   For more information on the license terms and requirements, please visit:                  ///
///     https://creativecommons.org/licenses/by/4.0/                                             ///
///                                                                                              ///
///   SPDX-License-Identifier: CC-BY-4.0                                                         ///
///   Copyright (c) 2024 The Kairo Project (CC BY 4.0)                                           ///
///                                                                                              ///
///-------------------------------------------------------------------------------------- C++ ---///

#ifndef __KAIRO_LSP_HH__
#define __KAIRO_LSP_HH__

#include <iostream>
#include <set>
#include <string>
#include <map>
#include <memory>
#include <fstream>
#include <sstream>
#include <filesystem>
#include <nlohmann/json.hpp>
#include "controller/include/tooling/tooling.hh"

#ifdef _WIN32
    #include <windows.h>
    #include <io.h>
    #define popen _popen
    #define pclose _pclose
#else
    #include <unistd.h>
    #include <sys/wait.h>
    #include <poll.h>
    #include <signal.h>
#endif

#include "generator/include/CX-IR/CXIR.hh"

namespace kairo::lsp {

using json = nlohmann::json;

// ============================================================================
// ClangdProcess - Manages clangd subprocess lifecycle
// ============================================================================
class ClangdProcess {
private:
#ifdef _WIN32
    HANDLE stdin_write{INVALID_HANDLE_VALUE};
    HANDLE stdout_read{INVALID_HANDLE_VALUE};
    PROCESS_INFORMATION process_info{};
#else
    int stdin_pipe[2]{-1, -1};
    int stdout_pipe[2]{-1, -1};
    pid_t pid{-1};
#endif
    bool running{false};

public:
    ClangdProcess() = default;
    ~ClangdProcess() { shutdown(); }

    bool is_running() const { return running; }

    bool start(const std::string& compile_commands_dir) {
#ifdef _WIN32
        SECURITY_ATTRIBUTES sa;
        sa.nLength = sizeof(SECURITY_ATTRIBUTES);
        sa.bInheritHandle = TRUE;
        sa.lpSecurityDescriptor = NULL;

        HANDLE stdin_read_h, stdout_write_h;
        if (!CreatePipe(&stdin_read_h, &stdin_write, &sa, 0)) return false;
        if (!CreatePipe(&stdout_read, &stdout_write_h, &sa, 0)) {
            CloseHandle(stdin_read_h);
            CloseHandle(stdin_write);
            return false;
        }

        SetHandleInformation(stdin_write, HANDLE_FLAG_INHERIT, 0);
        SetHandleInformation(stdout_read, HANDLE_FLAG_INHERIT, 0);

        STARTUPINFOA si{};
        si.cb = sizeof(si);
        si.hStdInput = stdin_read_h;
        si.hStdOutput = stdout_write_h;
        si.hStdError = GetStdHandle(STD_ERROR_HANDLE);
        si.dwFlags |= STARTF_USESTDHANDLES;

        std::string cmd = "clangd --header-insertion=never --clang-tidy=false" + " --compile-commands-dir=" + compile_commands_dir;
        bool success = CreateProcessA(NULL, const_cast<char*>(cmd.c_str()),
                                       NULL, NULL, TRUE, 0, NULL, NULL, &si, &process_info);
        CloseHandle(stdin_read_h);
        CloseHandle(stdout_write_h);

        if (success) {
            running = true;
        } else {
            CloseHandle(stdin_write);
            CloseHandle(stdout_read);
            stdin_write = INVALID_HANDLE_VALUE;
            stdout_read = INVALID_HANDLE_VALUE;
        }
        return success;
#else
        if (pipe(stdin_pipe) == -1) return false;
        if (pipe(stdout_pipe) == -1) {
            close(stdin_pipe[0]);
            close(stdin_pipe[1]);
            return false;
        }

        pid = fork();
        if (pid == -1) {
            close(stdin_pipe[0]);
            close(stdin_pipe[1]);
            close(stdout_pipe[0]);
            close(stdout_pipe[1]);
            return false;
        }

        if (pid == 0) {
            close(stdin_pipe[1]);
            close(stdout_pipe[0]);
            dup2(stdin_pipe[0], STDIN_FILENO);
            dup2(stdout_pipe[1], STDOUT_FILENO);
            close(stdin_pipe[0]);
            close(stdout_pipe[1]);

            execlp("clangd", "clangd",
                  ("--compile-commands-dir=" + compile_commands_dir).c_str(),
                   "--header-insertion=never",
                   "--clang-tidy=false",
                   nullptr);
            _exit(1);
        }

        close(stdin_pipe[0]);
        close(stdout_pipe[1]);
        stdin_pipe[0] = -1;
        stdout_pipe[1] = -1;
        running = true;
        return true;
#endif
    }

    void write(const std::string& data) {
        if (!running) return;
#ifdef _WIN32
        DWORD written;
        WriteFile(stdin_write, data.c_str(), data.size(), &written, NULL);
#else
        size_t total = 0;
        while (total < data.size()) {
            ssize_t n = ::write(stdin_pipe[1], data.c_str() + total, data.size() - total);
            if (n <= 0) { running = false; return; }
            total += n;
        }
#endif
    }

    std::string read() {
        if (!running) return "";
        std::string header;
        char c;

#ifdef _WIN32
        DWORD read_bytes;
        while (ReadFile(stdout_read, &c, 1, &read_bytes, NULL) && read_bytes > 0) {
            header += c;
            if (header.size() >= 4 && header.substr(header.size() - 4) == "\r\n\r\n") break;
        }
#else
        while (true) {
            ssize_t n = ::read(stdout_pipe[0], &c, 1);
            if (n <= 0) { running = false; return ""; }
            header += c;
            if (header.size() >= 4 && header.substr(header.size() - 4) == "\r\n\r\n") break;
        }
#endif
        if (header.empty()) return "";
        size_t cl_pos = header.find("Content-Length:");
        if (cl_pos == std::string::npos) return "";
        size_t cl_end = header.find("\r\n", cl_pos);
        size_t length = std::stoul(header.substr(cl_pos + 16, cl_end - cl_pos - 16));

        std::string body;
        body.resize(length);
#ifdef _WIN32
        DWORD total_read = 0;
        while (total_read < length) {
            DWORD rb;
            if (!ReadFile(stdout_read, &body[total_read], length - total_read, &rb, NULL) || rb == 0) {
                running = false; return "";
            }
            total_read += rb;
        }
#else
        size_t total_read = 0;
        while (total_read < length) {
            ssize_t n = ::read(stdout_pipe[0], &body[total_read], length - total_read);
            if (n <= 0) { running = false; return ""; }
            total_read += n;
        }
#endif
        return body;
    }

    bool has_data(int timeout_ms = 0) {
        if (!running) return false;
#ifdef _WIN32
        return true;
#else
        struct pollfd pfd;
        pfd.fd = stdout_pipe[0];
        pfd.events = POLLIN;
        int ret = poll(&pfd, 1, timeout_ms);
        return ret > 0 && (pfd.revents & POLLIN);
#endif
    }

    void shutdown() {
        if (!running) return;
        running = false;
#ifdef _WIN32
        if (process_info.hProcess != NULL) {
            TerminateProcess(process_info.hProcess, 0);
            CloseHandle(process_info.hProcess);
            CloseHandle(process_info.hThread);
            process_info.hProcess = NULL;
        }
        if (stdin_write != INVALID_HANDLE_VALUE) { CloseHandle(stdin_write); stdin_write = INVALID_HANDLE_VALUE; }
        if (stdout_read != INVALID_HANDLE_VALUE) { CloseHandle(stdout_read); stdout_read = INVALID_HANDLE_VALUE; }
#else
        if (stdin_pipe[1] >= 0) { close(stdin_pipe[1]); stdin_pipe[1] = -1; }
        if (stdout_pipe[0] >= 0) { close(stdout_pipe[0]); stdout_pipe[0] = -1; }
        if (pid > 0) { kill(pid, SIGTERM); waitpid(pid, nullptr, 0); pid = -1; }
#endif
    }
};

// ============================================================================
// PositionTranslator - Translates between Kairo and C++ positions
//
// LSP positions are 0-based. Kairo's LSPPositionMapper uses 1-based.
// ============================================================================
class PositionTranslator {
private:
    const generator::CXIR::LSPPositionMapper& mapper;
    std::string kairo_file;
    std::string cpp_file;

public:
    PositionTranslator(const generator::CXIR::LSPPositionMapper& m,
                      const std::string& k_file, const std::string& c_file)
        : mapper(m), kairo_file(k_file), cpp_file(c_file) {}

    std::optional<std::pair<size_t, size_t>> kairo_to_cpp(size_t lsp_line, size_t lsp_col) {
        auto result = mapper.map_helix_to_cpp(kairo_file, lsp_line + 1, lsp_col + 1);
        if (result) return std::make_pair(result->line - 1, result->col - 1);
        return std::nullopt;
    }

    std::optional<std::pair<size_t, size_t>> cpp_to_kairo(size_t lsp_line, size_t lsp_col) {
        auto result = mapper.map_cpp_to_helix(kairo_file, lsp_line + 1, lsp_col + 1);
        if (result) return std::make_pair(result->line - 1, result->col - 1);
        return std::nullopt;
    }

    const std::string& get_cpp_file() const { return cpp_file; }
    const std::string& get_kairo_file() const { return kairo_file; }
};

// ============================================================================
// CompileCommandsWriter - Writes compile_commands.json for clangd
// Uses the real compile command from CXIRCompiler.
// ============================================================================
class CompileCommandsWriter {
public:
    static void write(const std::filesystem::path& cpp_file,
                     const std::string& compile_command) {
        std::filesystem::path commands_file = cpp_file.parent_path() / "compile_commands.json";

        json commands = json::array();
        json entry;
        entry["directory"] = cpp_file.parent_path().string();
        entry["file"] = cpp_file.string();
        entry["command"] = compile_command;
        commands.push_back(entry);

        std::ofstream out(commands_file);
        if (out.is_open()) {
            out << commands.dump(2);
            out.close();
        }

        std::cerr << "[LSP] Wrote compile_commands.json: " << commands_file.string() << std::endl;
        std::cerr << "[LSP] Command: " << compile_command << std::endl;
    }
};

// ============================================================================
// LSPProxy - Main LSP server that intercepts and translates positions
// ============================================================================
class LSPProxy {
private:
    ClangdProcess clangd;
    std::unique_ptr<PositionTranslator> translator;
    std::map<std::string, std::string> kairo_to_cpp_uri;
    std::set<std::string> pending_server_requests;  // ids of requests clangd sent TO the client

    // ---- Wire protocol helpers ----

    void send_to_client(const std::string& message) {
        std::string header = "Content-Length: " + std::to_string(message.size()) + "\r\n\r\n";
        std::cout.write(header.c_str(), header.size());
        std::cout.write(message.c_str(), message.size());
        std::cout.flush();
    }

    std::string read_from_client() {
        std::string header;
        char c;
        while (std::cin.get(c)) {
            header += c;
            if (header.size() >= 4 &&
                header[header.size()-4] == '\r' && header[header.size()-3] == '\n' &&
                header[header.size()-2] == '\r' && header[header.size()-1] == '\n') {
                break;
            }
        }
        if (header.empty() || std::cin.eof()) return "";
        size_t cl_pos = header.find("Content-Length:");
        if (cl_pos == std::string::npos) return "";
        size_t cl_end = header.find("\r\n", cl_pos);
        size_t length = std::stoul(header.substr(cl_pos + 16, cl_end - cl_pos - 16));
        std::string body;
        body.resize(length);
        std::cin.read(&body[0], length);
        if (static_cast<size_t>(std::cin.gcount()) != length) return "";
        return body;
    }

    void send_to_clangd(const json& message) {
        std::string body = message.dump();
        std::string header = "Content-Length: " + std::to_string(body.size()) + "\r\n\r\n";
        clangd.write(header + body);
    }

    /// Read a response from clangd, forwarding notifications AND server-initiated
    /// requests to the client. Returns only when we get an actual response (has "id"
    /// but no "method").
    ///
    /// LSP message types from clangd:
    ///   - Notification:     has "method", no "id"       → forward to client
    ///   - Server request:   has "method" AND "id"       → forward to client
    ///   - Response:         has "id", no "method"       → return it
    json read_response_from_clangd() {
        while (clangd.is_running()) {
            std::string body = clangd.read();
            if (body.empty()) return json{};

            try {
                json msg = json::parse(body);

                bool has_id = msg.contains("id");
                bool has_method = msg.contains("method");

                if (has_method) {
                    // Notification or server-initiated request — forward to client
                    translate_response_positions(msg);
                    send_to_client(msg.dump());

                    if (has_id) {
                        // Server request — clangd expects a reply from the client.
                        // Track it so we can forward the client's reply back.
                        std::cerr << "[LSP] Server request from clangd: "
                                  << msg["method"] << " (id=" << msg["id"].dump() << ")" << std::endl;
                        pending_server_requests.insert(msg["id"].dump());
                    }
                    continue;
                }

                if (has_id) {
                    // Actual response to our request
                    return msg;
                }

                // Shouldn't happen, but forward anyway
                send_to_client(msg.dump());

            } catch (const std::exception& e) {
                std::cerr << "[LSP] Failed to parse clangd message: " << e.what() << std::endl;
                return json{};
            }
        }
        return json{};
    }

    void drain_clangd_notifications() {
        while (clangd.has_data(50)) {
            std::string body = clangd.read();
            if (body.empty()) return;

            try {
                json msg = json::parse(body);
                bool has_method = msg.contains("method");
                bool has_id = msg.contains("id");

                translate_response_positions(msg);
                send_to_client(msg.dump());

                if (has_method && has_id) {
                    std::cerr << "[LSP] Server request from clangd (drain): "
                              << msg["method"] << " (id=" << msg["id"].dump() << ")" << std::endl;
                    pending_server_requests.insert(msg["id"].dump());
                }
            } catch (...) {}
        }
    }

    // ---- Position translation ----

    void translate_request_positions(json& request) {
        if (!translator) return;
        try {
            if (request.contains("params") && request["params"].contains("textDocument")) {
                auto& td = request["params"]["textDocument"];
                if (td.contains("uri")) {
                    std::string uri = td["uri"];
                    if (kairo_to_cpp_uri.count(uri)) {
                        std::cerr << "[LSP] URI: " << uri << " -> " << kairo_to_cpp_uri[uri] << std::endl;
                        td["uri"] = kairo_to_cpp_uri[uri];
                    }
                }
            }
            if (request.contains("params") && request["params"].contains("position")) {
                size_t line = request["params"]["position"]["line"];
                size_t character = request["params"]["position"]["character"];
                auto cpp_pos = translator->kairo_to_cpp(line, character);
                if (cpp_pos) {
                    std::cerr << "[LSP] Position: (" << line << "," << character
                              << ") -> (" << cpp_pos->first << "," << cpp_pos->second << ")" << std::endl;
                    request["params"]["position"]["line"] = cpp_pos->first;
                    request["params"]["position"]["character"] = cpp_pos->second;
                } else {
                    std::cerr << "[LSP] Position: (" << line << "," << character
                              << ") -> no mapping found" << std::endl;
                }
            }
        } catch (...) {}
    }

    void translate_response_positions(json& response) {
        if (!translator) return;
        try {
            if (response.contains("result")) translate_positions_recursive(response["result"]);
            if (response.contains("params")) translate_positions_recursive(response["params"]);
        } catch (...) {}
    }

    void translate_positions_recursive(json& node) {
        if (node.is_null()) return;

        // Translate URIs back from C++ to Kairo
        if (node.contains("uri")) {
            std::string uri = node["uri"];
            if (translator && uri.find(translator->get_cpp_file()) != std::string::npos) {
                node["uri"] = "file://" + translator->get_kairo_file();
            }
        }

        // Translate all range-like fields
        if (node.contains("range")) translate_range(node["range"]);
        if (node.contains("targetRange")) translate_range(node["targetRange"]);
        if (node.contains("targetSelectionRange")) translate_range(node["targetSelectionRange"]);
        if (node.contains("selectionRange")) translate_range(node["selectionRange"]);

        // Clamp selectionRange within range (LSP spec requires this)
        if (node.contains("range") && node.contains("selectionRange")) {
            auto& range = node["range"];
            auto& sel = node["selectionRange"];

            auto line_char_lt = [](const json& a, const json& b) -> bool {
                size_t al = a["line"], ac = a["character"];
                size_t bl = b["line"], bc = b["character"];
                return (al < bl) || (al == bl && ac < bc);
            };

            auto line_char_gt = [](const json& a, const json& b) -> bool {
                size_t al = a["line"], ac = a["character"];
                size_t bl = b["line"], bc = b["character"];
                return (al > bl) || (al == bl && ac > bc);
            };

            if (line_char_lt(sel["start"], range["start"])) {
                sel["start"] = range["start"];
            }
            if (line_char_gt(sel["end"], range["end"])) {
                sel["end"] = range["end"];
            }
            // If clamping made it invalid (start > end), collapse to start
            if (line_char_gt(sel["start"], sel["end"])) {
                sel["end"] = sel["start"];
            }
        }

        // Recurse
        if (node.is_array()) {
            for (auto& item : node) translate_positions_recursive(item);
        } else if (node.is_object()) {
            for (auto& [key, value] : node.items()) {
                if (value.is_object() || value.is_array()) translate_positions_recursive(value);
            }
        }
    }

    void translate_range(json& range) {
        if (!translator || range.is_null()) return;
        if (range.contains("start")) translate_position(range["start"]);
        if (range.contains("end")) translate_position(range["end"]);
    }

    void translate_position(json& pos) {
        if (!translator || pos.is_null()) return;
        try {
            size_t line = pos["line"];
            size_t character = pos["character"];
            auto kairo_pos = translator->cpp_to_kairo(line, character);
            if (kairo_pos) {
                pos["line"] = kairo_pos->first;
                pos["character"] = kairo_pos->second;
            } else {
                // No mapping found — clamp to line 0 col 0 so we don't
                // leak C++ line numbers (1200+) into a 3-line Kairo file
                pos["line"] = 0;
                pos["character"] = 0;
            }
        } catch (...) {}
    }

    // ---- Kairo compilation ----

    bool compile_kairo_file(const std::string& file_path, int argc, char** argv) {
        std::cerr << "[LSP] Compiling Kairo file: " << file_path << std::endl;

        try {
            error::HAS_ERRORED = false;

            std::vector<std::string> arg_strings = {"kairo", file_path, "--quiet"};
            std::vector<char*> arg_ptrs;
            for (auto& s : arg_strings) arg_ptrs.push_back(const_cast<char*>(s.c_str()));
            arg_ptrs.push_back(nullptr);

            __CONTROLLER_CLI_N::CLIArgs compile_args(
                static_cast<int>(arg_ptrs.size() - 1),
                arg_ptrs.data(),
                "Kairo LSP Compile"
            );

            compile_args.build_mode = __CONTROLLER_CLI_N::CLIArgs::MODE::DEBUG_;

            CompilationUnit compilation_unit;
            auto [action, result] = compilation_unit.build_unit(compile_args);

            if (result != 0) {
                std::cerr << "[LSP] Compilation failed with code: " << result << std::endl;
                return false;
            }

            if (action.cc_source.empty()) {
                std::cerr << "[LSP] Compilation produced no C++ output" << std::endl;
                return false;
            }

            // Save paths before action gets moved
            std::string cpp_file = action.cc_source.string();
            std::filesystem::path cpp_source_path = action.cc_source;

            // Generate the real platform-correct compile command without invoking compiler
            compilation_unit.compiler.compile_CXIR(std::move(action), false, true);
            std::string compile_command = compilation_unit.compiler.command;

            if (!compile_command.empty()) {
                CompileCommandsWriter::write(cpp_source_path, compile_command);
            } else {
                std::cerr << "[LSP] Warning: empty compile command, skipping compile_commands.json" << std::endl;
            }

            // Set up translator
            const auto& mapping = generator::CXIR::CXIR::lsp_position_mapper;
            translator = std::make_unique<PositionTranslator>(mapping, file_path, cpp_file);

            // Set up URI mapping
            std::string kairo_uri = "file://" + file_path;
            std::string cpp_uri = "file://" + cpp_file;
            kairo_to_cpp_uri[kairo_uri] = cpp_uri;

            std::cerr << "[LSP] Compilation succeeded. C++ file: " << cpp_file << std::endl;
            return true;

        } catch (const std::exception& e) {
            std::cerr << "[LSP] Compilation exception: " << e.what() << std::endl;
            return false;
        } catch (...) {
            std::cerr << "[LSP] Compilation failed with unknown exception" << std::endl;
            return false;
        }
    }

    void rewrite_did_open_for_cpp(json& request) {
        if (!translator) return;
        try {
            auto& td = request["params"]["textDocument"];
            std::string uri = td["uri"];
            std::string cpp_file = translator->get_cpp_file();
            std::string cpp_uri = "file://" + cpp_file;

            std::ifstream cpp_stream(cpp_file);
            if (!cpp_stream.good()) {
                std::cerr << "[LSP] Failed to read generated C++ file: " << cpp_file << std::endl;
                return;
            }

            std::string cpp_content((std::istreambuf_iterator<char>(cpp_stream)),
                                     std::istreambuf_iterator<char>());
            td["uri"] = cpp_uri;
            td["text"] = cpp_content;
            td["languageId"] = "cpp";

            std::cerr << "[LSP] Rewrote didOpen: " << uri << " -> " << cpp_uri << std::endl;
        } catch (const std::exception& e) {
            std::cerr << "[LSP] Failed to rewrite didOpen: " << e.what() << std::endl;
        }
    }

    static bool is_kairo_file(const std::string& uri) {
        return uri.ends_with(".hlx") || uri.ends_with(".kro");
    }

    static std::string uri_to_path(const std::string& uri) {
        if (uri.starts_with("file://")) return uri.substr(7);
        return uri;
    }

public:
    bool start() {
        // Cache dir is always relative to the kairo binary
        auto exe_dir = __CONTROLLER_FS_N::get_exe().parent_path().parent_path();
        auto cache_dir = exe_dir / "cache" / "cxx";
        
        // Ensure it exists
        std::error_code ec;
        std::filesystem::create_directories(cache_dir, ec);
        
        return clangd.start(cache_dir.string());
    }

    void set_translator(std::unique_ptr<PositionTranslator> t) {
        translator = std::move(t);
    }

    void run(int argc, char** argv) {
        std::cerr << "[LSP] Kairo LSP proxy started" << std::endl;

        while (true) {
            std::string request_str = read_from_client();
            if (request_str.empty()) {
                if (std::cin.eof()) {
                    std::cerr << "[LSP] Client disconnected (EOF)" << std::endl;
                    break;
                }
                continue;
            }

            try {
                json request = json::parse(request_str);
                std::string method = request.value("method", "");
                bool has_id = request.contains("id");

                std::cerr << "[LSP] <- " << method
                          << (has_id ? " (id=" + request["id"].dump() + ")" : " (notification)")
                          << std::endl;

                // ==== Handle replies from client to clangd's server-requests ====
                if (!has_id && method.empty()) {
                    // Shouldn't happen normally
                    continue;
                }

                if (has_id && method.empty()) {
                    // This is a REPLY from the client — could be responding to a
                    // server-initiated request from clangd (e.g. workDoneProgress/create)
                    std::string id_str = request["id"].dump();
                    if (pending_server_requests.count(id_str)) {
                        std::cerr << "[LSP] Forwarding client reply to clangd server-request id=" << id_str << std::endl;
                        pending_server_requests.erase(id_str);
                        send_to_clangd(request);
                        continue;
                    }
                    // Otherwise it's something unexpected — still forward it
                    send_to_clangd(request);
                    continue;
                }

                // ==== shutdown ====
                if (method == "shutdown") {
                    send_to_clangd(request);
                    json response = read_response_from_clangd();
                    if (!response.is_null()) {
                        send_to_client(response.dump());
                    } else {
                        json r = {{"jsonrpc","2.0"},{"id",request["id"]},{"result",nullptr}};
                        send_to_client(r.dump());
                    }
                    continue;
                }

                // ==== exit ====
                if (method == "exit") {
                    send_to_clangd(request);
                    break;
                }

                // ==== initialize ====
                if (method == "initialize") {
                    send_to_clangd(request);
                    json response = read_response_from_clangd();
                    if (!response.is_null()) send_to_client(response.dump());
                    continue;
                }

                // ==== initialized ====
                if (method == "initialized") {
                    send_to_clangd(request);
                    drain_clangd_notifications();
                    continue;
                }

                // ==== didOpen / didSave ====
                if (method == "textDocument/didOpen" || method == "textDocument/didSave") {
                    std::string uri = request["params"]["textDocument"]["uri"];

                    if (is_kairo_file(uri)) {
                        std::string file_path = uri_to_path(uri);
                        compile_kairo_file(file_path, argc, argv);

                        if (method == "textDocument/didOpen" && translator) {
                            rewrite_did_open_for_cpp(request);
                        } else if (method == "textDocument/didSave" && translator) {
                            std::string cpp_uri = "file://" + translator->get_cpp_file();

                            std::ifstream cpp_stream(translator->get_cpp_file());
                            if (cpp_stream.good()) {
                                std::string cpp_content(
                                    (std::istreambuf_iterator<char>(cpp_stream)),
                                     std::istreambuf_iterator<char>());

                                json close_notif = {
                                    {"jsonrpc","2.0"},
                                    {"method","textDocument/didClose"},
                                    {"params",{{"textDocument",{{"uri",cpp_uri}}}}}
                                };
                                send_to_clangd(close_notif);
                                drain_clangd_notifications();

                                json open_notif = {
                                    {"jsonrpc","2.0"},
                                    {"method","textDocument/didOpen"},
                                    {"params",{{"textDocument",{
                                        {"uri",cpp_uri},{"languageId","cpp"},
                                        {"version",1},{"text",cpp_content}
                                    }}}}
                                };
                                send_to_clangd(open_notif);
                                drain_clangd_notifications();
                                continue;
                            }
                        }
                    }

                    send_to_clangd(request);
                    drain_clangd_notifications();
                    continue;
                }

                // ==== didClose ====
                if (method == "textDocument/didClose") {
                    translate_request_positions(request);
                    send_to_clangd(request);
                    drain_clangd_notifications();
                    continue;
                }

                // ==== didChange ====
                // ==== didChange ====
                if (method == "textDocument/didChange") {
                    std::string uri = request["params"]["textDocument"]["uri"];
                    if (is_kairo_file(uri)) {
                        continue;
                    }
                    
                    translate_request_positions(request);
                    send_to_clangd(request);
                    drain_clangd_notifications();
                    continue;
                }

                // ==== Generic request/notification ====
                translate_request_positions(request);
                send_to_clangd(request);

                if (has_id) {
                    json response = read_response_from_clangd();
                    if (!response.is_null()) {
                        translate_response_positions(response);
                        send_to_client(response.dump());
                    }
                } else {
                    drain_clangd_notifications();
                }

            } catch (const std::exception& e) {
                std::cerr << "[LSP] Error: " << e.what() << std::endl;
                json err = {
                    {"jsonrpc","2.0"},{"id",nullptr},
                    {"error",{{"code",-32603},{"message",std::string("Internal error: ")+e.what()}}}
                };
                send_to_client(err.dump());
            }
        }

        std::cerr << "[LSP] Shutting down" << std::endl;
        clangd.shutdown();
    }
};

inline int start_lsp_server(int argc, char** argv) {
    kairo::lsp::LSPProxy proxy;
    std::cerr << "[LSP] Starting clangd..." << std::endl;

    if (!proxy.start()) {
        std::cerr << "[LSP] Failed to start clangd" << std::endl;
        return 1;
    }

    proxy.run(argc, argv);
    return 0;
}

} // namespace kairo::lsp

#endif // __KAIRO_LSP_HH__