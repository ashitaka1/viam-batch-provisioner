public enum ProvisioningStep: String, Sendable, CaseIterable {
    case found, booting, downloading, installing, configuring, installed
}
