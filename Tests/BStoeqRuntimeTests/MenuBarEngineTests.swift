import XCTest
@testable import BStoeqRuntime

@MainActor private final class FakeBackend: MenuBarBackend {
    final class Token: NSObject { let id: Int; init(_ id: Int) { self.id = id } }
    var available = true
    var returnsNil = false
    var synchronous = false
    var requests: [Set<String>] = []
    var completions: [(String?) -> Void] = []
    var invalidations: [Int: Int] = [:]
    func activate(allowed: Set<String>, completion: @escaping (String?) -> Void) -> AnyObject? {
        requests.append(allowed); completions.append(completion)
        if synchronous { completion(nil) }
        return returnsNil ? nil : Token(requests.count - 1)
    }
    func invalidate(_ token: AnyObject) {
        let id = (token as! Token).id; invalidations[id, default: 0] += 1
    }
}

@MainActor final class MenuBarEngineTests: XCTestCase {
    private func flush() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
    func testClearingAPendingRequestReleasesTheBackendBeforeItsCallbackArrives() {
        weak var releasedBackend: FakeBackend?
        do {
            let backend = FakeBackend()
            releasedBackend = backend
            let engine = MenuBarEngine(backend: backend)
            engine.apply(allowed: ["org.example.Menu"])
            engine.clear()
            XCTAssertEqual(backend.invalidations[0], 1)
        }
        XCTAssertNil(releasedBackend)
    }

    func testReturningToActivePlanCancelsPendingPlan() async {
        let backend = FakeBackend(); let engine = MenuBarEngine(backend: backend)
        engine.apply(allowed: ["A"]); backend.completions[0](nil); await flush()
        engine.apply(allowed: ["B"])
        engine.apply(allowed: ["A"])
        backend.completions[1](nil); await flush()
        XCTAssertNil(backend.invalidations[0], "A must remain active")
        XCTAssertEqual(backend.invalidations[1], 1, "B must be invalidated exactly once")
        XCTAssertEqual(backend.requests.count, 2)
        engine.clear()
        XCTAssertEqual(backend.invalidations[0], 1)
    }
    func testSamePendingPlanDoesNotRestartActivation() async {
        let backend = FakeBackend(); let engine = MenuBarEngine(backend: backend)
        engine.apply(allowed: ["A"]); engine.apply(allowed: ["A"])
        XCTAssertEqual(backend.requests.count, 1)
        backend.completions[0](nil); await flush(); engine.clear()
    }
    func testOldErrorDoesNotClearNewerSuccessfulPlan() async {
        let backend = FakeBackend(); let engine = MenuBarEngine(backend: backend)
        var failure: EngineFailure?
        engine.onError = { failure = $0 }
        engine.apply(allowed: ["A"]); engine.apply(allowed: ["B"])
        backend.completions[1](nil); await flush()
        backend.completions[0]("late error"); await flush()
        XCTAssertNil(failure); XCTAssertNil(backend.invalidations[1])
        XCTAssertEqual(backend.invalidations[0], 1); engine.clear()
    }
    func testEmergencyClearPreventsLateReactivation() async {
        let backend = FakeBackend(); let engine = MenuBarEngine(backend: backend)
        var successes = 0; engine.onApplied = { successes += 1 }
        engine.apply(allowed: ["A"]); engine.clear()
        backend.completions[0](nil); await flush()
        XCTAssertEqual(successes, 0); XCTAssertEqual(backend.invalidations[0], 1)
    }
    func testFailureReleasesActiveAndPendingAssertions() async {
        let backend = FakeBackend(); let engine = MenuBarEngine(backend: backend)
        var failure: EngineFailure?; engine.onError = { failure = $0 }
        engine.apply(allowed: ["A"]); backend.completions[0](nil); await flush()
        engine.apply(allowed: ["B"]); backend.completions[1]("denied"); await flush()
        XCTAssertEqual(failure, .activation("denied"))
        XCTAssertEqual(backend.invalidations, [0: 1, 1: 1])
    }
    func testSynchronousCompletionAndDuplicateCompletionAreSafe() async {
        let backend = FakeBackend(); backend.synchronous = true
        let engine = MenuBarEngine(backend: backend)
        var successes = 0; engine.onApplied = { successes += 1 }
        engine.apply(allowed: ["A"]); await flush()
        backend.completions[0](nil); await flush()
        XCTAssertEqual(successes, 1); XCTAssertTrue(backend.invalidations.isEmpty)
        engine.clear(); XCTAssertEqual(backend.invalidations[0], 1)
    }
    func testCreationFailureIsReported() {
        let backend = FakeBackend(); backend.returnsNil = true
        let engine = MenuBarEngine(backend: backend)
        var failure: EngineFailure?; engine.onError = { failure = $0 }
        engine.apply(allowed: ["A"])
        XCTAssertEqual(failure, .creationFailed)
    }
    func testUnavailableBackendDoesNotActivate() {
        let backend = FakeBackend(); backend.available = false
        let engine = MenuBarEngine(backend: backend)
        var failure: EngineFailure?; engine.onError = { failure = $0 }
        engine.apply(allowed: ["A"])
        XCTAssertEqual(failure, .unavailable); XCTAssertTrue(backend.requests.isEmpty)
    }
    func testTimeoutReleasesPendingAssertionAndIgnoresLateReply() async throws {
        let backend = FakeBackend(); let engine = MenuBarEngine(backend: backend, timeoutInterval: 0.01)
        var failure: EngineFailure?; engine.onError = { failure = $0 }
        engine.apply(allowed: ["A"])
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(failure, .timedOut); XCTAssertEqual(backend.invalidations[0], 1)
        backend.completions[0](nil); await flush()
        XCTAssertEqual(failure, .timedOut); XCTAssertEqual(backend.invalidations[0], 1)
    }
}
