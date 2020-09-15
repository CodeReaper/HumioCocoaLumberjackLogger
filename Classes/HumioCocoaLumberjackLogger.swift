import os.log
import CocoaLumberjack
import CoreFoundation

public struct HumioLoggerConfiguration {
    public var postFrequency:TimeInterval = 10
    public var maximumQueueTime:TimeInterval = 3600
    public var allowsCellularAccess = true
    public var ommitEscapeCharacters = false

    public static func defaultConfiguration() -> HumioLoggerConfiguration {
        return HumioLoggerConfiguration()
    }
}

public protocol HumioLogger: DDLogger  {
    func appWillTerminate()
    func handleEvents(for identifier: String, with completion: @escaping () -> Void)
}

public class HumioLoggerFactory {
    public class func createLogger(serviceUrl:URL? = nil, accessToken:String?=nil, dataSpace:String?=nil, additionalAttributes:[String:String] = [:], loggerId:String=NSUUID().uuidString, tags:[String:String] = HumioLoggerFactory.defaultTags(), configuration:HumioLoggerConfiguration=HumioLoggerConfiguration.defaultConfiguration(), verbose: Bool = false) -> HumioLogger {
        return HumioCocoaLumberjackLogger(accessToken: accessToken, dataSpace: dataSpace, serviceUrl:serviceUrl, additionalAttributes:additionalAttributes, loggerId:loggerId, tags: tags, configuration: configuration, verbose: verbose)
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
    private let tags:[String:String]
    private let postFrequency:TimeInterval
    private let maximumQueueTime:TimeInterval
    private let attributes:[String:String]
    private let ommitEscapeCharacters:Bool

    private let identifier = "\(Bundle.main.bundleIdentifier!).humio-logger"
    private let bundleVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? "unknown") as! String
    private let bundleShortVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "unknown") as! String
    private let deviceSystemVersion = UIDevice.current.systemVersion
    private let deviceModel:String

    private let log: OSLog

    private let offloadingQueue = OperationQueue()
    private let cacheQueue:OperationQueue
    private var timer:Timer?
    private var session = URLSession()

    internal var completions: [() -> Void] = []
    internal var cache:[Any]


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

    init(accessToken:String?=nil, dataSpace:String?=nil, serviceUrl:URL? = nil, additionalAttributes:[String:String] = [:], loggerId:String, tags:[String:String], configuration:HumioLoggerConfiguration, verbose: Bool) {
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

        self.tags = tags
        self.maximumQueueTime = configuration.maximumQueueTime
        self.postFrequency = configuration.postFrequency
        self.ommitEscapeCharacters = configuration.ommitEscapeCharacters

        let sessionConfiguration = URLSessionConfiguration.background(withIdentifier: self.identifier)
        sessionConfiguration.allowsCellularAccess = configuration.allowsCellularAccess

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

        log = verbose ? OSLog(subsystem: Bundle.main.bundleIdentifier!, category: "humio-logger") : OSLog.disabled

        super.init()
        os_log("initialized", log: log)

        offloadingQueue.qualityOfService = .background
        offloadingQueue.maxConcurrentOperationCount = 1

        self.session = URLSession(configuration: sessionConfiguration, delegate: self, delegateQueue: offloadingQueue)
        self.logFormatter = SimpleHumioLogFormatter()

        session.getTasksWithCompletionHandler { (_, tasks, _) in
            for task in tasks {
                os_log("cancelling task with id=%s", log: self.log, task.taskDescription ?? "(nil)")
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

        os_log("setup completed", log: log)
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
        os_log("App will terminate, queueing logs", log: log)
        queueLogs()
    }
}

private extension HumioCocoaLumberjackLogger {
    @objc private func ingest() {
        os_log("ingesting logs", log: log)
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

        os_log("Preparing to send %{public}d events.", log: log, eventsToPost.count)

        let id = UUID().uuidString
        let dataFile = self.file(for: id)
        do {
            try? FileManager.default.createDirectory(at: dataFile.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
            try data.write(to: dataFile)
            self.cache.removeAll()
            self.send(request: id, with: dataFile)
        } catch {
            os_log("Failed to write data to file, error: %{public}s", log: log, error.localizedDescription)
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
            os_log("Failed to create data for humio. Most likely the JSON is invalid: %s", log: log, "\(jsonDict)")
            return nil
        }
    }

    private func send(request id: String, with file: URL) {
        os_log("sending request with id=%{public}s", log: log, id)

        var request = URLRequest(url: humioServiceUrl, timeoutInterval: 10)
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
        guard let id = dataTask.taskDescription, let response = dataTask.response as? HTTPURLResponse else { return }
        os_log("received status=%{public}i, id=%{public}s", log: self.log, response.statusCode, id)

        let dataFile = file(for: id)
        let cancel = {
            os_log("task cancelled for id=%{public}s", log: self.log, id)
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

        os_log("task completed for id=%{public}s", log: self.log, id)
        try? FileManager.default.removeItem(at: dataFile)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        os_log("handle events finishing with %{public}d callbacks registered.", log: log, completions.count)
        let completions = self.completions
        self.completions = []
        DispatchQueue.main.async {
            for callback in completions {
                callback()
            }
        }
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
    func handleEvents(for identifier: String, with completion: @escaping () -> Void) {
        os_log("did receive completion for identifier=%s matching ours: %i", log: log, identifier, identifier == self.identifier)
        guard identifier == self.identifier else { return }
        completions.append(completion)
    }
}
