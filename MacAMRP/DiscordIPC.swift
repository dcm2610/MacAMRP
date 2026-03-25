//
//  DiscordIPC.swift
//  MacAMRP
//
//  Custom Discord Rich Presence IPC client using Unix domain sockets.
//  Protocol reference: https://github.com/discord/discord-rpc/blob/master/documentation/hard-mode.md
//

import Foundation

// MARK: - Types

struct DiscordActivity {
    var details: String?        // Top line (e.g. track name)
    var state: String?          // Bottom line (e.g. artist)
    var largeImageURL: String?  // External https:// URL for album art
    var largeImageText: String? // Tooltip for large image
    var smallImageKey: String?  // Asset key for small image
    var smallImageText: String? // Tooltip for small image
    var startTimestamp: Date?   // When playback started (shows elapsed time)
    var endTimestamp: Date?     // When track ends (shows remaining time)
    var buttons: [(label: String, url: String)]? // Up to 2 buttons
}

// MARK: - DiscordIPC

/// Manages a persistent connection to the local Discord client via Unix socket IPC.
/// All operations are performed on an internal serial queue.
final class DiscordIPC {
    private let clientID: String
    private let queue = DispatchQueue(label: "com.macamrp.discord-ipc", qos: .utility)

    private var socketFD: Int32 = -1
    private var isConnected = false
    private var reconnectTimer: DispatchSourceTimer?

    // Called on main queue when connection state changes
    var onConnectionStateChange: ((Bool) -> Void)?

    init(clientID: String) {
        self.clientID = clientID
    }

    deinit {
        disconnect()
    }

    // MARK: - Public API

    func connect() {
        queue.async { [weak self] in
            self?.attemptConnection()
        }
    }

    func disconnect() {
        queue.async { [weak self] in
            self?.closeSocket()
            self?.cancelReconnectTimer()
        }
    }

    func setActivity(_ activity: DiscordActivity?) {
        queue.async { [weak self] in
            guard let self, isConnected else { return }
            let payload = buildSetActivityPayload(activity)
            sendFrame(opcode: 1, payload: payload)
        }
    }

    func clearActivity() {
        setActivity(nil)
    }

    // MARK: - Connection

    private func attemptConnection() {
        cancelReconnectTimer()
        closeSocket()

        guard let tempDir = discordTempDir() else {
            scheduleReconnect()
            return
        }

        // Try discord-ipc-0 through discord-ipc-9
        for i in 0..<10 {
            let path = "\(tempDir)/discord-ipc-\(i)"
            if tryConnect(path: path) {
                return
            }
        }

        scheduleReconnect()
    }

    private func tryConnect(path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        // Copy path into sun_path (fixed 104-byte field on macOS)
        let pathBytes = path.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            return false
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { ptr in
            pathBytes.withUnsafeBytes { src in
                ptr.copyMemory(from: src)
            }
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Foundation.connect(fd, $0, addrLen)
            }
        }

        guard result == 0 else {
            close(fd)
            return false
        }

        socketFD = fd

        // Send handshake
        let handshake = #"{"v":1,"client_id":"\#(clientID)"}"#
        sendFrame(opcode: 0, payload: handshake)

        // Read READY response
        if readReady() {
            isConnected = true
            DispatchQueue.main.async { [weak self] in
                self?.onConnectionStateChange?(true)
            }
            // Start reading loop to catch disconnects
            startReadLoop()
            return true
        } else {
            close(fd)
            socketFD = -1
            return false
        }
    }

    private func readReady() -> Bool {
        guard let (opcode, data) = readFrame(), opcode == 1,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let evt = json["evt"] as? String, evt == "READY"
        else { return false }
        return true
    }

    // MARK: - Read Loop

    private func startReadLoop() {
        queue.async { [weak self] in
            self?.readLoop()
        }
    }

    private func readLoop() {
        while isConnected {
            guard let (_, _) = readFrame() else {
                handleDisconnect()
                return
            }
            // We don't need to process incoming frames for basic Rich Presence
        }
    }

    // MARK: - Framing

    /// Sends a frame: [opcode: uint32 LE][length: uint32 LE][payload: UTF-8]
    private func sendFrame(opcode: UInt32, payload: String) {
        guard socketFD >= 0 else { return }
        guard let payloadData = payload.data(using: .utf8) else { return }

        let length = UInt32(payloadData.count)
        var header = Data(capacity: 8)
        header.appendUInt32LE(opcode)
        header.appendUInt32LE(length)

        var frame = header
        frame.append(payloadData)

        frame.withUnsafeBytes { ptr in
            _ = write(socketFD, ptr.baseAddress!, frame.count)
        }
    }

    /// Reads one frame, returning (opcode, payloadData) or nil on error/disconnect.
    private func readFrame() -> (UInt32, Data)? {
        guard socketFD >= 0 else { return nil }

        // Read 8-byte header
        var header = [UInt8](repeating: 0, count: 8)
        guard readExact(into: &header, count: 8) else { return nil }

        let opcode = UInt32(littleEndian: header[0..<4].withUnsafeBytes { $0.load(as: UInt32.self) })
        let length = UInt32(littleEndian: header[4..<8].withUnsafeBytes { $0.load(as: UInt32.self) })

        guard length <= 65528 else { return nil }

        var payload = [UInt8](repeating: 0, count: Int(length))
        guard readExact(into: &payload, count: Int(length)) else { return nil }

        return (opcode, Data(payload))
    }

    private func readExact(into buffer: inout [UInt8], count: Int) -> Bool {
        var bytesRead = 0
        while bytesRead < count {
            let n = read(socketFD, &buffer[bytesRead], count - bytesRead)
            if n <= 0 { return false }
            bytesRead += n
        }
        return true
    }

    // MARK: - Disconnect / Reconnect

    private func handleDisconnect() {
        guard isConnected else { return }
        closeSocket()
        DispatchQueue.main.async { [weak self] in
            self?.onConnectionStateChange?(false)
        }
        scheduleReconnect()
    }

    private func closeSocket() {
        isConnected = false
        if socketFD >= 0 {
            close(socketFD)
            socketFD = -1
        }
    }

    private func scheduleReconnect() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5)
        timer.setEventHandler { [weak self] in
            self?.attemptConnection()
        }
        timer.resume()
        reconnectTimer = timer
    }

    private func cancelReconnectTimer() {
        reconnectTimer?.cancel()
        reconnectTimer = nil
    }

    // MARK: - Payload Building

    private func buildSetActivityPayload(_ activity: DiscordActivity?) -> String {
        let nonce = UUID().uuidString
        let pid = ProcessInfo.processInfo.processIdentifier

        if activity == nil {
            // Clear presence
            return """
            {"cmd":"SET_ACTIVITY","args":{"pid":\(pid)},"nonce":"\(nonce)"}
            """
        }

        let act = activity!
        var activityDict: [String: Any] = [:]
        activityDict["type"] = 2 // Listening

        if let details = act.details {
            activityDict["details"] = details
        }
        if let state = act.state {
            activityDict["state"] = state
        }

        // Timestamps
        var timestamps: [String: Any] = [:]
        if let start = act.startTimestamp {
            timestamps["start"] = Int(start.timeIntervalSince1970)
        }
        if let end = act.endTimestamp {
            timestamps["end"] = Int(end.timeIntervalSince1970)
        }
        if !timestamps.isEmpty {
            activityDict["timestamps"] = timestamps
        }

        // Assets
        var assets: [String: Any] = [:]
        if let img = act.largeImageURL {
            assets["large_image"] = img
        }
        if let txt = act.largeImageText {
            assets["large_text"] = txt
        }
        if let img = act.smallImageKey {
            assets["small_image"] = img
        }
        if let txt = act.smallImageText {
            assets["small_text"] = txt
        }
        if !assets.isEmpty {
            activityDict["assets"] = assets
        }

        // Buttons (max 2)
        if let buttons = act.buttons, !buttons.isEmpty {
            let buttonArray = buttons.prefix(2).map { ["label": $0.label, "url": $0.url] }
            activityDict["buttons"] = buttonArray
        }

        let args: [String: Any] = ["pid": pid, "activity": activityDict]
        let payload: [String: Any] = ["cmd": "SET_ACTIVITY", "args": args, "nonce": nonce]

        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let string = String(data: data, encoding: .utf8) else {
            return #"{"cmd":"SET_ACTIVITY","args":{"pid":\#(pid)},"nonce":"\#(nonce)"}"#
        }
        return string
    }

    // MARK: - Helpers

    private func discordTempDir() -> String? {
        // Check env vars in the order Discord's own code does
        for key in ["XDG_RUNTIME_DIR", "TMPDIR", "TMP", "TEMP"] {
            if let val = ProcessInfo.processInfo.environment[key] {
                return val.hasSuffix("/") ? String(val.dropLast()) : val
            }
        }
        return "/tmp"
    }
}

// MARK: - Data helpers

private extension Data {
    mutating func appendUInt32LE(_ value: UInt32) {
        var v = value.littleEndian
        withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
}
