# HumioCocoaLogger
**HumioCocoaLogger** is a Logger for [CocoaLumberJack](https://github.com/CocoaLumberjack/CocoaLumberjack) which allows loggin directly into [Humio](http://humio.com/)

##### Swift version via CocoaPods
```ruby
platform :ios, '10.0'
use_frameworks!

pod 'HumioCocoaLumberjackLogger', :git => "https://github.com/jjuncker/HumioCocoaLumberjackLogger.git"
```

##### API access
You can specify your access token and dataspace by setting this information in your info.plist file or by parameters (see below)
```xml
	<key>HumioAccessToken</key>
	<string>yourAccessKeyHere</string>
	<key>HumioDataSpace</key>
	<string>yourDataSpaceHere</string>
```
##### Swift Usage

If you installed using CocoaPods or manually:
```swift
import CocoaLumberjack
```

```swift
let logger = HumioLoggerFactory.createLogger()
//OR 
//HumioLoggerFactory.createLogger(accessToken:"yourTokenHere", dataSpace:"yourDataSpaceHere")

DDLog.add(logger, with: .error) 
// OR
//DDLog.setLevel(.error, for: HumioCocoaLumberjackLogger.self)

...
```
##### Log format


##### Settings
When the logger is created, it sets a uniuque id for that logger. This can be overridden by specifying loggerId in the create method. The default is:

```swift
	loggerId:String=NSUUID().uuidString
```


