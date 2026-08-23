import Darwin
import Foundation
import PhotosIndexCore
import PhotosIndexPhotos

public struct PendingMoveJournal: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let digest: String
    public let plan: MovePlan
    public let exportReceipt: ExportReceipt
    public let deletionTargets: [PhotoDeletionTarget]

    public init(
        schemaVersion: Int = 1,
        digest: String,
        plan: MovePlan,
        exportReceipt: ExportReceipt,
        deletionTargets: [PhotoDeletionTarget]
    ) {
        self.schemaVersion = schemaVersion
        self.digest = digest
        self.plan = plan
        self.exportReceipt = exportReceipt
        self.deletionTargets = deletionTargets
    }
}

public protocol PendingMoveStoring: Sendable {
    func save(_ journal: PendingMoveJournal) throws
    func load(digest: String) throws -> PendingMoveJournal?
    func remove(digest: String) throws
}

public enum PendingMoveStoreError: Error, Equatable, Sendable {
    case invalidDigest
    case insecurePath(String)
}

public final class FilePendingMoveStore: PendingMoveStoring, @unchecked Sendable {
    private let root: URL
    private let fileManager: FileManager
    private let writer: FileManagerExportWriter
    private let lock = NSLock()

    public init(root: URL, fileManager: FileManager = .default) {
        self.root = root.standardizedFileURL
        self.fileManager = fileManager
        writer = FileManagerExportWriter(fileManager: fileManager)
    }

    public func save(_ journal: PendingMoveJournal) throws {
        lock.lock()
        defer { lock.unlock() }
        let url = try journalURL(digest: journal.digest)
        try prepareRoot()
        try ExportSupport.writeCanonicalJSON(journal, to: url, fileWriter: writer)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: url.path
        )
    }

    public func load(digest: String) throws -> PendingMoveJournal? {
        lock.lock()
        defer { lock.unlock() }
        let url = try journalURL(digest: digest)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        try validateOwnerOnlyItem(at: root, expectedPermissions: 0o700)
        try validateOwnerOnlyItem(at: url, expectedPermissions: 0o600)
        return try CanonicalJSON.decode(PendingMoveJournal.self, from: Data(contentsOf: url))
    }

    public func remove(digest: String) throws {
        lock.lock()
        defer { lock.unlock() }
        let url = try journalURL(digest: digest)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try validateOwnerOnlyItem(at: root, expectedPermissions: 0o700)
        try validateOwnerOnlyItem(at: url, expectedPermissions: 0o600)
        try fileManager.removeItem(at: url)
    }

    private func prepareRoot() throws {
        try ExportSupport.rejectSymlinkIfPresent(at: root)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: root.path
        )
        try validateOwnerOnlyItem(at: root, expectedPermissions: 0o700)
    }

    private func journalURL(digest: String) throws -> URL {
        guard digest.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil else {
            throw PendingMoveStoreError.invalidDigest
        }
        return try ExportSupport.validatedChildURL(
            root: root,
            childName: "\(digest).json"
        )
    }

    private func validateOwnerOnlyItem(at url: URL, expectedPermissions: Int) throws {
        try ExportSupport.rejectSymlinkIfPresent(at: url)
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let ownerID = (attributes[.ownerAccountID] as? NSNumber)?.uint32Value
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
        guard ownerID == getuid(), permissions == expectedPermissions else {
            throw PendingMoveStoreError.insecurePath(url.path)
        }
    }
}
