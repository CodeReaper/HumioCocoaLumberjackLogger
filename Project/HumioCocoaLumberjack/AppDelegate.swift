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

    func application(_ application: UIApplication, willFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        DDLog.add((DDTTYLogger.sharedInstance)) // or DDLog.add(DDOSLogger.sharedInstance) for iOS 10+

        //        let logger = HumioLoggerFactory.createLogger("your token here", dataSpace:"some dataspace")

        //or if you set up the info plist:
        let logger = HumioLoggerFactory.createLogger()

//        logger.verbose = true //prints the requests/responses from humio

        DDLog.add(logger, with: .error)
        DDLog.setLevel(.error, for: HumioCocoaLumberjackLogger.self)

        return true
    }
}
