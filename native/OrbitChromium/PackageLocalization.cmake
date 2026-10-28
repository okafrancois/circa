cmake_minimum_required(VERSION 3.26)

# Resource-only assembly; no browser process, CEF, signing or installation.
foreach(REQUIRED SOURCE DESTINATION)
  if(NOT DEFINED ${REQUIRED} OR "${${REQUIRED}}" STREQUAL "")
    message(FATAL_ERROR "Missing localization argument: ${REQUIRED}")
  endif()
endforeach()
if(NOT EXISTS "${SOURCE}/en.lproj/Localizable.strings" OR IS_SYMLINK "${DESTINATION}")
  message(FATAL_ERROR "Missing English localization or unsafe resource destination")
endif()
file(MAKE_DIRECTORY "${DESTINATION}/Contents/Resources")
file(COPY "${SOURCE}/" DESTINATION "${DESTINATION}/Contents/Resources")
file(WRITE "${DESTINATION}/Contents/Info.plist" [=[<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>io.github.okatech.orbit.test.orbit.localization</string>
<key>CFBundleName</key><string>OrbitLabNative_BrowserShell</string>
<key>CFBundlePackageType</key><string>BNDL</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
</dict></plist>
]=])
