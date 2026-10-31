import Foundation
import Network

final class TelemetryAPIServer {
    let port: UInt16
    var onStatus: ((String) -> Void)?
    private let queue = DispatchQueue(label: "com.fermaxo.api")
    private let snapshotProvider: () -> [String: Any]
    private var listener: NWListener?

    init(port: UInt16 = 8081, snapshotProvider: @escaping () -> [String: Any]) {
        self.port = port
        self.snapshotProvider = snapshotProvider
    }

    func start() {
        guard listener == nil, let endpointPort = NWEndpoint.Port(rawValue: port) else { return }
        do {
            let server = try NWListener(using: .tcp, on: endpointPort)
            server.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready: DispatchQueue.main.async { self.onStatus?("API READY") }
                case .failed(let error): DispatchQueue.main.async { self.onStatus?("API ERROR: \(error.localizedDescription)") }
                case .cancelled: DispatchQueue.main.async { self.onStatus?("API STOPPED") }
                default: break
                }
            }
            server.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                connection.start(queue: self.queue)
                self.readRequest(on: connection, buffer: Data())
            }
            listener = server
            server.start(queue: queue)
        } catch {
            onStatus?("API ERROR: \(error.localizedDescription)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func readRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var request = buffer
            if let data { request.append(data) }
            guard request.count <= 8192 else {
                self.send(on: connection, status: 413, object: ["error": "Request too large"])
                return
            }
            let text = String(decoding: request, as: UTF8.self)
            guard text.contains("\r\n\r\n") else {
                if error == nil && !complete { self.readRequest(on: connection, buffer: request) }
                else { connection.cancel() }
                return
            }
            let line = text.components(separatedBy: "\r\n").first ?? ""
            let parts = line.split(separator: " ")
            guard parts.count >= 2 else {
                self.send(on: connection, status: 400, object: ["error": "Malformed request"])
                return
            }
            guard parts[0] == "GET" else {
                self.send(on: connection, status: 405, object: ["error": "Use GET"])
                return
            }
            let path = String(parts[1].split(separator: "?", maxSplits: 1).first ?? "")
            self.route(path, connection: connection)
        }
    }

    private func route(_ path: String, connection: NWConnection) {
        let snapshot = snapshotProvider()
        switch path {
        case "/api/telemetry":
            send(on: connection, status: 200, object: snapshot)
        case "/api/health":
            send(on: connection, status: 200, object: [
                "ok": true,
                "telemetry": (snapshot["status"] as? String) == "LIVE" ? "live" : "waiting",
                "updated": snapshot["updated"] ?? NSNull(),
                "apiPort": port
            ])
        case "/api/openapi.json":
            send(on: connection, status: 200, object: [
                "openapi": "3.1.0",
                "info": ["title": "Fermaxo iPhone Telemetry API", "version": "1.0.0"],
                "servers": [["url": "http://<iphone-ip>:\(port)"]],
                "paths": [
                    "/api/telemetry": ["get": ["summary": "Latest F1 telemetry snapshot",
                        "responses": ["200": ["description": "Current telemetry",
                            "content": ["application/json": ["schema": ["type": "object", "additionalProperties": true]]]]]]],
                    "/api/health": ["get": ["summary": "iPhone API and receiver health",
                        "responses": ["200": ["description": "Receiver status",
                            "content": ["application/json": ["schema": ["type": "object", "additionalProperties": true]]]]]]]
                ]
            ])
        default:
            send(on: connection, status: 404, object: ["error": "Not found"])
        }
    }

    private func send(on connection: NWConnection, status: Int, object: [String: Any]) {
        guard let body = try? JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed, .sortedKeys]) else {
            connection.cancel()
            return
        }
        let reason = status == 200 ? "OK" : status == 400 ? "Bad Request" : status == 404 ? "Not Found" : status == 405 ? "Method Not Allowed" : "Payload Too Large"
        var response = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }
}
