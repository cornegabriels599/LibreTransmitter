import Combine
import Foundation
import os.log

public class MockSensorPairingService: SensorPairingProtocol {
    fileprivate lazy var logger = Logger(forType: Self.self)

    private var readingsSubject = PassthroughSubject<SensorPairingInfo, Never>()
    private var errorsSubject = PassthroughSubject<Error, Never>()
    private var phasesSubject = PassthroughSubject<SensorPairingPhase, Never>()

    public var onCancel: (() -> Void)?

    public var publisher: AnyPublisher<SensorPairingInfo, Never> {
        readingsSubject.eraseToAnyPublisher()
    }

    public var errorPublisher: AnyPublisher<Error, Never> {
        errorsSubject.eraseToAnyPublisher()
    }

    public var phasePublisher: AnyPublisher<SensorPairingPhase, Never> {
        phasesSubject.eraseToAnyPublisher()
    }

    public init() {}

    private func sendUpdate(_ info: SensorPairingInfo) {
        DispatchQueue.main.async { [weak self] in
            self?.readingsSubject.send(info)
        }
    }

    public func pairSensor() throws {
        phasesSubject.send(.scanning)
        let info = FakeSensorPairingData().fakeSensorPairingInfo()
        logger.debug("Sending fake sensor pairinginfo: \(info.description)")
        // delay a bit to simulate a real tag readout
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            self.phasesSubject.send(.completed)
            self.sendUpdate(info)
        }
    }
}
