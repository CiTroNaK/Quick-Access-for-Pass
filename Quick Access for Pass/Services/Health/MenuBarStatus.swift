/// Aggregate menu bar health status. Error wins over degraded; disabled proxies are skipped.
nonisolated enum MenuBarStatus: Sendable, Equatable {
    case normal
    case degraded(services: [String])
    case error(services: [String])

    var severityRank: Int {
        switch self {
        case .normal:   return 0
        case .degraded: return 1
        case .error:    return 2
        }
    }
}

/// Computes worst-case ``MenuBarStatus`` across CLI, SSH, and Run health sources.
nonisolated enum MenuBarHealthAggregator {
    static func aggregate(
        sshHealth: ProxyHealthState,
        runHealth: ProxyHealthState,
        cliHealth: PassCLIHealth
    ) -> MenuBarStatus {
        var errorServices: [String] = []
        var degradedServices: [String] = []

        classifyCLI(cliHealth, errors: &errorServices, degraded: &degradedServices)
        classifyProxy(sshHealth, name: "SSH Agent", errors: &errorServices, degraded: &degradedServices)
        classifyProxy(runHealth, name: "Run Proxy", errors: &errorServices, degraded: &degradedServices)

        if !errorServices.isEmpty {
            return .error(services: errorServices)
        } else if !degradedServices.isEmpty {
            return .degraded(services: degradedServices)
        } else {
            return .normal
        }
    }

    private static func classifyCLI(
        _ health: PassCLIHealth,
        errors: inout [String],
        degraded: inout [String]
    ) {
        switch health {
        case .ok:              break
        case .notLoggedIn:     degraded.append("Pass CLI")
        case .notInstalled, .failed: errors.append("Pass CLI")
        }
    }

    private static func classifyProxy(
        _ health: ProxyHealthState,
        name: String,
        errors: inout [String],
        degraded: inout [String]
    ) {
        switch health {
        case .disabled, .ok: break
        case .degraded:      degraded.append(name)
        case .unreachable:   errors.append(name)
        }
    }
}
