Pod::Spec.new do |s|
  s.name = 'HumioCocoaLumberjackLogger'
  s.version  = '3.0.4'
  s.license = 'MIT'
  s.summary  = 'Sends your Lumberjack logging directly to Humio'
  s.homepage = 'https://cloud.humio.com'
  s.authors   = { 'Jimmy Juncker' => '' }
  s.source = { :git => 'https://github.com/jjuncker/HumioCocoaLumberjackLogger', :tag => s.version }

  s.ios.deployment_target = '9.0'
  s.source_files = 'Classes/*.swift'
  s.dependency 'CocoaLumberjack/Swift', '~> 3.6.0'
  
end
