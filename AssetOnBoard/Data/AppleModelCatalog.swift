//
//  AppleModelCatalog.swift
//  AssetOnBoard
//
//  Apple hardware identifier -> marketing name.
//
//  Apple devices publish their exact model through the `_device-info._tcp`
//  Bonjour record, so "iPhone16,2" on the wire becomes "iPhone 15 Pro Max" in
//  the UI. Non-Apple model strings fall through untouched — a Chromecast that
//  says `md=Chromecast Ultra` is already readable.
//

import Foundation

nonisolated enum AppleModelCatalog {

    struct Match: Sendable {
        let name: String
        let category: DeviceCategory
        let operatingSystem: String?
    }

    static func name(for identifier: String) -> Match? {
        let key = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let entry = table[key] else { return nil }
        return entry
    }

    private static let table: [String: Match] = {
        var result: [String: Match] = [:]
        result.reserveCapacity(200)
        for line in packed.split(separator: "\n") {
            let fields = line.split(separator: "|", omittingEmptySubsequences: false)
            guard fields.count >= 3, let separator = fields[0].firstIndex(of: "=") else { continue }
            let identifier = String(fields[0][fields[0].startIndex..<separator])
            let name = String(fields[0][fields[0].index(after: separator)...])
            let category = DeviceCategory(rawValue: String(fields[1])) ?? .unknown
            let operatingSystem = fields[2].isEmpty ? nil : String(fields[2])
            result[identifier] = Match(name: name, category: category, operatingSystem: operatingSystem)
        }
        return result
    }()

    private static let phone = DeviceCategory.phone.rawValue
    private static let tablet = DeviceCategory.tablet.rawValue
    private static let computer = DeviceCategory.computer.rawValue
    private static let tv = DeviceCategory.tv.rawValue
    private static let speaker = DeviceCategory.speaker.rawValue
    private static let wearable = DeviceCategory.wearable.rawValue
    private static let router = DeviceCategory.router.rawValue

    private static let packed = """
    iPhone8,1=iPhone 6s|Phone|iOS
    iPhone8,2=iPhone 6s Plus|Phone|iOS
    iPhone8,4=iPhone SE (1st generation)|Phone|iOS
    iPhone9,1=iPhone 7|Phone|iOS
    iPhone9,3=iPhone 7|Phone|iOS
    iPhone9,2=iPhone 7 Plus|Phone|iOS
    iPhone9,4=iPhone 7 Plus|Phone|iOS
    iPhone10,1=iPhone 8|Phone|iOS
    iPhone10,4=iPhone 8|Phone|iOS
    iPhone10,2=iPhone 8 Plus|Phone|iOS
    iPhone10,5=iPhone 8 Plus|Phone|iOS
    iPhone10,3=iPhone X|Phone|iOS
    iPhone10,6=iPhone X|Phone|iOS
    iPhone11,2=iPhone XS|Phone|iOS
    iPhone11,4=iPhone XS Max|Phone|iOS
    iPhone11,6=iPhone XS Max|Phone|iOS
    iPhone11,8=iPhone XR|Phone|iOS
    iPhone12,1=iPhone 11|Phone|iOS
    iPhone12,3=iPhone 11 Pro|Phone|iOS
    iPhone12,5=iPhone 11 Pro Max|Phone|iOS
    iPhone12,8=iPhone SE (2nd generation)|Phone|iOS
    iPhone13,1=iPhone 12 mini|Phone|iOS
    iPhone13,2=iPhone 12|Phone|iOS
    iPhone13,3=iPhone 12 Pro|Phone|iOS
    iPhone13,4=iPhone 12 Pro Max|Phone|iOS
    iPhone14,2=iPhone 13 Pro|Phone|iOS
    iPhone14,3=iPhone 13 Pro Max|Phone|iOS
    iPhone14,4=iPhone 13 mini|Phone|iOS
    iPhone14,5=iPhone 13|Phone|iOS
    iPhone14,6=iPhone SE (3rd generation)|Phone|iOS
    iPhone14,7=iPhone 14|Phone|iOS
    iPhone14,8=iPhone 14 Plus|Phone|iOS
    iPhone15,2=iPhone 14 Pro|Phone|iOS
    iPhone15,3=iPhone 14 Pro Max|Phone|iOS
    iPhone15,4=iPhone 15|Phone|iOS
    iPhone15,5=iPhone 15 Plus|Phone|iOS
    iPhone16,1=iPhone 15 Pro|Phone|iOS
    iPhone16,2=iPhone 15 Pro Max|Phone|iOS
    iPhone17,1=iPhone 16 Pro|Phone|iOS
    iPhone17,2=iPhone 16 Pro Max|Phone|iOS
    iPhone17,3=iPhone 16|Phone|iOS
    iPhone17,4=iPhone 16 Plus|Phone|iOS
    iPhone17,5=iPhone 16e|Phone|iOS
    iPad6,11=iPad (5th generation)|Tablet|iPadOS
    iPad6,12=iPad (5th generation)|Tablet|iPadOS
    iPad7,5=iPad (6th generation)|Tablet|iPadOS
    iPad7,6=iPad (6th generation)|Tablet|iPadOS
    iPad7,11=iPad (7th generation)|Tablet|iPadOS
    iPad7,12=iPad (7th generation)|Tablet|iPadOS
    iPad11,6=iPad (8th generation)|Tablet|iPadOS
    iPad11,7=iPad (8th generation)|Tablet|iPadOS
    iPad12,1=iPad (9th generation)|Tablet|iPadOS
    iPad12,2=iPad (9th generation)|Tablet|iPadOS
    iPad13,18=iPad (10th generation)|Tablet|iPadOS
    iPad13,19=iPad (10th generation)|Tablet|iPadOS
    iPad15,7=iPad (11th generation)|Tablet|iPadOS
    iPad15,8=iPad (11th generation)|Tablet|iPadOS
    iPad11,1=iPad mini (5th generation)|Tablet|iPadOS
    iPad11,2=iPad mini (5th generation)|Tablet|iPadOS
    iPad14,1=iPad mini (6th generation)|Tablet|iPadOS
    iPad14,2=iPad mini (6th generation)|Tablet|iPadOS
    iPad16,1=iPad mini (A17 Pro)|Tablet|iPadOS
    iPad16,2=iPad mini (A17 Pro)|Tablet|iPadOS
    iPad11,3=iPad Air (3rd generation)|Tablet|iPadOS
    iPad11,4=iPad Air (3rd generation)|Tablet|iPadOS
    iPad13,1=iPad Air (4th generation)|Tablet|iPadOS
    iPad13,2=iPad Air (4th generation)|Tablet|iPadOS
    iPad13,16=iPad Air (5th generation)|Tablet|iPadOS
    iPad13,17=iPad Air (5th generation)|Tablet|iPadOS
    iPad14,8=iPad Air 11-inch (M2)|Tablet|iPadOS
    iPad14,9=iPad Air 11-inch (M2)|Tablet|iPadOS
    iPad14,10=iPad Air 13-inch (M2)|Tablet|iPadOS
    iPad14,11=iPad Air 13-inch (M2)|Tablet|iPadOS
    iPad15,3=iPad Air 11-inch (M3)|Tablet|iPadOS
    iPad15,5=iPad Air 13-inch (M3)|Tablet|iPadOS
    iPad8,1=iPad Pro 11-inch|Tablet|iPadOS
    iPad8,9=iPad Pro 11-inch (2nd generation)|Tablet|iPadOS
    iPad13,4=iPad Pro 11-inch (3rd generation)|Tablet|iPadOS
    iPad14,3=iPad Pro 11-inch (4th generation)|Tablet|iPadOS
    iPad16,3=iPad Pro 11-inch (M4)|Tablet|iPadOS
    iPad16,4=iPad Pro 11-inch (M4)|Tablet|iPadOS
    iPad8,5=iPad Pro 12.9-inch (3rd generation)|Tablet|iPadOS
    iPad8,11=iPad Pro 12.9-inch (4th generation)|Tablet|iPadOS
    iPad13,8=iPad Pro 12.9-inch (5th generation)|Tablet|iPadOS
    iPad14,5=iPad Pro 12.9-inch (6th generation)|Tablet|iPadOS
    iPad16,5=iPad Pro 13-inch (M4)|Tablet|iPadOS
    iPad16,6=iPad Pro 13-inch (M4)|Tablet|iPadOS
    MacBookAir8,1=MacBook Air (Retina, 13-inch, 2018)|Computer|macOS
    MacBookAir9,1=MacBook Air (Retina, 13-inch, 2020)|Computer|macOS
    MacBookAir10,1=MacBook Air (M1, 2020)|Computer|macOS
    MacBookPro15,1=MacBook Pro (15-inch, 2018)|Computer|macOS
    MacBookPro16,1=MacBook Pro (16-inch, 2019)|Computer|macOS
    MacBookPro16,2=MacBook Pro (13-inch, 2020)|Computer|macOS
    MacBookPro17,1=MacBook Pro (13-inch, M1, 2020)|Computer|macOS
    MacBookPro18,1=MacBook Pro (16-inch, M1 Pro)|Computer|macOS
    MacBookPro18,2=MacBook Pro (16-inch, M1 Max)|Computer|macOS
    MacBookPro18,3=MacBook Pro (14-inch, M1 Pro)|Computer|macOS
    MacBookPro18,4=MacBook Pro (14-inch, M1 Max)|Computer|macOS
    Mac14,2=MacBook Air (M2, 2022)|Computer|macOS
    Mac14,15=MacBook Air (15-inch, M2, 2023)|Computer|macOS
    Mac14,7=MacBook Pro (13-inch, M2, 2022)|Computer|macOS
    Mac14,5=MacBook Pro (14-inch, M2 Max)|Computer|macOS
    Mac14,6=MacBook Pro (16-inch, M2 Max)|Computer|macOS
    Mac14,9=MacBook Pro (14-inch, M2 Pro)|Computer|macOS
    Mac14,10=MacBook Pro (16-inch, M2 Pro)|Computer|macOS
    Mac15,3=MacBook Pro (14-inch, M3)|Computer|macOS
    Mac15,6=MacBook Pro (14-inch, M3 Pro)|Computer|macOS
    Mac15,7=MacBook Pro (16-inch, M3 Pro)|Computer|macOS
    Mac15,8=MacBook Pro (14-inch, M3 Max)|Computer|macOS
    Mac15,9=MacBook Pro (16-inch, M3 Max)|Computer|macOS
    Mac15,12=MacBook Air (13-inch, M3, 2024)|Computer|macOS
    Mac15,13=MacBook Air (15-inch, M3, 2024)|Computer|macOS
    Mac16,1=MacBook Pro (14-inch, M4)|Computer|macOS
    Mac16,5=MacBook Pro (16-inch, M4 Pro)|Computer|macOS
    Mac16,6=MacBook Pro (14-inch, M4 Max)|Computer|macOS
    Mac16,7=MacBook Pro (16-inch, M4 Max)|Computer|macOS
    Mac16,8=MacBook Pro (14-inch, M4 Pro)|Computer|macOS
    Mac16,12=MacBook Air (13-inch, M4)|Computer|macOS
    Mac16,13=MacBook Air (15-inch, M4)|Computer|macOS
    Macmini8,1=Mac mini (2018)|Computer|macOS
    Macmini9,1=Mac mini (M1, 2020)|Computer|macOS
    Mac14,3=Mac mini (M2, 2023)|Computer|macOS
    Mac14,12=Mac mini (M2 Pro, 2023)|Computer|macOS
    Mac16,10=Mac mini (M4)|Computer|macOS
    Mac16,11=Mac mini (M4 Pro)|Computer|macOS
    iMac19,1=iMac (Retina 5K, 27-inch, 2019)|Computer|macOS
    iMac20,1=iMac (Retina 5K, 27-inch, 2020)|Computer|macOS
    iMac21,1=iMac (24-inch, M1)|Computer|macOS
    iMac21,2=iMac (24-inch, M1)|Computer|macOS
    Mac15,4=iMac (24-inch, M3)|Computer|macOS
    Mac15,5=iMac (24-inch, M3)|Computer|macOS
    Mac16,2=iMac (24-inch, M4)|Computer|macOS
    Mac16,3=iMac (24-inch, M4)|Computer|macOS
    Mac13,1=Mac Studio (M1 Max, 2022)|Computer|macOS
    Mac13,2=Mac Studio (M1 Ultra, 2022)|Computer|macOS
    Mac14,13=Mac Studio (M2 Max, 2023)|Computer|macOS
    Mac14,14=Mac Studio (M2 Ultra, 2023)|Computer|macOS
    Mac16,9=Mac Studio (M4 Max)|Computer|macOS
    MacPro7,1=Mac Pro (2019)|Computer|macOS
    Mac14,8=Mac Pro (M2 Ultra, 2023)|Computer|macOS
    AppleTV5,3=Apple TV HD|TV / Streaming|tvOS
    AppleTV6,2=Apple TV 4K (1st generation)|TV / Streaming|tvOS
    AppleTV11,1=Apple TV 4K (2nd generation)|TV / Streaming|tvOS
    AppleTV14,1=Apple TV 4K (3rd generation)|TV / Streaming|tvOS
    AudioAccessory1,1=HomePod|Speaker|audioOS
    AudioAccessory1,2=HomePod|Speaker|audioOS
    AudioAccessory5,1=HomePod mini|Speaker|audioOS
    AudioAccessory6,1=HomePod (2nd generation)|Speaker|audioOS
    Watch5,1=Apple Watch Series 5|Wearable|watchOS
    Watch5,9=Apple Watch SE|Wearable|watchOS
    Watch6,1=Apple Watch Series 6|Wearable|watchOS
    Watch6,6=Apple Watch Series 7|Wearable|watchOS
    Watch6,10=Apple Watch SE (2nd generation)|Wearable|watchOS
    Watch6,14=Apple Watch Series 8|Wearable|watchOS
    Watch6,18=Apple Watch Ultra|Wearable|watchOS
    Watch7,1=Apple Watch Series 9|Wearable|watchOS
    Watch7,5=Apple Watch Ultra 2|Wearable|watchOS
    Watch7,8=Apple Watch Series 10|Wearable|watchOS
    RealityDevice14,1=Apple Vision Pro|Computer|visionOS
    AirPort4,107=AirPort Express|Router / Gateway|
    AirPort5,108=AirPort Extreme|Router / Gateway|
    AirPort10,115=AirPort Time Capsule|Router / Gateway|
    """
}
