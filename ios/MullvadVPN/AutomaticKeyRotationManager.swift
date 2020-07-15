//
//  AutomaticKeyRotationManager.swift
//  MullvadVPN
//
//  Created by pronebird on 05/05/2020.
//  Copyright © 2020 Mullvad VPN AB. All rights reserved.
//

import Foundation
import os

/// A private key rotation retry interval on failure (in seconds)
private let kRetryIntervalOnFailure = 300

/// A private key rotation interval (in days)
private let kRotationInterval = 4

/// A struct describing the key rotation result
struct KeyRotationResult {
    var isNew: Bool
    var creationDate: Date
    var publicKey: WireguardPublicKey
}

class AutomaticKeyRotationManager {

    enum Error: ChainedError {
        /// REST error
        case rest(RestError)

        /// A failure to read the tunnel settings
        case readTunnelSettings(TunnelSettingsManager.Error)

        /// A failure to update tunnel settings
        case updateTunnelSettings(TunnelSettingsManager.Error)

        var errorDescription: String? {
            switch self {
            case .rest:
                return "REST error"
            case .readTunnelSettings:
                return "Read tunnel settings error"
            case .updateTunnelSettings:
                return "Update tunnel settings error"
            }
        }
    }

    private let rest = MullvadRest(session: URLSession(configuration: .ephemeral))
    private let persistentKeychainReference: Data

    /// A dispatch queue used for synchronization
    private let dispatchQueue = DispatchQueue(label: "net.mullvad.vpn.key-manager", qos: .utility)

    /// A timer source used to schedule a delayed key rotation
    private var timerSource: DispatchSourceTimer?

    /// Internal lock used for access synchronization to public members of this class
    private let stateLock = NSLock()

    /// Internal variable indicating that the key rotation has already started
    private var isAutomaticRotationEnabled = false

    /// A REST request for replacing the key on server
    private var request: URLSessionTask?

    /// A variable backing the `eventHandler` public property
    private var _eventHandler: ((KeyRotationResult) -> Void)?

    /// An event handler that's invoked when key rotation occurred
    var eventHandler: ((KeyRotationResult) -> Void)? {
        get {
            stateLock.withCriticalBlock {
                self._eventHandler
            }
        }
        set {
            stateLock.withCriticalBlock {
                self._eventHandler = newValue
            }
        }
    }

    init(persistentKeychainReference: Data) {
        self.persistentKeychainReference = persistentKeychainReference
    }

    func startAutomaticRotation(completionHandler: @escaping () -> Void) {
        dispatchQueue.async {
            guard !self.isAutomaticRotationEnabled else { return }

            os_log(.default, log: tunnelProviderLog, "Start automatic key rotation")

            self.isAutomaticRotationEnabled = true
            self.performKeyRotation()

            completionHandler()
        }
    }

    func stopAutomaticRotation(completionHandler: @escaping () -> Void) {
        dispatchQueue.async {
            guard self.isAutomaticRotationEnabled else { return }

            os_log(.default, log: tunnelProviderLog, "Stop automatic key rotation")

            self.isAutomaticRotationEnabled = false

            self.request?.cancel()
            self.request = nil

            self.timerSource?.cancel()

            completionHandler()
        }
    }

    private func performKeyRotation() {
        let result = TunnelSettingsManager.load(searchTerm: .persistentReference(persistentKeychainReference))

        switch result {
        case .success(let keychainEntry):
            let currentPrivateKey = keychainEntry.tunnelSettings.interface.privateKey

            if Self.shouldRotateKey(creationDate: currentPrivateKey.creationDate) {
                let result = makeReplaceKeyTask(accountToken: keychainEntry.accountToken, oldPublicKey: currentPrivateKey.publicKey) { (result) in
                    let result = result.map { (tunnelSettings) -> KeyRotationResult in
                        let newPrivateKey = tunnelSettings.interface.privateKey

                        return KeyRotationResult(
                            isNew: true,
                            creationDate: newPrivateKey.creationDate,
                            publicKey: newPrivateKey.publicKey
                        )
                    }

                    self.didCompleteKeyRotation(result: result)
                }

                switch result {
                case .success(let newTask):
                    self.request = newTask
                case .failure(let error):
                    self.request = nil
                    self.didCompleteKeyRotation(result: .failure(.rest(error)))
                }
            } else {
                let event = KeyRotationResult(
                    isNew: false,
                    creationDate: currentPrivateKey.creationDate,
                    publicKey: currentPrivateKey.publicKey
                )

                self.didCompleteKeyRotation(result: .success(event))
            }

        case .failure(let error):
            self.didCompleteKeyRotation(result: .failure(.readTunnelSettings(error)))
        }
    }

    private func makeReplaceKeyTask(
        accountToken: String,
        oldPublicKey: WireguardPublicKey,
        completionHandler: @escaping (Result<TunnelSettings, Error>) -> Void) -> Result<URLSessionDataTask, RestError>
    {
        let newPrivateKey = WireguardPrivateKey()
        let payload = TokenPayload(
            token: accountToken,
            payload: ReplaceWireguardKeyRequest(
                old: oldPublicKey.rawRepresentation,
                new: newPrivateKey.publicKey.rawRepresentation
            )
        )

        return rest.replaceWireguardKey().dataTask(payload: payload) { (result) in
            self.dispatchQueue.async {
                let updateResult = result.mapError { (error) -> Error in
                    return .rest(error)
                }.flatMap { (addresses) -> Result<TunnelSettings, Error> in
                    self.updateTunnelSettings(privateKey: newPrivateKey, addresses: addresses)
                }
                completionHandler(updateResult)
            }
        }
    }

    private func updateTunnelSettings(privateKey: WireguardPrivateKey, addresses: WireguardAssociatedAddresses) -> Result<TunnelSettings, Error> {
        let updateResult = TunnelSettingsManager.update(searchTerm: .persistentReference(self.persistentKeychainReference))
            { (tunnelSettings) in
                tunnelSettings.interface.privateKey = privateKey
                tunnelSettings.interface.addresses = [
                    addresses.ipv4Address,
                    addresses.ipv6Address
                ]
        }

        return updateResult.mapError { .updateTunnelSettings($0) }
    }

    private func didCompleteKeyRotation(result: Result<KeyRotationResult, Error>) {
        var nextRotationTime: DispatchWallTime?

        switch result {
        case .success(let event):
            if event.isNew {
                os_log(.default, log: tunnelProviderLog, "Finished private key rotation")

                eventHandler?(event)
            }

            if let rotationDate = Self.nextRotation(creationDate: event.creationDate) {
                let interval = rotationDate.timeIntervalSinceNow

                os_log(.default, log: tunnelProviderLog,
                       "Next private key rotation on %{public}s", "\(rotationDate)")

                nextRotationTime = .now() + .seconds(Int(interval))
            } else {
                os_log(.error, log: tunnelProviderLog,
                       "Failed to compute the next private rotation date. Retry in %d seconds.")

                nextRotationTime = .now() + .seconds(kRetryIntervalOnFailure)
            }

        case .failure(.rest(.network(let urlError))) where urlError.code == .cancelled:
            os_log(.default, log: tunnelProviderLog, "Key rotation was cancelled")
            break

        case .failure(let error):
            os_log(.error, log: tunnelProviderLog,
                   "Failed to rotate the private key: %{public}s. Retry in %d seconds.",
                   error.localizedDescription,
                   kRetryIntervalOnFailure)

            nextRotationTime = .now() + .seconds(kRetryIntervalOnFailure)
        }

        if let nextRotationTime = nextRotationTime, isAutomaticRotationEnabled {
            scheduleRetry(wallDeadline: nextRotationTime)
        }
    }

    private func scheduleRetry(wallDeadline: DispatchWallTime) {
        let timerSource = DispatchSource.makeTimerSource(queue: dispatchQueue)
        timerSource.setEventHandler { [weak self] in
            guard let self = self else { return }

            if self.isAutomaticRotationEnabled {
                self.performKeyRotation()
            }
        }

        timerSource.schedule(wallDeadline: wallDeadline)
        timerSource.activate()

        self.timerSource = timerSource
    }

    private class func nextRotation(creationDate: Date) -> Date? {
        return Calendar.current.date(byAdding: .day, value: kRotationInterval, to: creationDate)
    }

    private class func shouldRotateKey(creationDate: Date) -> Bool {
        return nextRotation(creationDate: creationDate)
            .map { $0 <= Date() } ?? false
    }

}
