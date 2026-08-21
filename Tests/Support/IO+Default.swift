public import Kernel

extension IO where Capabilities == Basic.Capabilities {

    public static func `default`() -> IO<Basic.Capabilities> {
        #if os(Linux)
            if Kernel.IO.Uring.isSupported,
                let actor = try? Completion.Actor.shared()
            {
                return .completions(on: actor)
            }
        #endif
        #if !os(Windows)
            if let actor = try? Event.Actor.shared() {
                return .events(on: actor)
            }
        #endif
        return .blocking()
    }
}
