//
//  MenuBarController.swift
//  LosslessSwitcher
//
//  Created by Vincent Neo on 18/6/25.
//

import Observation
import SwiftUI

@Observable
class MenuBarController {
    @ObservationIgnored
    var outputDevices: OutputDevices!
    
    @ObservationIgnored
    private var mrController: MediaRemoteController!
    
    // Owned here rather than by OutputDevices: AppDelegate creates a second OutputDevices,
    // and two switchers would each pause and restart Music.
    @ObservationIgnored
    private var trackBoundarySwitcher: TrackBoundarySwitcher!
    
    init() {
        let outputDevices = OutputDevices()
        self.outputDevices = outputDevices
        self.mrController = MediaRemoteController(outputDevices: outputDevices)
        self.trackBoundarySwitcher = TrackBoundarySwitcher(outputDevices: outputDevices)
    }
}
