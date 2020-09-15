//
//  AppDelegate.swift
//  HumioCocoaLumberjack
//
//  Created by Jimmy Juncker on 06/06/16.
//

import UIKit
import CocoaLumberjack

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

//    private let logger = HumioLoggerFactory.createLogger("your token here", dataSpace:"some dataspace")
    //or if you set up the info plist:
    private let logger = HumioLoggerFactory.createLogger(loggerId: "a-star-found", verbose: true)

    func application(_ application: UIApplication, willFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        DDLog.add((DDTTYLogger.sharedInstance)) // or DDLog.add(DDOSLogger.sharedInstance) for iOS 10+

        DDLog.add(logger, with: .error)
        DDLog.setLevel(.error, for: HumioCocoaLumberjackLogger.self)

        return true
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        logger.handleEvents(for: identifier, with: completionHandler)
    }
}
