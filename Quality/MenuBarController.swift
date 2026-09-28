//
//  MenuBarController.swift
//  LosslessSwitcher
//
//  Created by Vincent Neo on 18/6/25.
//

import Combine
import Observation
import SwiftUI

@Observable
class MenuBarController {
    // One instance for the whole app: AppDelegate reads its OutputDevices too.
    static let shared = MenuBarController()

    @ObservationIgnored
    var outputDevices: OutputDevices!
    
    @ObservationIgnored
    private var mrController: MediaRemoteController!
    
    // Owned here, next to the only OutputDevices, so there is exactly one switcher.
    @ObservationIgnored
    private var trackBoundarySwitcher: TrackBoundarySwitcher!

    @ObservationIgnored
    var bitPerfectCheck: BitPerfectCheck!

    @ObservationIgnored
    private var rendererEngine: RendererEngine!

    @ObservationIgnored
    private var rendererCancellable: AnyCancellable?

    @ObservationIgnored
    private var selectedDeviceCancellable: AnyCancellable?
    
    private init() {
        let outputDevices = OutputDevices()
        self.outputDevices = outputDevices
        self.mrController = MediaRemoteController(outputDevices: outputDevices)
        self.trackBoundarySwitcher = TrackBoundarySwitcher(outputDevices: outputDevices)
        self.bitPerfectCheck = BitPerfectCheck(outputDevice: { [weak outputDevices] in
            (outputDevices?.selectedOutputDevice ?? outputDevices?.defaultOutputDevice)?.id
        })
        self.selectedDeviceCancellable = outputDevices.$selectedOutputDevice.dropFirst().sink { [weak self] _ in
            self?.bitPerfectCheck.refreshAfterDeviceChange()
        }
        let engine = RendererEngine(outputDevices: outputDevices)
        self.rendererEngine = engine
        self.rendererCancellable = Defaults.shared.$userPreferRendererEngine
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { on in
                if on { engine.start() } else { engine.stop() }
            }
    }

    /// Called on quit: tears the renderer's pipeline down and gives Music its volume back.
    func stopRenderer() {
        rendererEngine.stop()
    }
}
