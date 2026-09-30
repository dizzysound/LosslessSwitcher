//
//  SampleRateLabel.swift
//  Nativerate
//
//  Created by Vincent Neo on 23/6/25.
//

import SwiftUI

struct SampleRateLabel: View {
    @EnvironmentObject private var outputDevices: OutputDevices
    @ObservedObject private var renderer = RendererOutput.shared
    var body: some View {
        if let currentSampleRate = outputDevices.currentSampleRate {
            // Exclusive Mode: the rate is the virtual device's, which has no source depth; the engine
            // knows the track's (Bit Depth Switching is hidden there, so it shows either way)
            if renderer.dacName != nil {
                Text(String(format: "%.1f kHz / ", currentSampleRate) + renderer.sourceText)
            } else if outputDevices.enableBitDepthDetection {
                if let bitDepth = outputDevices.currentBitDepth {
                    Text(String(format: "%.1f kHz / %d bit", currentSampleRate, bitDepth))
                } else {
                    Text(String(format: "%.1f kHz / ? bit", currentSampleRate))
                }
            } else {
                Text(String(format: "%.1f kHz", currentSampleRate))
            }
        } else {
            Text("Unknown")
        }
    }
}
