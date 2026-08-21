public enum Toolchain {}

extension Toolchain {

    public static var hasTaggedMetadataSIGSEGV: Bool {
        #if compiler(<6.4)
            return true
        #else
            return false
        #endif
    }
}
