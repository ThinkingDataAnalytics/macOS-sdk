Pod::Spec.new do |s|
  s.name             = 'ThinkingSDKMacOS'
  s.version          = '1.0.0'
  s.summary          = 'Official ThinkingData SDK for OSX.'
  s.homepage         = 'https://github.com/ThinkingDataAnalytics/macOS-sdk'
  s.license          = 'Apache License, Version 2.0'
  s.author           = { 'ThinkingData, Inc' => 'sdk@thinkingdata.cn' }
  s.source           = { :git => 'https://github.com/ThinkingDataAnalytics/macOS-sdk.git', :tag => "v#{s.version}" }
  s.requires_arc     = true
  s.osx.deployment_target = '10.10'
  s.libraries        = 'sqlite3', 'z'
  s.default_subspec = 'Main'

  s.subspec 'OSX' do |s|
    path = "ThinkingSDK/Source"
    s.osx.deployment_target = '10.10'
    s.source_files = path + '/EventTracker/**/*.{h,m}', path + '/TDRuntime/**/*.{h,m}', path + '/Config/**/*.{h,m}', path + '/DeviceInfo/**/*.{h,m}', path + '/main/**/*.{h,m}',  path + '/Store/**/*.{h,m}', path + '/Network/**/*.{h,m}'
    s.osx.exclude_files = path + '/DeviceInfo/TDFPSMonitor.{h,m}', path + '/DeviceInfo/TDPerformance.{h,m}'

    s.dependency 'ThinkingSDKMacOS/Base'
  end

  s.subspec 'Base' do |b|
    path = "ThinkingSDK/Source"
    b.source_files = path + '/AppLifeCycle/**/*.{h,m}'

    b.dependency 'ThinkingSDKMacOS/Util'
    b.dependency 'ThinkingSDKMacOS/Core'
    b.dependency 'ThinkingSDKMacOS/Extension'
  end

  s.subspec 'Core' do |c|
    c.source_files = 'ThinkingSDK/Source/Core/**/*.{h,m,c}'
  end

  s.subspec 'Util' do |u|
    u.source_files = 'ThinkingSDK/Source/Util/**/*.{h,m}'
    u.osx.exclude_files = 'ThinkingSDK/Source/Util/Toast/*.{h,m}'
    u.dependency 'ThinkingSDKMacOS/Core'
  end

  s.subspec 'Extension' do |e|
    e.source_files = 'ThinkingSDK/Source/Extension/**/*.{h,m}'
    e.dependency 'ThinkingSDKMacOS/Core'
  end

  s.subspec 'Main' do |m|
    m.osx.dependency 'ThinkingSDKMacOS/OSX'
  end

end
