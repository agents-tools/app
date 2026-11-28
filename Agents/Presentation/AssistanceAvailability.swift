import FoundationModels

struct AssistanceAvailability {
  static var isAvailable: Bool {
    guard #available(macOS 26, *) else { return false }
    if case .available = SystemLanguageModel.default.availability { return true }
    return false
  }
  static var status: String {
    guard #available(macOS 26, *) else { return "Requires macOS 26 or later." }
    switch SystemLanguageModel.default.availability {
    case .available: return "The on-device model is available."
    case .unavailable(let reason):
      switch reason {
      case .deviceNotEligible: return "This Mac does not support the on-device model."
      case .appleIntelligenceNotEnabled: return "Apple Intelligence is not enabled."
      case .modelNotReady: return "The on-device model is not ready."
      @unknown default: return "The on-device model is currently unavailable."
      }
    }
  }
}
