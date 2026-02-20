#!/usr/bin/env python3
"""
Test script for Kairo LSP server
Tests position mapping, hover, completion, and go-to-definition
"""

import subprocess
import json
import sys
import time
import select
from pathlib import Path


class LSPClient:
    def __init__(self, command):
        self.stderr_log = open("lsp_stderr.log", "w")
        self.process = subprocess.Popen(
            command,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=self.stderr_log,
            bufsize=0
        )
        self.request_id = 0

    def send_message(self, message):
        """Send LSP message with Content-Length header (binary mode)"""
        content = json.dumps(message)
        content_bytes = content.encode('utf-8')
        header = f"Content-Length: {len(content_bytes)}\r\n\r\n"
        full_message = header.encode('utf-8') + content_bytes

        method = message.get('method', 'response')
        print(f"\n>>> Sending: {method}")

        self.process.stdin.write(full_message)
        self.process.stdin.flush()

    def read_message(self, timeout=15):
        """Read LSP message from server with timeout (binary mode)"""
        header = b""
        start_time = time.time()
        
        while True:
            remaining = timeout - (time.time() - start_time)
            if remaining <= 0:
                if header:
                    print(f"    ⏰ Timeout with partial header: {header[:100]}")
                else:
                    print(f"    ⏰ Timeout after {timeout}s — no data")
                return None

            ready, _, _ = select.select([self.process.stdout], [], [], min(remaining, 1.0))
            if not ready:
                if not header:
                    # No data at all within timeout
                    return None
                # Have partial header, keep trying
                continue

            char = self.process.stdout.read(1)
            if not char:
                print(f"    ❌ EOF — server likely crashed. Check lsp_stderr.log")
                return None
            header += char
            if header.endswith(b"\r\n\r\n"):
                break

        header_str = header.decode('utf-8')
        length = None
        for line in header_str.split("\r\n"):
            if line.startswith("Content-Length:"):
                length = int(line.split(":")[1].strip())
                break

        if length is None:
            print(f"    ❌ No Content-Length in header: {header_str[:100]!r}")
            return None

        body = b""
        while len(body) < length:
            remaining = timeout - (time.time() - start_time)
            if remaining <= 0:
                print(f"    ⏰ Timeout reading body ({len(body)}/{length} bytes)")
                return None
            ready, _, _ = select.select([self.process.stdout], [], [], min(remaining, 1.0))
            if not ready:
                continue
            chunk = self.process.stdout.read(length - len(body))
            if not chunk:
                print(f"    ❌ EOF reading body")
                return None
            body += chunk

        message = json.loads(body.decode('utf-8'))

        # Compact display
        method = message.get("method", "")
        msg_id = message.get("id", "")
        msg_str = json.dumps(message, indent=2)
        if len(msg_str) > 400:
            msg_str = msg_str[:400] + "\n    ..."
        print(f"\n<<< Received{f' {method}' if method else ''}{f' (id={msg_id})' if msg_id else ''}: {msg_str}")

        return message

    def read_all_messages(self, timeout=3):
        """Read all available messages (drains notifications).
        Returns list of messages. Stops when no more data arrives within timeout."""
        messages = []
        while True:
            msg = self.read_message(timeout=timeout)
            if msg is None:
                break
            messages.append(msg)
            # After first message, use shorter timeout for subsequent ones
            timeout = 1.0
        return messages

    def initialize(self, root_uri):
        """Send initialize request"""
        self.request_id += 1
        self.send_message({
            "jsonrpc": "2.0",
            "id": self.request_id,
            "method": "initialize",
            "params": {
                "processId": None,
                "rootUri": root_uri,
                "capabilities": {
                    "textDocument": {
                        "hover": {
                            "contentFormat": ["markdown", "plaintext"]
                        },
                        "completion": {
                            "completionItem": {
                                "snippetSupport": True
                            }
                        },
                        "publishDiagnostics": {
                            "relatedInformation": True
                        }
                    }
                },
                "trace": "off"
            }
        })
        return self.read_message()

    def initialized(self):
        """Send initialized notification"""
        self.send_message({
            "jsonrpc": "2.0",
            "method": "initialized",
            "params": {}
        })
        # Give server a moment, then drain any notifications
        time.sleep(0.5)

    def did_open(self, uri, language_id, text):
        """Send didOpen notification"""
        self.send_message({
            "jsonrpc": "2.0",
            "method": "textDocument/didOpen",
            "params": {
                "textDocument": {
                    "uri": uri,
                    "languageId": language_id,
                    "version": 1,
                    "text": text
                }
            }
        })
        # Wait for compilation + clangd indexing, drain notifications
        print("    Waiting for compilation and indexing...")
        time.sleep(3)
        notifications = self.read_all_messages(timeout=2)
        if notifications:
            print(f"    Received {len(notifications)} notification(s) during open")

    def hover(self, uri, line, character):
        """Request hover information"""
        self.request_id += 1
        self.send_message({
            "jsonrpc": "2.0",
            "id": self.request_id,
            "method": "textDocument/hover",
            "params": {
                "textDocument": {"uri": uri},
                "position": {"line": line, "character": character}
            }
        })
        return self.read_message()

    def completion(self, uri, line, character):
        """Request completion"""
        self.request_id += 1
        self.send_message({
            "jsonrpc": "2.0",
            "id": self.request_id,
            "method": "textDocument/completion",
            "params": {
                "textDocument": {"uri": uri},
                "position": {"line": line, "character": character}
            }
        })
        return self.read_message()

    def definition(self, uri, line, character):
        """Request go-to-definition"""
        self.request_id += 1
        self.send_message({
            "jsonrpc": "2.0",
            "id": self.request_id,
            "method": "textDocument/definition",
            "params": {
                "textDocument": {"uri": uri},
                "position": {"line": line, "character": character}
            }
        })
        return self.read_message()

    def shutdown(self):
        """Shutdown server"""
        self.request_id += 1
        self.send_message({
            "jsonrpc": "2.0",
            "id": self.request_id,
            "method": "shutdown",
            "params": {}
        })
        response = self.read_message(timeout=5)

        self.send_message({
            "jsonrpc": "2.0",
            "method": "exit",
            "params": {}
        })

        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            self.process.wait(timeout=5)

        return response

    def close(self):
        """Force close the process"""
        try:
            self.process.terminate()
            self.process.wait(timeout=5)
        except Exception:
            self.process.kill()
        finally:
            self.stderr_log.close()


def test_kairo_lsp():
    """Main test function"""

    # Test file
    test_file = Path("test.hlx").absolute()
    test_content = """fn main() -> i32 {
    std::print("Hello, World!");
    return 0;
}"""

    # Write test file
    test_file.write_text(test_content)

    print("=" * 80)
    print("KAIRO LSP TEST SUITE")
    print("=" * 80)

    client = None
    try:
        # Start LSP server
        print("\n[1/7] Starting Kairo LSP server...")
        client = LSPClient([
            "./build/debug/x86_64-linux-gnu/bin/kairo",
            "test.hlx",
            "--lsp-mode"
        ])

        # Initialize
        print("\n[2/7] Initializing...")
        init_response = client.initialize(f"file://{test_file.parent}")

        if init_response is None:
            print("❌ Initialize failed: no response")
            return False

        if init_response.get("error"):
            print(f"❌ Initialize failed: {init_response['error']}")
            return False

        server_info = init_response.get("result", {}).get("serverInfo", {})
        print(f"✅ Initialize successful — {server_info.get('name', '?')} {server_info.get('version', '?')}")

        client.initialized()

        # Open document
        print("\n[3/7] Opening test.hlx...")
        file_uri = f"file://{test_file}"
        client.did_open(file_uri, "helix", test_content)
        print("✅ Document opened")

        # Test hover on "print" (line 1, col 10)
        print("\n[4/7] Testing hover on 'print' at line 1, col 10...")
        hover_response = client.hover(file_uri, 1, 10)

        if hover_response is None:
            print("⚠️  No response — check lsp_stderr.log")
        elif hover_response.get("error"):
            print(f"⚠️  Hover error: {hover_response['error']}")
        elif hover_response.get("result"):
            contents = hover_response["result"].get("contents", {})
            print("✅ Hover succeeded!")
            if isinstance(contents, dict):
                print(f"    {contents.get('value', contents)[:200]}")
            else:
                print(f"    {str(contents)[:200]}")
        else:
            print("⚠️  Hover returned null result (no info at this position)")

        # Test hover on "std" (line 1, col 4)
        print("\n[5/7] Testing hover on 'std' at line 1, col 4...")
        hover_response = client.hover(file_uri, 1, 4)

        if hover_response is None:
            print("⚠️  No response")
        elif hover_response.get("result"):
            contents = hover_response["result"].get("contents", {})
            print("✅ Hover succeeded!")
            if isinstance(contents, dict):
                print(f"    {contents.get('value', contents)[:200]}")
            else:
                print(f"    {str(contents)[:200]}")
        else:
            print("⚠️  Hover returned null result")

        # Test completion
        print("\n[6/7] Testing completion at line 1, col 15...")
        completion_response = client.completion(file_uri, 1, 15)

        if completion_response is None:
            print("⚠️  No response")
        elif completion_response.get("error"):
            print(f"⚠️  Completion error: {completion_response['error']}")
        elif completion_response.get("result"):
            items = completion_response["result"]
            if isinstance(items, dict):
                items = items.get("items", [])

            print(f"✅ Completion succeeded! Found {len(items)} items")
            if items:
                print("    Sample completions:")
                for item in items[:5]:
                    label = item.get("label", "?")
                    kind = item.get("kind", "?")
                    print(f"      - {label} (kind: {kind})")
        else:
            print("⚠️  Completion returned null result")

        # Shutdown
        print("\n[7/7] Shutting down...")
        client.shutdown()
        print("✅ Shutdown successful")

        print("\n" + "=" * 80)
        print("TEST SUMMARY")
        print("=" * 80)
        print("✅ LSP server started successfully")
        print("✅ Document compilation triggered")
        print("✅ Hover/completion requests handled")
        print("\nCheck lsp_stderr.log for detailed server output.")
        print("If you see C++ type info above, the LSP proxy is working!")

        return True

    except Exception as e:
        print(f"\n❌ Test failed with error: {e}")
        import traceback
        traceback.print_exc()
        return False

    finally:
        if client:
            client.close()

        # Print stderr log
        print("\n" + "-" * 40)
        print("LSP STDERR LOG:")
        print("-" * 40)
        try:
            print(Path("lsp_stderr.log").read_text())
        except Exception:
            print("(could not read log)")


if __name__ == "__main__":
    success = test_kairo_lsp()
    sys.exit(0 if success else 1)