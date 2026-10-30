/// Product identity shared by the application, CMake and Python packaging.
/// Keep these literal strings here: build tools read them without running Swift.
public enum ProductIdentity {
    public static let bundleIdentifier = "io.github.okatech.orbit"
    public static let displayName = "Circa"
    public static let executableName = "Orbit"
    public static let dataDirectoryName = "Orbit"
    public static let keychainAccount = "Orbit"
    public static let keychainService = "Orbit Safe Storage"
}
