//
//  AssetOnBoardApp.swift
//  AssetOnBoard
//
//  Created by Sclera on 03/09/26.
//

import SwiftUI

@main
struct AssetOnBoardApp: App {
    init() {
        // Do this before any scanning: the descriptor ceiling decides how wide
        // the scanner is allowed to fan out.
        SystemLimits.raiseFileDescriptorLimit()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
