// Measures a DAC's real sample rate against the host clock: an IOProc (silence) records its output
// timestamps; the rate is the sample-time slope over the host-time span, compared with the nominal
// rate and with the HAL's own rate scalar (mRateScalar). Independent of the engine.
// Usage: clockrate <device-name-substring> <rate> [seconds]
import CoreAudio
import Foundation

func addr(_ s: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: s, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
}
func devices() -> [AudioObjectID] {
    var a = addr(kAudioHardwarePropertyDevices); var z = UInt32(0)
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &z)
    var ids = [AudioObjectID](repeating: 0, count: Int(z) / 4)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &z, &ids); return ids
}
func name(_ d: AudioObjectID) -> String {
    var a = addr(kAudioObjectPropertyName); var s: Unmanaged<CFString>?; var z = UInt32(MemoryLayout<CFString?>.size)
    AudioObjectGetPropertyData(d, &a, 0, nil, &z, &s); return (s?.takeRetainedValue() as String?) ?? "?"
}

let args = CommandLine.arguments
guard args.count > 2, let dac = devices().first(where: { name($0).contains(args[1]) }), let rate = Double(args[2]) else {
    print("usage: clockrate <device-name-substring> <rate> [seconds]"); exit(1)
}
let seconds = args.count > 3 ? Double(args[3]) ?? 60 : 60
var r = rate; var a = addr(kAudioDevicePropertyNominalSampleRate)
AudioObjectSetPropertyData(dac, &a, 0, nil, 8, &r)
Thread.sleep(forTimeInterval: 1.5)
var nominal = 0.0; var z = UInt32(8); AudioObjectGetPropertyData(dac, &a, 0, nil, &z, &nominal)
var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
let ticksPerSec = 1e9 * Double(tb.denom) / Double(tb.numer)

final class Stamps: @unchecked Sendable {
    let lock = NSLock()
    var first: (Double, UInt64)?, last: (Double, UInt64)?
    var scalars: [Double] = []
}
let st = Stamps()
var proc: AudioDeviceIOProcID?
AudioDeviceCreateIOProcIDWithBlock(&proc, dac, nil) { _, _, _, out, outTime in
    for b in UnsafeMutableAudioBufferListPointer(out) { if let p = b.mData { memset(p, 0, Int(b.mDataByteSize)) } }
    let t = outTime.pointee
    st.lock.lock()
    if st.first == nil { st.first = (t.mSampleTime, t.mHostTime) }
    st.last = (t.mSampleTime, t.mHostTime)
    st.scalars.append(t.mRateScalar)
    st.lock.unlock()
}
guard let proc else { print("no IOProc"); exit(1) }
print("\(name(dac)): nominal \(nominal) Hz; measuring \(Int(seconds)) s")
AudioDeviceStart(dac, proc)
Thread.sleep(forTimeInterval: 3) // skip the start-up
st.lock.lock(); st.first = st.last; st.scalars = []; st.lock.unlock()
var slices: [String] = []
let t0 = Date()
while Date().timeIntervalSince(t0) < seconds {
    Thread.sleep(forTimeInterval: 10)
    st.lock.lock()
    if let f = st.first, let l = st.last, l.1 > f.1 {
        let measured = (l.0 - f.0) / (Double(l.1 - f.1) / ticksPerSec)
        let s = st.scalars.isEmpty ? 0 : st.scalars.reduce(0, +) / Double(st.scalars.count)
        slices.append(String(format: "  %3.0f s: measured %.3f Hz (%+.0f ppm vs nominal); HAL mRateScalar mean %.6f (%+.0f ppm)",
                             Date().timeIntervalSince(t0), measured, (measured / nominal - 1) * 1e6, s, (s - 1) * 1e6))
        print(slices.last!)
    }
    st.lock.unlock()
}
AudioDeviceStop(dac, proc)
AudioDeviceDestroyIOProcID(dac, proc)
