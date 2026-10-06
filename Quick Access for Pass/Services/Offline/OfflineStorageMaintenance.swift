import Foundation
import GRDB

/// The outcome of a WAL checkpoint attempt. A busy checkpoint is retryable;
/// other SQL failures are intentionally surfaced to the lifecycle owner as a
/// non-fatal maintenance failure.
nonisolated enum OfflineCheckpointResult: Sendable, Equatable {
    case complete
    case busy
}

/// Metadata-only checkpoint boundary. It has no snapshot-key or plaintext dependency.
nonisolated protocol OfflineCheckpointing: Sendable {
    func checkpoint() async throws -> OfflineCheckpointResult
}

/// Interprets SQLite's complete three-column WAL checkpoint result.
nonisolated struct DatabaseWALCheckpointer: OfflineCheckpointing {
    enum Error: Swift.Error, Equatable, Sendable {
        case malformedResult
    }

    private let writer: any DatabaseWriter

    init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    func checkpoint() async throws -> OfflineCheckpointResult {
        try await writer.writeWithoutTransaction { db in
            let rows = try Row.fetchAll(db, sql: "PRAGMA wal_checkpoint(TRUNCATE)")
            guard rows.count == 1 else { throw Error.malformedResult }
            return try Self.interpret(
                busy: rows[0]["busy"],
                log: rows[0]["log"],
                checkpointed: rows[0]["checkpointed"]
            )
        }
    }

    /// Interprets all three SQLite WAL checkpoint columns without exposing a
    /// database row or any secret-bearing state to maintenance callers.
    nonisolated static func interpret(
        busy: Int?,
        log: Int?,
        checkpointed: Int?
    ) throws -> OfflineCheckpointResult {
        guard let busy, let log, let checkpointed, busy == 0 || busy == 1 else {
            throw Error.malformedResult
        }

        // SQLite reports -1/-1 when no WAL is available (for example an
        // in-memory connection). This is a benign no-op only when it is not
        // busy; malformed or unavailable rows never become fake completion.
        if busy == 0, log == -1, checkpointed == -1 {
            return .complete
        }
        guard log >= 0, checkpointed >= 0, checkpointed <= log else {
            throw Error.malformedResult
        }
        if busy == 0 {
            guard checkpointed == log else { throw Error.malformedResult }
            return .complete
        }
        return .busy
    }
}

/// Lifecycle-owned, bounded WAL-remnant maintenance. Checkpoint outcomes never
/// alter already committed logical deletion or metadata-sync outcomes.
actor OfflineStorageMaintenance {
    private let checkpointer: any OfflineCheckpointing
    private let retryDelay: @Sendable () async throws -> Void
    private var worker: Task<Void, Never>?
    private var workerID: UUID?
    private var stopped = false

    init(
        checkpointer: any OfflineCheckpointing,
        retryDelay: @escaping @Sendable () async throws -> Void = {
            try await Task.sleep(for: .milliseconds(250))
        }
    ) {
        self.checkpointer = checkpointer
        self.retryDelay = retryDelay
    }

    /// Registers a coalesced request and returns without waiting for retries.
    func requestCheckpoint() {
        guard !stopped, worker == nil else { return }
        startWorker()
    }

    /// Runs the same bounded coalesced batch during startup and waits for it.
    func checkpointAtStartup() async {
        guard !stopped else { return }
        if worker == nil { startWorker() }
        await worker?.value
    }

    /// Terminal lifecycle transition: cancel and await the one owned worker.
    func stop() async {
        guard !stopped else {
            if let worker { await worker.value }
            return
        }
        stopped = true
        workerID = nil
        let currentWorker = worker
        currentWorker?.cancel()
        await currentWorker?.value
        worker = nil
    }

    private func startWorker() {
        let id = UUID()
        workerID = id
        worker = Task { [weak self] in
            await self?.runBatch(id: id)
        }
    }

    private func runBatch(id: UUID) async {
        defer {
            if workerID == id {
                workerID = nil
                worker = nil
            }
        }

        for attempt in 0..<3 {
            guard isCurrentWorker(id), !Task.isCancelled else { return }
            do {
                switch try await checkpointer.checkpoint() {
                case .complete:
                    return
                case .busy:
                    guard attempt < 2 else { return }
                    try Task.checkCancellation()
                    try await retryDelay()
                }
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }

    private func isCurrentWorker(_ id: UUID) -> Bool {
        !stopped && workerID == id
    }
}
