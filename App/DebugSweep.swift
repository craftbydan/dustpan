#if DEBUG
    import AppKit
    import Foundation

    /// DEBUG only. `-debugSweepAndExit <file>` runs a real Sweep through `SweepModel` (same
    /// scanners, same Full Disk Access state as the app), writes a JSON report and quits.
    /// `-debugSweepCancelAfter <seconds>` cancels it after that long and reports how long every
    /// module took to stop. Read-only: nothing is moved or deleted ("Clean recommended" is never run).
    @MainActor
    enum DebugSweep {
        struct Request {
            let output: URL
            let cancelAfter: Double?
        }

        static var request: Request? {
            let defaults = UserDefaults.standard
            guard let output = defaults.string(forKey: "debugSweepAndExit") else { return nil }
            let cancel = defaults.double(forKey: "debugSweepCancelAfter")
            return Request(output: URL(fileURLWithPath: output), cancelAfter: cancel > 0 ? cancel : nil)
        }

        struct Report: Encodable {
            struct Module: Encodable {
                let module: String
                let state: String
                let bytes: Int64
                let count: Int
                let seconds: Double?
            }
            var fullDiskAccess = false
            var modules: [Module] = []
            var recommendedBytes: Int64 = 0
            var recommendedItems = 0
            var recommendedAllSafeAndSelected = true
            var totalSeconds = 0.0
            var cancelledAfter: Double?
            /// From `cancel()` to the Sweep having stopped every module.
            var cancelLatencySeconds: Double?
            var statesWhenCancelled: [String: String] = [:]
            var peakPhysFootprintMB = 0.0
            /// Main-thread responsiveness while sweeping (Prompt 11): a 10 ms heartbeat on the main
            /// actor; how late it woke at worst, and how often it was more than 50 ms late.
            var mainThreadWorstLateMs = 0.0
            var mainThreadLateOver50ms = 0
            var mainThreadBeats = 0
        }

        /// Wakes every 10 ms on the main actor and records how late each wake-up was.
        @MainActor
        final class Heartbeat {
            var worst = 0.0
            var over50 = 0
            var beats = 0
            var running = true

            func run() async {
                let clock = ContinuousClock()
                while running {
                    let before = clock.now
                    try? await Task.sleep(for: .milliseconds(10))
                    let over = (clock.now - before - .milliseconds(10)).components
                    let late = Double(over.seconds) * 1_000 + Double(over.attoseconds) / 1e15
                    beats += 1
                    worst = max(worst, late)
                    if late > 50 { over50 += 1 }
                }
            }
        }

        static func run(_ request: Request, appState: AppState) async {
            while !appState.onboarding.isLoaded { try? await Task.sleep(for: .milliseconds(50)) }
            let model = appState.sweep
            var report = Report(fullDiskAccess: appState.onboarding.hasFullDiskAccess)
            let started = Date()
            let heartbeat = Heartbeat()
            let beating = Task { @MainActor in await heartbeat.run() }
            model.start()
            if let delay = request.cancelAfter {
                try? await Task.sleep(for: .seconds(delay))
                report.cancelledAfter = Date().timeIntervalSince(started)
                for module in model.modules {
                    report.statesWhenCancelled[module.rawValue] = describe(model.state(module))
                }
                let cancelled = Date()
                model.cancel()
                await model.waitForSweep()
                report.cancelLatencySeconds = Date().timeIntervalSince(cancelled)
            } else {
                await model.waitForSweep()
            }
            report.totalSeconds = Date().timeIntervalSince(started)
            heartbeat.running = false
            await beating.value
            report.mainThreadWorstLateMs = (heartbeat.worst * 10).rounded() / 10
            report.mainThreadLateOver50ms = heartbeat.over50
            report.mainThreadBeats = heartbeat.beats
            report.modules = model.modules.map {
                .init(
                    module: $0.rawValue, state: describe(model.state($0)), bytes: model.bytes($0),
                    count: model.count($0), seconds: model.seconds[$0])
            }
            report.recommendedBytes = model.recommendedBytes
            report.recommendedItems = model.recommendedItems.count
            report.recommendedAllSafeAndSelected = model.recommendedItems.allSatisfy {
                $0.risk == .safe && $0.isSelected && !$0.detectionOnly
            }
            report.peakPhysFootprintMB = Double(DebugWalk.memory().peak) / 1_048_576
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? encoder.encode(report).write(to: request.output)
            NSApp.terminate(nil)
        }

        static func describe(_ state: SweepModuleState) -> String {
            switch state {
            case .waiting: "waiting"
            case .running(let fraction): "running \(fraction.map { String(format: "%.2f", $0) } ?? "")"
            case .finished: "finished"
            case .needsAccess: "needsAccess"
            case .failed(let message): "failed: \(message)"
            case .cancelled: "cancelled"
            }
        }
    }
#endif
