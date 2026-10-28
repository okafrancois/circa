        // Retained service references must revalidate instead of trusting discovery time.
        let oldManager = engine.extensionManagement!
        engine.isShutDown = true
        do { try oldManager.openManagement(on: surface); preconditionFailure("retained manager after shutdown") } catch {}
        engine.isShutDown = false
        let beforeCalls = calls.count
        registration.token = 0
        do { try oldManager.openManagement(on: surface); preconditionFailure("registration token mismatch") } catch {}
        registration.token = 3
        surface.engine = nil
        do { try oldManager.openManagement(on: surface); preconditionFailure("orphan surface") } catch {}
        surface.engine = engine
        precondition(calls.count == beforeCalls)
        final class ForeignSurface: BrowserEngineSurface {}
        do { try oldManager.openManagement(on: ForeignSurface()); preconditionFailure("foreign surface type") } catch {}
        precondition(calls.count == beforeCalls)
        print("PASS independent actual Swift adapter: retained service, orphan, registration token and foreign type")
