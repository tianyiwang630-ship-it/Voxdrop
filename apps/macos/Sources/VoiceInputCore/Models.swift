import Foundation

public enum TriggerMode: String, Codable, Sendable { case hold, toggle }

public enum SessionState: Equatable, Sendable {
    case starting, ready, recording(TriggerMode), transcribing, delivering, cancelling
    case blocked(String), recovering(String)
}

public enum ClipboardStatus: String, Codable, Sendable, Hashable { case written, failed }
public enum PasteStatus: String, Codable, Sendable, Hashable { case attempted, skipped, failed }

public struct FocusSnapshot: Equatable, Sendable {
    public let pid: Int32
    public let windowToken: String?
    public let elementToken: String?
    public let isSecure: Bool
    public let isEditable: Bool
    public init(pid: Int32, windowToken: String?, elementToken: String?, isSecure: Bool = false, isEditable: Bool = true) {
        self.pid = pid; self.windowToken = windowToken; self.elementToken = elementToken
        self.isSecure = isSecure; self.isEditable = isEditable
    }

    /// Web browsers may recreate the focused accessibility element while a page
    /// rerenders. The application and window are the stable paste context; only
    /// fall back to element identity when neither snapshot exposes a window.
    public func sharesPasteContext(with other: FocusSnapshot) -> Bool {
        guard pid == other.pid else { return false }
        switch (windowToken, other.windowToken) {
        case let (.some(lhs), .some(rhs)): return lhs == rhs
        case (nil, nil): return elementToken == other.elementToken
        default: return false
        }
    }
}

public struct Session: Equatable, Sendable {
    public let id: UUID
    public let mode: TriggerMode
    public let startedAt: Date
    public let initialFocus: FocusSnapshot?
    public var focusChanged: Bool
    public var cancelled: Bool
    public let workerGeneration: Int
    public init(id: UUID = UUID(), mode: TriggerMode, startedAt: Date = Date(),
                initialFocus: FocusSnapshot?, workerGeneration: Int) {
        self.id = id; self.mode = mode; self.startedAt = startedAt
        self.initialFocus = initialFocus; self.focusChanged = false
        self.cancelled = false; self.workerGeneration = workerGeneration
    }
}

public struct TranscriptionRecord: Identifiable, Sendable, Hashable {
    public let id: String
    public let createdAt: Date
    public let text: String
    public let audioDurationMS: Int
    public let inferenceMS: Int?
    public let endToEndMS: Int?
    public let modelID: String
    public let hotwordsEnabled: Bool
    public let hotwordCount: Int
    public let clipboardStatus: ClipboardStatus
    public let pasteStatus: PasteStatus
    public let skipReason: String?
    public init(id: String, createdAt: Date, text: String, audioDurationMS: Int,
                inferenceMS: Int?, endToEndMS: Int?, modelID: String,
                hotwordsEnabled: Bool, hotwordCount: Int, clipboardStatus: ClipboardStatus,
                pasteStatus: PasteStatus, skipReason: String?) {
        self.id = id; self.createdAt = createdAt; self.text = text
        self.audioDurationMS = audioDurationMS; self.inferenceMS = inferenceMS
        self.endToEndMS = endToEndMS; self.modelID = modelID
        self.hotwordsEnabled = hotwordsEnabled; self.hotwordCount = hotwordCount
        self.clipboardStatus = clipboardStatus; self.pasteStatus = pasteStatus
        self.skipReason = skipReason
    }
}

public struct Hotword: Identifiable, Sendable {
    public let id: Int64
    public var text: String
    public var enabled: Bool
}

public struct SessionEngine: Sendable {
    public private(set) var state: SessionState = .starting
    public private(set) var session: Session?
    public init() {}
    public mutating func workerReady() { if session == nil { state = .ready } }
    public mutating func block(_ reason: String) { session = nil; state = .blocked(reason) }
    public mutating func recover(_ reason: String) { session = nil; state = .recovering(reason) }
    @discardableResult public mutating func start(_ mode: TriggerMode, focus: FocusSnapshot?, generation: Int) -> Bool {
        guard state == .ready else { return false }
        session = Session(mode: mode, initialFocus: focus, workerGeneration: generation)
        state = .recording(mode); return true
    }
    @discardableResult public mutating func stop(_ mode: TriggerMode) -> Bool {
        guard case .recording(let owner) = state, owner == mode else { return false }
        state = .transcribing; return true
    }
    public mutating func observeFocus(_ focus: FocusSnapshot?) {
        guard let initial = session?.initialFocus else { return }
        if focus?.sharesPasteContext(with: initial) != true { session?.focusChanged = true }
    }
    public mutating func cancel() {
        guard session != nil else { return }
        session?.cancelled = true; state = .cancelling
    }
    public mutating func beginDelivery(requestID: UUID, generation: Int) -> Bool {
        guard var current = session, current.id == requestID,
              current.workerGeneration == generation, !current.cancelled,
              state == .transcribing else { return false }
        state = .delivering; current.cancelled = false; session = current; return true
    }
    public mutating func finish() { session = nil; state = .ready }
}
