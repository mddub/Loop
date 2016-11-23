//
//  UrchinDataManager.swift
//  Loop
//
//  Created by Mark Wilson on 8/22/16.
//  Copyright © 2016 Nathan Racklyeft. All rights reserved.
//

import Foundation
import UserNotifications
import CarbKit
import HealthKit
import InsulinKit
import LoopKit

class PushStatusManager: NSObject {

    unowned let deviceDataManager: DeviceDataManager

    // TODO should be 72
    let HISTORY_LENGTH = 84

    // for now we need our own cache of glucose because HealthKit data becomes inaccessible when the phone is locked
    var localGlucoseCache: [GlucoseValue]

    init(deviceDataManager: DeviceDataManager) {
        self.deviceDataManager = deviceDataManager
        self.localGlucoseCache = []
        super.init()

        UIDevice.current.isBatteryMonitoringEnabled = true

        NotificationCenter.default.addObserver(self, selector: #selector(loopDataUpdated(_:)), name: .LoopDataUpdated, object: deviceDataManager.loopManager)
    }

    @objc private func loopDataUpdated(_ note: Notification) {
        if let rawContext = note.userInfo?[LoopDataManager.LoopUpdateContextKey] as? LoopDataManager.LoopUpdateContext.RawValue,
            let context = LoopDataManager.LoopUpdateContext(rawValue: rawContext) {
            // TODO maybe limit status updates to a subset of events (glucose, bolus, carbs, temp basal?)
            print("context \(context)")
        }

        sendLoopStatusAsPushNotification()
    }

    struct PebbleLoopStatus {
        let timeString: String
        let iobString: String
        let cobString: String
        let lastBGString: String
        let lastBGRecencyString: String
        let evBGString: String
        let currentTempString: String
        let batteryString: String
        let recommendedBolusString: String
    }

    private func getStatus(completion: @escaping (PebbleLoopStatus, [GlucoseValue]) -> Void) {
        guard let glucoseStore = self.deviceDataManager.glucoseStore else {
            return
        }

        // _ predictedGlucose: [GlucoseValue]?, _ retrospectivePredictedGlucose: [GlucoseValue]?, _ recommendedTempBasal: TempBasalRecommendation?, _ lastTempBasal: DoseEntry?, _ lastLoopCompleted: Date?, _ insulinOnBoard: InsulinValue?, _ carbsOnBoard: CarbValue?, _ error: Error?) -> Void

        deviceDataManager.loopManager.getLoopStatus { (predictedGlucose, _, recommendedTempBasal, lastTempBasal, lastLoopCompleted, insulinOnBoard, carbsOnBoard, loopError) in

            glucoseStore.getRecentGlucoseValues(startDate: NSDate(timeIntervalSinceNow: TimeInterval(minutes: -5 * Double(self.HISTORY_LENGTH + 1))) as Date) { (recentGlucose, getGlucoseValuesError) in
                if getGlucoseValuesError != nil {
                    self.deviceDataManager.logger.addError(getGlucoseValuesError!, fromSource: "UrchinDataManager")
                } else {

                    print("got \(recentGlucose.count) recentGlucose")
                    for glucose in recentGlucose {
                        if !self.localGlucoseCache.contains(where: {$0.startDate == glucose.startDate}) {
                            self.localGlucoseCache.append(glucose)
                        }
                    }
                    self.localGlucoseCache.sort(by: {$0.startDate < $1.startDate})
                    if self.localGlucoseCache.count > self.HISTORY_LENGTH {
                        self.localGlucoseCache.removeFirst(self.localGlucoseCache.count - self.HISTORY_LENGTH)
                    }

                    self.deviceDataManager.loopManager.getRecommendedBolus() { (units, recommendedBolusError) in
                        if recommendedBolusError != nil {
                            self.deviceDataManager.logger.addError(recommendedBolusError!, fromSource: "UrchinDataManager")
                        } else {
                            completion(self.formatStatus(insulinOnBoard: insulinOnBoard, carbsOnBoard: carbsOnBoard, predictedGlucose: predictedGlucose, lastTempBasal: lastTempBasal, pastGlucose: self.localGlucoseCache, recommendedBolus: units), self.localGlucoseCache)
                        }
                    }
                }
            }
        }

    }

    private func formatStatus(insulinOnBoard: InsulinValue?, carbsOnBoard: CarbValue?, predictedGlucose: [GlucoseValue]?, lastTempBasal: DoseEntry?, pastGlucose: [GlucoseValue], recommendedBolus: Double?) -> PebbleLoopStatus {
        // TODO match locale, or show recency instead
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "h:mm"
        timeFormatter.amSymbol = "a"
        timeFormatter.pmSymbol = "p"
        let formattedTime = timeFormatter.string(from: Date())

        let insulinFormatter = NumberFormatter()
        insulinFormatter.numberStyle = .decimal
        insulinFormatter.usesSignificantDigits = false
        insulinFormatter.minimumFractionDigits = 1
        insulinFormatter.maximumFractionDigits = 1

        let iobString: String
        if let insulinOnBoard = insulinOnBoard,
            let roundedIob = insulinFormatter.string(from: insulinOnBoard.value.rawValue) {
            iobString = "\(roundedIob)U"
        } else {
            iobString = ""
        }

        let cobString: String
        if let cob = carbsOnBoard {
            cobString = " \(formatCarbs(cob))g"
        } else {
            cobString = ""
        }

        let evBGString: String
        if let predictedGlucose = predictedGlucose,
            let last = predictedGlucose.last {
            evBGString = "\(formatGlucose(last))"
        } else {
            evBGString = ""
        }

        let currentTempString: String
        let basalRateFormatter = NumberFormatter()
        basalRateFormatter.numberStyle = .decimal
        basalRateFormatter.usesSignificantDigits = false
        basalRateFormatter.minimumFractionDigits = 2
        basalRateFormatter.maximumFractionDigits = 2
        if let tempBasal = lastTempBasal, tempBasal.unit == .unitsPerHour {
            let remaining = Int(round(tempBasal.endDate.timeIntervalSinceNow.minutes))
            if let formattedRate = basalRateFormatter.string(from: tempBasal.value.rawValue), remaining > 0 {
                currentTempString = "\(formattedRate) "
            } else {
                currentTempString = ""
            }
        } else {
            currentTempString = ""
        }

        let batteryString: String
        let device = UIDevice.current
        if device.isBatteryMonitoringEnabled {
            batteryString = " \(Int(device.batteryLevel * 100))%%"
        } else {
            batteryString = ""
        }

        let lastBGString: String
        let lastBGRecencyString: String
        if let lastBG = pastGlucose.last {
            let delta: Int?
            if pastGlucose.count > 1 && pastGlucose.last!.startDate.timeIntervalSince(pastGlucose[pastGlucose.count - 2].startDate).minutes < 10 {
                delta = formatGlucose(pastGlucose.last!) - formatGlucose(pastGlucose[pastGlucose.count - 2])
            } else {
                delta = nil
            }
            let deltaString: String
            if let delta = delta {
                deltaString = " " + (delta < 0 ? "" : "+") + String(delta)
            } else {
                deltaString = ""
            }
            lastBGString = " \(formatGlucose(lastBG))" + deltaString
            lastBGRecencyString = " (\(Int(round(-lastBG.startDate.timeIntervalSinceNow.minutes))))"
        } else {
            lastBGString = ""
            lastBGRecencyString = ""
        }

        let recBolusString: String
        if let units = recommendedBolus,
            let formattedBolus = insulinFormatter.string(from: units.rawValue) {
            recBolusString = "\(formattedBolus)U"
        } else {
            recBolusString = ""
        }

        return PebbleLoopStatus(
            timeString: formattedTime,
            iobString: iobString,
            cobString: cobString,
            lastBGString: lastBGString,
            lastBGRecencyString: lastBGRecencyString,
            evBGString: evBGString,
            currentTempString: currentTempString,
            batteryString: batteryString,
            recommendedBolusString: recBolusString
        )
    }

    private func formatStatusBarString(_ s: PebbleLoopStatus) -> String {
        return "\(s.timeString)\(s.batteryString)\(s.evBGString)\n\(s.iobString)\(s.cobString)\(s.currentTempString)"
    }

    private func formatGlucose(_ glucoseValue: GlucoseValue) -> Int {
        return Int(round(glucoseValue.quantity.doubleValue(for: HKUnit.milligramsPerDeciliterUnit())))
    }

    private func formatCarbs(_ carbValue: CarbValue) -> Int {
        return Int(round(carbValue.quantity.doubleValue(for: HKUnit.gram())))
    }

    func sendLoopStatusAsPushNotification() {
        self.getStatus() { (status, _) in

            print("sending notification")

            let notification = UNMutableNotificationContent()

            notification.title = status.currentTempString + status.iobString + status.cobString + status.batteryString
            notification.body = NSLocalizedString(status.timeString + status.lastBGString + " ->" + status.evBGString, comment: "")
            notification.sound = UNNotificationSound.default()
            notification.categoryIdentifier = NotificationManager.Category.PumpBatteryLow.rawValue

            let request = UNNotificationRequest(
                // needs to be unique?
                identifier: notification.body,
                content: notification,
                trigger: nil
            )

            UNUserNotificationCenter.current().add(request)
        }
    }

}
