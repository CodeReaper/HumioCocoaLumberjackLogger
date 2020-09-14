//
//  HumioLogger.swift
//  HumioCocoaLumberjack
//
//  Created by Jimmy Juncker on 06/06/16.
//
import UIKit
import CocoaLumberjack
import CoreFoundation

public struct HumioLoggerConfiguration {
    public var cachePolicy:NSURLRequest.CachePolicy = .useProtocolCachePolicy
    public var timeout:TimeInterval = 10
    public var postFrequency:TimeInterval = 10
    public var maximumQueueTime:TimeInterval = 3600
    public var allowsCellularAccess = true
    public var ommitEscapeCharacters = false

    public static func defaultConfiguration() -> HumioLoggerConfiguration {
        return HumioLoggerConfiguration()
    }
}

public protocol HumioLogger: DDLogger  {
    var verbose: Bool { get set }
    func appWillTerminate()
}

public class HumioLoggerFactory {
    public class func createLogger(serviceUrl:URL? = nil, accessToken:String?=nil, dataSpace:String?=nil, additionalAttributes:[String:String] = [:], loggerId:String=NSUUID().uuidString, tags:[String:String] = HumioLoggerFactory.defaultTags(), configuration:HumioLoggerConfiguration=HumioLoggerConfiguration.defaultConfiguration()) -> HumioLogger {
        return HumioCocoaLumberjackLogger(accessToken: accessToken, dataSpace: dataSpace, serviceUrl:serviceUrl, additionalAttributes:additionalAttributes, loggerId:loggerId, tags: tags, configuration: configuration)
    }

    public class func defaultTags() -> [String:String] {
        return [
            "platform":"ios",
            "bundleIdentifier": (Bundle.main.object(forInfoDictionaryKey: "CFBundleIdentifier") ?? "unknown") as! String,
            "source":HumioCocoaLumberjackLogger.LOGGER_NAME
        ]
    }
}

class HumioCocoaLumberjackLogger: DDAbstractLogger {
    fileprivate static let LOGGER_NAME = "MobileDeviceLogger"
    private static let HUMIO_ENDPOINT_FORMAT = "https://cloud.humio.com/api/v1/dataspaces/%@/ingest"

    private let loggerId:String
    private let logs: URL
    private let accessToken:String

    private let humioServiceUrl:URL
    private let cachePolicy:URLRequest.CachePolicy
    private let timeout:TimeInterval
    private let tags:[String:String]
    private let postFrequency:TimeInterval
    private let maximumQueueTime:TimeInterval
    private let attributes:[String:String]
    private let ommitEscapeCharacters:Bool

    private let bundleVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? "unknown") as! String
    private let bundleShortVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "unknown") as! String
    private let deviceSystemVersion = UIDevice.current.systemVersion
    private let deviceModel:String

    private let offloadingQueue = OperationQueue()
    private let cacheQueue:OperationQueue
    private var timer:Timer?
    private var session = URLSession()

    internal var cache:[Any]
    internal var _verbose:Bool


    // ###########################################################################
    // Fails when formatting using the logformatter from parent
    //
    // https://github.com/CocoaLumberjack/CocoaLumberjack/issues/643
    //
    private var internalLogFormatter: DDLogFormatter?

    override internal var logFormatter: DDLogFormatter! {
        set {
            super.logFormatter = newValue
            internalLogFormatter = newValue
        }
        get {
            return super.logFormatter
        }
    }
    // ###########################################################################

    init(accessToken:String?=nil, dataSpace:String?=nil, serviceUrl:URL? = nil, additionalAttributes:[String:String] = [:], loggerId:String, tags:[String:String], configuration:HumioLoggerConfiguration) {
        self.loggerId = loggerId

        var setToken:String? = accessToken
        setToken = setToken ?? Bundle.main.infoDictionary!["HumioAccessToken"] as? String

        var setSpace:String? = dataSpace
        setSpace = setSpace ?? Bundle.main.infoDictionary!["HumioDataSpace"] as? String

        guard let space = setSpace, let token = setToken, space.count > 0 && token.count > 0 else {
            fatalError("dataSpace [\(String(describing: setSpace))] or accessToken [\(String(describing: setToken))] not properly set for humio")
        }

        var systemInfo = utsname() ; uname(&systemInfo)
        let identifier = Mirror(reflecting: systemInfo.machine).children.reduce("") { identifier, element in
            guard let value = element.value as? Int8, value != 0 else { return identifier }
            return identifier + String(UnicodeScalar(UInt8(value)))
        }
        self.deviceModel = identifier

        self.humioServiceUrl = serviceUrl ?? URL(string: String(format: HumioCocoaLumberjackLogger.HUMIO_ENDPOINT_FORMAT, space))!
        self.accessToken = setToken!

        self.cachePolicy = configuration.cachePolicy
        self.timeout = configuration.timeout
        self.tags = tags
        self._verbose = false
        self.maximumQueueTime = configuration.maximumQueueTime
        self.postFrequency = configuration.postFrequency
        self.ommitEscapeCharacters = configuration.ommitEscapeCharacters

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.allowsCellularAccess = configuration.allowsCellularAccess
        sessionConfiguration.timeoutIntervalForResource = timeout

        self.cache = [Any]()

        self.cacheQueue = OperationQueue()
        cacheQueue.qualityOfService = .background
        cacheQueue.maxConcurrentOperationCount = 1

        var attributes:[String: String] = ["loggerId":self.loggerId, "CFBundleVersion":self.bundleVersion, "CFBundleShortVersionString":self.bundleShortVersion, "systemVersion":self.deviceSystemVersion, "deviceModel":self.deviceModel]
        for (key, value) in additionalAttributes {
            attributes[key] = value
        }
        self.attributes = attributes

        logs = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!

        super.init()

        offloadingQueue.qualityOfService = .background
        offloadingQueue.maxConcurrentOperationCount = 1

        self.session = URLSession(configuration: sessionConfiguration, delegate: self, delegateQueue: offloadingQueue)
        self.logFormatter = SimpleHumioLogFormatter()

        session.getTasksWithCompletionHandler { (_, tasks, _) in
            for task in tasks {
                task.cancel()
            }
            self.offloadingQueue.addOperation {
                for file in self.files() {
                    let id = file.lastPathComponent.replacingOccurrences(of: ".data", with: "")
                    self.send(request: id, with: file)
                }
            }
        }

        DispatchQueue.main.async {
            self.timer = Timer.scheduledTimer(timeInterval: self.postFrequency, target: self, selector: #selector(self.ingest), userInfo: nil, repeats: true)
        }

        NotificationCenter.default.addObserver(self, selector: #selector(appWillTerminate), name: UIApplication.willTerminateNotification, object: nil)
    }

    override func log(message: DDLogMessage) {
        var messageText = message.message
        if let logFormatter = internalLogFormatter, let formatted = logFormatter.format(message: message) {
            messageText = formatted
        }

        let event = ["timestamp":Date().timeIntervalSince1970*1000, //ms
                     "kvparse":true,
                     "attributes":self.attributes,
                     "rawstring":ommitEscapeCharacters ? messageText.replacingOccurrences(of: "\\", with: "") : messageText
                    ] as [String : Any]

        self.cacheQueue.addOperation {
            self.cache.append(event)
        }
    }

    override var loggerName: DDLoggerName {
        get {
            return DDLoggerName.os
        }
    }

    override func flush() {
        self.session.flush {}
    }

    @objc func appWillTerminate() {
        if self._verbose {
            print("HumioCocoaLumberjackLogger: App will terminate, queueing logs")
        }

        queueLogs()
    }
}

private extension HumioCocoaLumberjackLogger {
    @objc private func ingest() {
        offloadingQueue.addOperation {
            self.queueLogs()
        }
    }

    private func queueLogs() {
        defer {
            self.cacheQueue.isSuspended = false
        }
        self.cacheQueue.isSuspended = true

        let eventsToPost = [Any](self.cache)
        guard
            eventsToPost.count != 0,
            let data = self.requestData(for: eventsToPost)
            else { return }

        if self._verbose {
            print("HumioCocoaLumberjackLogger: Preparing to send \(eventsToPost.count) events.")
        }

        let id = UUID().uuidString
        let dataFile = self.file(for: id)
        do {
            try? FileManager.default.createDirectory(at: dataFile.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
            try data.write(to: dataFile)
            self.cache.removeAll()
            self.send(request: id, with: dataFile)
        } catch {
            if self._verbose {
                print("HumioCocoaLumberjackLogger: Failed to write data to file, error: \(error.localizedDescription)")
            }
        }
    }

    private func file(for id: String) -> URL {
        return logs.appendingPathComponent("\(id).data")
    }

    private func files() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: logs, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        return files.filter { $0.pathExtension == "data" }
    }

    private func requestData(for events: [Any]) -> Data? {
        let jsonDict: [NSDictionary] = [[
            "tags": self.tags,
            "events": events
            ]]
        do {
            return try JSONSerialization.data(withJSONObject: jsonDict, options:[])
        } catch {
            if self._verbose {
                print("HumioCocoaLumberjackLogger: Failed to create data for humio. Most likely the JSON is invalid: \(jsonDict)")
            }
            return nil
        }
    }

    private func send(request id: String, with file: URL) {
        if self._verbose {
            print("HumioCocoaLumberJackLogger: sending request with id=\(id)")
        }

        var request = URLRequest(url: humioServiceUrl, cachePolicy: cachePolicy, timeoutInterval: timeout)
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.httpMethod = "POST"

        let task = session.uploadTask(with: request, fromFile: file)
        task.taskDescription = id
        task.resume()
    }
}

extension HumioCocoaLumberjackLogger: URLSessionDataDelegate {
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if self._verbose {
            print("HumioCocoaLumberjackLogger: request", dataTask.originalRequest!.allHTTPHeaderFields!)
            print("HumioCocoaLumberjackLogger: response", dataTask.response!)
        }

        guard let id = dataTask.taskDescription, let response = dataTask.response as? HTTPURLResponse else { return }
        let dataFile = file(for: id)
        let cancel = {
            dataTask.cancel()
            try? FileManager.default.removeItem(at: dataFile)
        }

        guard !(400..<499).contains(response.statusCode) else {
            cancel()
            return
        }

        guard (200..<299).contains(response.statusCode) else {
            if let attributes = try? FileManager.default.attributesOfItem(atPath: dataFile.path), let creation = attributes[.creationDate] as? Date {
                if Date().timeIntervalSince(creation) > maximumQueueTime {
                    cancel()
                }
            } else {
                cancel()
            }
            return
        }

        try? FileManager.default.removeItem(at: dataFile)
    }
}

final class SimpleHumioLogFormatter: NSObject, DDLogFormatter {
    func format(message: DDLogMessage) -> String? {
        return "logLevel=\(self.logLevelString(message)) filename='\(message.fileName)' line=\(message.line) \(message.message)"
    }

    func logLevelString(_ logMessage: DDLogMessage) -> String {
        let logLevel: String
        let logFlag = logMessage.flag
        if logFlag.contains(.error) {
            logLevel = "ERROR"
        } else if logFlag.contains(.warning) {
            logLevel = "WARNING"
        } else if logFlag.contains(.info) {
            logLevel = "INFO"
        } else if logFlag.contains(.debug) {
            logLevel = "DEBUG"
        } else if logFlag.contains(.verbose) {
            logLevel = "VERBOSE"
        } else {
            logLevel = "UNKNOWN"
        }
        return logLevel
    }
}

extension HumioCocoaLumberjackLogger: HumioLogger {
    var verbose: Bool {
        get { self._verbose }
        set { self._verbose = newValue }
    }
}
