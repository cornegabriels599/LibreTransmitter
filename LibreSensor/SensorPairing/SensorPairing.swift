//
//  SensorPairing.swift
//  LibreDirect
//
//  Created by Reimar Metzen on 06.07.21.
//
import Foundation
import Combine


public class SensorPairingInfo: ObservableObject, Codable {
    @Published public var uuid: Data
    @Published public var patchInfo: Data
    @Published public var fram: Data
    @Published public var streamingEnabled: Bool

    @Published public var sensorName: String? = nil
    @Published public var macAddress: String? = nil
    /// Confirmed NFC activation time. BLE sensor age replaces this estimate
    /// as soon as the first packet arrives.
    @Published public var activatedAt: Date?

    enum CodingKeys: CodingKey {
        case uuid, patchInfo, fram, streamingEnabled, sensorName, macAddress, activatedAt
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(uuid, forKey: .uuid)
        try container.encode(patchInfo, forKey: .patchInfo)
        try container.encode(fram, forKey: .fram)
        try container.encode(streamingEnabled, forKey: .streamingEnabled)
        try container.encode(sensorName, forKey: .sensorName)
        try container.encode(macAddress, forKey: .macAddress)
        try container.encodeIfPresent(activatedAt, forKey: .activatedAt)
    }

    public required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        uuid = try container.decode(Data.self, forKey: .uuid)
        patchInfo = try container.decode(Data.self, forKey: .patchInfo)

        fram = try container.decode(Data.self, forKey: .fram)
        streamingEnabled = try container.decode(Bool.self, forKey: .streamingEnabled)
        sensorName = try container.decode(String?.self, forKey: .sensorName)
        macAddress = try container.decode(String?.self, forKey: .macAddress)
        activatedAt = try container.decodeIfPresent(Date.self, forKey: .activatedAt)
    }

    public init(
        uuid: Data = Data(),
        patchInfo: Data = Data(),
        fram: Data = Data(),
        streamingEnabled: Bool = false,
        sensorName: String? = nil,
        macAddress: String? = nil,
        activatedAt: Date? = nil
    ) {
        self.uuid = uuid
        self.patchInfo = patchInfo
        self.fram = fram
        self.streamingEnabled = streamingEnabled
        self.sensorName = sensorName
        self.macAddress = macAddress
        self.activatedAt = activatedAt
    }

    public var sensorData: SensorData? {
        SensorData(bytes: [UInt8](fram))
    }

    public var calibrationData: SensorData.CalibrationInfo? {
        sensorData?.calibrationData
    }

    public var description: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted

        do {
            let data = try encoder.encode(self) // convert user to json data here
            return String(data: data, encoding: .utf8)! // print to console
        } catch {
            return "SensorPairingInfoError"
        }
    }
}

public enum SensorPairingPhase: Equatable {
    case scanning
    case activating
    case sensorRestart(attempt: Int, maximumAttempts: Int)
    case confirmingFRAM
    case enablingStreaming
    case completed
    case activatedScanAgain
}

/// Transport-independent activation state used by the NFC service and focused tests.
public struct Libre2ActivationStateMachine {
    public enum State: Equatable {
        case awaitingSensorState
        case activating
        case activationAccepted
        case retrying(attempt: Int)
        case confirmed
        case scanAgain
        case failed
    }

    public enum Event {
        case sensorNotYetStarted
        case sensorAlreadyStarting
        case activationAccepted
        case activationRejected
        case transientReadFailure
        case confirmationSucceeded
        case sessionLost
        case retriesExhausted
    }

    public private(set) var state: State = .awaitingSensorState
    private let maximumRetries: Int

    public init(maximumRetries: Int) {
        self.maximumRetries = maximumRetries
    }

    @discardableResult
    public mutating func apply(_ event: Event) -> State {
        switch event {
        case .sensorNotYetStarted:
            state = .activating
        case .sensorAlreadyStarting:
            state = .confirmed
        case .activationAccepted:
            state = .activationAccepted
        case .activationRejected:
            state = .failed
        case .transientReadFailure:
            let nextAttempt: Int
            if case let .retrying(attempt) = state {
                nextAttempt = attempt + 1
            } else {
                nextAttempt = 1
            }
            state = nextAttempt <= maximumRetries ? .retrying(attempt: nextAttempt) : .scanAgain
        case .confirmationSucceeded:
            state = .confirmed
        case .sessionLost:
            switch state {
            case .activationAccepted, .retrying, .confirmed:
                state = .scanAgain
            default:
                state = .failed
            }
        case .retriesExhausted:
            state = .scanAgain
        }
        return state
    }
}

public protocol SensorPairingProtocol: AnyObject {
    var onCancel: (() -> Void)? { get set }
    var publisher: AnyPublisher<SensorPairingInfo, Never> { get }
    var errorPublisher: AnyPublisher<Error, Never> { get }
    var phasePublisher: AnyPublisher<SensorPairingPhase, Never> { get }
    func pairSensor() throws
}

/// Short-lived bridge between NFC activation and the first authoritative BLE age.
///
/// Records are UID-scoped and expire quickly, so an activation estimate cannot
/// leak into a replacement sensor. The first BLE packet reconciles and removes it.
public struct PendingLibre2Activation: Codable, Equatable {
    public static let maximumLifetime: TimeInterval = 2 * 60 * 60

    public let sensorUID: Data
    public let activatedAt: Date
    public let expiresAt: Date

    public init(sensorUID: Data, activatedAt: Date) {
        self.sensorUID = sensorUID
        self.activatedAt = activatedAt
        expiresAt = activatedAt.addingTimeInterval(Self.maximumLifetime)
    }

    public func isValid(for sensorUID: Data, at date: Date) -> Bool {
        self.sensorUID == sensorUID && date >= activatedAt && date < expiresAt
    }
}

public final class PendingLibre2ActivationStore {
    private static let key = "com.loopkit.libre2.pending-activation"
    private let defaults: UserDefaults
    private let now: () -> Date

    public init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
    }

    @discardableResult
    public func confirm(sensorUID: Data, at date: Date? = nil) -> Date {
        let confirmedAt = date ?? now()
        let record = PendingLibre2Activation(sensorUID: sensorUID, activatedAt: confirmedAt)
        defaults.set(try? JSONEncoder().encode(record), forKey: Self.key)
        return confirmedAt
    }

    public func activationDate(for sensorUID: Data) -> Date? {
        guard let data = defaults.data(forKey: Self.key),
              let record = try? JSONDecoder().decode(PendingLibre2Activation.self, from: data)
        else {
            defaults.removeObject(forKey: Self.key)
            return nil
        }
        guard record.isValid(for: sensorUID, at: now()) else {
            defaults.removeObject(forKey: Self.key)
            return nil
        }
        return record.activatedAt
    }

    public func reconcile(sensorUID: Data, authoritativeActivatedAt _: Date) {
        // Reading the scoped record first clears stale or different-sensor data.
        _ = activationDate(for: sensorUID)
        defaults.removeObject(forKey: Self.key)
    }

    public func clearIfDifferentSensor(from sensorUID: Data) {
        guard let data = defaults.data(forKey: Self.key),
              let record = try? JSONDecoder().decode(PendingLibre2Activation.self, from: data)
        else {
            defaults.removeObject(forKey: Self.key)
            return
        }
        if record.sensorUID != sensorUID {
            defaults.removeObject(forKey: Self.key)
        }
    }
}
