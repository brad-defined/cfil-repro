// A deliberately tiny "Little Snitch": a content filter that pauses matching
// outbound UDP flows (like an "allow this connection?" prompt that nobody has
// answered yet) and then resolves them with a configurable verdict.
//
// While a flow is paused, xnu queues the socket's outbound datagrams inside the
// content filter. That queued data counts against the socket's send-buffer space
// (sbspace() subtracts cfil_sock_data_space()), so a non-blocking sendto() soon
// returns EWOULDBLOCK. The question being tested is whether a "drop" verdict
// (or flow teardown) ever posts an EVFILT_WRITE edge afterwards.
//
// For unconnected UDP sockets (sendto), the remote endpoint is usually nil in
// handleNewFlow and only populated once data arrives. So every UDP flow is asked
// to send its first outbound bytes to handleOutboundData, where the port is
// checked and matching flows are paused.

import Foundation
import Network
import NetworkExtension
import os.log

final class FilterDataProvider: NEFilterDataProvider {
    // .notice so `log stream` shows these without --level info.
    private let log = Logger(subsystem: "net.example.cfilrepro", category: "filter")
    private let queue = DispatchQueue(label: "cfilrepro.resume")

    private struct Config {
        var port = "4242"      // remote UDP port to hold
        var holdMs = 2000      // how long the "prompt" stays unanswered
        var verdict = "drop"   // drop | allow | never
    }

    // Read on every flow so `CFILRepro enable ...` takes effect without restarting the extension.
    private var config: Config {
        var c = Config()
        let v = filterConfiguration.vendorConfiguration ?? [:]
        if let s = v["port"] as? String { c.port = s }
        if let n = v["holdMs"] as? Int { c.holdMs = n }
        if let s = v["verdict"] as? String { c.verdict = s }
        return c
    }

    override func startFilter(completionHandler: @escaping (Error?) -> Void) {
        // Send all outbound UDP to handleNewFlow; everything else is allowed in-kernel.
        let rule = NENetworkRule(remoteNetwork: nil, remotePrefix: 0,
                                 localNetwork: nil, localPrefix: 0,
                                 protocol: .UDP, direction: .outbound)
        let settings = NEFilterSettings(rules: [NEFilterRule(networkRule: rule, action: .filterData)],
                                        defaultAction: .allow)
        apply(settings) { [log, config] error in
            if let error { log.error("apply settings failed: \(error.localizedDescription, privacy: .public)") }
            else { log.notice("filter started: port=\(config.port, privacy: .public) holdMs=\(config.holdMs) verdict=\(config.verdict, privacy: .public)") }
            completionHandler(error)
        }
    }

    override func stopFilter(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        log.notice("filter stopped: \(reason.rawValue)")
        completionHandler()
    }

    /// "host:port" for the flow's remote endpoint, or nil if not known yet.
    private func remote(_ flow: NEFilterFlow) -> (host: String, port: String)? {
        guard let sf = flow as? NEFilterSocketFlow else { return nil }
        if #available(macOS 15.0, *) {
            guard case let .hostPort(host, port)? = sf.remoteFlowEndpoint else { return nil }
            return ("\(host)", String(port.rawValue))
        }
        guard let ep = sf.remoteEndpoint as? NWHostEndpoint else { return nil }
        return (ep.hostname, ep.port)
    }

    override func handleNewFlow(_ flow: NEFilterFlow) -> NEFilterNewFlowVerdict {
        guard let sf = flow as? NEFilterSocketFlow, sf.socketProtocol == IPPROTO_UDP else { return .allow() }
        let r = remote(flow)
        log.notice("new UDP flow \(flow.identifier, privacy: .public) remote=\(r.map { "\($0.host):\($0.port)" } ?? "unknown yet", privacy: .public)")
        if let r, r.port != config.port { return .allow() }
        // Remote matches, or isn't known yet: look at the first outbound data.
        return .filterDataVerdict(withFilterInbound: false, peekInboundBytes: 0,
                                  filterOutbound: true, peekOutboundBytes: 1024)
    }

    override func handleOutboundData(from flow: NEFilterFlow, readBytesStartOffset offset: Int,
                                     readBytes: Data) -> NEFilterDataVerdict {
        let c = config
        guard let r = remote(flow) else {
            log.notice("outbound data on \(flow.identifier, privacy: .public) with no remote endpoint; allowing")
            return .allow()
        }
        guard r.port == c.port else { return .allow() }

        let desc = "\(flow.identifier) remote=\(r.host):\(r.port)"
        log.notice("PAUSE \(desc, privacy: .public) verdict=\(c.verdict, privacy: .public) in \(c.holdMs)ms")
        if c.verdict != "never" {
            let allow = c.verdict == "allow"
            queue.asyncAfter(deadline: .now() + .milliseconds(c.holdMs)) { [weak self] in
                guard let self else { return }
                self.log.notice("RESUME \(desc, privacy: .public) -> \(allow ? "allow" : "drop", privacy: .public)")
                self.resumeFlow(flow, with: allow ? NEFilterDataVerdict.allow() : NEFilterDataVerdict.drop())
            }
        }
        return .pause()
    }
}
