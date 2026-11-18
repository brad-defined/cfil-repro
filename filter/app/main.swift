// Host app for the cfilrepro content filter. It's run from Terminal, not as a GUI:
//
//   /Applications/CFILRepro.app/Contents/MacOS/CFILRepro activate
//   /Applications/CFILRepro.app/Contents/MacOS/CFILRepro enable --port 4242 --hold-ms 2000 --verdict drop
//   /Applications/CFILRepro.app/Contents/MacOS/CFILRepro status
//   /Applications/CFILRepro.app/Contents/MacOS/CFILRepro disable
//   /Applications/CFILRepro.app/Contents/MacOS/CFILRepro deactivate

import Foundation
import NetworkExtension
import SystemExtensions

let extID = Bundle.main.bundleIdentifier! + ".filter"

func die(_ msg: String) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(1)
}

final class ExtDelegate: NSObject, OSSystemExtensionRequestDelegate {
    func request(_ r: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        print("replacing \(existing.bundleShortVersion) with \(ext.bundleShortVersion)")
        return .replace
    }
    func requestNeedsUserApproval(_ r: OSSystemExtensionRequest) {
        print("approve the extension in System Settings > General > Login Items & Extensions > Network Extensions ...")
    }
    func request(_ r: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        print(result == .completed ? "done" : "done; reboot required")
        exit(0)
    }
    func request(_ r: OSSystemExtensionRequest, didFailWithError error: Error) {
        die("system extension request failed: \(error)")
    }
}

func submit(_ req: OSSystemExtensionRequest) -> Never {
    let d = ExtDelegate()
    req.delegate = d
    OSSystemExtensionManager.shared.submitRequest(req)
    withExtendedLifetime(d) { dispatchMain() }
}

func withManager(_ body: @escaping (NEFilterManager) -> Void) -> Never {
    let m = NEFilterManager.shared()
    m.loadFromPreferences { err in
        if let err { die("loadFromPreferences: \(err)") }
        body(m)
    }
    dispatchMain()
}

func save(_ m: NEFilterManager) {
    m.saveToPreferences { err in
        if let err { die("saveToPreferences: \(err)") }
        print("filter enabled=\(m.isEnabled) config=\(m.providerConfiguration?.vendorConfiguration ?? [:])")
        exit(0)
    }
}

func parseFlags(_ args: ArraySlice<String>) -> [String: Any] {
    var cfg: [String: Any] = ["port": "4242", "holdMs": 2000, "verdict": "drop"]
    var it = args.makeIterator()
    while let a = it.next() {
        guard let v = it.next() else { die("missing value for \(a)") }
        switch a {
        case "--port": cfg["port"] = v
        case "--hold-ms": cfg["holdMs"] = Int(v) ?? { die("bad --hold-ms") }()
        case "--verdict":
            guard ["drop", "allow", "never"].contains(v) else { die("--verdict must be drop|allow|never") }
            cfg["verdict"] = v
        default: die("unknown flag \(a)")
        }
    }
    return cfg
}

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "" {
case "activate":
    submit(.activationRequest(forExtensionWithIdentifier: extID, queue: .main))
case "deactivate":
    submit(.deactivationRequest(forExtensionWithIdentifier: extID, queue: .main))
case "enable":
    let cfg = parseFlags(args.dropFirst(2))
    withManager { m in
        let c = NEFilterProviderConfiguration()
        c.filterSockets = true
        c.filterPackets = false
        c.filterDataProviderBundleIdentifier = extID
        c.vendorConfiguration = cfg
        m.providerConfiguration = c
        m.localizedDescription = "cfilrepro"
        m.isEnabled = true
        save(m)
    }
case "disable":
    withManager { m in
        m.isEnabled = false
        save(m)
    }
case "status":
    withManager { m in
        print("enabled=\(m.isEnabled) config=\(m.providerConfiguration?.vendorConfiguration ?? [:])")
        exit(0)
    }
default:
    die("usage: CFILRepro activate | enable [--port P] [--hold-ms N] [--verdict drop|allow|never] | status | disable | deactivate")
}
