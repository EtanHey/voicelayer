import CoreGraphics

public enum VoiceBarScreenFollowPolicy {
    public static func targetScreenIndex(
        mouseLocation: CGPoint,
        screenFrames: [CGRect]
    ) -> Int? {
        screenFrames.firstIndex { $0.contains(mouseLocation) }
    }
}
