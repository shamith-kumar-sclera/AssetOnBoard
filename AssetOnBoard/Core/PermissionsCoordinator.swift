//
//  PermissionsCoordinator.swift
//  AssetOnBoard
//
//  Asks for everything the app needs, once, at launch.
//
//  Three permissions gate three different parts of this app, and each is
//  requested by *doing* the thing rather than by calling a request API — iOS has
//  no way to raise several prompts at once, and no way to raise one without the
//  underlying work starting. So this drives them one at a time, in the order
//  that makes each prompt explicable to whoever is reading it.
//
//  Local Network is the awkward one: iOS offers no API to read its status, so
//  the only way to know is to browse and see whether anything answers. That is
//  why it is inferred with a timeout rather than queried, and why "not decided"
//  and "quiet network" can look alike.
//

import Foundation
import CoreLocation
import CoreBluetooth
import Observation

@Observable
final class PermissionsCoordinator: NSObject {

    enum Permission: String, CaseIterable, Identifiable {
        case localNetwork
        case location
        case bluetooth

        var id: String { rawValue }

        var title: String {
            switch self {
            case .localNetwork: "Local Network"
            case .location: "Location"
            case .bluetooth: "Bluetooth"
            }
        }

        var symbolName: String {
            switch self {
            case .localNetwork: "network"
            case .location: "location.fill"
            case .bluetooth: "dot.radiowaves.left.and.right"
            }
        }

        /// Why the app is asking — phrased as the user's benefit, not the API's.
        var rationale: String {
            switch self {
            case .localNetwork:
                "Lets the app see the devices on the network you are joined to. Without it the Wi-Fi tab stays empty."
            case .location:
                "iOS releases your access point's MAC address (BSSID) only with location access, because a BSSID identifies a physical place. Your position is never recorded or sent anywhere."
            case .bluetooth:
                "Finds Bluetooth devices nearby, and the setup beacons that access point hardware broadcasts."
            }
        }

        /// What still works if the user says no.
        var consequenceIfDenied: String {
            switch self {
            case .localNetwork: "Network scanning will not work."
            case .location: "Everything works except your access point's MAC address."
            case .bluetooth: "The Bluetooth tab stays empty; the other tabs are unaffected."
            }
        }
    }

    enum Status: Equatable {
        case notDetermined
        case granted
        case denied
        /// The hardware or simulator cannot provide it at all.
        case unavailable(String)

        var isDecided: Bool {
            switch self {
            case .notDetermined: false
            case .granted, .denied, .unavailable: true
            }
        }
    }

    private(set) var statuses: [Permission: Status] = [:]
    private(set) var isRequesting = false
    /// The permission currently showing a system prompt, for the UI to highlight.
    private(set) var inFlight: Permission?

    /// True once every permission has an answer, however the user answered.
    var allDecided: Bool {
        Permission.allCases.allSatisfy { statuses[$0]?.isDecided ?? false }
    }

    var grantedCount: Int {
        Permission.allCases.filter { statuses[$0] == .granted }.count
    }

    private let locationManager = CLLocationManager()
    private var bluetoothCentral: CBCentralManager?
    private var bluetoothContinuation: CheckedContinuation<Void, Never>?
    private var locationContinuation: CheckedContinuation<Void, Never>?

    override init() {
        super.init()
        locationManager.delegate = self
        refresh()
    }

    // MARK: - Reading current state

    func refresh() {
        statuses[.location] = Self.map(locationManager.authorizationStatus)
        statuses[.bluetooth] = Self.map(CBManager.authorization)
        // Local Network has no queryable status; keep whatever we inferred.
        if statuses[.localNetwork] == nil { statuses[.localNetwork] = .notDetermined }
    }

    private static func map(_ status: CLAuthorizationStatus) -> Status {
        switch status {
        case .notDetermined: .notDetermined
        case .authorizedWhenInUse, .authorizedAlways: .granted
        case .denied, .restricted: .denied
        @unknown default: .notDetermined
        }
    }

    private static func map(_ status: CBManagerAuthorization) -> Status {
        switch status {
        case .notDetermined: .notDetermined
        case .allowedAlways: .granted
        case .denied, .restricted: .denied
        @unknown default: .notDetermined
        }
    }

    // MARK: - Requesting

    /// Walks every undecided permission, one prompt at a time.
    ///
    /// Sequential on purpose: iOS queues simultaneous prompts and the user ends
    /// up approving things without reading them.
    func requestAll() async {
        guard !isRequesting else { return }
        isRequesting = true
        defer { isRequesting = false; inFlight = nil }

        for permission in Permission.allCases {
            guard statuses[permission]?.isDecided != true else { continue }
            inFlight = permission
            await request(permission)
            // A beat between prompts so they do not appear to stack.
            try? await Task.sleep(for: .milliseconds(350))
        }
    }

    func request(_ permission: Permission) async {
        switch permission {
        case .localNetwork: await requestLocalNetwork()
        case .location: await requestLocation()
        case .bluetooth: await requestBluetooth()
        }
    }

    /// Triggers the Local Network prompt by actually browsing.
    ///
    /// There is no request API and no status API. Starting a Bonjour browse is
    /// what raises the prompt, and the only signal afterwards is whether the
    /// browser was refused — so this waits, then reads that.
    private func requestLocalNetwork() async {
        let discovery = BonjourDiscovery()
        let stream = discovery.start(types: ["_companion-link._tcp"])

        // Draining the stream keeps the browser alive; we want the side effect.
        let drain = Task { for await _ in stream { } }
        try? await Task.sleep(for: .seconds(3))
        drain.cancel()

        statuses[.localNetwork] = discovery.permissionDenied ? .denied : .granted
    }

    private func requestLocation() async {
        guard locationManager.authorizationStatus == .notDetermined else {
            statuses[.location] = Self.map(locationManager.authorizationStatus)
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            locationContinuation = continuation
            locationManager.requestWhenInUseAuthorization()
        }
    }

    /// Instantiating a central manager is what raises the Bluetooth prompt.
    private func requestBluetooth() async {
        guard CBManager.authorization == .notDetermined else {
            statuses[.bluetooth] = Self.map(CBManager.authorization)
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            bluetoothContinuation = continuation
            bluetoothCentral = CBCentralManager(delegate: self,
                                                queue: .main,
                                                options: [CBCentralManagerOptionShowPowerAlertKey: false])
        }
    }

    private func finishBluetooth() {
        let pending = bluetoothContinuation
        bluetoothContinuation = nil
        pending?.resume()
    }
}

// MARK: - CLLocationManagerDelegate

extension PermissionsCoordinator: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        statuses[.location] = Self.map(manager.authorizationStatus)
        guard manager.authorizationStatus != .notDetermined else { return }
        let pending = locationContinuation
        locationContinuation = nil
        pending?.resume()
    }
}

// MARK: - CBCentralManagerDelegate

extension PermissionsCoordinator: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .unsupported:
            statuses[.bluetooth] = .unavailable("No Bluetooth LE radio. The iOS Simulator does not provide one.")
            finishBluetooth()
        case .unauthorized:
            statuses[.bluetooth] = .denied
            finishBluetooth()
        case .poweredOn, .poweredOff:
            // Powered off is not a refusal — the permission itself was granted.
            statuses[.bluetooth] = Self.map(CBManager.authorization)
            finishBluetooth()
        case .resetting, .unknown:
            break
        @unknown default:
            finishBluetooth()
        }
    }
}
