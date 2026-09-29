import UIKit

/// The name the Mac shows in its paired-device list.
enum UIDeviceNameBridge {
    @MainActor static var name: String { UIDevice.current.name }
}
