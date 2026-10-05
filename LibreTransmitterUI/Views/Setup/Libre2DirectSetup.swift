//
//  Libre2DirectSetup.swift
//  LibreTransmitterUI
//
//  Created by LoopKit Authors on 30/08/2021.
//  Copyright © 2021 LoopKit Authors. All rights reserved.
//

import SwiftUI
import LibreTransmitter
import LoopKitUI
import LoopKit
import os.log

fileprivate var logger = Logger(forType: "Libre2DirectSetup")

struct Libre2DirectSetup: View {

    @State private var presentableStatus: StatusMessage?
    @State private var showPairingInfo = false
    @State private var isPairing = false
    @State private var pairingInfo = SensorPairingInfo()

    @ObservedObject public var cancelNotifier: GenericObservableObject
    @ObservedObject public var saveNotifier: GenericObservableObject
    
    let pairingService: SensorPairingProtocol

    func pairSensor() {

        pairingService.onCancel = {
            DispatchQueue.main.async {
                isPairing = false
            }
        }
        
        showPairingInfo = false
        isPairing = true

        do {
            try pairingService.pairSensor()
        } catch {
            let message = (error as? LocalizedError)?.recoverySuggestion ?? error.localizedDescription
            presentableStatus = StatusMessage(title: error.localizedDescription, message: message)
        }
    }
    
    func receivePairingInfo(_ info: SensorPairingInfo) {

        print("Received Pairinginfo: \(String(describing: info))")

        pairingInfo = info

        isPairing = false
        showPairingInfo = true

        // calibrationdata must always be extracted from the full nfc scan
        if let calibrationData = info.calibrationData {
            do {
                try KeychainManager.standard.setLibreNativeCalibrationData(calibrationData)
            } catch {
                NotificationHelper.sendCalibrationNotification(.invalidCalibrationData)
                return
            }
            // here we assume success, data is not changed,
            // and we trust that the remote endpoint returns correct data for the sensor

            NotificationHelper.sendCalibrationNotification(.success)

            UserDefaults.standard.calibrationMapping = CalibrationToSensorMapping(uuid: info.uuid, reverseFooterCRC: calibrationData.isValidForFooterWithReverseCRCs)

        }

        let max = info.sensorData?.maxMinutesWearTime ?? 0

        let sensor = Sensor(uuid: info.uuid, patchInfo: info.patchInfo, maxAge: max, sensorName: info.sensorName, macAddress: info.macAddress)
        UserDefaults.standard.preSelectedSensor = sensor

        SelectionState.shared.selectedUID = pairingInfo.uuid
        
        // only relevant for launch through settings, as selectionstate can be persisted
        // we need to enforce libre2 by removing any selected third party transmitter
        SelectionState.shared.selectedStringIdentifier = nil
        print("Paired and set selected UID to: \(String(describing: SelectionState.shared.selectedUID?.hex))")
        saveNotifier.notify()
        NotificationHelper.sendLibre2DirectFinishedSetupNotifcation()

    }

    #if DEBUG
    /// Provisions only the fixed profile advertised by Libre2BLESimulator.
    /// This bypasses NFC and is unavailable in Release/TestFlight builds.
    func pairTrainingSimulator() {
        let uid = Data([0xD6, 0xF1, 0x0F, 0x01, 0x00, 0xA4, 0x07, 0xE0])
        let patchInfo = Data([0x9D, 0x08, 0x30, 0x01, 0x9C, 0x16])
        let calibration = SensorData.CalibrationInfo(
            i1: 0, i2: 1, i3: 0, i4: 6500, i5: 0, i6: 1066,
            isValidForFooterWithReverseCRCs: 0
        )
        do {
            try KeychainManager.standard.setLibreNativeCalibrationData(calibration)
        } catch {
            presentableStatus = StatusMessage(
                title: "Training simulator setup failed",
                message: error.localizedDescription
            )
            return
        }
        UserDefaults.standard.calibrationMapping = CalibrationToSensorMapping(
            uuid: uid, reverseFooterCRC: 0
        )
        UserDefaults.standard.preSelectedSensor = Sensor(
            uuid: uid, patchInfo: patchInfo, maxAge: 14 * 24 * 60,
            sensorName: "3MH000GUR5W", macAddress: "ABBOTTTRIOSIM01"
        )
        SelectionState.shared.selectedUID = uid
        SelectionState.shared.selectedStringIdentifier = nil
        saveNotifier.notify()
        NotificationHelper.sendLibre2DirectFinishedSetupNotifcation()
    }
    #endif

    var cancelButton: some View {
        Button("Cancel") {
            print("cancel button pressed")
            cancelNotifier.notify()

        }// .accentColor(.red)
    }
    
    
    var body : some View {
        GuidePage(content: {
            
            VStack {
                getLeadingImage()
                HStack {
                    InstructionList(instructions: [
                        LocalizedString("A new sensor is activated automatically when you scan it with NFC.", comment: "Label text for step 1 of libre2 setup"),
                        LocalizedString("During the 60-minute warmup, sensor readings are paused and Trio shows the remaining time.", comment: "Label text for warmup behavior during libre2 setup"),
                        LocalizedString("Disconnect and unpair any other app or device communicating with the sensor via bluetooth.", comment: "Label text for step 2 of libre2 setup"),
                        LocalizedString("Keep phone unlocked and your Loop app in the foreground.", comment: "Label text for step 3 of libre2 setup"),
                        LocalizedString("The Bluetooth connection will take up to four minutes before it starts working.", comment: "Label text for step 3 of libre2 setup")
                    ])
                }
            }

        }) {
            VStack(spacing: 10) {
                Button {
                    pairSensor()
                } label: {
                    if isPairing {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text(LocalizedString("Pairing...", comment: "Button title for pairing sensor when pairing"))
                        }
                    } else {
                        Text(LocalizedString("Pair Sensor", comment: "Button title for pairing sensor"))
                    }
                }
                .actionButtonStyle(.primary)
                .disabled(isPairing)
                #if DEBUG
                Button("Use Libre 2 Training Simulator") {
                    pairTrainingSimulator()
                }
                .actionButtonStyle(.secondary)
                .disabled(isPairing)
                .accessibilityHint("Connects only to the TRAINING Libre 2 simulator")
                #endif
            }.padding()
        }
        .navigationTitle("Libre 2 Setup")
        .navigationBarBackButtonHidden(true)
        .navigationBarItems(leading: cancelButton)  // the pair button does the save process for us! //, trailing: saveButton)
        .onReceive(pairingService.publisher, perform: receivePairingInfo)
        .alert(item: $presentableStatus) { status in
            Alert(title: Text(status.title), message: Text(status.message), dismissButton: .default(Text("Got it!")))
        
        }
    }
}

struct Libre2DirectSetup_Previews: PreviewProvider {
    static var previews: some View {
        Libre2DirectSetup(cancelNotifier: GenericObservableObject(), saveNotifier: GenericObservableObject(), pairingService: MockSensorPairingService())
    }
}
