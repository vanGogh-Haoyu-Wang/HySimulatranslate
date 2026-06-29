import Foundation

enum ResourcePressureLevel: Equatable, Sendable {
    case normal
    case warning
    case critical
}

enum ResourcePressureAction: Equatable, Sendable {
    case none
    case shedHeavyWork
}

enum ResourcePressurePolicy {
    static func action(for level: ResourcePressureLevel) -> ResourcePressureAction {
        switch level {
        case .normal:
            .none
        case .warning, .critical:
            .shedHeavyWork
        }
    }
}

final class ResourcePressureMonitor {
    private let handler: @Sendable (ResourcePressureLevel) -> Void
    private var source: DispatchSourceMemoryPressure?

    init(handler: @escaping @Sendable (ResourcePressureLevel) -> Void) {
        self.handler = handler
    }

    func start() {
        guard source == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical],
            queue: .main
        )
        source.setEventHandler { [weak source, handler] in
            guard let data = source?.data else { return }
            if data.contains(.critical) {
                handler(.critical)
            } else if data.contains(.warning) {
                handler(.warning)
            } else {
                handler(.normal)
            }
        }
        source.resume()
        self.source = source
    }

    func cancel() {
        source?.cancel()
        source = nil
    }
}
