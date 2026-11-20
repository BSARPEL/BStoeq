import Foundation
import MenuBarBridge

public enum EngineFailure: Equatable, Sendable {
    case unavailable, creationFailed, timedOut, activation(String)
}

@MainActor public protocol MenuBarBackend: AnyObject {
    var available: Bool { get }
    func activate(allowed: Set<String>, completion: @escaping (String?) -> Void) -> AnyObject?
    func invalidate(_ token: AnyObject)
}

@MainActor public final class NativeMenuBarBackend: MenuBarBackend {
    public init() {}
    public var available: Bool { STMenuBarShim.isAvailable() }
    public func activate(allowed: Set<String>, completion: @escaping (String?) -> Void) -> AnyObject? {
        STMenuBarShim.activate(withAllowedBundleIdentifiers: allowed.sorted(),
            allowedSystemItems: (0...255).map { NSNumber(value: $0) }) { error in
                completion(error?.localizedDescription)
            } as AnyObject?
    }
    public func invalidate(_ token: AnyObject) { STMenuBarShim.invalidate(token) }
}

@MainActor public final class MenuBarEngine {
    private let backend: MenuBarBackend
    private let timeoutInterval: TimeInterval
    public var available: Bool { backend.available }
    private var active: Lease?
    private var pending: Lease?
    private var generation = 0
    private var applied: Set<String>?
    private var requested: Set<String>?
    private var timeout: DispatchWorkItem?
    public var onError: ((EngineFailure?) -> Void)?
    public var onApplied: (() -> Void)?

    public init(backend: MenuBarBackend, timeoutInterval: TimeInterval = 4) {
        self.backend = backend; self.timeoutInterval = timeoutInterval
    }
    public convenience init() { self.init(backend: NativeMenuBarBackend()) }

    public func apply(allowed: Set<String>?) {
        guard let allowed else { clear(); onError?(nil); onApplied?(); return }
        guard available else { clear(); onError?(.unavailable); return }
        if requested == allowed, pending != nil { return }

        // Cancel a pending B before recognizing that A is already active. Otherwise
        // A → B → A returns early and a late B completion overrides the last request.
        generation += 1
        let request = generation
        timeout?.cancel(); timeout = nil
        pending?.invalidate(); pending = nil; requested = nil
        if applied == allowed, active != nil { onError?(nil); onApplied?(); return }

        let box = CompletionBox()
        let token = backend.activate(allowed: allowed) { [weak self] error in
            // Supports both synchronous and asynchronous backend completions.
            DispatchQueue.main.async {
                guard !box.completed else { return }
                box.completed = true
                guard let lease = box.lease else { return }
                guard let self, self.generation == request else { lease.invalidate(); return }
                self.timeout?.cancel(); self.timeout = nil
                if let error {
                    self.clear(); self.onError?(.activation(error))
                } else {
                    self.active?.invalidate()
                    self.active = lease; self.pending = nil
                    self.applied = allowed; self.requested = nil
                    self.onError?(nil); self.onApplied?()
                }
            }
        }
        guard let token else { clear(); onError?(.creationFailed); return }
        let lease = Lease(token: token, backend: backend)
        box.lease = lease; pending = lease; requested = allowed
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == request else { return }
            self.clear(); self.onError?(.timedOut)
        }
        timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + timeoutInterval, execute: work)
    }

    public func clear() {
        generation += 1
        timeout?.cancel(); timeout = nil
        pending?.invalidate(); pending = nil; requested = nil
        active?.invalidate(); active = nil; applied = nil
    }
}

@MainActor private final class Lease {
    let token: AnyObject
    let backend: MenuBarBackend
    private var invalidated = false
    init(token: AnyObject, backend: MenuBarBackend) { self.token = token; self.backend = backend }
    func invalidate() {
        guard !invalidated else { return }
        invalidated = true; backend.invalidate(token)
    }
}
@MainActor private final class CompletionBox {
    var lease: Lease?
    var completed = false
}
