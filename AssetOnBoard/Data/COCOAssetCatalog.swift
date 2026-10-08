//
//  COCOAssetCatalog.swift
//  AssetOnBoard
//
//  Maps the classes a detector emits onto asset categories.
//
//  This table used to be a complaint. COCO has 80 classes and only about a
//  dozen are things an IT asset register cares about: no router, no access
//  point, no switch, no server, no printer, no projector — which meant the
//  detector could not see most of what the Wi-Fi tab finds, and no amount of
//  making the model bigger would change that, because the vocabulary was the
//  limit rather than the accuracy.
//
//  The bundled detector is now open-vocabulary (YOLO-World v2), which is told
//  at export time what to look for, so it was told exactly that missing list.
//  Both vocabularies are kept here: the app loads whichever model is present,
//  and a COCO model still works with the classes it does have.
//
//  Only electrical classes are reported. The furniture and household rows stay
//  in the table so a class can still be named, but `isElectrical` is what the
//  sweep and the photo pass consult before a detection is allowed to exist,
//  and a chair never passes it.
//

import Foundation

nonisolated enum COCOAssetCatalog {

    /// The open-vocabulary detector's classes, which are the ones that matter.
    ///
    /// These names are the prompts baked into the model at export, so this table
    /// and the exported vocabulary have to agree exactly — changing one without
    /// the other silently files real detections under "Other".
    private static let assetVocabulary: [String: AssetCategory] = [
        "printer": .printer,
        "wifi router": .networkGear,
        "wireless access point": .networkGear,
        "network switch": .networkGear,
        "server rack": .networkGear,
        "desktop computer tower": .computer,
        "computer monitor": .display,
        "laptop": .computer,
        "tablet computer": .phone,
        "mobile phone": .phone,
        "desk telephone": .peripheral,
        "security camera": .networkGear,
        "projector": .display,
        "document scanner": .printer,
        "uninterruptible power supply": .networkGear,
        "keyboard": .peripheral,
        "computer mouse": .peripheral,
        "television": .display,
        "loudspeaker": .peripheral,

        // Context, useful for recognising the room, not for the register.
        "office chair": .furniture,
        "desk": .furniture
    ]

    /// COCO class name -> the category we file it under, for a COCO model.
    private static let cocoMapping: [String: AssetCategory] = [
        // Things an asset register wants.
        "tv": .display,
        "laptop": .computer,
        "keyboard": .peripheral,
        "mouse": .peripheral,
        "remote": .peripheral,
        "cell phone": .phone,

        // Electrical, so inventoried, even if nothing on the network answers
        // for them.
        "microwave": .appliance,
        "oven": .appliance,
        "toaster": .appliance,
        "refrigerator": .appliance,
        "hair drier": .appliance,

        // Known so they can be named; never reported, because not electrical.
        "sink": .furniture,
        "chair": .furniture,
        "couch": .furniture,
        "bed": .furniture,
        "dining table": .furniture,
        "potted plant": .furniture,
        "book": .other,
        "clock": .other,
        "vase": .other
    ]

    /// Everything either vocabulary can file.
    private static let mapping: [String: AssetCategory] =
        cocoMapping.merging(assetVocabulary) { _, open in open }

    /// Asset classes a plain COCO model will never report.
    ///
    /// Kept so the UI can still explain the gap when a COCO model is what is
    /// bundled. The open-vocabulary detector covers all of these.
    static let unmappedButRelevant = [
        "router", "access point", "network switch", "NAS", "server",
        "printer", "scanner", "projector", "IP camera", "desk phone",
        "monitor (reported as tv)", "desktop tower", "tablet", "UPS"
    ]

    /// True when the loaded model knows the asset vocabulary rather than COCO.
    static func isOpenVocabulary(_ labels: [String]) -> Bool {
        labels.contains { assetVocabulary[$0.lowercased()] != nil }
    }

    /// Classes that are people. Never listed as assets.
    ///
    /// A detector pointed at an office will find staff. Putting them in an
    /// inventory would be both useless and a privacy problem, so they are
    /// counted and discarded rather than recorded.
    static let personClasses: Set<String> = ["person"]

    static func category(for label: String) -> AssetCategory? {
        mapping[label.lowercased()]
    }

    /// Whether a detector class is something the sweep reports at all.
    ///
    /// The single gate for both the video sweep and the photo pass: a class
    /// that is not electrical equipment is dropped before it can open a track
    /// or draw a box. Unknown classes are not electrical.
    static func isElectrical(_ label: String) -> Bool {
        category(for: label)?.isElectrical == true
    }

    /// True for a class worth showing at all.
    static func isRecognisedAsset(_ label: String) -> Bool {
        mapping[label.lowercased()] != nil
    }

    /// A friendlier name than the raw class where one helps.
    ///
    /// `tv` is the notable one: COCO uses it for anything screen-shaped, so a
    /// desk monitor comes back as "tv" and calling it that reads as a mistake.
    static func displayName(for label: String) -> String {
        switch label.lowercased() {
        case "tv": "Display or TV"
        case "wifi router": "Router"
        case "wireless access point": "Access point"
        case "desktop computer tower": "Desktop PC"
        case "computer monitor": "Monitor"
        case "tablet computer": "Tablet"
        case "mobile phone": "Phone"
        case "desk telephone": "Desk phone"
        case "uninterruptible power supply": "UPS"
        case "document scanner": "Scanner"
        case "computer mouse": "Mouse"
        case "loudspeaker": "Speaker"
        case "security camera": "IP camera"
        case "cell phone": "Phone"
        case "remote": "Remote control"
        case "potted plant": "Plant"
        case "dining table": "Table"
        default: label.capitalized
        }
    }
}
