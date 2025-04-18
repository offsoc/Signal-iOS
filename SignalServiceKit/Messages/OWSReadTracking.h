//
// Copyright 2017 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

NS_ASSUME_NONNULL_BEGIN

@class DBWriteTransaction;
@class TSThread;

typedef NS_CLOSED_ENUM(NSInteger, OWSReceiptCircumstance) {
    OWSReceiptCircumstanceOnLinkedDevice,
    OWSReceiptCircumstanceOnLinkedDeviceWhilePendingMessageRequest,
    OWSReceiptCircumstanceOnThisDevice,
    OWSReceiptCircumstanceOnThisDeviceWhilePendingMessageRequest
};

/**
 * Some interactions track read/unread status.
 * e.g. incoming messages and call notifications
 */
@protocol OWSReadTracking <NSObject>

/**
 * Has the local user seen the interaction?
 */
@property (nonatomic, readonly, getter=wasRead) BOOL read;

@property (nonatomic, readonly) NSString *uniqueId;
@property (nonatomic, readonly) uint64_t expireStartedAt;
@property (nonatomic, readonly) uint64_t sortId;
@property (nonatomic, readonly) NSString *uniqueThreadId;


/**
 * Used both for *responding* to a remote read receipt and in response to the local user's activity.
 */
- (void)markAsReadAtTimestamp:(uint64_t)readTimestamp
                       thread:(TSThread *)thread
                 circumstance:(OWSReceiptCircumstance)circumstance
     shouldClearNotifications:(BOOL)shouldClearNotifications
                  transaction:(DBWriteTransaction *)transaction;

@end

NS_ASSUME_NONNULL_END
