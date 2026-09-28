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
    private var virtualEngine: VirtualDeviceEngine!

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
        let vEngine = VirtualDeviceEngine(outputDevices: outputDevices)
        self.rendererEngine = engine
        self.virtualEngine = vEngine
        // an earlier run that died can leave the virtual device as the default output
        VirtualDeviceEngine.recoverOutput()
        self.rendererCancellable = Defaults.shared.$userPreferRendererEngine
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { on in
                guard on else { vEngine.stop(); engine.stop(); return }
                // The virtual device (HAL plug-in) allows hog mode and integer output on the DAC;
                // without it the engine takes Music's audio with a process tap.
                if UserDefaults.standard.bool(forKey: "RendererForceTapEngine") {
                    engine.startupNote = "RendererForceTapEngine is set; using the process-tap engine"
                    engine.start()
                } else if VirtualDeviceEngine.findDevice() != nil {
                    vEngine.start()
                } else {
                    engine.startupNote = "LosslessSwitcher Output plug-in not found (\(VirtualDeviceEngine.pluginPath)); using the process-tap engine (no hog mode)"
                    engine.start()
                }
            }
    }

    /// Called on quit: stops the renderer, gives the DAC back, restores the default output and
    /// Music's volume.
    func stopRenderer() {
        virtualEngine.stop()
        rendererEngine.stop()
    }
}
