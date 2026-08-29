Pod::Spec.new do |s|
  s.name             = 'vdodtor_engine'
  s.version          = '0.0.1'
  s.summary          = 'vdodtor native preview engine (S1 spike)'
  s.description      = 'FFmpeg + VideoToolbox decode, Metal compositor, Flutter external texture.'
  s.homepage         = 'https://github.com/iChintanSoni/vdodtor'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Chintan Soni' => 'ichintansoni@gmail.com' }

  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.public_header_files = 'Classes/**/*.h'
  s.dependency 'FlutterMacOS'

  s.platform = :osx, '11.0'
  s.swift_version = '5.0'

  # SPIKE ONLY: links Homebrew's FFmpeg (a GPL build) from a hardcoded prefix.
  # Shipping requires a vendored LGPL build with no GPL components.
  ffmpeg = '/opt/homebrew/opt/ffmpeg'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'ARCHS' => 'arm64',
    'EXCLUDED_ARCHS[sdk=macosx*]' => 'x86_64',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
    'HEADER_SEARCH_PATHS' => "$(inherited) #{ffmpeg}/include",
    'LIBRARY_SEARCH_PATHS' => "$(inherited) #{ffmpeg}/lib",
    'CLANG_ENABLE_MODULES' => 'YES',
    'OTHER_LDFLAGS' => '$(inherited) -framework FlutterMacOS -lavformat -lavcodec -lavutil -lswscale -lswresample',
  }
  s.frameworks = 'Metal', 'CoreVideo', 'CoreMedia', 'VideoToolbox', 'QuartzCore', 'ImageIO', 'CoreGraphics'
end
