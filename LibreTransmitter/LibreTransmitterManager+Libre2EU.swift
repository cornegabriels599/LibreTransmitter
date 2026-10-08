import Foundation
import LoopKit

public extension LibreTransmitterManagerV3 {
    func libreSensorDidUpdate(with error: LibreError) {
        delegateQueue.async {
            self.logDeviceCommunication("Sensor error \(error)", type: .error)
            self.cgmManagerDelegate?.cgmManager(self, hasNew: .error(error))
        }
    }

    func libreSensorDidUpdate(with bleData: Libre2.LibreBLEResponse, and Device: LibreTransmitterMetadata) {
        logger.debug("Received Libre 2 BLE packet age=\(bleData.age) trendCount=\(bleData.trend.count)")
        let typeDesc = Device.sensorType().debugDescription

        let now = Date()
        // only one reading per 1 minute / 5 minutes
        let mins = Features.allowOneMinuteReadings ? 0.8 : 4.5
        if let earlierplus = lastDirectUpdate?.addingTimeInterval(mins * 60), earlierplus >= now {
            logger.debug("last ble update was less than \(mins) minutes ago, aborting loop update")
            // self.logDeviceCommunication("Sensor didUpdate (not used) \(bleData)", type: .receive)
            return
        }

        logger.debug("Connected directly to supported Libre sensor type \(typeDesc)")
        logDeviceCommunication(
            "Libre sensor packet received; age=\(bleData.age), trendCount=\(bleData.trend.count)",
            type: .receive
        )

        guard let mapping = UserDefaults.standard.calibrationMapping,
              let calibrationData,
              let sensor = UserDefaults.standard.preSelectedSensor
        else {
            logger.error("calibrationdata, sensor uid or mapping missing, could not continue")

            delegateQueue.async {
                self.cgmManagerDelegate?.cgmManager(self, hasNew: .error(LibreError.noCalibrationData))
            }
            return
        }

        guard mapping.reverseFooterCRC == calibrationData.isValidForFooterWithReverseCRCs,
              mapping.uuid == sensor.uuid
        else {
            logger
                .error(
                    "Calibrationdata was not correct for these bluetooth packets. This is a fatal error, we cannot calibrate without re-pairing"
                )
            delegateQueue.async {
                self.cgmManagerDelegate?.cgmManager(self, hasNew: .error(LibreError.noCalibrationData))
            }
            return
        }

        if sensor.maxAge > 0 {
            let minutesLeft = Double(sensor.maxAge - bleData.age)
            NotificationHelper.sendSensorExpireAlertIfNeeded(minutesLeft: minutesLeft)
        }

        let authoritativeActivatedAt = Date() - TimeInterval(minutes: Double(bleData.age))
        PendingLibre2ActivationStore().reconcile(
            sensorUID: sensor.uuid,
            authoritativeActivatedAt: authoritativeActivatedAt
        )
        verifySensorChange(for: sensor.uuid, activatedAt: authoritativeActivatedAt)

        let sortedTrends = bleData.trend.sorted { $0.date > $1.date }

        let glucose = LibreGlucose.fromTrendMeasurements(sortedTrends, nativeCalibrationData: calibrationData)

        var newGlucose: [NewGlucoseSample] = glucosesToSamplesFilter(glucose, startDate: getStartDateForFilter())
        // For libre2 bluetooth we do need all trend elements to calculate trendarrow,
        // but we can't report all those trends back to loop
        if let newest = newGlucose.first {
            newGlucose = [newest]
        }

        if newGlucose.isEmpty {
            countTimesWithoutData &+= 1
        } else {
            latestBackfill = glucose.max { $0.startDate < $1.startDate }
            latestPrediction = createBloodSugarPrediction(bleData.trend, calibration: calibrationData)
            logger.debug("latestbackfill set to \(self.latestBackfill.debugDescription)")
            countTimesWithoutData = 0
        }

        // Derive safety state from this packet. setObservables publishes on
        // the main queue, so its observable can still hold the previous value.
        let isInWarmup = SensorInfo.isInWarmup(sensorMinutesSinceStart: bleData.age)

        setObservables(sensorData: nil, bleData: bleData, metaData: Device)

        logger.debug("handleGoodReading returned with \(newGlucose.count) entries")
        delegateQueue.async {
            // During warmup (first 60 minutes), glucose data is unreliable
            // Don't send to loop to prevent incorrect dosing decisions
            if isInWarmup {
                self.logger.debug("Sensor is in warmup phase, not sending glucose data to loop")
                self.cgmManagerDelegate?.cgmManager(self, hasNew: .noData)
                return
            }

            var result: CGMReadingResult
            // If several readings from a valid and running sensor come out empty,
            // we have (with a large degree of confidence) a sensor that has been
            // ripped off the body
            if self.countTimesWithoutData > 1 {
                result = .error(LibreError.noValidSensorData)
            } else {
                result = newGlucose.isEmpty ? .noData : .newData(newGlucose)
            }
            self.cgmManagerDelegate?.cgmManager(self, hasNew: result)
        }

        lastDirectUpdate = Date()
    }
}
