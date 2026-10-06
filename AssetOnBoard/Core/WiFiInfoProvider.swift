//
//  WiFiInfoProvider.swift
//  AssetOnBoard
//
//  Details of the Wi-Fi network this device is joined to.
//
//  This is the only way an App Store app learns an access point's MAC address:
//  the BSSID of the network you are *currently associated with*. iOS provides no
//  API for scanning the airwaves — enumerating nearby SSIDs needs the
//  NEHotspotHelper entitlement, which Apple issues only to captive-network
//  vendors. So this reports one access point, accurately, rather than a list.
//
//  Two gates apply. The target needs the "Access WiFi Information" capability
//  (com.apple.developer.networking.wifi-info), and iOS withholds the BSSID until
//  the user grants location access, because a BSSID identifies a physical place.
//

import Foundation
import NetworkExtension
import CoreLocation

nonisolated struct JoinedNetwork: Sendable {
    var ssid: String?
    /// The access point's hardware address.
    var bssid: MACAddress?
    var vendor: String?
    var isSecure: Bool?
    var signalStrength: Double?
}

@Observable
final class WiFiInfoProvider: NSObject {

    enum Status: Equatable {
        case idle
        case needsLocationPermission
        case locationDenied
        case unavailable(String)
        case ready

        var message: String {
            switch self {
            case .idle: "Checking the joined network…"
            case .needsLocationPermission:
                "iOS releases an access point's BSSID only once location access is granted, because a BSSID pinpoints a physical location."
            case .locationDenied:
                "Location access was declined, so iOS withholds the access point's MAC address. The network name and gateway are still available."
            case .unavailable(let reason): reason
            case .ready: "Ready"
            }
        }
    }

    private(set) var status: Status = .idle
    private(set) var joined: JoinedNetwork?

    private let locationManager = CLLocationManager()

    override init() {
        super.init()
        locationManager.delegate = self
    }

    /// Asks for location access if it has not been decided yet.
    func requestLocationPermission() {
        switch locationManager.authorizationStatus {
        case .notDetermined: locationManager.requestWhenInUseAuthorization()
        case .denied, .restricted: status = .locationDenied
        default: Task { await refresh() }
        }
    }

    /// Reads the currently joined network.
    func refresh() async {
        #if targetEnvironment(simulator)
        status = .unavailable("The iOS Simulator has no Wi-Fi radio, so no access point information is available. Run on a real iPhone.")
        return
        #else
        let authorisation = locationManager.authorizationStatus
        switch authorisation {
        case .notDetermined:
            status = .needsLocationPermission
            return
        case .denied, .restricted:
            status = .locationDenied
        default:
            break
        }

        guard let network = await NEHotspotNetwork.fetchCurrent() else {
            status = .unavailable("Not joined to a Wi-Fi network, or the Access WiFi Information capability is not enabled for this build.")
            joined = nil
            return
        }

        let mac = MACAddress(network.bssid)
        joined = JoinedNetwork(ssid: network.ssid.isEmpty ? nil : network.ssid,
                               bssid: mac,
                               vendor: mac.flatMap { OUIDatabase.vendor(for: $0) },
                               isSecure: network.isSecure,
                               signalStrength: network.signalStrength)
        if authorisation == .authorizedWhenInUse || authorisation == .authorizedAlways {
            status = .ready
        }
        #endif
    }
}

extension WiFiInfoProvider: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            Task { await refresh() }
        case .denied, .restricted:
            status = .locationDenied
            Task { await refresh() }
        default:
            status = .needsLocationPermission
        }
    }
}
