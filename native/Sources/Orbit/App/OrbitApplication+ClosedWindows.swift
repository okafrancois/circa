import AppKit

extension OrbitApplication: NSUserInterfaceValidations {
    func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(undo(_:)) {
            return commandKeyWindow() == nil && environment?.lastClosedWindowDate != nil
        }
        return true
    }

    @objc func undo(_ sender: Any?) {
        guard commandKeyWindow() == nil, let environment, environment.lastClosedWindowDate != nil else { return }
        Task { do { _ = try await environment.reopenClosedWindow() } catch { presentSaveError(error) } }
    }
}
