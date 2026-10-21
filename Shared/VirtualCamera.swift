import Foundation

/// What the app and its camera extension agree on: the virtual camera's IDs
/// and video format. Shared by both targets.
nonisolated enum VirtualCamera {
    /// The camera extension's bundle identifier, for activation requests.
    static let extensionID = "com.moishelettvin.LifeXPhysarum.Camera"
    /// The name video apps show in their camera menus.
    static let name = "Life × Physarum"

    // Fixed so the app can find the device and its sink stream, and so the
    // camera keeps its identity (and video apps their selection) across updates.
    static let deviceID = UUID(uuidString: "1DB6B6FF-437A-4A62-BF92-C222DD705A1F")!
    static let sourceStreamID = UUID(uuidString: "7A621441-4FB8-4B8E-9916-450FB632EE17")!
    static let sinkStreamID = UUID(uuidString: "29F2F7A9-28FD-4300-818A-C64D81614E54")!

    /// 720p, which every video app accepts; the square field is centered in it.
    static let width = 1280
    static let height = 720
    static let framesPerSecond: Int32 = 30
}
