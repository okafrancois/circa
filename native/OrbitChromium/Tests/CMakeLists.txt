add_library(ChromiumLifecycleBridgeStub STATIC LifecycleBridgeStub.c)
target_include_directories(ChromiumLifecycleBridgeStub PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/../Bridge")

file(GLOB LIFECYCLE_ENGINE_SOURCES CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/../ChromiumEngine/*.swift")
add_executable(ChromiumLifecycleTests LifecycleTests.swift ${LIFECYCLE_ENGINE_SOURCES})
set_target_properties(ChromiumLifecycleTests PROPERTIES Swift_LANGUAGE_VERSION 6)
target_compile_options(ChromiumLifecycleTests PRIVATE ${ORBIT_SWIFT_FLAGS} -parse-as-library)
target_include_directories(ChromiumLifecycleTests PRIVATE
  "${CMAKE_BINARY_DIR}/swift-modules" "${CMAKE_CURRENT_SOURCE_DIR}/../Bridge" "${CMAKE_CURRENT_SOURCE_DIR}")
target_link_libraries(ChromiumLifecycleTests PRIVATE BrowserEngine ChromiumLifecycleBridgeStub)

# Pure bridge policies (OrbitBridgePolicy.h), no CEF: `cmake --build <dir> --target OrbitBridgePolicyTests`.
add_executable(OrbitBridgePolicyTests BridgePolicyTests.cc)
target_include_directories(OrbitBridgePolicyTests PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/../Bridge")
set_target_properties(OrbitBridgePolicyTests PROPERTIES CXX_STANDARD 20 CXX_STANDARD_REQUIRED ON)

# Exercises the helper's compiled dyld interposition against a separately loaded image.
add_library(NetworkQoSFixture SHARED NetworkQoSFixture.cc)
add_executable(OrbitNetworkQoSTests NetworkQoSTests.cc)
target_link_libraries(OrbitNetworkQoSTests PRIVATE OrbitNetworkQoS)
target_include_directories(OrbitNetworkQoSTests PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/../Bridge")
set_target_properties(OrbitNetworkQoSTests PROPERTIES CXX_STANDARD 20 CXX_STANDARD_REQUIRED ON)

# Pure configuration/signature probe; no CEF or AppKit. It must be signed explicitly with the
# existing development identity and identifier io.github.okatech.orbit.test.orbit before execution. Never auto-run.
add_executable(OrbitProductAdmissionProbe ProductAdmissionProbe.swift
  "${ORBIT_SOURCES}/Orbit/Environment/OrbitBuildIdentity.swift"
  "${ORBIT_SOURCES}/Orbit/Environment/OrbitProductConfiguration.swift"
  "${ORBIT_SOURCES}/Orbit/Environment/SyntheticDataGuard.swift"
  "${ORBIT_SOURCES}/Orbit/Environment/LaunchConfiguration.swift"
  "${CMAKE_BINARY_DIR}/StableSigning.swift"
  "${CMAKE_CURRENT_SOURCE_DIR}/../App/ProductRuntimeOptions.swift")
target_compile_options(OrbitProductAdmissionProbe PRIVATE ${ORBIT_SWIFT_FLAGS} -parse-as-library)
set_target_properties(OrbitProductAdmissionProbe PROPERTIES Swift_LANGUAGE_VERSION 6)

target_include_directories(OrbitProductAdmissionProbe PRIVATE "${CMAKE_BINARY_DIR}/swift-modules"
  "${CMAKE_CURRENT_SOURCE_DIR}/../Bridge")
target_link_libraries(OrbitProductAdmissionProbe PRIVATE ChromiumEngine)

# Actual AppKit core/quit routing, shared with the product; no CEF, windows or Keychain.
add_executable(OrbitApplicationQuitTests ApplicationQuitTests.mm ../Bridge/OrbitApplicationLifecycle.mm)
target_compile_options(OrbitApplicationQuitTests PRIVATE -fobjc-arc)
set_target_properties(OrbitApplicationQuitTests PROPERTIES OBJCXX_STANDARD 20)
target_link_libraries(OrbitApplicationQuitTests PRIVATE "-framework AppKit" "-framework Carbon")

# Exact manager documents: details of one extension and keyboard shortcuts (EXT-OUTCOME-R2).
add_executable(OrbitExtensionRouteTests ../Bridge/OrbitExtensionRouteTests.cc)
target_include_directories(OrbitExtensionRouteTests PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/../Bridge")
set_target_properties(OrbitExtensionRouteTests PROPERTIES CXX_STANDARD 20 CXX_STANDARD_REQUIRED ON)
target_compile_options(OrbitExtensionRouteTests PRIVATE -UNDEBUG)

add_executable(OrbitFaviconPolicyTests FaviconPolicyTests.cc)
target_include_directories(OrbitFaviconPolicyTests PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/../Bridge")
set_target_properties(OrbitFaviconPolicyTests PROPERTIES CXX_STANDARD 20 CXX_STANDARD_REQUIRED ON)
target_compile_options(OrbitFaviconPolicyTests PRIVATE -UNDEBUG)

# Actual production operation/CEF adapter bodies against public interfaces and ASCII string
# doubles. Never links/loads the CEF framework or initializes a browser/application runtime.
add_executable(AuthenticationImportTests AuthenticationImportTests.mm AuthenticationCEFStrings.cc)
target_include_directories(AuthenticationImportTests PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/../Bridge" "${CEF_ROOT}")
target_compile_definitions(AuthenticationImportTests PRIVATE CEF_API_VERSION=15600)
set_target_properties(AuthenticationImportTests PROPERTIES CXX_STANDARD 20 OBJCXX_STANDARD 20)
target_compile_options(AuthenticationImportTests PRIVATE -UNDEBUG)

add_executable(AuthenticationImportSanitizerTests AuthenticationImportTests.mm AuthenticationCEFStrings.cc)
target_include_directories(AuthenticationImportSanitizerTests PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/../Bridge" "${CEF_ROOT}")
target_compile_definitions(AuthenticationImportSanitizerTests PRIVATE CEF_API_VERSION=15600)
set_target_properties(AuthenticationImportSanitizerTests PROPERTIES CXX_STANDARD 20 OBJCXX_STANDARD 20)
target_compile_options(AuthenticationImportSanitizerTests PRIVATE -UNDEBUG -fsanitize=address,undefined -fno-omit-frame-pointer)
target_link_options(AuthenticationImportSanitizerTests PRIVATE -fsanitize=address,undefined)

add_executable(AuthenticationCoordinatorTests AuthenticationCoordinatorTests.swift ${LIFECYCLE_ENGINE_SOURCES})
set_target_properties(AuthenticationCoordinatorTests PROPERTIES Swift_LANGUAGE_VERSION 6)
target_compile_options(AuthenticationCoordinatorTests PRIVATE ${ORBIT_SWIFT_FLAGS} -parse-as-library
  -assert-config Debug)
target_include_directories(AuthenticationCoordinatorTests PRIVATE
  "${CMAKE_BINARY_DIR}/swift-modules" "${CMAKE_CURRENT_SOURCE_DIR}/../Bridge")
target_link_libraries(AuthenticationCoordinatorTests PRIVATE BrowserEngine ChromiumLifecycleBridgeStub)

# Exact production callback receipts generated by FaviconR2/run_callbacks.py, no live CEF.
add_executable(FaviconReplayTests FaviconR2/FaviconReplayTests.swift ${LIFECYCLE_ENGINE_SOURCES})
set_target_properties(FaviconReplayTests PROPERTIES Swift_LANGUAGE_VERSION 6)
target_compile_options(FaviconReplayTests PRIVATE ${ORBIT_SWIFT_FLAGS} -parse-as-library)
target_include_directories(FaviconReplayTests PRIVATE
  "${CMAKE_BINARY_DIR}/swift-modules" "${CMAKE_CURRENT_SOURCE_DIR}/../Bridge" "${CMAKE_CURRENT_SOURCE_DIR}")
target_link_libraries(FaviconReplayTests PRIVATE BrowserEngine ChromiumLifecycleBridgeStub)

# API compatibility checks do not initialize CEF or open any browser/profile.
add_executable(OrbitEngineBinaryCompatibilityTests EngineBinaryCompatibilityTests.cc)
foreach(TARGET OrbitEngineBinaryCompatibilityTests)
  set_target_properties(${TARGET} PROPERTIES CXX_STANDARD 20 CXX_STANDARD_REQUIRED ON)
  target_compile_options(${TARGET} PRIVATE -UNDEBUG)
endforeach()

# Navigation actions and original popup metadata through the production Swift adapter, no CEF.
add_executable(ChromiumNavigationMetadataTests NavigationMetadataTests.swift ${LIFECYCLE_ENGINE_SOURCES})
set_target_properties(ChromiumNavigationMetadataTests PROPERTIES Swift_LANGUAGE_VERSION 6)
target_compile_options(ChromiumNavigationMetadataTests PRIVATE ${ORBIT_SWIFT_FLAGS} -parse-as-library -assert-config Debug)
target_include_directories(ChromiumNavigationMetadataTests PRIVATE
  "${CMAKE_BINARY_DIR}/swift-modules" "${CMAKE_CURRENT_SOURCE_DIR}/../Bridge" "${CMAKE_CURRENT_SOURCE_DIR}")
target_link_libraries(ChromiumNavigationMetadataTests PRIVATE BrowserEngine ChromiumLifecycleBridgeStub)
