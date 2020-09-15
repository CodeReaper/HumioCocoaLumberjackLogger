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

    // Here are some ways to setup your logger:
    // ----------------------------------------
    // private let logger = HumioLoggerFactory.createLogger(accessToken: "your token here", dataSpace:"some dataspace")
    // private let logger = HumioLoggerFactory.createLogger(accessToken: "your token here", dataSpace:"some dataspace", verbose: true) // with logging of humio logger, should not be enabled in production.
    private let logger = HumioLoggerFactory.createLogger() // if you set it up using the info plist.

    func application(_ application: UIApplication, willFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        DDLog.add(DDOSLogger.sharedInstance)
        DDLog.add(logger, with: .error)
        DDLog.setLevel(.error, for: HumioCocoaLumberjackLogger.self)
        return true
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        logger.handleEvents(for: identifier, with: completionHandler)
    }
}
