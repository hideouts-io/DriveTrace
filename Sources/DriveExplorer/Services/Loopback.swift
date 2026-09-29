import Foundation
import Network
import DriveCore

/// A one-use OAuth callback listener bound only to IPv4 loopback.
actor Loopback {
    private var listener: NWListener?
    private var ready: CheckedContinuation<String, Error>?
    private var callback: CheckedContinuation<String, Error>?
    private var received: Result<String, Error>?
    private let state: String
    private var timeout: Task<Void, Never>?
    init(state: String) { self.state = state }
    func start() async throws -> String {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters); self.listener = listener
        listener.stateUpdateHandler = { status in Task { await self.changed(status) } }
        listener.newConnectionHandler = { connection in Task { await self.accept(connection) } }
        timeout = Task { do { try await Task.sleep(for: .seconds(180)); self.finish(.failure(MonitorError.authentication("Sign-in timed out. Connect again to retry."))) } catch is CancellationError {} catch { self.finish(.failure(error)) } }
        return try await withCheckedThrowingContinuation { continuation in ready = continuation; listener.start(queue: .global(qos: .userInitiated)) }
    }
    private func changed(_ status: NWListener.State) {
        switch status {
        case .ready:
            guard let port = listener?.port else { finish(.failure(MonitorError.authentication("OAuth listener has no port."))); return }
            ready?.resume(returning: "http://127.0.0.1:\(port.rawValue)/oauth/callback"); ready = nil
        case .failed(let error): finish(.failure(error))
        default: break
        }
    }
    func code() async throws -> String {
        if let received { return try received.get() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { callback = $0 }
        } onCancel: { Task { await self.cancel() } }
    }
    func cancel() { finish(.failure(CancellationError())) }
    private func accept(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        receive(connection, bytes: Data())
    }
    private func receive(_ connection: NWConnection, bytes: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, complete, error in
            Task { await self.consume(connection, bytes: bytes + (data ?? Data()), complete: complete, error: error) }
        }
    }
    private func consume(_ connection: NWConnection, bytes: Data, complete: Bool, error: NWError?) {
        if let error { connection.cancel(); finish(.failure(error)); return }
        guard bytes.count <= 16384 else { connection.cancel(); return }
        guard let request = String(data: bytes, encoding: .utf8), request.contains("\r\n\r\n") else {
            if complete { connection.cancel() } else { receive(connection, bytes: bytes) }; return
        }
        let parts = request.components(separatedBy: "\r\n")[0].split(separator: " ")
        guard parts.count == 3, parts[0] == "GET", let url = URLComponents(string: "http://127.0.0.1\(parts[1])"), url.path == "/oauth/callback" else { respond(connection, text: "Not found", status: "404 Not Found"); return }
        let states = url.queryItems?.filter { $0.name == "state" } ?? []
        guard states.count == 1, states[0].value == state else { respond(connection, text: "State mismatch. Return to the app and retry.", status: "400 Bad Request"); return }
        if let error = url.queryItems?.first(where: { $0.name == "error" })?.value {
            respond(connection, text: "Sign-in was declined. You may close this page.", status: "200 OK")
            finish(.failure(MonitorError.authentication("Google sign-in declined: \(error). \(oauthRemedy(error))"))); return
        }
        let codes = url.queryItems?.filter { $0.name == "code" } ?? []
        guard codes.count == 1, let code = codes[0].value, !code.isEmpty else { respond(connection, text: "Missing authorization code.", status: "400 Bad Request"); return }
        respond(connection, text: "Authorization received. Return to Drive Explorer to complete sign-in.", status: "200 OK")
        finish(.success(code))
    }
    private func respond(_ connection: NWConnection, text: String, status: String) {
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nContent-Length: \(text.utf8.count)\r\nConnection: close\r\n\r\n\(text)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
    private func finish(_ result: Result<String, Error>) {
        guard received == nil else { return }
        received = result; timeout?.cancel(); timeout = nil
        callback?.resume(with: result); callback = nil
        if case .failure(let error) = result { ready?.resume(throwing: error); ready = nil }
        listener?.cancel(); listener = nil
    }
}
