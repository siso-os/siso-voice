import Foundation
import CoreData
import SQLite3
import os.log

final class PipelineHistoryStore {
    struct RecoverySnapshot {
        let referencedAudioFileNames: Set<String>
        let unfinishedItems: [PipelineHistoryItem]
    }

    private let container: NSPersistentContainer
    private let isStoreLoaded: Bool

    init() {
        let model = Self.makeModel()
        container = NSPersistentContainer(name: "PipelineHistory", managedObjectModel: model)

        var storeURL: URL?
        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let appName = AppName.displayName
            let baseURL = appSupport.appendingPathComponent(appName, isDirectory: true)
            try? FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
            storeURL = baseURL.appendingPathComponent("PipelineHistory.sqlite")
        }

        if let storeURL {
            let description = NSPersistentStoreDescription(url: storeURL)
            description.shouldMigrateStoreAutomatically = true
            description.shouldInferMappingModelAutomatically = true
            container.persistentStoreDescriptions = [description]
        } else {
            container.persistentStoreDescriptions = [NSPersistentStoreDescription()]
        }

        if Self.loadPersistentStoresSynchronously(container: container) == nil {
            isStoreLoaded = true
        } else {
            if let storeURL {
                print("[PipelineHistoryStore] Failed to load persistent store at \(storeURL.path). Attempting recovery.")
                Self.destroySQLiteStoreFiles(at: storeURL)

                // Clear any partially loaded stores and reset descriptions before retrying.
                let coordinator = container.persistentStoreCoordinator
                for store in coordinator.persistentStores {
                    try? coordinator.remove(store)
                }

                let recoveryDescription = NSPersistentStoreDescription(url: storeURL)
                recoveryDescription.shouldMigrateStoreAutomatically = true
                recoveryDescription.shouldInferMappingModelAutomatically = true
                container.persistentStoreDescriptions = [recoveryDescription]
            }

            if Self.loadPersistentStoresSynchronously(container: container) == nil {
                isStoreLoaded = true
            } else {
                print("[PipelineHistoryStore] Failed to recover persistent store. Falling back to in-memory history.")
                let coordinator = container.persistentStoreCoordinator
                for store in coordinator.persistentStores {
                    try? coordinator.remove(store)
                }
                let description = NSPersistentStoreDescription()
                description.type = NSInMemoryStoreType
                container.persistentStoreDescriptions = [description]
                isStoreLoaded = Self.loadPersistentStoresSynchronously(container: container) == nil
            }
        }

        if isStoreLoaded {
            Self.ensureTimestampIndexExists(container: container)
        }
    }

    /// Core Data only applies `entity.indexes` when it (re)creates the schema.
    /// Adding an index does NOT change the entity version hash, so an existing
    /// store is considered already-migrated and silently keeps its original
    /// schema — verified against a real 5k-row store, where the declared index
    /// was never created. Every history read sorts by `timestamp` descending,
    /// which without an index is a full table scan plus a temp B-tree sort, so
    /// create it directly when it is missing. `IF NOT EXISTS` makes this a
    /// no-op on stores that already have it (including newly created ones).
    private static func ensureTimestampIndexExists(container: NSPersistentContainer) {
        guard let store = container.persistentStoreCoordinator.persistentStores.first,
              store.type == NSSQLiteStoreType,
              let storeURL = store.url else { return }

        // Core Data exposes no API for raw DDL, so open the store file directly.
        // This runs once at init, before any Core Data work is issued, and the
        // statement is a no-op when the index is already present.
        var handle: OpaquePointer?
        guard sqlite3_open_v2(storeURL.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            if let handle { sqlite3_close(handle) }
            return
        }
        defer { sqlite3_close(handle) }

        // Core Data mangles attribute names to Z-prefixed uppercase columns.
        let sql = """
        CREATE INDEX IF NOT EXISTS Z_PipelineHistoryEntry_byTimestampDesc \
        ON ZPIPELINEHISTORYENTRY (ZTIMESTAMP DESC)
        """
        if sqlite3_exec(handle, sql, nil, nil, nil) != SQLITE_OK {
            // Non-fatal: the index is a performance optimization only.
            os_log(.info, "[PipelineHistoryStore] timestamp index creation skipped")
        }
    }

    func loadAllHistory(fetchLimit: Int? = nil) -> [PipelineHistoryItem] {
        guard isStoreLoaded else { return [] }
        var result: [PipelineHistoryItem] = []
        container.viewContext.performAndWait {
            let request = pipelineHistoryRequest()
            request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
            if let fetchLimit, fetchLimit > 0 {
                request.fetchLimit = fetchLimit
            }
            guard let entities = try? container.viewContext.fetch(request) else { return }
            result = entities.compactMap(Self.makeHistoryItem(from:))
        }
        return result
    }

    /// Load only the data needed by startup recovery, independently of the
    /// resident UI history limit. The reference query is dictionary-only so a
    /// large transcript archive does not become a second in-memory history.
    func loadRecoverySnapshot() async -> RecoverySnapshot {
        guard isStoreLoaded else {
            return RecoverySnapshot(referencedAudioFileNames: [], unfinishedItems: [])
        }

        let context = container.newBackgroundContext()
        return await withCheckedContinuation { continuation in
            context.perform {
                do {
                    let referenceRequest = NSFetchRequest<NSDictionary>(entityName: "PipelineHistoryEntry")
                    referenceRequest.resultType = .dictionaryResultType
                    referenceRequest.propertiesToFetch = ["audioFileName"]
                    referenceRequest.predicate = NSPredicate(format: "audioFileName != nil")
                    let referencedAudioFileNames = Set(
                        try context.fetch(referenceRequest).compactMap { $0["audioFileName"] as? String }
                    )

                    let unfinishedRequest = self.pipelineHistoryRequest()
                    unfinishedRequest.fetchBatchSize = 128
                    let blankTranscript = NSCompoundPredicate(orPredicateWithSubpredicates: [
                        NSPredicate(format: "rawTranscript == nil"),
                        NSPredicate(format: "rawTranscript == ''"),
                        NSPredicate(format: "postProcessedTranscript == nil"),
                        NSPredicate(format: "postProcessedTranscript == ''")
                    ])
                    unfinishedRequest.predicate = NSCompoundPredicate(
                        andPredicateWithSubpredicates: [
                            NSPredicate(format: "audioFileName != nil"),
                            blankTranscript
                        ]
                    )
                    let unfinishedItems = try context.fetch(unfinishedRequest).map(Self.makeHistoryItem(from:))
                    continuation.resume(
                        returning: RecoverySnapshot(
                            referencedAudioFileNames: referencedAudioFileNames,
                            unfinishedItems: unfinishedItems
                        )
                    )
                } catch {
                    print("[PipelineHistoryStore] Failed to load recovery snapshot: \(error)")
                    continuation.resume(returning: RecoverySnapshot(referencedAudioFileNames: [], unfinishedItems: []))
                }
            }
        }
    }

    /// Remove durable audio only after its history row is old enough and both
    /// transcript fields are complete. The work runs on a private Core Data
    /// context so a large first sweep never blocks the main actor.
    func purgeCompletedAudio(olderThan cutoff: Date, in audioDirectory: URL) async -> Int {
        guard isStoreLoaded else { return 0 }

        let context = container.newBackgroundContext()
        return await withCheckedContinuation { continuation in
            context.perform {
                let request = self.pipelineHistoryRequest()
                request.predicate = NSPredicate(
                    format: "timestamp < %@ AND audioFileName != nil",
                    cutoff as NSDate
                )
                request.fetchBatchSize = 128

                do {
                    let referenceRequest = NSFetchRequest<NSDictionary>(entityName: "PipelineHistoryEntry")
                    referenceRequest.resultType = .dictionaryResultType
                    referenceRequest.propertiesToFetch = ["audioFileName"]
                    referenceRequest.predicate = NSPredicate(format: "audioFileName != nil")
                    let referenceCounts = try context.fetch(referenceRequest).reduce(into: [String: Int]()) {
                        guard let fileName = $1["audioFileName"] as? String else { return }
                        $0[fileName, default: 0] += 1
                    }

                    let entries = try context.fetch(request)
                    var purgedCount = 0

                    for entry in entries {
                        guard let timestamp = entry.timestamp,
                              timestamp < cutoff,
                              let rawTranscript = entry.rawTranscript,
                              !rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                              let postProcessedTranscript = entry.postProcessedTranscript,
                              !postProcessedTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                              let fileName = entry.audioFileName,
                              Self.isSafeAudioFileName(fileName),
                              referenceCounts[fileName] == 1 else {
                            continue
                        }

                        let fileURL = audioDirectory.appendingPathComponent(fileName, isDirectory: false)
                        if FileManager.default.fileExists(atPath: fileURL.path) {
                            guard let values = try? fileURL.resourceValues(
                                forKeys: [.contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey]
                            ),
                            values.isRegularFile == true,
                            values.isSymbolicLink != true,
                            let modifiedAt = values.contentModificationDate,
                            modifiedAt < cutoff else {
                                continue
                            }

                            do {
                                try FileManager.default.removeItem(at: fileURL)
                            } catch {
                                continue
                            }
                        }

                        // Clear the reference after the file operation. If the
                        // database save fails, the next sweep sees the missing
                        // file and safely clears the stale reference.
                        entry.audioFileName = nil
                        purgedCount += 1
                    }

                    guard context.hasChanges else {
                        continuation.resume(returning: 0)
                        return
                    }

                    do {
                        try context.save()
                        continuation.resume(returning: purgedCount)
                    } catch {
                        context.rollback()
                        print("[PipelineHistoryStore] Failed to save audio retention sweep: \(error)")
                        continuation.resume(returning: 0)
                    }
                } catch {
                    print("[PipelineHistoryStore] Failed to fetch audio retention candidates: \(error)")
                    continuation.resume(returning: 0)
                }
            }
        }
    }

    func append(_ item: PipelineHistoryItem, maxCount: Int) throws -> [String] {
        guard isStoreLoaded else { return [] }
        try insert(item)
        return try trim(to: maxCount)
    }

    func update(_ item: PipelineHistoryItem) throws {
        guard isStoreLoaded else { return }

        var thrownError: Error?
        container.viewContext.performAndWait {
            do {
                let request = pipelineHistoryRequest()
                request.predicate = NSPredicate(format: "id == %@", item.id as CVarArg)
                guard let entity = try container.viewContext.fetch(request).first else { return }
                entity.intent = item.intent.rawValue
                entity.selectedText = item.selectedText
                entity.capturedSelection = item.capturedSelection
                entity.rawTranscript = item.rawTranscript
                entity.postProcessedTranscript = item.postProcessedTranscript
                entity.postProcessingPrompt = item.postProcessingPrompt
                entity.systemPrompt = item.systemPrompt
                entity.contextSystemPrompt = item.contextSystemPrompt
                entity.postProcessingStatus = item.postProcessingStatus
                entity.debugStatus = item.debugStatus
                entity.contextAppName = item.contextAppName
                entity.contextBundleIdentifier = item.contextBundleIdentifier
                entity.contextWindowTitle = item.contextWindowTitle
                entity.audioFileName = item.audioFileName
                entity.audioDurationSeconds = item.audioDurationSeconds.map { NSNumber(value: $0) }
                try saveContext()
            } catch {
                thrownError = error
            }
        }
        if let thrownError { throw thrownError }
    }

    func delete(id: UUID) throws -> String? {
        guard isStoreLoaded else { return nil }

        var deletedAudioFileName: String?
        var thrownError: Error?
        container.viewContext.performAndWait {
            do {
                let request = pipelineHistoryRequest()
                request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
                guard let entity = try container.viewContext.fetch(request).first else { return }
                deletedAudioFileName = entity.audioFileName
                container.viewContext.delete(entity)
                try saveContext()
            } catch {
                thrownError = error
            }
        }
        if let thrownError { throw thrownError }
        return deletedAudioFileName
    }

    func clearAll() throws -> [String] {
        guard isStoreLoaded else { return [] }

        var audioFileNames: [String] = []
        var thrownError: Error?
        container.viewContext.performAndWait {
            do {
                let request = pipelineHistoryRequest()
                request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
                guard let entities = try? container.viewContext.fetch(request) else { return }
                audioFileNames = entities.compactMap(\.audioFileName)
                for entity in entities {
                    container.viewContext.delete(entity)
                }
                try saveContext()
            } catch {
                thrownError = error
            }
        }
        if let thrownError { throw thrownError }
        return audioFileNames
    }

    func trim(to maxCount: Int) throws -> [String] {
        guard isStoreLoaded else { return [] }
        guard maxCount > 0 else {
            let audioFileNames = try clearAll()
            return audioFileNames
        }

        var audioFileNames: [String] = []
        var thrownError: Error?
        container.viewContext.performAndWait {
            do {
                let countRequest = pipelineHistoryRequest()
                let count = try container.viewContext.count(for: countRequest)
                guard count > maxCount else { return }

                let request = pipelineHistoryRequest()
                request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
                request.fetchOffset = maxCount
                request.fetchLimit = count - maxCount
                let dropped = try container.viewContext.fetch(request)
                audioFileNames = dropped.compactMap(\.audioFileName)
                for entity in dropped {
                    container.viewContext.delete(entity)
                }
                try saveContext()
            } catch {
                thrownError = error
            }
        }
        if let thrownError { throw thrownError }
        return audioFileNames
    }

    private func insert(_ item: PipelineHistoryItem) throws {
        guard isStoreLoaded else { return }

        var thrownError: Error?
        container.viewContext.performAndWait {
            do {
                let context = container.viewContext
                let entity = PipelineHistoryEntry(context: context)
                entity.id = item.id
                entity.intent = item.intent.rawValue
                entity.selectedText = item.selectedText
                entity.capturedSelection = item.capturedSelection
                entity.timestamp = item.timestamp
                entity.rawTranscript = item.rawTranscript
                entity.postProcessedTranscript = item.postProcessedTranscript
                entity.postProcessingPrompt = item.postProcessingPrompt
                entity.systemPrompt = item.systemPrompt
                entity.contextSummary = item.contextSummary
                entity.contextSystemPrompt = item.contextSystemPrompt
                entity.contextPrompt = item.contextPrompt
                entity.contextScreenshotDataURL = item.contextScreenshotDataURL
                entity.contextScreenshotStatus = item.contextScreenshotStatus
                entity.postProcessingStatus = item.postProcessingStatus
                entity.debugStatus = item.debugStatus
                entity.customVocabulary = item.customVocabulary
                entity.audioFileName = item.audioFileName
                entity.audioDurationSeconds = item.audioDurationSeconds.map { NSNumber(value: $0) }
                entity.contextAppName = item.contextAppName
                entity.contextBundleIdentifier = item.contextBundleIdentifier
                entity.contextWindowTitle = item.contextWindowTitle
                try saveContext()
            } catch {
                thrownError = error
            }
        }
        if let thrownError { throw thrownError }
    }

    private func saveContext() throws {
        guard container.viewContext.hasChanges else { return }
        do {
            try container.viewContext.save()
        } catch {
            container.viewContext.rollback()
            throw error
        }
    }

    private func pipelineHistoryRequest() -> NSFetchRequest<PipelineHistoryEntry> {
        NSFetchRequest<PipelineHistoryEntry>(entityName: "PipelineHistoryEntry")
    }

    private static func isSafeAudioFileName(_ fileName: String) -> Bool {
        guard !fileName.isEmpty,
              !fileName.contains("/"),
              !fileName.contains("\\") else { return false }
        let extensionName = URL(fileURLWithPath: fileName).pathExtension.lowercased()
        return extensionName == "m4a" || extensionName == "wav"
    }

    // Safe: loadPersistentStores calls back on a private queue, not the calling thread.
    private static func loadPersistentStoresSynchronously(container: NSPersistentContainer) -> Error? {
        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var capturedError: Error?
        var remainingCompletions = max(1, container.persistentStoreDescriptions.count)

        container.loadPersistentStores { _, error in
            lock.lock()
            if capturedError == nil, let error {
                capturedError = error
            }
            remainingCompletions -= 1
            let shouldSignal = remainingCompletions <= 0
            lock.unlock()

            if shouldSignal {
                semaphore.signal()
            }
        }

        semaphore.wait()
        return capturedError
    }

    private static func destroySQLiteStoreFiles(at storeURL: URL) {
        let basePath = storeURL.path
        let fileManager = FileManager.default
        for path in [basePath, basePath + "-wal", basePath + "-shm"] {
            try? fileManager.removeItem(atPath: path)
        }
    }

    private static func makeHistoryItem(from entity: PipelineHistoryEntry) -> PipelineHistoryItem {
        PipelineHistoryItem(
            intent: PipelineHistoryItemIntent(rawValue: entity.intent ?? "") ?? .dictation,
            selectedText: entity.selectedText,
            capturedSelection: entity.capturedSelection,
            id: entity.id,
            timestamp: entity.timestamp ?? Date(),
            rawTranscript: entity.rawTranscript ?? "",
            postProcessedTranscript: entity.postProcessedTranscript ?? "",
            postProcessingPrompt: entity.postProcessingPrompt,
            systemPrompt: entity.systemPrompt,
            contextSummary: entity.contextSummary ?? "",
            contextSystemPrompt: entity.contextSystemPrompt,
            contextPrompt: entity.contextPrompt,
            contextScreenshotDataURL: entity.contextScreenshotDataURL,
            contextScreenshotStatus: entity.contextScreenshotStatus ?? "available (image)",
            postProcessingStatus: entity.postProcessingStatus ?? "",
            debugStatus: entity.debugStatus ?? "",
            customVocabulary: entity.customVocabulary ?? "",
            audioFileName: entity.audioFileName,
            audioDurationSeconds: entity.audioDurationSeconds?.doubleValue,
            contextAppName: entity.contextAppName,
            contextBundleIdentifier: entity.contextBundleIdentifier,
            contextWindowTitle: entity.contextWindowTitle
        )
    }

    private static func makeModel() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()

        let entity = NSEntityDescription()
        entity.name = "PipelineHistoryEntry"
        entity.managedObjectClassName = NSStringFromClass(PipelineHistoryEntry.self)

        entity.properties = [
            makeAttribute(name: "intent", type: .stringAttributeType, isOptional: true, defaultValue: "dictation"),
            makeAttribute(name: "selectedText", type: .stringAttributeType, isOptional: true),
            makeAttribute(name: "capturedSelection", type: .stringAttributeType, isOptional: true),
            makeAttribute(name: "id", type: .UUIDAttributeType, isOptional: false),
            makeAttribute(name: "timestamp", type: .dateAttributeType, isOptional: false),
            makeAttribute(name: "rawTranscript", type: .stringAttributeType, isOptional: false),
            makeAttribute(name: "postProcessedTranscript", type: .stringAttributeType, isOptional: false),
            makeAttribute(name: "postProcessingPrompt", type: .stringAttributeType, isOptional: true),
            makeAttribute(name: "systemPrompt", type: .stringAttributeType, isOptional: true),
            makeAttribute(name: "contextSummary", type: .stringAttributeType, isOptional: false),
            makeAttribute(name: "contextSystemPrompt", type: .stringAttributeType, isOptional: true),
            makeAttribute(name: "contextPrompt", type: .stringAttributeType, isOptional: true),
            makeAttribute(name: "contextScreenshotDataURL", type: .stringAttributeType, isOptional: true),
            makeAttribute(name: "contextScreenshotStatus", type: .stringAttributeType, isOptional: false),
            makeAttribute(name: "postProcessingStatus", type: .stringAttributeType, isOptional: false),
            makeAttribute(name: "debugStatus", type: .stringAttributeType, isOptional: false),
            makeAttribute(name: "customVocabulary", type: .stringAttributeType, isOptional: false),
            makeAttribute(name: "audioFileName", type: .stringAttributeType, isOptional: true),
            makeAttribute(name: "audioDurationSeconds", type: .doubleAttributeType, isOptional: true),
            makeAttribute(name: "contextAppName", type: .stringAttributeType, isOptional: true),
            makeAttribute(name: "contextBundleIdentifier", type: .stringAttributeType, isOptional: true),
            makeAttribute(name: "contextWindowTitle", type: .stringAttributeType, isOptional: true)
        ]

        // Every history read sorts by `timestamp` descending. Without an index
        // SQLite does a full table SCAN plus a temp B-tree sort — measured at
        // ~576ms on a 5k-row store, on the main thread, before every paste.
        // The index turns that into an ordered range scan.
        let timestampIndexValue = NSFetchIndexElementDescription(
            property: entity.propertiesByName["timestamp"]!,
            collationType: .binary
        )
        timestampIndexValue.isAscending = false
        entity.indexes = [
            NSFetchIndexDescription(name: "byTimestampDesc", elements: [timestampIndexValue])
        ]

        model.entities = [entity]
        return model
    }

    private static func makeAttribute(
        name: String,
        type: NSAttributeType,
        isOptional: Bool,
        defaultValue: Any? = nil
    ) -> NSAttributeDescription {
        let attribute = NSAttributeDescription()
        attribute.name = name
        attribute.attributeType = type
        attribute.isOptional = isOptional
        attribute.defaultValue = defaultValue
        return attribute
    }
}

@objc(PipelineHistoryEntry)
final class PipelineHistoryEntry: NSManagedObject {
    @NSManaged var id: UUID
    @NSManaged var intent: String?
    @NSManaged var selectedText: String?
    @NSManaged var capturedSelection: String?
    @NSManaged var timestamp: Date?
    @NSManaged var rawTranscript: String?
    @NSManaged var postProcessedTranscript: String?
    @NSManaged var postProcessingPrompt: String?
    @NSManaged var systemPrompt: String?
    @NSManaged var contextSummary: String?
    @NSManaged var contextSystemPrompt: String?
    @NSManaged var contextPrompt: String?
    @NSManaged var contextScreenshotDataURL: String?
    @NSManaged var contextScreenshotStatus: String?
    @NSManaged var postProcessingStatus: String?
    @NSManaged var debugStatus: String?
    @NSManaged var customVocabulary: String?
    @NSManaged var audioFileName: String?
    @NSManaged var audioDurationSeconds: NSNumber?
    @NSManaged var contextAppName: String?
    @NSManaged var contextBundleIdentifier: String?
    @NSManaged var contextWindowTitle: String?
}
