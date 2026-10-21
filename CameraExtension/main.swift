import CoreMediaIO
import Foundation

// The Life × Physarum virtual camera. macOS runs this extension on its own;
// the app sends it frames through the device's sink stream, and video apps
// read them from its source stream.
let providerSource = CameraProviderSource()
CMIOExtensionProvider.startService(provider: providerSource.provider)
CFRunLoopRun()
