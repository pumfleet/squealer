import Foundation
import NetworkExtension

autoreleasepool {
    NEProvider.startSystemExtensionMode()
}
Engine.shared.start()
dispatchMain()
