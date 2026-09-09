import Foundation
import AinkradAppKit
import ThrallFeature

/// The bundle's principal class (matches `NSPrincipalClass` in Info.plist).
@objc(ThrallEntryPoint)
final class ThrallEntryPoint: NSObject, AinkradPluginEntryPoint {
    static func app() -> any AinkradApp.Type { ThrallApp.self }
}
