// mx serve: the background process behind the CLI. The same JSON-RPC as stdio, one message
// per line, on a Unix socket per agent session (CLI.swift starts it and picks the path).
// Calls from every connection go through the one `calls` queue and handle(), so refs,
// the session, the overlay and the gates behave exactly as under MCP.
import AppKit

/// Seconds with no call before the process cleans up and exits. MX_IDLE_SECONDS overrides (tests).
private let idleLimit = Double(ProcessInfo.processInfo.environment["MX_IDLE_SECONDS"] ?? "") ?? 1800

private let state = NSLock()
private var active = 0       // calls queued or running
private var lastCall = now()

func serve(_ path: String) {
    exposeRefusals = true
    signal(SIGPIPE, SIG_IGN)  // a client that left before its reply must not kill the process
    if AuditSession.client.isEmpty { AuditSession.client = "mx cli" }
    let listener: Int32
    do { listener = try listenUnix(path) } catch {
        FileHandle.standardError.write(Data("mx serve: \(error)\n".utf8)); exit(1)
    }
    FileHandle.standardError.write(Data("mx serve: pid \(getpid()) on \(path), accessibility \(AXIsProcessTrusted() ? "trusted" : "NOT trusted")\n".utf8))

    var stopping = false
    func stop() {
        state.lock(); let first = !stopping; stopping = true; state.unlock()
        guard first else { return }
        unlink(path)
        close(listener)
        shutdown()
    }

    // Idle exit: checked a few times per limit, never while a call is queued or running.
    let timer = DispatchSource.makeTimerSource(queue: .global())
    let tick = min(max(idleLimit / 4, 0.2), 30)
    timer.schedule(deadline: .now() + tick, repeating: tick)
    timer.setEventHandler {
        state.lock(); let idle = active == 0 && now() - lastCall >= idleLimit; state.unlock()
        if idle { timer.cancel(); FileHandle.standardError.write(Data("mx serve: idle, exiting\n".utf8)); stop() }
    }
    timer.resume()

    Thread {
        while true {
            let fd = accept(listener, nil, nil)
            if fd < 0 { if errno == EINTR { continue } else { return } }
            Thread { connection(fd, stop: stop) }.start()
        }
    }.start()
}

/// One client connection: read requests line by line, answer each on the same socket.
private func connection(_ fd: Int32, stop: @escaping () -> Void) {
    let writeLock = NSLock()
    func out(_ msg: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: msg, options: [.withoutEscapingSlashes]) else { return }
        data.append(0x0A)
        writeLock.lock(); defer { writeLock.unlock() }
        data.withUnsafeBytes { p in
            var off = 0
            while off < p.count {
                let n = write(fd, p.baseAddress! + off, p.count - off)
                if n <= 0 { if errno == EINTR { continue } else { return } }
                off += n
            }
        }
    }
    guard let file = fdopen(fd, "r") else { close(fd); return }
    var line: UnsafeMutablePointer<CChar>?
    var cap = 0
    while getline(&line, &cap, file) > 0 {
        let text = String(cString: line!).trimmingCharacters(in: .newlines)
        guard !text.isEmpty else { continue }
        guard let req = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            out(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "parse error"]])
            continue
        }
        if req["method"] as? String == "mx/stop" {
            out(["jsonrpc": "2.0", "id": req["id"] ?? NSNull(), "result": ["pid": Int(getpid())]])
            stop()
            continue
        }
        state.lock(); active += 1; state.unlock()
        calls.async {
            handle(req, out: out)
            state.lock(); active -= 1; lastCall = now(); state.unlock()
        }
    }
    free(line)
    // The reply may still be pending on the queue; it writes to this fd, so close after it.
    calls.async { fclose(file) }
}

/// Binds and listens on path, replacing a stale socket file nobody answers on.
private func listenUnix(_ path: String) throws -> Int32 {
    if let fd = connectUnix(path) { close(fd); throw MXError("another mx serve already answers on \(path)") }
    unlink(path)
    guard var addr = unixAddress(path) else { throw MXError("socket path too long: \(path)") }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw MXError("socket: \(String(cString: strerror(errno)))") }
    let ok = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard ok == 0, listen(fd, 16) == 0 else { close(fd); throw MXError("bind \(path): \(String(cString: strerror(errno)))") }
    chmod(path, 0o600)
    return fd
}

func unixAddress(_ path: String) -> sockaddr_un? {
    var addr = sockaddr_un()
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
    addr.sun_family = sa_family_t(AF_UNIX)
    addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &addr.sun_path) { p in
        p.copyBytes(from: bytes)
        p[bytes.count] = 0
    }
    return addr
}

/// A connected socket to path, or nil if nothing answers there.
func connectUnix(_ path: String) -> Int32? {
    guard var addr = unixAddress(path) else { return nil }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    let r = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    if r != 0 { close(fd); return nil }
    return fd
}
