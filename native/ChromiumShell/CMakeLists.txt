cmake_minimum_required(VERSION 3.26)

set(CMAKE_OSX_ARCHITECTURES arm64 CACHE STRING "Pinned architecture" FORCE)
set(CMAKE_OSX_DEPLOYMENT_TARGET 15.0 CACHE STRING "Minimum macOS" FORCE)
project(ChromiumShell LANGUAGES C CXX OBJCXX Swift)

get_filename_component(SHELL_REPO_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../.." REALPATH)
set(SHELL_BUILD_ROOT "${SHELL_REPO_ROOT}/.tools/chromium-shell")
file(REAL_PATH "${CMAKE_BINARY_DIR}" SHELL_BUILD_DIRECTORY)
cmake_path(IS_PREFIX SHELL_BUILD_ROOT "${SHELL_BUILD_DIRECTORY}" NORMALIZE SHELL_BUILD_PRIVATE)
if(NOT APPLE OR NOT CMAKE_GENERATOR STREQUAL "Ninja" OR NOT SHELL_BUILD_PRIVATE
    OR NOT CMAKE_BUILD_TYPE STREQUAL "Release")
  message(FATAL_ERROR "Use macOS, Ninja, Release and a build directory inside .tools/chromium-shell")
endif()

set(SHELL_PINNED_SDK "${SHELL_REPO_ROOT}/.tools/cef/source/cef_binary_156.0.14+g4fa4ab5+chromium-156.0.8078.48_macosarm64")
set(SHELL_PINNED_WRAPPER "${SHELL_REPO_ROOT}/.tools/cef/build-release-arm64/libcef_dll_wrapper/libcef_dll_wrapper.a")
if(NOT IS_DIRECTORY "${CEF_ROOT}" OR NOT EXISTS "${CEF_WRAPPER_LIBRARY}")
  message(FATAL_ERROR "Pass the existing pinned CEF_ROOT and CEF_WRAPPER_LIBRARY; no SDK download or wrapper rebuild is supported")
endif()
file(REAL_PATH "${CEF_ROOT}" CEF_INPUT_ROOT)
file(REAL_PATH "${CEF_WRAPPER_LIBRARY}" CEF_INPUT_WRAPPER)
if(NOT CEF_INPUT_ROOT STREQUAL SHELL_PINNED_SDK OR NOT CEF_INPUT_WRAPPER STREQUAL SHELL_PINNED_WRAPPER)
  message(FATAL_ERROR "The SDK and wrapper paths must match the pinned laboratory inputs")
endif()
file(SHA256 "${CEF_WRAPPER_LIBRARY}" SHELL_WRAPPER_HASH)
if(NOT SHELL_WRAPPER_HASH STREQUAL "5b85d48f3caf9069cb2ebf794722dc356925c3dcba0b7ad800065cdc57686e85")
  message(FATAL_ERROR "Pinned wrapper hash mismatch")
endif()
file(READ "${CEF_ROOT}/include/cef_version.h" SHELL_CEF_VERSION)
if(NOT SHELL_CEF_VERSION MATCHES "4fa4ab516dacf6c49fc7e6e70d2b7ebce29fa35f")
  message(FATAL_ERROR "Pinned CEF source commit mismatch")
endif()

set(PROJECT_ARCH arm64 CACHE STRING "Pinned architecture" FORCE)
set(USE_SANDBOX ON CACHE BOOL "All helpers require the CEF sandbox" FORCE)
set(api_version 15600 CACHE STRING "Pinned CEF API" FORCE)
list(APPEND CMAKE_MODULE_PATH "${CEF_ROOT}/cmake")
find_package(CEF REQUIRED)
# The SDK resets these to macOS 13. Restore 15 for every host/helper target,
# and remove its competing command-line minimum before applying its flags.
set(CMAKE_OSX_DEPLOYMENT_TARGET 15.0 CACHE STRING "Minimum macOS" FORCE)
set(CMAKE_OSX_DEPLOYMENT_TARGET 15.0)
list(FILTER CEF_COMPILER_FLAGS EXCLUDE REGEX "^-mmacosx-version-min=")
add_library(pinned_cef_wrapper STATIC IMPORTED)
set_target_properties(pinned_cef_wrapper PROPERTIES IMPORTED_LOCATION "${CEF_WRAPPER_LIBRARY}")

add_library(ChromiumBridge STATIC ChromiumBridge.mm)
target_include_directories(ChromiumBridge PRIVATE "${CEF_ROOT}")
target_compile_definitions(ChromiumBridge PRIVATE ${CEF_COMPILER_DEFINES}
  CEF_API_VERSION=15600 CEF_USE_SANDBOX=1 AL_SHELL_REPO_ROOT="${SHELL_REPO_ROOT}")
target_compile_options(ChromiumBridge PRIVATE ${CEF_COMPILER_FLAGS}
  ${CEF_CXX_COMPILER_FLAGS} ${CEF_COMPILER_FLAGS_RELEASE} -fobjc-arc)
set_target_properties(ChromiumBridge PROPERTIES OBJCXX_STANDARD 20)
# CMake propagates the C++ runtime from this Objective-C++ dependency to Swift.
target_link_libraries(ChromiumBridge PUBLIC pinned_cef_wrapper ${CEF_STANDARD_LIBS})

add_executable(ChromiumShell MACOSX_BUNDLE main.swift)
target_compile_options(ChromiumShell PRIVATE
  -target arm64-apple-macosx15.0
  -module-cache-path "${CMAKE_CURRENT_BINARY_DIR}/swift-module-cache"
  -import-objc-header "${CMAKE_CURRENT_SOURCE_DIR}/ChromiumBridge.h")
target_link_libraries(ChromiumShell PRIVATE ChromiumBridge)
target_link_options(ChromiumShell PRIVATE "LINKER:-ObjC")
set_target_properties(ChromiumShell PROPERTIES Swift_LANGUAGE_VERSION 6
  MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/Info.plist.in")

set(SHELL_HELPER_TARGETS "")
set(SHELL_HELPER_NAMES "")
foreach(SUFFIX_LIST IN LISTS CEF_HELPER_APP_SUFFIXES)
  string(REPLACE ":" ";" SUFFIX_VALUES "${SUFFIX_LIST}")
  list(GET SUFFIX_VALUES 0 HELPER_NAME_SUFFIX)
  list(GET SUFFIX_VALUES 1 HELPER_TARGET_SUFFIX)
  list(GET SUFFIX_VALUES 2 HELPER_PLIST_SUFFIX)
  set(HELPER_TARGET "ChromiumShell_Helper${HELPER_TARGET_SUFFIX}")
  set(HELPER_OUTPUT_NAME "ChromiumShell Helper${HELPER_NAME_SUFFIX}")
  set(HELPER_PLIST "${CMAKE_CURRENT_BINARY_DIR}/helper${HELPER_TARGET_SUFFIX}-Info.plist")
  configure_file(helper-Info.plist.in "${HELPER_PLIST}" @ONLY)
  add_executable(${HELPER_TARGET} MACOSX_BUNDLE "${CEF_ROOT}/tests/cefsimple/process_helper_mac.cc")
  SET_EXECUTABLE_TARGET_PROPERTIES(${HELPER_TARGET})
  target_compile_definitions(${HELPER_TARGET} PRIVATE CEF_API_VERSION=15600 CEF_USE_SANDBOX=1)
  target_link_libraries(${HELPER_TARGET} PRIVATE pinned_cef_wrapper ${CEF_STANDARD_LIBS})
  set_target_properties(${HELPER_TARGET} PROPERTIES OUTPUT_NAME "${HELPER_OUTPUT_NAME}"
    CXX_STANDARD 20 MACOSX_BUNDLE_INFO_PLIST "${HELPER_PLIST}")
  list(APPEND SHELL_HELPER_TARGETS "${HELPER_TARGET}")
  list(APPEND SHELL_HELPER_NAMES "${HELPER_OUTPUT_NAME}")
endforeach()
list(LENGTH SHELL_HELPER_TARGETS SHELL_HELPER_COUNT)
if(NOT SHELL_HELPER_COUNT EQUAL 5)
  message(FATAL_ERROR "The pinned sandbox packaging requires all five helper variants")
endif()
string(REPLACE ";" "|" SHELL_HELPER_NAMES_ARGUMENT "${SHELL_HELPER_NAMES}")
add_custom_target(package_shell ALL
  COMMAND "${CMAKE_COMMAND}"
    "-DAPP=$<TARGET_BUNDLE_DIR:ChromiumShell>"
    "-DBUILD_DIRECTORY=${CMAKE_CURRENT_BINARY_DIR}"
    "-DPRIVATE_ROOT=${SHELL_BUILD_ROOT}"
    "-DCEF_ROOT=${CEF_ROOT}"
    "-DHELPER_NAMES=${SHELL_HELPER_NAMES_ARGUMENT}"
    -P "${CMAKE_CURRENT_SOURCE_DIR}/PackageBundle.cmake"
  DEPENDS ChromiumShell ${SHELL_HELPER_TARGETS}
  VERBATIM)
