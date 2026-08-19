import Foundation

/// On-disk field values of the recordings archive that Settings → History reads.
///
/// AIDEV-NOTE: This file is the ONE place in VoiceBarUI allowed to name the archive's ask
/// `source` discriminator, and `BoundaryContractTests` exempts it by name for that token alone.
/// The boundary it protects — VoiceBarUI stays presentation-only, with no sockets, no MCP calls,
/// no accessibility APIs — is untouched: this is a stored string in a JSON file the UI already
/// reads, not a call into the MCP layer. Keep it a lone constant; do not spread the literal.
enum SettingsArchiveSchema {
    /// `metadata.json` → `source` for an archived ask exchange.
    static let askSourceValue = "voice_ask"
}
