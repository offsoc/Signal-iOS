//
// Copyright 2020 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import SignalServiceKit

class NSEEnvironment {
    let appReadiness: AppReadinessSetter
    let appContext: NSEContext

    init() {
        self.appContext = NSEContext()
        SetCurrentAppContext(self.appContext, isRunningTests: false)
        appReadiness = AppReadinessImpl()
    }

    // MARK: -

    var processingMessageCounter = AtomicUInt(0, lock: .sharedGlobal)
    var isProcessingMessages: Bool {
        processingMessageCounter.get() > 0
    }

    // MARK: - Main App Comms

    private static var mainAppDarwinQueue: DispatchQueue { .global(qos: .userInitiated) }

    func askMainAppToHandleReceipt(logger: NSELogger) async -> Bool {
        await withCheckedContinuation { continuation in
            _askMainAppToHandleReceipt(logger: logger, continuation: continuation)
        }
    }

    private func _askMainAppToHandleReceipt(logger: NSELogger, continuation: CheckedContinuation<Bool, Never>) {
        Self.mainAppDarwinQueue.async {
            // We track whether we've ever handled the call back to ensure
            // we only notify the caller once and avoid any races that may
            // occur between the notification observer and the dispatch
            // after block.
            let hasCalledBack = AtomicBool(false, lock: .sharedGlobal)

            // Listen for an indication that the main app is going to handle
            // this notification. If the main app is active we don't want to
            // process any messages here.
            let token = DarwinNotificationCenter.addObserver(name: .mainAppHandledNotification, queue: Self.mainAppDarwinQueue) { token in
                guard hasCalledBack.tryToSetFlag() else { return }

                if DarwinNotificationCenter.isValid(token) {
                    DarwinNotificationCenter.removeObserver(token)
                }

                if DebugFlags.internalLogging {
                    logger.info("Main app ack'd.")
                }

                continuation.resume(returning: true)
            }

            // Notify the main app that we received new content to process.
            // If it's running, it will notify us so we can bail out.
            DarwinNotificationCenter.postNotification(name: .nseDidReceiveNotification)

            // The main app should notify us nearly instantaneously if it's
            // going to process this notification so we only wait a fraction
            // of a second to hear back from it.
            Self.mainAppDarwinQueue.asyncAfter(deadline: DispatchTime.now() + 0.010) {
                guard hasCalledBack.tryToSetFlag() else { return }

                if DarwinNotificationCenter.isValid(token) {
                    DarwinNotificationCenter.removeObserver(token)
                }

                // If we haven't called back yet and removed the observer token,
                // the main app is not running and will not handle receipt of this
                // notification.
                continuation.resume(returning: false)
            }
        }
    }

    private var mainAppLaunchObserverToken = DarwinNotificationCenter.invalidObserverToken
    func listenForMainAppLaunch(logger: NSELogger) {
        guard !DarwinNotificationCenter.isValid(mainAppLaunchObserverToken) else { return }
        mainAppLaunchObserverToken = DarwinNotificationCenter.addObserver(name: .mainAppLaunched, queue: .global(), block: { _ in
            // If we're currently processing messages we want to commit
            // suicide to ensure that we don't try and process messages
            // while the main app is running. If we're not processing
            // messages we keep alive since future notifications will
            // be passed off gracefully to the main app. We only kill
            // ourselves as a last resort.
            // TODO: We could eventually make the message fetch process
            // cancellable to never have to exit here.
            logger.warn("Main app launched.")
            guard self.isProcessingMessages else { return }
            logger.warn("Exiting because main app launched while we were processing messages.")
            logger.flush()
            exit(0)
        })
    }

    // MARK: - Setup

    @MainActor private var didStartAppSetup = false
    @MainActor private var finalContinuation: AppSetup.FinalContinuation?

    /// Called for each notification the NSE receives.
    ///
    /// Will be invoked multiple times in the same NSE process.
    @MainActor
    func setUp(logger: NSELogger) {
        let debugLogger = DebugLogger.shared

        if !didStartAppSetup {
            debugLogger.enableFileLogging(appContext: appContext, canLaunchInBackground: true)
            debugLogger.enableTTYLoggingIfNeeded()
            DebugLogger.registerLibsignal()
            DebugLogger.registerRingRTC()
            didStartAppSetup = true
        }

        logger.info(
            "pid: \(ProcessInfo.processInfo.processIdentifier), memoryUsage: \(LocalDevice.memoryUsageString)",
            flushImmediately: true
        )
    }

    @MainActor
    func setUpDatabase(logger: NSELogger) async throws -> AppSetup.FinalContinuation {
        if let finalContinuation {
            return finalContinuation
        }

        let keychainStorage = KeychainStorageImpl(isUsingProductionService: TSConstants.isUsingProductionService)
        let databaseStorage = try SDSDatabaseStorage(
            appReadiness: appReadiness,
            databaseFileUrl: SDSDatabaseStorage.grdbDatabaseFileUrl,
            keychainStorage: keychainStorage
        )
        databaseStorage.grdbStorage.setUpDatabasePathKVO()

        let finalContinuation = await AppSetup().start(
            appContext: CurrentAppContext(),
            appReadiness: appReadiness,
            backupArchiveErrorPresenterFactory: NoOpBackupArchiveErrorPresenterFactory(),
            databaseStorage: databaseStorage,
            deviceBatteryLevelManager: nil,
            deviceSleepManager: nil,
            paymentsEvents: PaymentsEventsAppExtension(),
            mobileCoinHelper: MobileCoinHelperMinimal(),
            callMessageHandler: NSECallMessageHandler(),
            currentCallProvider: CurrentCallNoOpProvider(),
            notificationPresenter: NotificationPresenterImpl(),
            incrementalMessageTSAttachmentMigratorFactory: NoOpIncrementalMessageTSAttachmentMigratorFactory(),
        ).prepareDatabase()
        self.finalContinuation = finalContinuation

        listenForMainAppLaunch(logger: logger)

        return finalContinuation
    }

    @MainActor
    func setAppIsReady() {
        if appReadiness.isAppReady {
            return
        }

        // Note that this does much more than set a flag; it will also run all deferred blocks.
        appReadiness.setAppIsReady()

        AppVersionImpl.shared.nseLaunchDidComplete()
    }
}
