/// Transient action value whose offline capability survives extraction to the final sink.
nonisolated struct ResolvedSecret<Value: Sendable>: Sendable {
    let value: Value
    let offlineCapability: OfflineReleaseCapability?

    func map<Output: Sendable>(_ transform: (Value) throws -> Output) rethrows -> ResolvedSecret<Output> {
        ResolvedSecret<Output>(value: try transform(value), offlineCapability: offlineCapability)
    }

    func release<T>(validating: () throws -> Void, effect: (Value) throws -> T) throws -> T {
        if let offlineCapability {
            return try offlineCapability.withRelease(validating: validating, effect: { try effect(value) })
        }
        try validating()
        return try effect(value)
    }
}
