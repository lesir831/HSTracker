import AppKit
import Foundation
import ProgressProbeCore

func emit(_ value: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
       let output = String(data: data, encoding: .utf8) { print(output) }
}

let args = Array(CommandLine.arguments.dropFirst())
if args == ["--help"] {
    print("Usage: progress-probe [--authorize-framework /path/to/HearthMirror.framework/HearthMirror]")
    exit(0)
}
if !args.isEmpty && (args.count != 2 || args[0] != "--authorize-framework") {
    emit(["status": "invalidArguments"])
    exit(2)
}

do {
    guard let app = NSWorkspace.shared.runningApplications.first(where: {
        $0.bundleIdentifier == "unity.Blizzard Entertainment.Hearthstone"
    }) else {
        throw ProbeError.unavailable("gameNotRunning")
    }
    if args.count == 2 {
        // Use the same user-approved task-port authorization as HSTracker, never sudo/SIP changes.
        guard let framework = dlopen(args[1], RTLD_NOW | RTLD_LOCAL),
              let symbol = dlsym(framework, "acquireTaskportRight") else {
            throw ProbeError.unavailable("authorizationFrameworkUnavailable")
        }
        let authorize = unsafeBitCast(symbol, to: (@convention(c) () -> Int32).self)
        guard authorize() == 0 else { throw ProbeError.unavailable("authorizationDenied") }
    }
    let reader = try AccountProgressReader(pid: app.processIdentifier)
    let result = try reader.read(includeSnapshot: true)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let snapshot = try result.snapshot.map { try JSONSerialization.jsonObject(with: encoder.encode($0)) } ?? NSNull()
    emit(["schemaVersion": 1, "status": "snapshotRead", "monoUUID": reader.runtimeUUID,
          "snapshot": snapshot, "inGameAchievements": result.inGame.map { ["id": $0.key, "progress": $0.value] }])

} catch {
    emit(["schemaVersion": 1, "status": "unavailable", "reason": String(describing: error),
          "accountProgressStatus": "notRead"])
    exit(1)
}
