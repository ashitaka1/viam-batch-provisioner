public enum ProvisioningStep: String, Sendable, CaseIterable {
    case found, booting, downloading, installing, configuring, installed

    /// The title a timeline row carries; `osName` nil reads as "OS".
    public func title(osName: String? = nil) -> String {
        let os = osName ?? "OS"
        return switch self {
        case .found: "Found"
        case .booting: "Booting"
        case .downloading: "Downloading \(os)"
        case .installing: "Installing \(os)"
        case .configuring: "Configuring"
        case .installed: "Installed"
        }
    }
}
