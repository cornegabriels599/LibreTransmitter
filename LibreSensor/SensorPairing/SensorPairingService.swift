import Combine
import CoreNFC
import Foundation

public enum PairingError: Error {
    case noTagInfo
    case noSensorData
    case wrongSensorType
    case decryptionError
    case noPatchInfo
    case nfcNotSupported
    case activationFailed
    case sensorRestartFailed
    case framConfirmationFailed
    case streamingEnableFailed
    case sensorActivatedScanAgain
    case unexpectedSensorState
}

extension PairingError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .noTagInfo:
            return LocalizedString("Could not get tag info", comment: "error description for PairingError.noTagInfo")
        case .noSensorData:
            return LocalizedString("Could not get sensor data", comment: "error description for PairingError.noSensorData")
        case .wrongSensorType:
            return LocalizedString("Wrong sensor type detected", comment: "error description for PairingError.wrongSensorType")
        case .decryptionError:
            return LocalizedString(
                "Could not decrypt sensor contents",
                comment: "error description for PairingError.decryptionError"
            )
        case .noPatchInfo:
            return LocalizedString("Could not get patch info", comment: "error description for PairingError.noPatchInfo")
        case .nfcNotSupported:
            return LocalizedString("Phone NFC not supported!", comment: "error description for PairingError.nfcNotSupported")
        case .activationFailed:
            return LocalizedString(
                "Could not activate Libre 2 sensor",
                comment: "error description for PairingError.activationFailed"
            )
        case .sensorRestartFailed:
            return LocalizedString(
                "Sensor restart could not be completed",
                comment: "error description for PairingError.sensorRestartFailed"
            )
        case .framConfirmationFailed:
            return LocalizedString(
                "Could not confirm the Libre 2 sensor state",
                comment: "error description for PairingError.framConfirmationFailed"
            )
        case .streamingEnableFailed:
            return LocalizedString(
                "Could not enable Libre 2 Bluetooth streaming",
                comment: "error description for PairingError.streamingEnableFailed"
            )
        case .sensorActivatedScanAgain:
            return LocalizedString(
                "Sensor activated; scan again to finish setup",
                comment: "partial success after Libre 2 activation"
            )
        case .unexpectedSensorState:
            return LocalizedString(
                "Unexpected Libre 2 sensor state",
                comment: "error description for PairingError.unexpectedSensorState"
            )
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .nfcNotSupported:
            return LocalizedString(
                "Your phone or app is not enabled for NFC communications, which is needed to pair to libre2 sensors",
                comment: "Recovery suggestion for PairingError.nfcNotSupported"
            )
        default:
            return nil
        }
    }
}

public class SensorPairingService: NSObject, NFCTagReaderSessionDelegate, SensorPairingProtocol {
    private static let maximumPostActivationAttempts = 3
    private static let postActivationBackoff: [TimeInterval] = [1, 2, 3]

    private var session: NFCTagReaderSession?
    private var readingsSubject = PassthroughSubject<SensorPairingInfo, Never>()
    private var errorSubject = PassthroughSubject<Error, Never>()
    private var phaseSubject = PassthroughSubject<SensorPairingPhase, Never>()
    private var isHandlingTag = false
    private var activationConfirmed = false
    private var pairingCompleted = false
    private var terminalErrorSent = false
    private var confirmedActivationDate: Date?
    private var activationStateMachine = Libre2ActivationStateMachine(
        maximumRetries: SensorPairingService.maximumPostActivationAttempts
    )
    private let activationStore = PendingLibre2ActivationStore()

    private let nfcQueue = DispatchQueue(label: "libre-direct.nfc-queue")
    private let accessQueue = DispatchQueue(label: "libre-direct.nfc-access-queue")

    private let unlockCode: UInt32 = 42 // 42

    public var onCancel: (() -> Void)?

    public func pairSensor() throws {
        if !Features.phoneNFCAvailable {
            throw PairingError.nfcNotSupported
        }
        isHandlingTag = false
        activationConfirmed = false
        pairingCompleted = false
        terminalErrorSent = false
        confirmedActivationDate = nil
        activationStateMachine = Libre2ActivationStateMachine(
            maximumRetries: Self.maximumPostActivationAttempts
        )
        sendPhase(.scanning, event: "pairing_requested")

        if NFCTagReaderSession.readingAvailable {
            accessQueue.async {
                self.session = NFCTagReaderSession(pollingOption: .iso15693, delegate: self, queue: self.nfcQueue)
                self.session?.alertMessage = LocalizedString("Hold the top of your iPhone near the sensor to pair", comment: "")
                self.session?.begin()
            }
        }
    }

    public var publisher: AnyPublisher<SensorPairingInfo, Never> {
        readingsSubject.eraseToAnyPublisher()
    }

    public var errorPublisher: AnyPublisher<Error, Never> {
        errorSubject.eraseToAnyPublisher()
    }

    public var phasePublisher: AnyPublisher<SensorPairingPhase, Never> {
        phaseSubject.eraseToAnyPublisher()
    }

    private func sendError(_ error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.errorSubject.send(error)
        }
    }

    private func sendUpdate(_ info: SensorPairingInfo) {
        DispatchQueue.main.async { [weak self] in
            self?.readingsSubject.send(info)
        }
    }

    private func sendPhase(_ phase: SensorPairingPhase, event: String) {
        logNFC("phase=\(phase) event=\(event)")
        DispatchQueue.main.async { [weak self] in
            self?.phaseSubject.send(phase)
        }
    }

    public func tagReaderSessionDidBecomeActive(_: NFCTagReaderSession) {
        sendPhase(.scanning, event: "session_active")
    }

    public func tagReaderSession(_: NFCTagReaderSession, didInvalidateWithError error: Error) {
        if activationConfirmed, !pairingCompleted, !terminalErrorSent {
            activationStateMachine.apply(.sessionLost)
            terminalErrorSent = true
            sendPhase(.activatedScanAgain, event: "session_lost_after_activation")
            sendError(PairingError.sensorActivatedScanAgain)
        }
        if let error = error as? NFCReaderError, error.code != .readerSessionInvalidationErrorUserCanceled {
            logNFC("phase=session event=invalidated code=\(error.code.rawValue)")
            if !terminalErrorSent {
                terminalErrorSent = true
                sendError(error)
            }
        }

        onCancel?()
    }

    public func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        guard !isHandlingTag else {
            logNFC("phase=scanning event=duplicate_tag_ignored")
            return
        }
        guard let firstTag = tags.first else { return }
        guard case let .iso15693(tag) = firstTag else { return }
        isHandlingTag = true

        session.connect(to: firstTag) { error in
            if let error {
                self.logNFC("phase=connection event=failed error=\(type(of: error))")
                self.failPairing(session: session, error: .noTagInfo)
                return
            }

            tag.getSystemInfo(requestFlags: [.address, .highDataRate]) { result in
                switch result {
                case let .failure(error):
                    self.logNFC("phase=identification event=system_info_failed error=\(type(of: error))")
                    self.failPairing(session: session, error: .noTagInfo)
                    return
                case .success:
                    tag
                        .customCommand(requestFlags: .highDataRate, customCommandCode: 0xA1,
                                       customRequestParameters: Data()) { response, error in
                            if let error {
                                self.logNFC("phase=identification event=patch_info_failed error=\(type(of: error))")
                                self.failPairing(session: session, error: .noPatchInfo)
                                return
                            }

                            let sensorUID = Data(tag.identifier.reversed())
                            let patchInfo = response

                            guard sensorUID.count == 8 else {
                                self.logNFC("Libre2 NFC: unexpected UID length: \(sensorUID.count)")
                                self.failPairing(session: session, error: .noSensorData)
                                return
                            }

                            guard patchInfo.count >= 6 else {
                                self.logNFC("phase=identification event=patch_info_too_short length=\(patchInfo.count)")
                                self.failPairing(session: session, error: .noPatchInfo)
                                return
                            }

                            let sensorType = SensorType(patchInfo: patchInfo)
                            self.logNFC("phase=identification event=supported_sensor type=\(sensorType)")

                            guard sensorType == .libre2 else {
                                self.logNFC("Libre2 NFC: wrong sensor type detected: \(sensorType)")
                                self.failPairing(session: session, error: .wrongSensorType)
                                return
                            }

                            self
                                .readSensorData(tag: tag, sensorUID: sensorUID, patchInfo: patchInfo,
                                                sensorType: sensorType) { initialResult in
                                    switch initialResult {
                                    case .failure:
                                        self.failPairing(session: session, error: .framConfirmationFailed)
                                    case let .success(initial):
                                        self.finishPairing(
                                            tag: tag,
                                            session: session,
                                            sensorUID: sensorUID,
                                            patchInfo: patchInfo,
                                            sensorType: sensorType,
                                            initialSensorData: initial.sensorData
                                        )
                                    }
                                }
                        }
                }
            }
        }
    }

    private func finishPairing(
        tag: NFCISO15693Tag,
        session: NFCTagReaderSession,
        sensorUID: Data,
        patchInfo: Data,
        sensorType: SensorType,
        initialSensorData: SensorData
    ) {
        logNFC("phase=fram_confirmation event=initial_state state=\(initialSensorData.state.description)")
        prepareSensorForStreaming(
            tag: tag,
            session: session,
            sensorUID: sensorUID,
            patchInfo: patchInfo,
            sensorType: sensorType,
            sensorData: initialSensorData
        ) { preparedResult in
            switch preparedResult {
            case let .failure(error):
                self.failPairing(session: session, error: error)
            case let .success(preparedSensorData):
                self.enableStreaming(tag: tag, sensorUID: sensorUID, patchInfo: patchInfo) { streamingResult in
                    switch streamingResult {
                    case let .failure(error):
                        self.failPairing(session: session, error: error)
                    case let .success(macAddress):
                        self.pairingCompleted = true
                        self.sendPhase(.completed, event: "streaming_enabled")
                        self.sendUpdate(SensorPairingInfo(
                            uuid: sensorUID,
                            patchInfo: patchInfo,
                            fram: Data(preparedSensorData.bytes),
                            streamingEnabled: true,
                            macAddress: macAddress,
                            activatedAt: self.confirmedActivationDate
                        ))
                        session.invalidate()
                    }
                }
            }
        }
    }

    private func prepareSensorForStreaming(
        tag: NFCISO15693Tag,
        session: NFCTagReaderSession,
        sensorUID: Data,
        patchInfo: Data,
        sensorType: SensorType,
        sensorData: SensorData,
        completion: @escaping (Result<SensorData, PairingError>) -> Void
    ) {
        switch sensorData.state {
        case .notYetStarted:
            activationStateMachine.apply(.sensorNotYetStarted)
            sendPhase(.activating, event: "activation_required")
            sendSubcommand(.activate, tag: tag, sensorUID: sensorUID, patchInfo: patchInfo) { result in
                switch result {
                case let .failure(error):
                    self.activationStateMachine.apply(.activationRejected)
                    self.logNFC("phase=activation event=rejected error=\(type(of: error))")
                    completion(.failure(.activationFailed))
                case .success:
                    self.activationStateMachine.apply(.activationAccepted)
                    self.activationConfirmed = true
                    self.confirmedActivationDate = self.activationStore.confirm(sensorUID: sensorUID)
                    self.logNFC("phase=activation event=accepted")
                    session.alertMessage = LocalizedString("Sensor activated. Checking sensor status...", comment: "")
                    self.confirmActivationAfterRestart(
                        tag: tag,
                        session: session,
                        sensorUID: sensorUID,
                        patchInfo: patchInfo,
                        sensorType: sensorType,
                        attempt: 1,
                        completion: completion
                    )
                }
            }
        case .starting, .ready:
            activationStateMachine.apply(.sensorAlreadyStarting)
            activationConfirmed = true
            if let pendingDate = activationStore.activationDate(for: sensorUID) {
                confirmedActivationDate = pendingDate
                logNFC("phase=activation event=confirmed_from_pending state=\(sensorData.state.description)")
            } else {
                let inferredActivationDate = Date().addingTimeInterval(
                    TimeInterval(minutes: -Double(max(sensorData.minutesSinceStart, 0)))
                )
                confirmedActivationDate = inferredActivationDate
                if Date().timeIntervalSince(inferredActivationDate) < PendingLibre2Activation.maximumLifetime {
                    activationStore.confirm(sensorUID: sensorUID, at: inferredActivationDate)
                }
                logNFC("phase=activation event=confirmed_from_fram state=\(sensorData.state.description)")
            }
            completion(.success(sensorData))
        default:
            logNFC("Libre2 NFC: unexpected sensor status before streaming: \(sensorData.state.description)")
            completion(.failure(.unexpectedSensorState))
        }
    }

    private func confirmActivationAfterRestart(
        tag: NFCISO15693Tag,
        session: NFCTagReaderSession,
        sensorUID: Data,
        patchInfo: Data,
        sensorType: SensorType,
        attempt: Int,
        completion: @escaping (Result<SensorData, PairingError>) -> Void
    ) {
        let maximumAttempts = Self.maximumPostActivationAttempts
        guard attempt <= maximumAttempts else {
            activationStateMachine.apply(.retriesExhausted)
            sendPhase(.activatedScanAgain, event: "restart_retry_exhausted")
            completion(.failure(.sensorActivatedScanAgain))
            return
        }

        sendPhase(.sensorRestart(attempt: attempt, maximumAttempts: maximumAttempts), event: "retry_scheduled")
        let delay = Self.postActivationBackoff[min(attempt - 1, Self.postActivationBackoff.count - 1)]
        nfcQueue.asyncAfter(deadline: .now() + delay) {
            session.connect(to: .iso15693(tag)) { connectionError in
                if let connectionError {
                    self.activationStateMachine.apply(.transientReadFailure)
                    self
                        .logNFC(
                            "phase=sensor_restart event=reconnect_failed attempt=\(attempt) error=\(type(of: connectionError))"
                        )
                    self.confirmActivationAfterRestart(
                        tag: tag,
                        session: session,
                        sensorUID: sensorUID,
                        patchInfo: patchInfo,
                        sensorType: sensorType,
                        attempt: attempt + 1,
                        completion: completion
                    )
                    return
                }

                self.sendPhase(.confirmingFRAM, event: "reconnected")
                self.readSensorData(
                    tag: tag,
                    sensorUID: sensorUID,
                    patchInfo: patchInfo,
                    sensorType: sensorType
                ) { rereadResult in
                    switch rereadResult {
                    case let .failure(error):
                        self.activationStateMachine.apply(.transientReadFailure)
                        self.logNFC("phase=fram_confirmation event=read_failed attempt=\(attempt) error=\(error)")
                        self.confirmActivationAfterRestart(
                            tag: tag,
                            session: session,
                            sensorUID: sensorUID,
                            patchInfo: patchInfo,
                            sensorType: sensorType,
                            attempt: attempt + 1,
                            completion: completion
                        )
                    case let .success(reread):
                        let state = reread.sensorData.state
                        self.logNFC("phase=fram_confirmation event=state_read state=\(state.description)")
                        guard state == .starting || state == .ready else {
                            completion(.failure(.framConfirmationFailed))
                            return
                        }
                        self.activationStateMachine.apply(.confirmationSucceeded)
                        completion(.success(reread.sensorData))
                    }
                }
            }
        }
    }

    private func enableStreaming(
        tag: NFCISO15693Tag,
        sensorUID: Data,
        patchInfo: Data,
        completion: @escaping (Result<String, PairingError>) -> Void
    ) {
        sendPhase(.enablingStreaming, event: "command_started")
        sendSubcommand(.enableStreaming, tag: tag, sensorUID: sensorUID, patchInfo: patchInfo) { result in
            switch result {
            case let .failure(error):
                self.logNFC("Libre2 NFC: enable streaming failed: \(error.localizedDescription)")
                completion(.failure(.streamingEnableFailed))
            case let .success(response):
                guard response.count == 6 else {
                    self.logNFC("phase=streaming_setup event=unexpected_response length=\(response.count)")
                    completion(.failure(.streamingEnableFailed))
                    return
                }

                let macAddress = Data(response.reversed()).hexEncodedString().uppercased()
                completion(.success(macAddress))
            }
        }
    }

    private func sendSubcommand(
        _ subcommand: Subcommand,
        tag: NFCISO15693Tag,
        sensorUID: Data,
        patchInfo: Data,
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        let cmd = nfcCommand(subcommand, unlockCode: unlockCode, patchInfo: patchInfo, sensorUID: sensorUID)
        tag.customCommand(
            requestFlags: .highDataRate,
            customCommandCode: Int(cmd.code),
            customRequestParameters: cmd.parameters
        ) { response, error in
            if let error {
                self.logNFC("Libre2 NFC: \(subcommand) NFC error: \(error.localizedDescription)")
                completion(.failure(error))
                return
            }

            completion(.success(response))
        }
    }

    private func readSensorData(
        tag: NFCISO15693Tag,
        sensorUID: Data,
        patchInfo: Data,
        sensorType: SensorType,
        completion: @escaping (Result<(fram: Data, sensorData: SensorData), PairingError>) -> Void
    ) {
        readFRAM(tag: tag) { result in
            switch result {
            case let .failure(error):
                self.logNFC("Libre2 NFC: FRAM read failed: \(error.localizedDescription)")
                completion(.failure(.noSensorData))
            case let .success(fram):
                guard fram.count == 344 else {
                    self.logNFC("Libre2 NFC: unexpected FRAM length: \(fram.count)")
                    completion(.failure(.noSensorData))
                    return
                }

                do {
                    let decryptedBytes = try Libre2.decryptFRAM(
                        type: sensorType,
                        id: [UInt8](sensorUID),
                        info: patchInfo,
                        data: [UInt8](fram)
                    )

                    guard let sensorData = SensorData(uuid: sensorUID, bytes: decryptedBytes) else {
                        self.logNFC("Libre2 NFC: decrypted FRAM could not create SensorData")
                        completion(.failure(.noSensorData))
                        return
                    }

                    completion(.success((Data(decryptedBytes), sensorData)))
                } catch {
                    self.logNFC("Libre2 NFC: FRAM decryption failed: \(error.localizedDescription)")
                    completion(.failure(.decryptionError))
                }
            }
        }
    }

    private func readFRAM(tag: NFCISO15693Tag, completion: @escaping (Result<Data, Error>) -> Void) {
        let blocks = 43
        let requestBlocks = 3
        let requests = Int(ceil(Double(blocks) / Double(requestBlocks)))
        let remainder = blocks % requestBlocks

        var dataArray = [Data](repeating: Data(), count: blocks)
        func readRequest(_ i: Int) {
            guard i < requests else {
                completion(.success(dataArray.reduce(Data(), +)))
                return
            }
            let blockCount = i == requests - 1 ? (remainder == 0 ? requestBlocks : remainder) : requestBlocks
            let startBlock = i * requestBlocks
            let endBlock = startBlock + blockCount - 1

            tag.readMultipleBlocks(
                requestFlags: [.highDataRate, .address],
                blockRange: NSRange(UInt8(startBlock) ... UInt8(endBlock))
            ) { blockArray, error in
                if let error {
                    self.logNFC("phase=fram_read event=block_failure request=\(i + 1) error=\(type(of: error))")
                    completion(.failure(error))
                    return
                }

                for j in 0 ..< blockArray.count where startBlock + j < dataArray.count {
                    dataArray[startBlock + j] = blockArray[j]
                }
                readRequest(i + 1)
            }
        }
        readRequest(0)
    }

    private func failPairing(session: NFCTagReaderSession, error: PairingError) {
        guard !terminalErrorSent else { return }
        terminalErrorSent = true
        logNFC("phase=pairing event=failed error=\(error)")
        if case .sensorActivatedScanAgain = error {
            sendPhase(.activatedScanAgain, event: "rescan_required")
        }
        session.invalidate(errorMessage: error.localizedDescription)
        sendError(error)
    }

    private func logNFC(_ message: String) {
        print("[Libre2Pairing] \(message)")
    }

    private func readRaw(
        _ address: UInt16,
        _ bytes: Int,
        buffer: Data = Data(),
        tag: NFCISO15693Tag,
        handler: @escaping (UInt16, Data, Error?) -> Void
    ) {
        var buffer = buffer
        let addressToRead = address + UInt16(buffer.count)

        var remainingBytes = bytes
        let bytesToRead = remainingBytes > 24 ? 24 : bytes

        var remainingWords = bytes / 2
        if bytes % 2 == 1 || (bytes % 2 == 0 && addressToRead % 2 == 1) { remainingWords += 1 }
        let wordsToRead = UInt8(remainingWords > 12 ? 12 : remainingWords) // real limit is 15

        // this is for libre 2 only, ignoring other libre types
        let readRawCommand = NFCCommand(
            code: 0xB3,
            parameters: Data([UInt8(addressToRead & 0x00FF), UInt8(addressToRead >> 8), wordsToRead])
        )

        tag.customCommand(
            requestFlags: .highDataRate,
            customCommandCode: Int(readRawCommand.code),
            customRequestParameters: readRawCommand.parameters
        ) { response, error in
            var data = response

            if error != nil {
                remainingBytes = 0
            } else {
                if addressToRead % 2 == 1 { data = data.subdata(in: 1 ..< data.count) }
                if data.count - Int(bytesToRead) == 1 { data = data.subdata(in: 0 ..< data.count - 1) }
            }

            buffer += data
            remainingBytes -= data.count

            if remainingBytes == 0 {
                handler(address, buffer, error)
            } else {
                self
                    .readRaw(address, remainingBytes, buffer: buffer, tag: tag) { address, data, error in
                        handler(address, data, error)
                    }
            }
        }
    }

    private func writeRaw(
        _ address: UInt16,
        _ data: Data,
        tag: NFCISO15693Tag,
        handler: @escaping (UInt16, Data, Error?) -> Void
    ) {
        let backdoor = "deadbeef".utf8

        tag.customCommand(requestFlags: .highDataRate, customCommandCode: 0xA4, customRequestParameters: Data(backdoor)) {
            _, error in

            let addressToRead = (address / 8) * 8
            let startOffset = Int(address % 8)
            let endAddressToRead = ((Int(address) + data.count - 1) / 8) * 8 + 7
            let blocksToRead = (endAddressToRead - Int(addressToRead)) / 8 + 1

            self.readRaw(addressToRead, blocksToRead * 8, tag: tag) { _, readData, error in
                if error != nil {
                    handler(address, data, error)
                    return
                }

                var bytesToWrite = readData
                bytesToWrite.replaceSubrange(startOffset ..< startOffset + data.count, with: data)

                let startBlock = Int(addressToRead / 8)
                let blocks = bytesToWrite.count / 8

                if address < 0xF860 { // lower than FRAM blocks
                    for i in 0 ..< blocks {
                        let blockToWrite = bytesToWrite[i * 8 ... i * 8 + 7]

                        // FIXME: doesn't work as the custom commands C1 or A5 for other chips
                        tag.extendedWriteSingleBlock(requestFlags: .highDataRate, blockNumber: startBlock + i, dataBlock: blockToWrite) { error in
                            if error != nil {
                                if i != blocks - 1 { return }
                            }

                            if i == blocks - 1 {
                                tag.customCommand(requestFlags: .highDataRate, customCommandCode: 0xA2, customRequestParameters: Data(backdoor)) { _, error in
                                    handler(address, data, error)
                                }
                            }
                        }
                    }

                } else { // address >= 0xF860: write to FRAM blocks
                    let requestBlocks = 2 // 3 doesn't work
                    let requests = Int(ceil(Double(blocks) / Double(requestBlocks)))
                    let remainder = blocks % requestBlocks
                    var blocksToWrite = [Data](repeating: Data(), count: blocks)

                    for i in 0 ..< blocks {
                        blocksToWrite[i] = Data(bytesToWrite[i * 8 ... i * 8 + 7])
                    }

                    for i in 0 ..< requests {
                        let startIndex = startBlock - 0xF860 / 8 + i * requestBlocks
                        let endIndex = startIndex + (i == requests - 1 ? (remainder == 0 ? requestBlocks : remainder) : requestBlocks) - (requestBlocks > 1 ? 1 : 0)
                        let blockRange = NSRange(UInt8(startIndex) ... UInt8(endIndex))

                        var dataBlocks = [Data]()
                        for j in startIndex ... endIndex { dataBlocks.append(blocksToWrite[j - startIndex]) }

                        // TODO: write to 16-bit addresses as the custom cummand C4 for other chips
                        tag.writeMultipleBlocks(requestFlags: [.highDataRate, .address], blockRange: blockRange, dataBlocks: dataBlocks) { error in // TEST
                            if error != nil {
                                if i != requests - 1 { return }
                            }

                            if i == requests - 1 {
                                // Lock
                                tag.customCommand(requestFlags: .highDataRate, customCommandCode: 0xA2, customRequestParameters: Data(backdoor)) {
                                    _, error in

                                    handler(address, data, error)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func nfcCommand(_ code: Subcommand, unlockCode: UInt32, patchInfo: Data, sensorUID: Data) -> NFCCommand {
        var b: [UInt8] = []
        var y: UInt16

        if code == .enableStreaming {
            // Enables Bluetooth on Libre 2. Returns peripheral MAC address to connect to.
            // unlockCode could be any 32 bit value. The unlockCode and sensor Uid / patchInfo
            // will have also to be provided to the login function when connecting to peripheral.
            b = [UInt8(unlockCode & 0xFF), UInt8((unlockCode >> 8) & 0xFF), UInt8((unlockCode >> 16) & 0xFF), UInt8((unlockCode >> 24) & 0xFF)]
            y = UInt16(patchInfo[4...5]) ^ UInt16(b[1], b[0])
        } else {
            y = 0x1b6a
        }

        let d = Libre2.usefulFunction(id: [UInt8](sensorUID), x: UInt16(code.rawValue), y: y)

        var parameters = Data([code.rawValue])

        if code == .enableStreaming {
            parameters += b
        }

        parameters += d

        return NFCCommand(code: 0xA1, parameters: parameters)
    }
}

extension UInt16 {
    init(_ high: UInt8, _ low: UInt8) {
        self = UInt16(high) << 8 + UInt16(low)
    }

    init(_ data: Data) {
        self = UInt16(data[data.startIndex + 1]) << 8 + UInt16(data[data.startIndex])
    }
}

private struct NFCCommand {
    let code: UInt8
    let parameters: Data
}

private enum Subcommand: UInt8, CustomStringConvertible {
    case activate = 0x1B
    case enableStreaming = 0x1E
    case unknown0x1a = 0x1A
    case unknown0x1c = 0x1C
    case unknown0x1d = 0x1D
    case unknown0x1f = 0x1F

    var description: String {
        switch self {
        case .activate: return "activate"
        case .enableStreaming: return "enable BLE streaming"
        default: return "[unknown: 0x\(String(format: "%x", rawValue))]"
        }
    }
}
