//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import GRDB

public protocol BackupAttachmentDownloadStore {

    /// "Enqueue" an attachment from a backup for download (using its reference).
    ///
    /// If the same attachment pointed to by the reference is already enqueued, updates it to the greater
    /// of the existing and new reference's timestamp.
    ///
    /// Doesn't actually trigger a download; callers must later call `dequeueAndClearTable` to insert
    /// rows into the normal AttachmentDownloadQueue, as this table serves only as an intermediary.
    ///
    /// - returns True IFF the attachment was previously enqueued for download, whether at higher
    /// or lower priority.
    func enqueue(_ reference: AttachmentReference, tx: DBWriteTransaction) throws -> Bool

    /// Returns whether a download is enqueued for a target attachment.
    func hasEnqueuedDownload(
        attachmentRowId: Attachment.IDType,
        tx: DBReadTransaction
    ) throws -> Bool

    /// Read the next highest priority downloads off the queue, up to count.
    /// Returns an empty array if nothing is left to download.
    func peek(count: UInt, tx: DBReadTransaction) throws -> [QueuedBackupAttachmentDownload]

    /// Remove the download from the queue. Should be called once downloaded (or permanently failed).
    func removeQueuedDownload(
        attachmentId: Attachment.IDType,
        tx: DBWriteTransaction
    ) throws

    /// Remove all enqueued downloads from the table.
    func removeAll(tx: DBWriteTransaction) throws

    /// Remove all enqueued downloads from the table for attachments older than the provided timestamp.
    func removeAll(olderThan timestamp: UInt64, tx: DBWriteTransaction) throws

    // MARK: Progress tracking cache

    /// We display the total byte count of backup attachment downloads. We want this number to remain consistent
    /// even as we download attachments and pop them off the queue. Once we do download an attachment, we
    /// don't keep state that it was downloaded because of backups. So we have to compute the total count once
    /// before downloading anything, and then use that cached value going forwards.
    ///
    /// Only set this value when scheduling a fresh batch of backup downloads, namely:
    /// 1. When restoring from a backup
    /// 2. When turning "media optimization" off (requires downloading older, previously offloaded, attachments)
    /// 3. When disabling backups (and therefore downloading all attachments)
    func setTotalPendingDownloadByteCount(_ byteCount: UInt64?, tx: DBWriteTransaction)

    /// See documentation for `setTotalPendingDownloadByteCount`.
    func getTotalPendingDownloadByteCount(tx: DBReadTransaction) -> UInt64?

    /// Cached value for the remaining bytes to download of backup attachments. Updated as attachments
    /// are downloaded.
    /// Computing the remaining byte count is expensive (requires a table join) so we cache the latest value
    /// to have it available immediately for UI population on app launch.
    func setCachedRemainingPendingDownloadByteCount(_ byteCount: UInt64?, tx: DBWriteTransaction)

    /// See documentation for `setCachedRemainingPendingDownloadByteCount`.
    func getCachedRemainingPendingDownloadByteCount(tx: DBReadTransaction) -> UInt64?

    /// Whether the banner for downloads being complete was dismissed. Reset when new downloads
    /// are scheduled (when `setTotalPendingDownloadByteCount` is set.)
    func getDidDismissDownloadCompleteBanner(tx: DBReadTransaction) -> Bool

    func setDidDismissDownloadCompleteBanner(tx: DBWriteTransaction)
}

public class BackupAttachmentDownloadStoreImpl: BackupAttachmentDownloadStore {

    private let kvStore: KeyValueStore

    public init() {
        self.kvStore = KeyValueStore(collection: "BackupAttachmentDownloadStoreImpl")
    }

    public func enqueue(_ reference: AttachmentReference, tx: DBWriteTransaction) throws -> Bool {
        let db = tx.database
        let timestamp: UInt64? = {
            switch reference.owner {
            case .message(let messageSource):
                return messageSource.receivedAtTimestamp
            case .storyMessage, .thread:
                return nil
            }
        }()

        let existingRecord = try QueuedBackupAttachmentDownload
            .filter(Column(QueuedBackupAttachmentDownload.CodingKeys.attachmentRowId) == reference.attachmentRowId)
            .fetchOne(db)

        if
            let existingRecord,
            existingRecord.timestamp ?? .max < timestamp ?? .max
        {
            // If we have an existing record with a smaller timestamp,
            // delete it in favor of the new row we are about to insert.
            // (nil timestamp counts as the largest timestamp)
            try existingRecord.delete(db)
        } else if existingRecord != nil {
            // Otherwise we had an existing record with a larger
            // timestamp, stop.
            return true
        }

        var record = QueuedBackupAttachmentDownload(
            attachmentRowId: reference.attachmentRowId,
            timestamp: timestamp
        )
        try record.insert(db)

        return existingRecord != nil
    }

    public func hasEnqueuedDownload(
        attachmentRowId: Attachment.IDType,
        tx: DBReadTransaction
    ) throws -> Bool {
        let existingRecord = try QueuedBackupAttachmentDownload
            .filter(Column(QueuedBackupAttachmentDownload.CodingKeys.attachmentRowId) == attachmentRowId)
            .fetchOne(tx.database)

        return existingRecord != nil
    }

    public func peek(
        count: UInt,
        tx: DBReadTransaction
    ) throws -> [QueuedBackupAttachmentDownload] {
        let db = tx.database
        return try QueuedBackupAttachmentDownload
            // We want to dequeue in _reverse_ insertion order.
            .order([Column(QueuedBackupAttachmentDownload.CodingKeys.id).desc])
            .limit(Int(count))
            .fetchAll(db)
    }

    public func removeQueuedDownload(
        attachmentId: Attachment.IDType,
        tx: DBWriteTransaction
    ) throws {
        let db = tx.database
        try QueuedBackupAttachmentDownload
            .filter(Column(QueuedBackupAttachmentDownload.CodingKeys.id) == attachmentId)
            .deleteAll(db)
    }

    public func removeAll(tx: DBWriteTransaction) throws {
        try QueuedBackupAttachmentDownload.deleteAll(tx.database)
    }

    public func removeAll(olderThan timestamp: UInt64, tx: DBWriteTransaction) throws {
        try QueuedBackupAttachmentDownload
            .filter(Column(QueuedBackupAttachmentDownload.CodingKeys.timestamp) != nil)
            .filter(Column(QueuedBackupAttachmentDownload.CodingKeys.timestamp) < timestamp)
            .deleteAll(tx.database)
    }

    private let totalPendingDownloadByteCountKey = "totalPendingDownloadByteCountKey"
    private let cachedRemainingPendingDownloadByteCountKey = "cachedRemainingPendingDownloadByteCountKey"
    private let didDismissDownloadCompleteBannerKey = "didDismissDownloadCompleteBannerKey"

    public func setTotalPendingDownloadByteCount(_ byteCount: UInt64?, tx: DBWriteTransaction) {
        if let byteCount {
            kvStore.setUInt64(byteCount, key: totalPendingDownloadByteCountKey, transaction: tx)
        } else {
            kvStore.removeValue(forKey: totalPendingDownloadByteCountKey, transaction: tx)
        }
        kvStore.setBool(false, key: didDismissDownloadCompleteBannerKey, transaction: tx)
    }

    public func getTotalPendingDownloadByteCount(tx: DBReadTransaction) -> UInt64? {
        return kvStore.getUInt64(totalPendingDownloadByteCountKey, transaction: tx)
    }

    public func setCachedRemainingPendingDownloadByteCount(_ byteCount: UInt64?, tx: DBWriteTransaction) {
        if let byteCount {
            kvStore.setUInt64(byteCount, key: cachedRemainingPendingDownloadByteCountKey, transaction: tx)
        } else {
            kvStore.removeValue(forKey: cachedRemainingPendingDownloadByteCountKey, transaction: tx)
        }
    }

    public func getCachedRemainingPendingDownloadByteCount(tx: DBReadTransaction) -> UInt64? {
        return kvStore.getUInt64(cachedRemainingPendingDownloadByteCountKey, transaction: tx)
    }

    public func getDidDismissDownloadCompleteBanner(tx: DBReadTransaction) -> Bool {
        return kvStore.getBool(didDismissDownloadCompleteBannerKey, defaultValue: false, transaction: tx)
    }

    public func setDidDismissDownloadCompleteBanner(tx: DBWriteTransaction) {
        kvStore.setBool(true, key: didDismissDownloadCompleteBannerKey, transaction: tx)
    }
}
