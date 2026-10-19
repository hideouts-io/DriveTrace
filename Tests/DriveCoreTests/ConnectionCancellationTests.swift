import Foundation
import Network
import Testing
@testable import DriveCore
@testable import DriveTrace

/// Real localhost callbacks only; these tests never restore or configure account credentials.
@Suite struct ConnectionCancellationTests {
    @Test func preCancelledListenerStartDoesNotLeaveReadinessWaiting() async throws {
        let loopback = Loopback(state: "pre-cancelled-state")
        let completion = CallbackCompletion()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do { await completion.finish(.success(try await loopback.start())) }
            catch { await completion.finish(.failure(error)) }
        }
        do {
            let result = try await waitForCallbackCompletion(completion)
            #expect(throws: CancellationError.self) { try result.get() }
        } catch {
            try await closeFailedCallbackTest(task, completion: completion, loopback: loopback, cause: error)
        }
        await task.value
        await loopback.cancel()
    }

    @Test func cancelledListenerCannotStartAgain() async throws {
        let loopback = Loopback(state: "already-cancelled-state")
        await loopback.cancel()
        let completion = CallbackCompletion()
        let task = Task {
            do { await completion.finish(.success(try await loopback.start())) }
            catch { await completion.finish(.failure(error)) }
        }
        do {
            let result = try await waitForCallbackCompletion(completion)
            #expect(throws: CancellationError.self) { try result.get() }
            await #expect(throws: CancellationError.self) { try await loopback.code() }
        } catch {
            try await closeFailedCallbackTest(task, completion: completion, loopback: loopback, cause: error)
        }
        await task.value
    }

    @Test func cancellingCallbackTaskFinishesTheActiveListener() async throws {
        let loopback = Loopback(state: "task-cancel-state")
        let redirect = try await loopback.start()
        let session = localCallbackSession()
        let completion = CallbackCompletion()
        let task = Task {
            do { await completion.finish(.success(try await loopback.code())) }
            catch { await completion.finish(.failure(error)) }
        }
        do {
            let (_, response) = try await session.data(for: callbackRequest(redirect, state: "wrong-state", error: "access_denied"))
            #expect((response as? HTTPURLResponse)?.statusCode == 400)
            #expect(await completion.result() == nil)
            task.cancel()
            let result = try await waitForCallbackCompletion(completion)
            #expect(throws: CancellationError.self) { try result.get() }
            await #expect(throws: CancellationError.self) { try await loopback.code() }
        } catch {
            session.invalidateAndCancel()
            try await closeFailedCallbackTest(task, completion: completion, loopback: loopback, cause: error)
        }
        await task.value
        session.finishTasksAndInvalidate()
        await loopback.cancel()
    }

    @Test func preCancelledCallbackTaskClosesTheActiveListener() async throws {
        let loopback = Loopback(state: "pre-cancelled-callback-state")
        _ = try await loopback.start()
        let completion = CallbackCompletion()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do { await completion.finish(.success(try await loopback.code())) }
            catch { await completion.finish(.failure(error)) }
        }
        do {
            let result = try await waitForCallbackCompletion(completion)
            #expect(throws: CancellationError.self) { try result.get() }
            await #expect(throws: CancellationError.self) { try await loopback.code() }
        } catch {
            try await closeFailedCallbackTest(task, completion: completion, loopback: loopback, cause: error)
        }
        await task.value
        await loopback.cancel()
    }

    @Test func consentRejectionRequiresMatchingStateAndReturnsRecoveryGuidance() async throws {
        let loopback = Loopback(state: "declined-state")
        let redirect = try await loopback.start()
        let session = localCallbackSession()
        let completion = CallbackCompletion()
        let task = Task {
            do { await completion.finish(.success(try await loopback.code())) }
            catch { await completion.finish(.failure(error)) }
        }
        do {
            let (wrongBody, wrongResponse) = try await session.data(for: callbackRequest(redirect, state: "wrong-state", error: "access_denied"))
            #expect((wrongResponse as? HTTPURLResponse)?.statusCode == 400)
            #expect(String(decoding: wrongBody, as: UTF8.self).contains("State mismatch"))
            #expect(await completion.result() == nil)
            let (body, response) = try await session.data(for: callbackRequest(redirect, state: "declined-state", error: "access_denied"))
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
            #expect(String(decoding: body, as: UTF8.self).contains("Sign-in was declined"))
            let result = try await waitForCallbackCompletion(completion)
            switch result {
            case .success: Issue.record("A rejected consent callback unexpectedly returned an authorization code.")
            case .failure(let error):
                let failure = try #require(error as? MonitorError)
                #expect(failure.localizedDescription.contains("access_denied"))
                #expect(failure.localizedDescription.contains("Audience"))
                #expect(failure.localizedDescription.contains("Test users"))
                #expect(failure.localizedDescription.contains("Workspace administrator"))
            }
        } catch {
            session.invalidateAndCancel()
            try await closeFailedCallbackTest(task, completion: completion, loopback: loopback, cause: error)
        }
        await task.value
        session.finishTasksAndInvalidate()
        await loopback.cancel()
    }

    @Test func repeatedListenerStartLeavesTheFirstAttemptUsable() async throws {
        let loopback = Loopback(state: "one-use-state")
        let redirect = try await loopback.start()
        let session = localCallbackSession()
        let completion = CallbackCompletion()
        let task = Task {
            do { await completion.finish(.success(try await loopback.code())) }
            catch { await completion.finish(.failure(error)) }
        }
        do {
            await #expect(throws: MonitorError.self) { try await loopback.start() }
            var components = try #require(URLComponents(string: redirect))
            components.queryItems = [URLQueryItem(name: "state", value: "one-use-state"), URLQueryItem(name: "code", value: "synthetic-authorization-code")]
            let request = URLRequest(url: try #require(components.url), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
            let (body, response) = try await session.data(for: request)
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
            #expect(String(decoding: body, as: UTF8.self).contains("Authorization received"))
            let result = try await waitForCallbackCompletion(completion)
            #expect(try result.get() == "synthetic-authorization-code")
        } catch {
            session.invalidateAndCancel()
            try await closeFailedCallbackTest(task, completion: completion, loopback: loopback, cause: error)
        }
        await task.value
        session.finishTasksAndInvalidate()
        await loopback.cancel()
    }

    @Test func listenerCancellationClosesAnIncompleteLocalRequest() async throws {
        let loopback = Loopback(state: "incomplete-request-state")
        let redirect = try await loopback.start()
        let components = try #require(URLComponents(string: redirect))
        let portValue = try #require(components.port)
        let port = try #require(NWEndpoint.Port(rawValue: UInt16(portValue)))
        let connection = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        let events = LocalCallbackEvents()
        connection.stateUpdateHandler = { state in Task { await events.change(state) } }
        connection.start(queue: .global(qos: .userInitiated))
        do {
            try await waitForLocalCallbackReady(events)
            let bytes = Data("GET /oauth/callback?state=incomplete-request-state HTTP/1.1\r\nHost: 127.0.0.1\r\n".utf8)
            connection.send(content: bytes, completion: .contentProcessed { error in Task { await events.sent(error) } })
            try await waitForLocalCallbackSend(events)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1_024) { _, _, complete, error in
                Task { await events.received(complete: complete, error: error) }
            }
            await loopback.cancel()
            try await waitForLocalCallbackClose(events)
            await #expect(throws: CancellationError.self) { try await loopback.code() }
        } catch {
            connection.cancel(); await loopback.cancel()
            let cause = error
            do { try await waitForLocalCallbackStop(events) }
            catch { throw MonitorError.invalid("The incomplete local request test failed: \(cause.localizedDescription). Task-owned connection cleanup also failed: \(error.localizedDescription)") }
            throw cause
        }
        connection.cancel()
        try await waitForLocalCallbackStop(events)
    }

    @Test @MainActor func immediateConnectCancellationPreservesAvailableWorkspaceState() async throws {
        let model = AppModel()
        let file = DriveFile(id: "previous-selected-file", name: "Previous selection.txt", mimeType: "text/plain")
        model.hasClient = true; model.connected = true; model.managementGranted = true
        model.syncVerified = true; model.rootID = "previous-account-root"
        model.files = [file]; model.selectedFiles = [file.id]; model.lastSync = "2026-10-10T00:00:00Z"
        model.requestedAccess = .management
        #expect(!(await model.credentials.hasConfiguration()))
        #expect(await model.credentials.grantedScopes().isEmpty)
        model.connect()
        #expect(model.busy)
        // Both calls run on MainActor before the operation gets its first actor turn.
        model.cancel()
        do { try await waitForConnectionOperation(model) }
        catch {
            let cause = error; model.cancel()
            do { try await waitForConnectionOperation(model) }
            catch { throw MonitorError.invalid("The immediate connection cancellation test failed: \(cause.localizedDescription). Task-owned operation cleanup also failed: \(error.localizedDescription)") }
            throw cause
        }
        #expect(!model.busy)
        #expect(model.progress.isEmpty)
        #expect(model.error == nil)
        #expect(model.operationNotice?.contains("Sign-in cancelled") == true)
        #expect(model.operationNotice?.contains("Sign in with Google") == true)
        #expect(model.operationNotice?.contains("synchronize") == true)
        #expect(model.hasClient && model.connected && model.managementGranted && model.syncVerified)
        #expect(model.rootID == "previous-account-root")
        #expect(model.files.map(\.id) == [file.id])
        #expect(model.selectedFiles == [file.id])
        #expect(model.lastSync == "2026-10-10T00:00:00Z")
        #expect(!(await model.credentials.hasConfiguration()))
        #expect(await model.credentials.grantedScopes().isEmpty)
    }
}

private actor CallbackCompletion {
    private var value: Result<String, Error>?
    func finish(_ result: Result<String, Error>) { value = result }
    func result() -> Result<String, Error>? { value }
}

private func waitForCallbackCompletion(_ completion: CallbackCompletion) async throws -> Result<String, Error> {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while true {
        if let result = await completion.result() { return result }
        guard ContinuousClock.now < deadline else { throw MonitorError.invalid("The local OAuth callback did not finish before the test deadline.") }
        await Task.yield()
    }
}

private func closeFailedCallbackTest(_ task: Task<Void, Never>, completion: CallbackCompletion, loopback: Loopback, cause: Error) async throws -> Never {
    task.cancel(); await loopback.cancel()
    do {
        _ = try await waitForCallbackCompletion(completion)
        await task.value
    } catch { throw MonitorError.invalid("The local OAuth callback test failed: \(cause.localizedDescription). Task-owned callback cleanup also failed: \(error.localizedDescription)") }
    throw cause
}

private func localCallbackSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 5
    configuration.timeoutIntervalForResource = 5
    return URLSession(configuration: configuration)
}

private func callbackRequest(_ redirect: String, state: String, error: String) throws -> URLRequest {
    var components = try #require(URLComponents(string: redirect))
    #expect(components.scheme == "http" && components.host == "127.0.0.1")
    components.queryItems = [URLQueryItem(name: "state", value: state), URLQueryItem(name: "error", value: error)]
    let url = try #require(components.url)
    return URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
}

@MainActor private func waitForConnectionOperation(_ model: AppModel) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while model.busy {
        guard ContinuousClock.now < deadline else { throw MonitorError.invalid("The cancelled connection operation did not finish before the test deadline.") }
        await Task.yield()
    }
}

/// Observes a real Network.framework connection without exposing listener internals.
private actor LocalCallbackEvents {
    private var ready = false
    private var sendCompleted = false
    private var remoteClosed = false
    private var locallyStopped = false
    private var failure: NWError?
    func change(_ state: NWConnection.State) {
        switch state {
        case .ready: ready = true
        case .failed(let error): failure = error
        case .cancelled: locallyStopped = true
        default: break
        }
    }
    func sent(_ error: NWError?) { if let error { failure = error }; sendCompleted = true }
    func received(complete: Bool, error: NWError?) {
        if let error {
            if error == .posix(.ECONNRESET) { remoteClosed = true }
            else { failure = error }
        }
        if complete { remoteClosed = true }
    }
    func connected() throws -> Bool { if let failure { throw failure }; return ready }
    func finishedSending() throws -> Bool { if let failure { throw failure }; return sendCompleted }
    func closed() throws -> Bool { if let failure { throw failure }; return remoteClosed }
    func stopped() -> Bool { locallyStopped }
}

private func waitForLocalCallbackReady(_ events: LocalCallbackEvents) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !(try await events.connected()) {
        guard ContinuousClock.now < deadline else { throw MonitorError.invalid("The task-owned local callback connection did not become ready before the test deadline.") }
        await Task.yield()
    }
}

private func waitForLocalCallbackSend(_ events: LocalCallbackEvents) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !(try await events.finishedSending()) {
        guard ContinuousClock.now < deadline else { throw MonitorError.invalid("The incomplete local callback request did not send before the test deadline.") }
        await Task.yield()
    }
}

private func waitForLocalCallbackClose(_ events: LocalCallbackEvents) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !(try await events.closed()) {
        guard ContinuousClock.now < deadline else { throw MonitorError.invalid("Cancelling OAuth did not close the incomplete local callback connection before the test deadline.") }
        await Task.yield()
    }
}

private func waitForLocalCallbackStop(_ events: LocalCallbackEvents) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !(await events.stopped()) {
        guard ContinuousClock.now < deadline else { throw MonitorError.invalid("The task-owned local callback connection did not stop before the cleanup deadline.") }
        await Task.yield()
    }
}
