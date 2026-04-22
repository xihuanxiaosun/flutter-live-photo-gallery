#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
#
Pod::Spec.new do |s|
  s.name             = 'live_photo_gallery'
  s.version          = '0.1.0'
  s.summary          = 'iOS & Android media picker & preview plugin for Flutter.'
  s.description      = <<-DESC
A Flutter plugin for picking and previewing images, videos, Live Photos (iOS) and Motion Photos (Android).
Supports mixed local + network preview, download-to-album button, and structured error codes on both platforms.
                       DESC
  s.homepage         = 'https://github.com/newtrip/live_photo_gallery'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'NewTrip' => 'dev@newtrip.com' }
  s.source           = { :path => '.' }

  # 包含 Classes 目录下所有子目录的 Swift 文件
  s.source_files = 'Classes/**/*.swift'

  s.dependency 'Flutter'
  s.dependency 'TOCropViewController', '~> 3.1'
  s.platform = :ios, '15.0'

  # Photos.framework 权限
  s.frameworks = 'Photos', 'PhotosUI', 'AVFoundation', 'UIKit'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386'
  }
  s.swift_version = '5.9'
end
