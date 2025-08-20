
// similar to python subprocess
/// \brief this allows a user to start a new process, connect to its input/output/error pipes,
///        and obtain its return code. while also allowing the user to send input to the process
///        and capture its output.

eval if defined(_WIN32) || defined(WIN32) || defined(_WIN64) || defined(WIN64) {
    macro __NEO_WINDOWS__;
} else {
    macro __NEO_UNIX__;
}

ffi "c++" import "iostream";
ffi "c++" import "string";
ffi "c++" import "vector";

eval if defined(__NEO_WINDOWS__) {
    ffi "c++" import "windows.h";
} else {
    ffi "c++" import "sys/wait.h";
    ffi "c++" import "unistd.h";
}

module neo {
    inline module detail {
        struct process_handle {
            eval if defined(__NEO_WINDOWS__) {
                var hProcess: HANDLE;
                var hThread: HANDLE;
            } else {
                var pid: pid_t;
            }
        }

        struct pipe_handle {
            eval if defined(__NEO_WINDOWS__) {
                var hRead: HANDLE;
                var hWrite: HANDLE;
            } else {
                var fd: *int = salloc(sizeof(int) * 2);
            }
        }

        class process_info {
            var handle: process_handle?;
            var stdin:  pipe_handle?;
            var stdout: pipe_handle?;
            var stderr: pipe_handle?;

            inline fn create_pipe() -> pipe_handle {
                var pipe: pipe_handle;

                eval if defined(__NEO_WINDOWS__) {
                    var saAttr: SECURITY_ATTRIBUTES;
                    saAttr.nLength              = sizeof(SECURITY_ATTRIBUTES);
                    saAttr.bInheritHandle       = TRUE;
                    saAttr.lpSecurityDescriptor = &null;

                    if !CreatePipe(&pipe.hRead, &pipe.hWrite, &saAttr, 0) {
                        panic std::runtime_error("failed to create pipe");
                    }

                } else {
                    if pipe(pipe.fd) == -1 {
                        panic std::runtime_error("failed to create pipe");
                    }
                }

                return pipe;
            }
        }

        inline fn close_pipe(pipe: &pipe_handle) {
            eval if defined(__NEO_WINDOWS__) {
                CloseHandle(pipe.hRead);
                CloseHandle(pipe.hWrite);
            } else {
                close(pipe.fd[0]);
                close(pipe.fd[1]);
            }
        }

        inline fn create_process(const command: &std::string) -> process_handle {
            var handle: process_handle;

            eval if defined(__NEO_WINDOWS__) {
                var si: STARTUPINFO;
                var pi: PROCESS_INFORMATION;

                ZeroMemory(&si, sizeof(si));
                si.cb = sizeof(si);
                ZeroMemory(&pi, sizeof(pi));

                if !CreateProcess(&null, (command.c_str() as const *char), &null, &null,
                                   true, 0, &null, &null, &si, &pi) {
                    panic std::runtime_error("failed to create process");
                }

                handle.hProcess = pi.hProcess;
                handle.hThread  = pi.hThread;

            } else {
                var pid = fork();

                if pid == -1 {
                    panic std::runtime_error("failed to create process");
                }

                if pid == 0 {
                    execl("/bin/sh", "sh", "-c", command.c_str(), &null);
                    exit(127);
                }

                handle.pid = pid;
                
            }
            return handle;
        }

        inline fn close_process(handle: &process_handle) -> void {
            eval if defined(__NEO_WINDOWS__) {
                CloseHandle(handle.hProcess);
                CloseHandle(handle.hThread);
            } else {
                waitpid(handle.pid, &null, 0);
            }
        }

        inline fn write_to_pipe(pipe: &pipe_handle, const data: &std::string) -> void {
            eval if defined(__NEO_WINDOWS__) {
                var bytes_written: DWORD;
                WriteFile(pipe.hWrite, data.c_str(), data.size(), &bytes_written, &null);
            } else {
                write(pipe.fd[1], data.c_str(), data.size());
            }
        }

        inline fn read_from_pipe(pipe: &pipe_handle) -> std::string {
            var data: std::string;

            eval if defined(__NEO_WINDOWS__) {
                var bytes_read: DWORD;
                var buffer[4096]: CHAR;

                while (true) {
                    if (!ReadFile(pipe.hRead, buffer, sizeof(buffer), &bytes_read, &null) ||
                        bytes_read == 0) {
                        break;
                    }
                    
                    data.append(buffer, bytes_read);
                }

            } else {
                var buffer[4096]: char;
                var bytes_read: size_t;

                while (true) {
                    bytes_read = read(pipe.fd[0], buffer, sizeof(buffer));
                    
                    if (bytes_read <= 0) {
                        break;
                    }
                    
                    data.append(buffer, bytes_read);
                }
            }
            return data;
        }
    }  // module detail

    class process {
        
    }
}  // module neo::process
