import Darwin
import Foundation
import PhotosIndexCore

public enum UnixSocketError: Error, Equatable {
    case pathTooLong
    case unsafeExistingPath
    case socketAlreadyActive
    case socketCreationFailed(Int32)
    case socketConfigurationFailed(Int32)
    case bindFailed(Int32)
    case listenFailed(Int32)
    case connectFailed(Int32)
    case peerRejected
    case requestTooLarge
    case disconnected
    case invalidMessage
}

public final class UnixCommandHost: @unchecked Sendable {
    public typealias Handler = @Sendable (CommandRequest) -> CommandResponse

    private let path: String
    private let queue = DispatchQueue(label: "photosindex.command-host", qos: .userInitiated)
    private let clientQueue = DispatchQueue(
        label: "photosindex.command-clients",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private let clientSlots: DispatchSemaphore
    private let clientReadTimeout: TimeInterval
    private let clientWriteTimeout: TimeInterval
    private let lock = NSLock()
    private var descriptor: Int32 = -1
    private var running = false
    private var handler: Handler?

    public init(
        path: String,
        maxConcurrentClients: Int = 4,
        clientReadTimeout: TimeInterval = 10,
        clientWriteTimeout: TimeInterval = 30
    ) {
        self.path = path
        clientSlots = DispatchSemaphore(value: max(1, maxConcurrentClients))
        self.clientReadTimeout = max(0.01, clientReadTimeout)
        self.clientWriteTimeout = max(0.01, clientWriteTimeout)
    }

    deinit {
        stop()
    }

    public func start(handler: @escaping Handler) throws {
        guard path.utf8.count < 100 else { throw UnixSocketError.pathTooLong }
        try removeOwnedStaleSocketIfPresent()

        let socketDescriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketDescriptor >= 0 else {
            throw UnixSocketError.socketCreationFailed(errno)
        }

        let previousMask = umask(0o077)
        defer { _ = umask(previousMask) }

        do {
            try bindSocket(socketDescriptor, path: path)
            guard chmod(path, 0o600) == 0 else {
                let code = errno
                Darwin.close(socketDescriptor)
                Darwin.unlink(path)
                throw UnixSocketError.bindFailed(code)
            }
            guard Darwin.listen(socketDescriptor, 8) == 0 else {
                let code = errno
                Darwin.close(socketDescriptor)
                Darwin.unlink(path)
                throw UnixSocketError.listenFailed(code)
            }
        } catch {
            Darwin.close(socketDescriptor)
            Darwin.unlink(path)
            throw error
        }

        lock.lock()
        descriptor = socketDescriptor
        self.handler = handler
        running = true
        lock.unlock()

        queue.async { [weak self] in
            self?.acceptLoop()
        }
    }

    public func stop() {
        lock.lock()
        let socketDescriptor = descriptor
        descriptor = -1
        running = false
        handler = nil
        lock.unlock()

        if socketDescriptor >= 0 {
            Darwin.shutdown(socketDescriptor, SHUT_RDWR)
            Darwin.close(socketDescriptor)
        }
        try? removeOwnedStaleSocketIfPresent()
    }

    private func acceptLoop() {
        while currentRunningState() {
            clientSlots.wait()
            guard currentRunningState() else {
                clientSlots.signal()
                return
            }
            let serverDescriptor = currentDescriptor()
            guard serverDescriptor >= 0 else {
                clientSlots.signal()
                return
            }
            let client = Darwin.accept(serverDescriptor, nil, nil)
            if client < 0 {
                clientSlots.signal()
                if currentRunningState() { continue }
                return
            }
            do {
                try configureSocket(
                    client,
                    receiveTimeout: clientReadTimeout,
                    sendTimeout: clientWriteTimeout
                )
            } catch {
                Darwin.close(client)
                clientSlots.signal()
                continue
            }
            clientQueue.async { [weak self] in
                defer {
                    Darwin.close(client)
                    self?.clientSlots.signal()
                }
                self?.handle(client: client)
            }
        }
    }

    private func handle(client: Int32) {
        var peerUID = uid_t()
        var peerGID = gid_t()
        guard getpeereid(client, &peerUID, &peerGID) == 0, peerUID == getuid() else {
            return
        }
        guard let requestData = try? readLine(from: client),
              let request = try? CanonicalJSON.decode(CommandRequest.self, from: requestData),
              let handler = currentHandler()
        else { return }

        let response: CommandResponse
        if request.protocolVersion != CommandProtocol.currentVersion {
            response = .failure(
                id: request.id,
                error: CommandFailure(
                    code: "protocol-version-mismatch",
                    message: "Unsupported command protocol version"
                )
            )
        } else {
            response = handler(request)
        }
        guard var bytes = try? CanonicalJSON.encode(response) else { return }
        bytes.append(0x0a)
        try? writeAll(bytes, to: client)
    }

    private func currentRunningState() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    private func currentDescriptor() -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        return descriptor
    }

    private func currentHandler() -> Handler? {
        lock.lock()
        defer { lock.unlock() }
        return handler
    }

    private func removeOwnedStaleSocketIfPresent() throws {
        var fileInfo = stat()
        guard lstat(path, &fileInfo) == 0 else {
            if errno == ENOENT { return }
            throw UnixSocketError.unsafeExistingPath
        }
        let kind = fileInfo.st_mode & S_IFMT
        guard kind == S_IFSOCK, fileInfo.st_uid == getuid() else {
            throw UnixSocketError.unsafeExistingPath
        }
        if try existingSocketIsActive() {
            throw UnixSocketError.socketAlreadyActive
        }
        guard Darwin.unlink(path) == 0 else {
            throw UnixSocketError.unsafeExistingPath
        }
    }

    private func existingSocketIsActive() throws -> Bool {
        let probe = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else { throw UnixSocketError.socketCreationFailed(errno) }
        defer { Darwin.close(probe) }

        var address = try makeAddress(path: path)
        let length = socketAddressLength(path: path)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(probe, $0, length)
            }
        }
        if result == 0 { return true }
        if errno == ECONNREFUSED || errno == ENOENT { return false }
        throw UnixSocketError.unsafeExistingPath
    }
}

public struct UnixCommandClient: Sendable {
    private let path: String
    private let receiveTimeout: TimeInterval
    private let sendTimeout: TimeInterval

    public init(
        path: String,
        receiveTimeout: TimeInterval = 3_700,
        sendTimeout: TimeInterval = 30
    ) {
        self.path = path
        self.receiveTimeout = max(0.01, receiveTimeout)
        self.sendTimeout = max(0.01, sendTimeout)
    }

    public func send(_ request: CommandRequest) throws -> CommandResponse {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw UnixSocketError.socketCreationFailed(errno) }
        defer { Darwin.close(descriptor) }
        try configureSocket(
            descriptor,
            receiveTimeout: receiveTimeout,
            sendTimeout: sendTimeout
        )

        var address = try makeAddress(path: path)
        let length = socketAddressLength(path: path)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, length)
            }
        }
        guard result == 0 else { throw UnixSocketError.connectFailed(errno) }

        var bytes = try CanonicalJSON.encode(request)
        bytes.append(0x0a)
        try writeAll(bytes, to: descriptor)
        let responseData = try readLine(from: descriptor)
        let response = try CanonicalJSON.decode(CommandResponse.self, from: responseData)
        guard response.id == request.id else { throw CommandTransportError.responseIDMismatch }
        guard response.protocolVersion == CommandProtocol.currentVersion else {
            throw CommandTransportError.protocolMismatch
        }
        return response
    }
}

private func configureSocket(
    _ descriptor: Int32,
    receiveTimeout: TimeInterval,
    sendTimeout: TimeInterval
) throws {
    var noSignal: Int32 = 1
    guard setsockopt(
        descriptor,
        SOL_SOCKET,
        SO_NOSIGPIPE,
        &noSignal,
        socklen_t(MemoryLayout.size(ofValue: noSignal))
    ) == 0 else {
        throw UnixSocketError.socketConfigurationFailed(errno)
    }
    try setSocketTimeout(descriptor, option: SO_RCVTIMEO, seconds: receiveTimeout)
    try setSocketTimeout(descriptor, option: SO_SNDTIMEO, seconds: sendTimeout)
}

private func setSocketTimeout(_ descriptor: Int32, option: Int32, seconds: TimeInterval) throws {
    let bounded = max(0.001, seconds)
    let wholeSeconds = floor(bounded)
    var timeout = timeval(
        tv_sec: Int(wholeSeconds),
        tv_usec: Int32((bounded - wholeSeconds) * 1_000_000)
    )
    guard setsockopt(
        descriptor,
        SOL_SOCKET,
        option,
        &timeout,
        socklen_t(MemoryLayout.size(ofValue: timeout))
    ) == 0 else {
        throw UnixSocketError.socketConfigurationFailed(errno)
    }
}

private func bindSocket(_ descriptor: Int32, path: String) throws {
    var address = try makeAddress(path: path)
    let length = socketAddressLength(path: path)
    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(descriptor, $0, length)
        }
    }
    guard result == 0 else { throw UnixSocketError.bindFailed(errno) }
}

private func makeAddress(path: String) throws -> sockaddr_un {
    guard path.utf8.count < 100 else { throw UnixSocketError.pathTooLong }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let length = socketAddressLength(path: path)
    address.sun_len = UInt8(length)
    withUnsafeMutablePointer(to: &address.sun_path) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: 104) { bytes in
            path.withCString { source in
                _ = strncpy(bytes, source, 103)
            }
        }
    }
    return address
}

private func socketAddressLength(path: String) -> socklen_t {
    socklen_t(MemoryLayout<sockaddr_un>.size)
}

private func readLine(from descriptor: Int32) throws -> Data {
    var output = Data()
    var byte: UInt8 = 0
    while output.count <= 1_048_576 {
        let count = withUnsafeMutablePointer(to: &byte) {
            Darwin.read(descriptor, $0, 1)
        }
        if count == 0 { throw UnixSocketError.disconnected }
        if count < 0 {
            if errno == EINTR { continue }
            throw UnixSocketError.disconnected
        }
        if byte == 0x0a { return output }
        output.append(byte)
    }
    throw UnixSocketError.requestTooLarge
}

private func writeAll(_ data: Data, to descriptor: Int32) throws {
    try data.withUnsafeBytes { rawBuffer in
        guard let base = rawBuffer.baseAddress else { return }
        var written = 0
        while written < rawBuffer.count {
            let count = Darwin.write(descriptor, base.advanced(by: written), rawBuffer.count - written)
            if count < 0 {
                if errno == EINTR { continue }
                throw UnixSocketError.disconnected
            }
            written += count
        }
    }
}
