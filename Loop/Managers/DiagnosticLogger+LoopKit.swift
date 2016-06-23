//
//  DiagnosticLogger+LoopKit.swift
//  Naterade
//
//  Created by Nathan Racklyeft on 3/25/16.
//  Copyright © 2016 Nathan Racklyeft. All rights reserved.
//

import Foundation
import HealthKit
import LoopKit


extension DiagnosticLogger {
    func addError(message: String, fromSource source: String) {
        let info = [
            "source": source,
            "message": message,
            "reportedAt": NSDateFormatter.ISO8601StrictDateFormatter().stringFromDate(NSDate())
        ]

        addMessage(info, toCollection: "errors")
    }

    func addError(message: ErrorType, fromSource source: String) {
        addError(String(message), fromSource: source)
    }

    func addLoopStatus(startDate startDate: NSDate, endDate: NSDate, glucose: GlucoseValue, effects: [String: [GlucoseEffect]], error: ErrorType?, prediction: [GlucoseValue], recommendedTempBasal: LoopDataManager.TempBasalRecommendation?) {

        let dateFormatter = NSDateFormatter.ISO8601StrictDateFormatter()
        let unit = HKUnit.milligramsPerDeciliterUnit()

        DeviceDataManager.sharedManager.loopManager.getLoopStatus { (predictedGlucose, recommendedTempBasal, lastTempBasal, lastLoopCompleted, getLoopStatusError) -> Void in

            var message: [String: AnyObject] = [
                "startDate": dateFormatter.stringFromDate(startDate),
                // needed for Nightscout
                "created_at": dateFormatter.stringFromDate(startDate),
                "duration": endDate.timeIntervalSinceDate(startDate),
                "glucose": [
                    "startDate": dateFormatter.stringFromDate(glucose.startDate),
                    "value": glucose.quantity.doubleValueForUnit(unit),
                    "unit": unit.unitString
                ],
                "input": effects.reduce([:], combine: { (previous, item) -> [String: AnyObject] in
                    var input = previous
                    input[item.0] = item.1.map {
                        [
                            "startDate": dateFormatter.stringFromDate($0.startDate),
                            "value": $0.quantity.doubleValueForUnit(unit),
                            "unit": unit.unitString
                        ]
                    }
                    return input
                }),
                "prediction": prediction.map({ (value) -> [String: AnyObject] in
                    [
                        "startDate": dateFormatter.stringFromDate(value.startDate),
                        "value": value.quantity.doubleValueForUnit(unit),
                        "unit": unit.unitString
                    ]
                })
            ]

            if let error = error {
                message["error"] = String(error)
            }

            if let recommendedTempBasal = recommendedTempBasal {
                message["recommendedTempBasal"] = [
                    "rate": recommendedTempBasal.rate,
                    "minutes": recommendedTempBasal.duration.minutes
                ]
            }

            if let scheduledBasal = DeviceDataManager.sharedManager.basalRateSchedule?.between(NSDate(), NSDate()).first,
                    lastTempBasal = lastTempBasal where lastTempBasal.endDate > NSDate() {
                message["lastTempBasal"] = [
                    "basalRate": lastTempBasal.value,
                    "netBasalRate": lastTempBasal.value - scheduledBasal.value,
                    "startDate": dateFormatter.stringFromDate(lastTempBasal.startDate),
                    "endDate": dateFormatter.stringFromDate(lastTempBasal.endDate),
                ]
            }

            self.addMessage(message, toCollection: "devicestatus")
        }
    }
}
