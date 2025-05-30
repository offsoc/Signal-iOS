//
// Copyright 2021 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit

/// Responsible for persisting the history of user-selected avatars.
///
/// At the time of writing, these include custom images, the stock icons, and
/// custom text overlaid over a colored background. They do not include default
/// avatars, such as "contact initials over a colored background".
///
/// - SeeAlso ``AvatarDefaultColorManager``
class AvatarHistoryManager {
    enum Context {
        case groupId(Data)
        case profile

        fileprivate var key: String {
            switch self {
            case .groupId(let data): return "group.\(data.hexadecimalString)"
            case .profile: return "profile"
            }
        }
    }

    private let db: any DB
    private let keyValueStore: KeyValueStore
    private let imageHistoryDirectory: URL

    init(
        appReadiness: AppReadiness,
        db: any DB
    ) {
        self.db = db
        self.keyValueStore = KeyValueStore(collection: "AvatarHistory")
        self.imageHistoryDirectory = URL(
            fileURLWithPath: "AvatarHistory",
            isDirectory: true,
            relativeTo: URL(fileURLWithPath: OWSFileSystem.appSharedDataDirectoryPath())
        )
    }

    func cleanupOrphanedImages() async {
        guard OWSFileSystem.fileOrFolderExists(url: imageHistoryDirectory) else { return }

        let allRecords: [[AvatarRecord]] = db.read { tx in
            do {
                return try keyValueStore.allCodableValues(transaction: tx)
            } catch {
                owsFailDebug("Failed to decode avatar history for orphan cleanup \(error)")
                return []
            }
        }

        let filesToKeep = allRecords.flatMap { $0.compactMap { $0.imageUrl?.path } }

        let filesInDirectory: [String]
        do {
            filesInDirectory = try OWSFileSystem.recursiveFilesInDirectory(imageHistoryDirectory.path)
        } catch {
            owsFailDebug("Failed to lookup files in image history directory \(error)")
            return
        }

        var orphanCount = 0
        for file in filesInDirectory where !filesToKeep.contains(file) {
            guard OWSFileSystem.deleteFile(file) else {
                owsFailDebug("Failed to delete orphaned avatar image file \(file)")
                continue
            }
            orphanCount += 1
        }

        if orphanCount > 0 {
            Logger.info("Deleted \(orphanCount) orphaned avatar images.")
        }
    }

    func touchedModel(_ model: AvatarModel, in context: Context, tx: DBWriteTransaction) {
        var models = models(for: context, tx: tx)

        models.removeAll { $0.identifier == model.identifier }
        models.insert(model, at: 0)

        let records: [AvatarRecord] = models.map { model in
            switch model.type {
            case .icon(let icon):
                owsAssertDebug(model.identifier == icon.rawValue)
                return AvatarRecord(kind: .icon, identifier: model.identifier, imageUrl: nil, text: nil, theme: model.theme.rawValue)
            case .image(let url):
                return AvatarRecord(kind: .image, identifier: model.identifier, imageUrl: url, text: nil, theme: model.theme.rawValue)
            case .text(let text):
                return AvatarRecord(kind: .text, identifier: model.identifier, imageUrl: nil, text: text, theme: model.theme.rawValue)
            }
        }

        do {
            try keyValueStore.setCodable(records, key: context.key, transaction: tx)
        } catch {
            owsFailDebug("Failed to touch avatar history \(error)")
        }
    }

    func deletedModel(_ model: AvatarModel, in context: Context, tx: DBWriteTransaction) {
        var models = models(for: context, tx: tx)

        models.removeAll { $0.identifier == model.identifier }

        if case .image(let url) = model.type {
            OWSFileSystem.deleteFileIfExists(url.path)
        }

        let records: [AvatarRecord] = models.map { model in
            switch model.type {
            case .icon(let icon):
                owsAssertDebug(model.identifier == icon.rawValue)
                return AvatarRecord(kind: .icon, identifier: model.identifier, imageUrl: nil, text: nil, theme: model.theme.rawValue)
            case .image(let url):
                return AvatarRecord(kind: .image, identifier: model.identifier, imageUrl: url, text: nil, theme: model.theme.rawValue)
            case .text(let text):
                return AvatarRecord(kind: .text, identifier: model.identifier, imageUrl: nil, text: text, theme: model.theme.rawValue)
            }
        }

        do {
            try keyValueStore.setCodable(records, key: context.key, transaction: tx)
        } catch {
            owsFailDebug("Failed to touch avatar history \(error)")
        }
    }

    func recordModelForImage(_ image: UIImage, in context: Context, tx: DBWriteTransaction) -> AvatarModel? {
        OWSFileSystem.ensureDirectoryExists(imageHistoryDirectory.path)

        let identifier = UUID().uuidString
        let url = URL(fileURLWithPath: identifier + ".jpg", relativeTo: imageHistoryDirectory)

        guard let avatarData = OWSProfileManager.avatarData(avatarImage: image) else {
            owsFailDebug("avatarData was nil")
            return nil
        }
        do {
            try avatarData.write(to: url)
        } catch {
            owsFailDebug("Failed to record model for image \(error)")
            return nil
        }

        let model = AvatarModel(identifier: identifier, type: .image(url), theme: .default)
        touchedModel(model, in: context, tx: tx)
        return model
    }

    func models(
        for context: Context,
        tx: DBReadTransaction
    ) -> [AvatarModel] {
        let records: [AvatarRecord]?

        do {
            records = try keyValueStore.getCodableValue(forKey: context.key, transaction: tx)
        } catch {
            owsFailDebug("Failed to load persisted avatar records \(error)")
            records = nil
        }

        var models = [AvatarModel]()

        for record in records ?? [] {
            switch record.kind {
            case .icon:
                guard let icon = AvatarIcon(rawValue: record.identifier) else {
                    owsFailDebug("Invalid avatar icon \(record.identifier)")
                    continue
                }
                models.append(.init(
                    identifier: record.identifier,
                    type: .icon(icon),
                    theme: AvatarTheme(rawValue: record.theme) ?? .default
                ))
            case .image:
                guard let imageUrl = record.imageUrl, OWSFileSystem.fileOrFolderExists(url: imageUrl) else {
                    owsFailDebug("Invalid avatar image \(record.identifier)")
                    continue
                }
                models.append(.init(
                    identifier: record.identifier,
                    type: .image(imageUrl),
                    theme: AvatarTheme(rawValue: record.theme) ?? .default
                ))
            case .text:
                guard let text = record.text else {
                    owsFailDebug("Missing avatar text")
                    continue
                }
                models.append(.init(
                    identifier: record.identifier,
                    type: .text(text),
                    theme: AvatarTheme(rawValue: record.theme) ?? .default
                ))
            }
        }

        return models
    }
}

// We don't encode an AvatarModel directly to future proof
// us against changes to AvatarIcon, AvatarType, etc. enums
// since Codable is brittle when it encounters things it
// doesn't know about.
private struct AvatarRecord: Codable {
    enum Kind: String, Codable {
        case icon, text, image
    }
    let kind: Kind
    let identifier: String
    let imageUrl: URL?
    let text: String?
    let theme: String
}
