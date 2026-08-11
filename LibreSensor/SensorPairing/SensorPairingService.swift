//
//  SensorPairingService.swift
//  LibreDirect
//
//  Created by Reimar Metzen on 06.07.21.
//

import Foundation
import Combine
import CoreNFC

public enum PairingError: Error {
    case noTagInfo
    case noSensorData
    case wrongSensorType
    case decryptionError
    case noPatchInfo
    case nfcNotSupported
    case activationFailed
    case streamingEnableFailed
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
            return LocalizedString("Could not decrypt sensor contents", comment: "error description for PairingError.decryptionError")
        case .noPatchInfo:
            return LocalizedString("Could not get patch info", comment: "error description for PairingError.noPatchInfo")
        case .nfcNotSupported:
            return LocalizedString("Phone NFC not supported!", comment: "error description for PairingError.nfcNotSupported")
        case .activationFailed:
            return LocalizedString("Could not activate Libre 2 sensor", comment: "error description for PairingError.activationFailed")
        case .streamingEnableFailed:
            return LocalizedString("Could not enable Libre 2 Bluetooth streaming", comment: "error description for PairingError.streamingEnableFailed")
        case .unexpectedSensorState:
            return LocalizedString("Unexpected Libre 2 sensor state", comment: "error description for PairingError.unexpectedSensorState")
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .nfcNotSupported:
            return LocalizedString("Your phone or app is not enabled for NFC communications, which is needed to pair to libre2 sensors", comment: "Recovery suggestion for PairingError.nfcNotSupported")
        default:
            return nil
        }
    }
}

public class SensorPairingService: NSObject, NFCTagReaderSessionDelegate, SensorPairingProtocol {
    private var session: NFCTagReaderSession?
    private var readingsSubject = PassthroughSubject<SensorPairingInfo, Never>()
    private var errorSubject  = PassthroughSubject<Error, Never>()

    private let nfcQueue = DispatchQueue(label: "libre-direct.nfc-queue")
    private let accessQueue = DispatchQueue(label: "libre-direct.nfc-access-queue")

    private let unlockCode: UInt32 = 42 // 42

    public var onCancel: (() -> Void)?

    public func pairSensor() throws {
        if !Features.phoneNFCAvailable {
            throw PairingError.nfcNotSupported
        }
        print("Asked to pair sensor! phoneNFCAvailable: \(Features.phoneNFCAvailable)")

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

    public func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {
    }

    public func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
        if let error = error as? NFCReaderError, error.code != .readerSessionInvalidationErrorUserCanceled {
            session.invalidate(errorMessage: "Connection failure: \(error.localizedDescription)")
            self.sendError(error)
        }

        self.onCancel?()
    }

    public func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        guard let firstTag = tags.first else { return }
        guard case .iso15693(let tag) = firstTag else { return }

        session.connect(to: firstTag) { error in
            if let error {
                self.logNFC("Libre2 NFC: connection failed: \(error.localizedDescription)")
                session.invalidate(errorMessage: error.localizedDescription)
                self.sendError(error)
                return
            }

            tag.getSystemInfo(requestFlags: [.address, .highDataRate]) { result in
                switch result {
                case .failure(let error):
                    self.logNFC("Libre2 NFC: getSystemInfo failed: \(error.localizedDescription)")
                    session.invalidate(errorMessage: PairingError.noTagInfo.localizedDescription)
                    self.sendError(PairingError.noTagInfo)
                    return
                case .success:
                    tag.customCommand(requestFlags: .highDataRate, customCommandCode: 0xA1, customRequestParameters: Data()) { response, error in
                        if let error {
                            self.logNFC("Libre2 NFC: patchInfo command failed: \(error.localizedDescription)")
                            session.invalidate(errorMessage: PairingError.noPatchInfo.localizedDescription)
                            self.sendError(PairingError.noPatchInfo)
                            return
                        }

                        let sensorUID = Data(tag.identifier.reversed())
                        let patchInfo = response

                        guard sensorUID.count == 8 else {
                            self.logNFC("Libre2 NFC: unexpected UID length: \(sensorUID.count)")
                            session.invalidate(errorMessage: PairingError.noSensorData.localizedDescription)
                            self.sendError(PairingError.noSensorData)
                            return
                        }

                        guard patchInfo.count >= 6 else {
                            self.logNFC("Libre2 NFC: patchInfo too short: \(patchInfo.hexEncodedString())")
                            session.invalidate(errorMessage: PairingError.noPatchInfo.localizedDescription)
                            self.sendError(PairingError.noPatchInfo)
                            return
                        }

                        let sensorType = SensorType(patchInfo: patchInfo)
                        self.logNFC("Libre2 NFC: patchInfo: \(patchInfo.hexEncodedString()), sensorType: \(sensorType)")

                        guard sensorType == .libre2 else {
                            self.logNFC("Libre2 NFC: wrong sensor type detected: \(sensorType)")
                            session.invalidate(errorMessage: PairingError.wrongSensorType.localizedDescription)
                            self.sendError(PairingError.wrongSensorType)
                            return
                        }

                        self.readSensorData(tag: tag, sensorUID: sensorUID, patchInfo: patchInfo, sensorType: sensorType) { initialResult in
                            switch initialResult {
                            case .failure(let error):
                                self.failPairing(session: session, error: error)
                            case .success(let initial):
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
        logNFC("Libre2 NFC: sensor status before activation: \(initialSensorData.state.description)")
        prepareSensorForStreaming(
            tag: tag,
            session: session,
            sensorUID: sensorUID,
            patchInfo: patchInfo,
            sensorType: sensorType,
            sensorData: initialSensorData
        ) { preparedResult in
            switch preparedResult {
            case .failure(let error):
                self.failPairing(session: session, error: error)
            case .success(let preparedSensorData):
                self.enableStreaming(tag: tag, sensorUID: sensorUID, patchInfo: patchInfo) { streamingResult in
                    switch streamingResult {
                    case .failure(let error):
                        self.failPairing(session: session, error: error)
                    case .success(let macAddress):
                        self.logNFC("Libre2 NFC: streaming enabled, MAC: \(macAddress)")
                        self.sendUpdate(SensorPairingInfo(
                            uuid: sensorUID,
                            patchInfo: patchInfo,
                            fram: Data(preparedSensorData.bytes),
                            streamingEnabled: true,
                            macAddress: macAddress
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
            logNFC("Libre2 NFC: sensor requires activation")
            sendSubcommand(.activate, tag: tag, sensorUID: sensorUID, patchInfo: patchInfo) { result in
                switch result {
                case .failure(let error):
                    self.logNFC("Libre2 NFC: activation command failed: \(error.localizedDescription)")
                    completion(.failure(.activationFailed))
                case .success(let response):
                    self.logNFC("Libre2 NFC: activation command sent")
                    self.logNFC("Libre2 NFC: activation response: \(response.hexEncodedString())")
                    session.alertMessage = LocalizedString("Sensor activated. Checking sensor status...", comment: "")
                    self.nfcQueue.asyncAfter(deadline: .now() + 1.0) {
                        self.readSensorData(tag: tag, sensorUID: sensorUID, patchInfo: patchInfo, sensorType: sensorType) { rereadResult in
                            switch rereadResult {
                            case .failure(let error):
                                completion(.failure(error))
                            case .success(let reread):
                                self.logNFC("Libre2 NFC: sensor status after activation: \(reread.sensorData.state.description)")
                                guard reread.sensorData.state == .starting || reread.sensorData.state == .ready else {
                                    completion(.failure(.activationFailed))
                                    return
                                }
                                completion(.success(reread.sensorData))
                            }
                        }
                    }
                }
            }
        case .starting, .ready:
            completion(.success(sensorData))
        default:
            logNFC("Libre2 NFC: unexpected sensor status before streaming: \(sensorData.state.description)")
            completion(.failure(.unexpectedSensorState))
        }
    }

    private func enableStreaming(
        tag: NFCISO15693Tag,
        sensorUID: Data,
        patchInfo: Data,
        completion: @escaping (Result<String, PairingError>) -> Void
    ) {
        logNFC("Libre2 NFC: enabling BLE streaming")
        sendSubcommand(.enableStreaming, tag: tag, sensorUID: sensorUID, patchInfo: patchInfo) { result in
            switch result {
            case .failure(let error):
                self.logNFC("Libre2 NFC: enable streaming failed: \(error.localizedDescription)")
                completion(.failure(.streamingEnableFailed))
            case .success(let response):
                guard response.count == 6 else {
                    self.logNFC("Libre2 NFC: enable streaming returned unexpected response: \(response.hexEncodedString())")
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
            case .failure(let error):
                self.logNFC("Libre2 NFC: FRAM read failed: \(error.localizedDescription)")
                completion(.failure(.noSensorData))
            case .success(let fram):
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
        var firstError: Error?
        let group = DispatchGroup()

        for i in 0 ..< requests {
            let blockCount = i == requests - 1 ? (remainder == 0 ? requestBlocks : remainder) : requestBlocks
            let startBlock = i * requestBlocks
            let endBlock = startBlock + blockCount - 1

            group.enter()
            tag.readMultipleBlocks(
                requestFlags: [.highDataRate, .address],
                blockRange: NSRange(UInt8(startBlock) ... UInt8(endBlock))
            ) { blockArray, error in
                if let error {
                    self.logNFC("Libre2 NFC: read blocks \(startBlock)-\(endBlock) failed: \(error.localizedDescription)")
                    firstError = firstError ?? error
                } else {
                    for j in 0 ..< blockArray.count where startBlock + j < dataArray.count {
                        dataArray[startBlock + j] = blockArray[j]
                    }
                }
                group.leave()
            }
        }

        group.notify(queue: nfcQueue) {
            if let firstError {
                completion(.failure(firstError))
                return
            }

            let fram = dataArray.reduce(Data(), +)
            completion(.success(fram))
        }
    }

    private func failPairing(session: NFCTagReaderSession, error: PairingError) {
        logNFC("Libre2 NFC: pairing failed: \(error.localizedDescription)")
        session.invalidate(errorMessage: error.localizedDescription)
        sendError(error)
    }

    private func logNFC(_ message: String) {
        print(message)
    }

    private func readRaw(_ address: UInt16, _ bytes: Int, buffer: Data = Data(), tag: NFCISO15693Tag, handler: @escaping (UInt16, Data, Error?) -> Void) {
        
        var buffer = buffer
        let addressToRead = address + UInt16(buffer.count)

        var remainingBytes = bytes
        let bytesToRead = remainingBytes > 24 ? 24 : bytes

        var remainingWords = bytes / 2
        if bytes % 2 == 1 || (bytes % 2 == 0 && addressToRead % 2 == 1) { remainingWords += 1 }
        let wordsToRead = UInt8(remainingWords > 12 ? 12 : remainingWords) // real limit is 15

        // this is for libre 2 only, ignoring other libre types
        let readRawCommand = NFCCommand(code: 0xB3, parameters: Data([UInt8(addressToRead & 0x00FF), UInt8(addressToRead >> 8), wordsToRead]))

        tag.customCommand(requestFlags: .highDataRate, customCommandCode: Int(readRawCommand.code), customRequestParameters: readRawCommand.parameters) { response, error in
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
                self.readRaw(address, remainingBytes, buffer: buffer, tag: tag) { address, data, error in handler(address, data, error) }
            }
        }
    }

    private func writeRaw(_ address: UInt16, _ data: Data, tag: NFCISO15693Tag, handler: @escaping (UInt16, Data, Error?) -> Void) {
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
    case activate = 0x1b
    case enableStreaming = 0x1e
    case unknown0x1a = 0x1a
    case unknown0x1c = 0x1c
    case unknown0x1d = 0x1d
    case unknown0x1f = 0x1f

    var description: String {
        switch self {
        case .activate: return "activate"
        case .enableStreaming: return "enable BLE streaming"
        default: return "[unknown: 0x\(String(format: "%x", rawValue))]"
        }
    }
}
