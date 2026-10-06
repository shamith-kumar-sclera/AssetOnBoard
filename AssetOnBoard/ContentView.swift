//
//  ContentView.swift
//  AssetOnBoard
//
//  Created by Sclera on 03/09/26.
//

import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase

    /// Held here rather than inside each tab so results survive tab switches.
    @State private var networkScanner = NetworkScanner()
    @State private var bluetoothScanner = BluetoothScanner()
    @State private var accessPointScanner = AccessPointScanner()
    @State private var roomScanner = RoomScanner()
    /// Sequences all four scans into one pass and merges their results.
    @State private var onboarding = OnboardingCoordinator()
    @State private var selection: Tab = .onboarding
    @State private var permissions = PermissionsCoordinator()
    /// Set once the user has been through the permission screen, so it does not
    /// reappear on every launch. They can still be revisited from Settings.
    @AppStorage("hasSeenPermissionsScreen") private var hasSeenPermissions = false

    enum Tab: Hashable {
        case onboarding
        case wifi
        case accessPoints
        case bluetooth
        case room
    }

    var body: some View {
        if hasSeenPermissions {
            tabs
        } else {
            PermissionsView(coordinator: permissions) {
                hasSeenPermissions = true
            }
        }
    }

    private var tabs: some View {
        TabView(selection: $selection) {
            OnboardingView(coordinator: onboarding,
                           networkScanner: networkScanner,
                           bluetoothScanner: bluetoothScanner,
                           accessPointScanner: accessPointScanner,
                           roomScanner: roomScanner,
                           onAddRoomPhoto: { selection = .room })
                .tabItem { Label("Onboarding", systemImage: "shippingbox") }
                .tag(Tab.onboarding)

            WiFiScanView(scanner: networkScanner, bluetoothScanner: bluetoothScanner)
                .tabItem { Label("Wi-Fi", systemImage: "wifi") }
                .tag(Tab.wifi)

            AccessPointsView(scanner: accessPointScanner,
                             networkScanner: networkScanner,
                             bluetoothScanner: bluetoothScanner)
                .tabItem { Label("Access Points", systemImage: "wifi.router") }
                .tag(Tab.accessPoints)

            BluetoothScanView(scanner: bluetoothScanner, networkScanner: networkScanner)
                .tabItem { Label("Bluetooth", systemImage: "dot.radiowaves.left.and.right") }
                .tag(Tab.bluetooth)

            RoomScanView(scanner: roomScanner, networkScanner: networkScanner)
                .tabItem { Label("Room", systemImage: "camera.viewfinder") }
                .tag(Tab.room)
        }
        // NEHotspotHelper insists on registration at launch. Returns false
        // without the entitlement, which is the expected outcome.
        .task { accessPointScanner.hotspotHelper.register() }
        // Permissions can be changed in Settings while the app is backgrounded.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { permissions.refresh() }
        }
    }
}

#Preview {
    ContentView()
}
