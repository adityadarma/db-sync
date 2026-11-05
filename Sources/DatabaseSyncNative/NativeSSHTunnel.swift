import Foundation
import Network

/// Keeps one local SSH port-forward alive for each database endpoint. The app
/// uses macOS's built-in OpenSSH client, so keys in ssh-agent and the system
/// Keychain continue to work without exposing a password to this process.
actor NativeSSHTunnel {
    static let shared = NativeSSHTunnel()

    private struct Tunnel {
        let port: Int
        let process: Process
    }

    private var tunnels: [String: Tunnel] = [:]

    func resolve(_ endpoint: NativeDatabaseEndpoint) async throws -> (host: String, port: Int) {
        guard let ssh = endpoint.ssh else { return (endpoint.host, endpoint.port) }
        let key = "\(ssh.user)@\(ssh.host):\(ssh.port)|\(endpoint.host):\(endpoint.port)|\(ssh.privateKeyPath ?? "agent")"
        if let tunnel = tunnels[key], tunnel.process.isRunning {
            return ("127.0.0.1", tunnel.port)
        }

        let localPort = try reserveLoopbackPort()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        var arguments = [
            "-N",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=8",
            "-o", "StrictHostKeyChecking=accept-new",
            "-L", "127.0.0.1:\(localPort):\(endpoint.host):\(endpoint.port)",
            "-p", "\(ssh.port)"
        ]
        if let keyPath = ssh.privateKeyPath, !keyPath.isEmpty {
            arguments += ["-i", (keyPath as NSString).expandingTildeInPath]
        }
        arguments.append("\(ssh.user)@\(ssh.host)")
        process.arguments = arguments
        let standardError = Pipe()
        process.standardError = standardError
        try process.run()

        try await Task.sleep(nanoseconds: 450_000_000)
        guard process.isRunning else {
            let data = try? standardError.fileHandleForReading.readToEnd()
            let details = data.flatMap { String(data: $0, encoding: .utf8) }?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw BridgeError.message(details?.isEmpty == false
                                      ? L10n.format("SSH tunnel gagal: %@", details!)
                                      : "SSH tunnel gagal dimulai. Periksa host, private key, dan SSH agent.")
        }
        tunnels[key] = Tunnel(port: localPort, process: process)
        return ("127.0.0.1", localPort)
    }

    private func reserveLoopbackPort() throws -> Int {
        let listener = try NWListener(using: .tcp, on: .any)
        listener.start(queue: .global(qos: .utility))
        guard let port = listener.port else {
            listener.cancel()
            throw BridgeError.message("Tidak dapat menentukan port lokal untuk SSH tunnel.")
        }
        let value = Int(port.rawValue)
        listener.cancel()
        return value
    }
}
