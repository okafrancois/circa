cmake_minimum_required(VERSION 3.26)

# ENG-X1 laboratory bundle: the engine contract modules compiled from native/Sources, the
# ChromiumEngine adapter on the stock (unpatched) CEF SDK, and a hidden laboratory driver.
set(CMAKE_OSX_ARCHITECTURES arm64 CACHE STRING "Pinned architecture" FORCE)
set(CMAKE_OSX_DEPLOYMENT_TARGET 15.0 CACHE STRING "Minimum macOS" FORCE)
project(OrbitChromium LANGUAGES C CXX OBJCXX Swift)

set(ORBIT_SOURCES "${CMAKE_CURRENT_SOURCE_DIR}/../Sources")
set(ORBIT_IDENTITY_SOURCE "${ORBIT_SOURCES}/BrowserCore/ProductIdentity.swift")
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${ORBIT_IDENTITY_SOURCE}")
file(READ "${ORBIT_IDENTITY_SOURCE}" ORBIT_IDENTITY)
string(REGEX MATCH "bundleIdentifier = \"([^\"]+)\"" ORBIT_ID_MATCH "${ORBIT_IDENTITY}")
set(ORBIT_BUNDLE_ID "${CMAKE_MATCH_1}")
string(REGEX MATCH "displayName = \"([^\"]+)\"" ORBIT_NAME_MATCH "${ORBIT_IDENTITY}")
set(ORBIT_PRODUCT_NAME "${CMAKE_MATCH_1}")
file(REAL_PATH "${CMAKE_BINARY_DIR}" ORBIT_BUILD_DIRECTORY)
cmake_path(IS_PREFIX CMAKE_CURRENT_SOURCE_DIR "${ORBIT_BUILD_DIRECTORY}" NORMALIZE ORBIT_BUILD_INSIDE)
if(NOT APPLE OR NOT CMAKE_GENERATOR STREQUAL "Ninja" OR NOT CMAKE_BUILD_TYPE STREQUAL "Release"
    OR NOT ORBIT_BUILD_INSIDE)
  message(FATAL_ERROR "Use macOS, Ninja, Release and a build directory inside native/OrbitChromium/build")
endif()

# Pinned inputs (read-only): see docs/native-port/swift-chromium-bridge-build-2026-10-25.md.
if(NOT IS_DIRECTORY "${CEF_ROOT}" OR NOT EXISTS "${CEF_WRAPPER_LIBRARY}")
  message(FATAL_ERROR "Pass the pinned CEF_ROOT and CEF_WRAPPER_LIBRARY")
endif()
file(SHA256 "${CEF_WRAPPER_LIBRARY}" ORBIT_WRAPPER_HASH)
set(CEF_FRAMEWORK_SHA256 "9c81eb633abb7c1ebd5058f939061b4ece215d8f56e053114dac7073204800e8"
  CACHE STRING "Expected SHA-256 of the CEF framework")
# ENG-X2 builds pass the hash of the wrapper built from their own distribution
# (scripts/orbit-chromium-x2.py); the default pins the binary SDK of ENG-X1.
set(CEF_WRAPPER_SHA256 "5b85d48f3caf9069cb2ebf794722dc356925c3dcba0b7ad800065cdc57686e85"
  CACHE STRING "Expected SHA-256 of CEF_WRAPPER_LIBRARY")
if(NOT ORBIT_WRAPPER_HASH STREQUAL CEF_WRAPPER_SHA256)
  message(FATAL_ERROR "Pinned wrapper hash mismatch")
endif()
include("${CMAKE_CURRENT_SOURCE_DIR}/ValidateCEFSource.cmake")

set(PROJECT_ARCH arm64 CACHE STRING "Pinned architecture" FORCE)
set(USE_SANDBOX ON CACHE BOOL "All helpers require the CEF sandbox" FORCE)
set(api_version 15600 CACHE STRING "Pinned CEF API" FORCE)
list(APPEND CMAKE_MODULE_PATH "${CEF_ROOT}/cmake")
find_package(CEF REQUIRED)
set(CMAKE_OSX_DEPLOYMENT_TARGET 15.0 CACHE STRING "Minimum macOS" FORCE)
set(CMAKE_OSX_DEPLOYMENT_TARGET 15.0)
list(FILTER CEF_COMPILER_FLAGS EXCLUDE REGEX "^-mmacosx-version-min=")
add_library(pinned_cef_wrapper STATIC IMPORTED)
set_target_properties(pinned_cef_wrapper PROPERTIES IMPORTED_LOCATION "${CEF_WRAPPER_LIBRARY}")

add_library(OrbitChromiumBridge STATIC Bridge/OrbitChromiumBridge.mm Bridge/OrbitApplicationLifecycle.mm
  Bridge/OrbitClientWrap.cc)
target_include_directories(OrbitChromiumBridge PRIVATE "${CEF_ROOT}")
target_compile_definitions(OrbitChromiumBridge PRIVATE ${CEF_COMPILER_DEFINES} CEF_API_VERSION=15600 CEF_USE_SANDBOX=1)
target_compile_options(OrbitChromiumBridge PRIVATE ${CEF_COMPILER_FLAGS} ${CEF_CXX_COMPILER_FLAGS}
  ${CEF_COMPILER_FLAGS_RELEASE} -fobjc-arc)
set_target_properties(OrbitChromiumBridge PROPERTIES OBJCXX_STANDARD 20)
target_link_libraries(OrbitChromiumBridge PUBLIC pinned_cef_wrapper ${CEF_STANDARD_LIBS} OrbitNetworkQoS)

# A private linked image: dyld does not apply executable-local interpose tuples to CEF.
add_library(OrbitNetworkQoS SHARED Bridge/OrbitNetworkQoS.cc)
set_target_properties(OrbitNetworkQoS PROPERTIES CXX_STANDARD 20 CXX_STANDARD_REQUIRED ON
  INSTALL_NAME_DIR "@rpath" BUILD_WITH_INSTALL_NAME_DIR TRUE)

# Swift modules of the engine contract, compiled from the SwiftPM sources unchanged.
# `-package-name` as SwiftPM sets it (package "OrbitLabNative"): the shared modules use the
# `package` access level across modules (SPLIT, BrowserSurfaceTransfer.swift).
set(ORBIT_SWIFT_FLAGS -target arm64-apple-macosx15.0 -package-name OrbitLabNative
  -module-cache-path "${CMAKE_CURRENT_BINARY_DIR}/swift-module-cache")
function(orbit_swift_module NAME DIRECTORY)
  file(GLOB_RECURSE SOURCES CONFIGURE_DEPENDS "${DIRECTORY}/*.swift")
  add_library(${NAME} STATIC ${SOURCES})
  set_target_properties(${NAME} PROPERTIES Swift_MODULE_NAME ${NAME} Swift_LANGUAGE_VERSION 6
    Swift_MODULE_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/swift-modules")
  target_compile_options(${NAME} PRIVATE ${ORBIT_SWIFT_FLAGS} -parse-as-library)
  target_include_directories(${NAME} PRIVATE "${CMAKE_CURRENT_BINARY_DIR}/swift-modules")
  target_link_libraries(${NAME} PUBLIC ${ARGN})
endfunction()
orbit_swift_module(BrowserCore "${ORBIT_SOURCES}/BrowserCore")
orbit_swift_module(BrowserShell "${ORBIT_SOURCES}/BrowserShell" BrowserCore)
# CMake builds the Swift modules without SwiftPM, so emit the same localization bundle.
add_custom_target(orbit_localization_resources ALL
  COMMAND "${CMAKE_COMMAND}"
    "-DSOURCE=${ORBIT_SOURCES}/BrowserShell/Resources"
    "-DDESTINATION=${CMAKE_CURRENT_BINARY_DIR}/OrbitLabNative_BrowserShell.bundle"
    -P "${CMAKE_CURRENT_SOURCE_DIR}/PackageLocalization.cmake"
  COMMAND "${CMAKE_COMMAND}" -E copy_directory "${ORBIT_SOURCES}/BrowserShell/AppIcons"
    "${CMAKE_CURRENT_BINARY_DIR}/OrbitLabNative_BrowserShell.bundle/Contents/Resources/AppIcons"
  COMMAND "${CMAKE_COMMAND}" -E copy_directory "${ORBIT_SOURCES}/BrowserShell/Icons"
    "${CMAKE_CURRENT_BINARY_DIR}/OrbitLabNative_BrowserShell.bundle/Contents/Resources/Icons"
  VERBATIM)
orbit_swift_module(BrowserEngine "${ORBIT_SOURCES}/BrowserEngine" BrowserCore BrowserShell)
orbit_swift_module(BrowserEngineConformance "${ORBIT_SOURCES}/BrowserEngineConformance" BrowserCore BrowserShell BrowserEngine)
orbit_swift_module(ChromiumEngine "${CMAKE_CURRENT_SOURCE_DIR}/ChromiumEngine"
  BrowserCore BrowserShell BrowserEngine OrbitChromiumBridge)
target_include_directories(ChromiumEngine PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/Bridge")

# Independent hidden-mode witness run by the laboratory runner (not packaged in the bundle).
add_executable(OrbitWindowWatch "${CMAKE_CURRENT_SOURCE_DIR}/WindowWatch/main.swift"
  "${CMAKE_CURRENT_SOURCE_DIR}/WindowWatch/WindowWitnessPolicy.swift")
target_compile_options(OrbitWindowWatch PRIVATE ${ORBIT_SWIFT_FLAGS})
set_target_properties(OrbitWindowWatch PROPERTIES Swift_LANGUAGE_VERSION 6)

file(GLOB LAB_SOURCES CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/Lab/*.swift")
add_executable(OrbitChromium MACOSX_BUNDLE ${LAB_SOURCES})
target_compile_options(OrbitChromium PRIVATE ${ORBIT_SWIFT_FLAGS})
target_include_directories(OrbitChromium PRIVATE "${CMAKE_CURRENT_BINARY_DIR}/swift-modules"
  "${CMAKE_CURRENT_SOURCE_DIR}/Bridge")
target_link_libraries(OrbitChromium PRIVATE ChromiumEngine BrowserEngineConformance BrowserEngine
  BrowserShell BrowserCore OrbitChromiumBridge)
target_link_options(OrbitChromium PRIVATE "LINKER:-ObjC")
set_target_properties(OrbitChromium PROPERTIES Swift_LANGUAGE_VERSION 6
  BUILD_WITH_INSTALL_RPATH TRUE INSTALL_RPATH "@executable_path/../Frameworks"
  MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/Info.plist.in")

set(ORBIT_HELPER_TARGETS "")
set(ORBIT_HELPER_NAMES "")
foreach(SUFFIX_LIST IN LISTS CEF_HELPER_APP_SUFFIXES)
  string(REPLACE ":" ";" SUFFIX_VALUES "${SUFFIX_LIST}")
  list(GET SUFFIX_VALUES 0 HELPER_NAME_SUFFIX)
  list(GET SUFFIX_VALUES 1 HELPER_TARGET_SUFFIX)
  list(GET SUFFIX_VALUES 2 HELPER_PLIST_SUFFIX)
  set(HELPER_TARGET "OrbitChromium_Helper${HELPER_TARGET_SUFFIX}")
  set(HELPER_OUTPUT_NAME "OrbitChromium Helper${HELPER_NAME_SUFFIX}")
  set(HELPER_PLIST "${CMAKE_CURRENT_BINARY_DIR}/helper${HELPER_TARGET_SUFFIX}-Info.plist")
  configure_file(helper-Info.plist.in "${HELPER_PLIST}" @ONLY)
  # Minimal CEF distributions omit tests/cefsimple. Keep the pinned sandbox
  # helper entry point in the laboratory instead of depending on SDK examples.
  add_executable(${HELPER_TARGET} MACOSX_BUNDLE "${CMAKE_CURRENT_SOURCE_DIR}/Helper/main.cc")
  target_include_directories(${HELPER_TARGET} PRIVATE "${CEF_ROOT}")
  SET_EXECUTABLE_TARGET_PROPERTIES(${HELPER_TARGET})
  target_compile_definitions(${HELPER_TARGET} PRIVATE CEF_API_VERSION=15600 CEF_USE_SANDBOX=1)
  target_link_libraries(${HELPER_TARGET} PRIVATE pinned_cef_wrapper ${CEF_STANDARD_LIBS} OrbitNetworkQoS)
  set_target_properties(${HELPER_TARGET} PROPERTIES OUTPUT_NAME "${HELPER_OUTPUT_NAME}"
    CXX_STANDARD 20 MACOSX_BUNDLE_INFO_PLIST "${HELPER_PLIST}"
    BUILD_WITH_INSTALL_RPATH TRUE INSTALL_RPATH "@executable_path/../../..")
  list(APPEND ORBIT_HELPER_TARGETS "${HELPER_TARGET}")
  list(APPEND ORBIT_HELPER_NAMES "${HELPER_OUTPUT_NAME}")
endforeach()
list(LENGTH ORBIT_HELPER_TARGETS ORBIT_HELPER_COUNT)
if(NOT ORBIT_HELPER_COUNT EQUAL 5)
  message(FATAL_ERROR "The pinned sandbox packaging requires all five helper variants")
endif()
string(REPLACE ";" "|" ORBIT_HELPER_NAMES_ARGUMENT "${ORBIT_HELPER_NAMES}")
add_custom_target(package_orbit_chromium ALL
  COMMAND "${CMAKE_COMMAND}"
    "-DAPP=$<TARGET_BUNDLE_DIR:OrbitChromium>"
    "-DBUILD_DIRECTORY=${CMAKE_CURRENT_BINARY_DIR}"
    "-DCEF_ROOT=${CEF_ROOT}"
    "-DCEF_FRAMEWORK_SHA256=${CEF_FRAMEWORK_SHA256}"
    "-DHELPER_NAMES=${ORBIT_HELPER_NAMES_ARGUMENT}"
    -P "${CMAKE_CURRENT_SOURCE_DIR}/PackageBundle.cmake"
  DEPENDS OrbitChromium orbit_localization_resources ${ORBIT_HELPER_TARGETS}
  VERBATIM)

# Product build of Orbit (CHROMIUM-APP): the internal Orbit application over ChromiumEngine with the
# Chromium composition root instead of App/EngineComposition.swift, packaged as
# <build>/product/Orbit.app with five "Orbit Helper" bundles. Unsigned:
# versioning, signing and installation belong to scripts/orbit-app.py. The hidden smoke build
# <build>/smoke/Orbit.app compiles the same sources and composition with Smoke/ (driver) and the
# laboratory's Lab/HiddenGuard.swift instead of App/ProductLaunchHooks.swift; it is never
# installed. See docs/native-port/chromium-app-2026-10-25.md.
file(GLOB_RECURSE ORBIT_APP_SOURCES CONFIGURE_DEPENDS "${ORBIT_SOURCES}/Orbit/*.swift")
list(FILTER ORBIT_APP_SOURCES EXCLUDE REGEX "/Orbit/App/EngineComposition\\.swift$")
list(APPEND ORBIT_APP_SOURCES "${CMAKE_CURRENT_SOURCE_DIR}/App/EngineComposition+Chromium.swift"
  "${CMAKE_CURRENT_SOURCE_DIR}/App/ProductRuntimeOptions.swift"
  "${CMAKE_CURRENT_SOURCE_DIR}/App/OrbitPerformanceProbe.swift"
  "${CMAKE_CURRENT_SOURCE_DIR}/App/OrbitEnginePerformanceProbe.swift"
  "${CMAKE_CURRENT_SOURCE_DIR}/App/OrbitEngineSecurityProbe.swift"
  "${CMAKE_CURRENT_SOURCE_DIR}/App/OrbitResourcePerformanceProbe.swift"
  "${CMAKE_CURRENT_SOURCE_DIR}/App/OrbitResourceBudgetProbe.swift"
  "${CMAKE_CURRENT_SOURCE_DIR}/App/OrbitThumbnailPerformanceProbe.swift"
  "${CMAKE_CURRENT_SOURCE_DIR}/App/OrbitSelectionPerformanceProbe.swift"
  "${CMAKE_CURRENT_SOURCE_DIR}/App/OrbitDownloadAudioProbe.swift"
  "${CMAKE_CURRENT_SOURCE_DIR}/App/OrbitScrollWheelProbe.swift"
  "${CMAKE_CURRENT_SOURCE_DIR}/App/OrbitPinnedTabProbe.swift")
# CHROMIUM-APP-R3: the stable signing certificate's SHA-1 required for product mode (empty: none).
set(ORBIT_STABLE_SIGNING_ROOT "" CACHE STRING "SHA-1 of the stable local signing certificate (product admission)")
string(LENGTH "${ORBIT_STABLE_SIGNING_ROOT}" ORBIT_STABLE_SIGNING_ROOT_LENGTH)
if(NOT ORBIT_STABLE_SIGNING_ROOT MATCHES "^[A-Fa-f0-9]*$" OR
   NOT (ORBIT_STABLE_SIGNING_ROOT_LENGTH EQUAL 0 OR ORBIT_STABLE_SIGNING_ROOT_LENGTH EQUAL 40))
  message(FATAL_ERROR "ORBIT_STABLE_SIGNING_ROOT must be a 40-digit SHA-1 or empty")
endif()
file(READ "${CMAKE_CURRENT_SOURCE_DIR}/../../release/config.json" ORBIT_SIGNING_JSON)
string(JSON ORBIT_DEVELOPER_TEAM GET "${ORBIT_SIGNING_JSON}" team_id)
configure_file("${CMAKE_CURRENT_SOURCE_DIR}/App/StableSigning.swift.in" "${CMAKE_CURRENT_BINARY_DIR}/StableSigning.swift" @ONLY)
list(APPEND ORBIT_APP_SOURCES "${CMAKE_CURRENT_BINARY_DIR}/StableSigning.swift")
file(GLOB ORBIT_SMOKE_SOURCES CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/Smoke/*.swift")
set(SPARKLE_ROOT "" CACHE PATH "Verified Sparkle binary distribution")
set(ORBIT_RELEASE_CONFIG "${CMAKE_CURRENT_SOURCE_DIR}/../../release/config.json")
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${ORBIT_RELEASE_CONFIG}")
file(READ "${ORBIT_RELEASE_CONFIG}" ORBIT_RELEASE_JSON)
string(JSON SPARKLE_PUBLIC_ED_KEY GET "${ORBIT_RELEASE_JSON}" public_ed_key)
string(JSON ORBIT_RELEASE_REPOSITORY GET "${ORBIT_RELEASE_JSON}" repository)
function(orbit_app_executable TARGET DIRECTORY PLIST)
  # Swift emits dependency files beside the executable. Keep all compiler outputs outside
  # the bundle and stage only the executable in PackageApp.cmake.
  add_executable(${TARGET} ${ORBIT_APP_SOURCES} ${ARGN})
  set(ORBIT_SYNTHETIC_ROOT "${CMAKE_CURRENT_BINARY_DIR}/smoke-synthetic-data")
  configure_file("${PLIST}" "${CMAKE_CURRENT_BINARY_DIR}/${DIRECTORY}-Info.plist" @ONLY)
  if(DIRECTORY STREQUAL "smoke")
    # Built on demand (scripts/orbit-chromium-app.py), not by the laboratory's default build.
    set_target_properties(${TARGET} PROPERTIES EXCLUDE_FROM_ALL TRUE)
  endif()
  target_compile_options(${TARGET} PRIVATE ${ORBIT_SWIFT_FLAGS} -parse-as-library)
  target_include_directories(${TARGET} PRIVATE "${CMAKE_CURRENT_BINARY_DIR}/swift-modules"
    "${CMAKE_CURRENT_SOURCE_DIR}/Bridge")
  set(ORBIT_APP_LIBRARIES ChromiumEngine BrowserEngine BrowserShell BrowserCore OrbitChromiumBridge)
  if(DIRECTORY STREQUAL "smoke")
    # Test code: smoke build only. First, so that its dependencies are not listed twice: with
    # -ObjC a repeated archive is loaded twice (duplicate symbols).
    list(PREPEND ORBIT_APP_LIBRARIES BrowserEngineConformance)
  endif()
  target_link_libraries(${TARGET} PRIVATE ${ORBIT_APP_LIBRARIES})
  if(SPARKLE_ROOT)
    target_compile_options(${TARGET} PRIVATE "-F${SPARKLE_ROOT}")
    target_link_options(${TARGET} PRIVATE "-F${SPARKLE_ROOT}" "SHELL:-framework Sparkle")
  endif()
  target_link_options(${TARGET} PRIVATE "LINKER:-ObjC")
  set_target_properties(${TARGET} PROPERTIES Swift_LANGUAGE_VERSION 6 Swift_MODULE_NAME Orbit OUTPUT_NAME "${ORBIT_PRODUCT_NAME}"
    BUILD_WITH_INSTALL_RPATH TRUE INSTALL_RPATH "@executable_path/../Frameworks"
    Swift_MODULE_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/${DIRECTORY}-module"
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/${DIRECTORY}-bin")
endfunction()
orbit_app_executable(OrbitChromiumApp product "${CMAKE_CURRENT_SOURCE_DIR}/App/Info.plist.in"
  "${CMAKE_CURRENT_SOURCE_DIR}/App/ProductLaunchHooks.swift")
orbit_app_executable(OrbitChromiumAppSmoke smoke "${CMAKE_CURRENT_SOURCE_DIR}/Smoke/Info.plist.in"
  ${ORBIT_SMOKE_SOURCES} "${CMAKE_CURRENT_SOURCE_DIR}/Lab/HiddenGuard.swift")
add_dependencies(OrbitChromiumApp orbit_localization_resources)
add_dependencies(OrbitChromiumAppSmoke orbit_localization_resources)

set(ORBIT_APP_HELPER_TARGETS "")
set(ORBIT_APP_HELPER_NAMES "")
foreach(SUFFIX_LIST IN LISTS CEF_HELPER_APP_SUFFIXES)
  string(REPLACE ":" ";" SUFFIX_VALUES "${SUFFIX_LIST}")
  list(GET SUFFIX_VALUES 0 HELPER_NAME_SUFFIX)
  list(GET SUFFIX_VALUES 1 HELPER_TARGET_SUFFIX)
  list(GET SUFFIX_VALUES 2 HELPER_PLIST_SUFFIX)
  set(HELPER_TARGET "OrbitApp_Helper${HELPER_TARGET_SUFFIX}")
  set(HELPER_OUTPUT_NAME "${ORBIT_PRODUCT_NAME} Helper${HELPER_NAME_SUFFIX}")
  set(HELPER_PLIST "${CMAKE_CURRENT_BINARY_DIR}/app-helper${HELPER_TARGET_SUFFIX}-Info.plist")
  configure_file(App/helper-Info.plist.in "${HELPER_PLIST}" @ONLY)
  add_executable(${HELPER_TARGET} MACOSX_BUNDLE "${CMAKE_CURRENT_SOURCE_DIR}/Helper/main.cc")
  target_include_directories(${HELPER_TARGET} PRIVATE "${CEF_ROOT}")
  SET_EXECUTABLE_TARGET_PROPERTIES(${HELPER_TARGET})
  target_compile_definitions(${HELPER_TARGET} PRIVATE CEF_API_VERSION=15600 CEF_USE_SANDBOX=1)
  target_link_libraries(${HELPER_TARGET} PRIVATE pinned_cef_wrapper ${CEF_STANDARD_LIBS} OrbitNetworkQoS)
  set_target_properties(${HELPER_TARGET} PROPERTIES OUTPUT_NAME "${HELPER_OUTPUT_NAME}"
    CXX_STANDARD 20 MACOSX_BUNDLE_INFO_PLIST "${HELPER_PLIST}"
    BUILD_WITH_INSTALL_RPATH TRUE INSTALL_RPATH "@executable_path/../../.."
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/app-helpers")
  list(APPEND ORBIT_APP_HELPER_TARGETS "${HELPER_TARGET}")
  list(APPEND ORBIT_APP_HELPER_NAMES "${HELPER_OUTPUT_NAME}")
endforeach()
string(REPLACE ";" "|" ORBIT_APP_HELPER_NAMES_ARGUMENT "${ORBIT_APP_HELPER_NAMES}")
foreach(VARIANT IN ITEMS product smoke)
  if(VARIANT STREQUAL "product")
    set(APP_TARGET OrbitChromiumApp)
    set(PACKAGE_TARGET package_orbit_app)
  else()
    set(APP_TARGET OrbitChromiumAppSmoke)
    set(PACKAGE_TARGET package_orbit_app_smoke)
  endif()
  add_custom_target(${PACKAGE_TARGET}
    COMMAND "${CMAKE_COMMAND}"
      "-DSPARKLE_ROOT=${SPARKLE_ROOT}"
      "-DAPP=${CMAKE_CURRENT_BINARY_DIR}/${VARIANT}/${ORBIT_PRODUCT_NAME}.app"
      "-DEXECUTABLE=$<TARGET_FILE:${APP_TARGET}>"
      "-DINFO_PLIST=${CMAKE_CURRENT_BINARY_DIR}/${VARIANT}-Info.plist"
      "-DBUILD_DIRECTORY=${CMAKE_CURRENT_BINARY_DIR}"
      "-DHELPER_DIRECTORY=${CMAKE_CURRENT_BINARY_DIR}/app-helpers"
      "-DCEF_ROOT=${CEF_ROOT}"
      "-DCEF_FRAMEWORK_SHA256=${CEF_FRAMEWORK_SHA256}"
      "-DHELPER_NAMES=${ORBIT_APP_HELPER_NAMES_ARGUMENT}"
      -P "${CMAKE_CURRENT_SOURCE_DIR}/PackageApp.cmake"
    DEPENDS ${APP_TARGET} ${ORBIT_APP_HELPER_TARGETS}
    VERBATIM)
endforeach()

# Adapter lifecycle checks link a synthetic C bridge; they never load or execute CEF.
add_subdirectory(Tests EXCLUDE_FROM_ALL)
