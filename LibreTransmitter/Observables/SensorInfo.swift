//
//  SensorInfo.swift
//  LibreTransmitter
//
//  Created by LoopKit Authors on 02/07/2021.
//  Copyright © 2021 LoopKit Authors. All rights reserved.
//

import Foundation
public class SensorInfo: ObservableObject, Equatable, Hashable {
    @Published public var sensorAge = ""
    @Published public var sensorAgeLeft = ""
    @Published public var sensorEndTime = ""
    @Published public var sensorState = ""
    @Published public var sensorSerial = ""
    
    @Published public var sensorMinutesLeft : Int = 0
    @Published public var sensorMinutesSinceStart : Int = 0
    @Published public var sensorMaxMinutesWearTime : Int = 0
    
    @Published public var activatedAt : Date?
    @Published public var expiresAt : Date?
    
    // MARK: - Warmup state
    public static let warmupDurationMinutes: Int = 60
    @Published public var isInWarmup: Bool = false
    @Published public var warmupMinutesRemaining: Int = 0
    
    public var warmupProgress: Double {
        guard isInWarmup else { return 1.0 }
        let elapsed = Double(Self.warmupDurationMinutes - warmupMinutesRemaining)
        return min(max(elapsed / Double(Self.warmupDurationMinutes), 0), 1.0)
    }
    
    public func updateWarmupState() {
        let remaining = Self.warmupDurationMinutes - sensorMinutesSinceStart
        if remaining > 0 {
            isInWarmup = true
            warmupMinutesRemaining = remaining
        } else {
            isInWarmup = false
            warmupMinutesRemaining = 0
        }
    }
    
    public func calculateProgress() -> Double {
        let minutesLeft = Double(self.sensorMinutesLeft)
        let maxWearTime = Double(self.sensorMaxMinutesWearTime)
        
        guard let activatedAt, let expiresAt else {
            return 0
        }
        
        if minutesLeft <= 0 {
            return 1
        }
        if maxWearTime == 0 {
            // shouldn't really happen, but if it does we don't want to crash because of a minor UI issue
            return 0
        }
        
        let progress = Date.now.getProgress(range: activatedAt...expiresAt)
        
        return progress == 0 ? progress : progress / 100
    }
    
    public var activatedAtString: String {
        if let activatedAt = activatedAt {
            return dateFormatter.string(from: activatedAt)
        } else {
            return "—"
        }
    }
    private let dateFormatter: DateFormatter = {
        let dateFormatter = DateFormatter()
        dateFormatter.timeStyle = .short
        dateFormatter.dateStyle = .medium
        dateFormatter.doesRelativeDateFormatting = true
        return dateFormatter
    }()
    public var expiresAtString: String {
        if let expiresAt = expiresAt {
            return dateFormatter.string(from: expiresAt)
        } else {
            return "—"
        }
    }
    
    public static func == (lhs: SensorInfo, rhs: SensorInfo) -> Bool {
         lhs.sensorAge == rhs.sensorAge && lhs.sensorAgeLeft == rhs.sensorAgeLeft &&
         lhs.sensorEndTime == rhs.sensorEndTime && lhs.sensorState == rhs.sensorState &&
         lhs.sensorSerial == rhs.sensorSerial && lhs.isInWarmup == rhs.isInWarmup &&
         lhs.warmupMinutesRemaining == rhs.warmupMinutesRemaining

     }

}
