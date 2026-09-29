import Foundation
// verbatim from VirtualDeviceEngine.swift (TPDFDither.noise / next)
@inline(__always) func next(_ x: inout UInt32) -> UInt32 { x ^= x << 13; x ^= x >> 17; x ^= x << 5; return x }
@inline(__always) func noise(_ state: inout UInt32) -> Double { (Double(next(&state)) - Double(next(&state))) / 4294967296.0 }
// the write() integer path, one channel: decision + quantize
func write(_ src: [Float], bits: Int, reduce: Bool, on: Bool, _ rng: inout UInt32) -> [Int64] {
    let scale = Double(Int64(1) << (bits - 1)); let lo = -scale, hi = scale - 1
    let gain: Float = 0.70794578
    var dither = false
    if bits < 32, on { dither = reduce; if !dither { for x in src { let y = Double(x) * scale; if y != y.rounded() { dither = true; break } } } }
    return src.map { s in
        let x = reduce ? s * gain : s
        let y = dither ? Double(x) * scale + noise(&rng) : Double(x) * scale
        return Int64(min(hi, max(lo, y.rounded())))
    }
}
var rng: UInt32 = 0x9E3779B9
// 1. distribution
let N = 2_000_000; var sum = 0.0, sq = 0.0, mn = 9.0, mx = -9.0; var hist = [Int](repeating: 0, count: 8)
for _ in 0..<N { let d = noise(&rng); sum += d; sq += d*d; mn = min(mn,d); mx = max(mx,d); hist[min(7, Int((d + 1) * 4))] += 1 }
print(String(format: "1. noise mean %.5f  var %.5f (TPDF 1/6 = %.5f)  range [%.4f, %.4f]", sum/Double(N), sq/Double(N), 1.0/6, mn, mx))
print("   histogram (-1..1, 8 bins, should be triangular):", hist.map { String(format: "%.3f", Double($0)/Double(N)*8/2) }.joined(separator: " "))
// 2. bit-perfect passthrough: 16-bit-exact samples, gain off, dither on
let exact16: [Float] = (0..<48000).map { i in Float(Int(sin(Double(i) * 0.1) * 30000)) / 32768 }
let out2 = write(exact16, bits: 16, reduce: false, on: true, &rng)
let identical = zip(exact16, out2).allSatisfy { Int64(Double($0) * 32768) == $1 }
print("2. 16-bit-exact input, gain off, dither on -> bit-identical: \(identical)")
let silence = write([Float](repeating: 0, count: 4096), bits: 24, reduce: false, on: true, &rng)
print("   digital silence stays all-zero: \(silence.allSatisfy { $0 == 0 })")
// 3. linearization: a constant 0.3 LSB below the step, 16-bit, averaged
let c = Float(0.3 / 32768.0); let many = [Float](repeating: c, count: 200_000)
let und = write(many, bits: 16, reduce: false, on: false, &rng), dit = write(many, bits: 16, reduce: false, on: true, &rng)
print(String(format: "3. input 0.300 LSB: undithered mean %.3f LSB, dithered mean %.3f LSB", Double(und.reduce(0,+))/Double(many.count), Double(dit.reduce(0,+))/Double(many.count)))
// 4. harmonic distortion: 1 kHz sine at -90 dBFS at 48 kHz, -3 dB gain, 16-bit
let fs = 48000.0, f0 = 1000.0, n = 48000
let sine: [Float] = (0..<n).map { Float(pow(10, -90.0/20) * sin(2 * .pi * f0 * Double($0) / fs)) }
func amp(_ x: [Int64], _ f: Double) -> Double { var re = 0.0, im = 0.0; for (i, v) in x.enumerated() { let a = 2 * .pi * f * Double(i) / fs; re += Double(v) * cos(a); im -= Double(v) * sin(a) }; return 2 * sqrt(re*re + im*im) / Double(x.count) }
for (label, on) in [("undithered", false), ("dithered  ", true)] {
    let q = write(sine, bits: 16, reduce: true, on: on, &rng)
    let fund = amp(q, f0), h3 = amp(q, 3 * f0), h5 = amp(q, 5 * f0)
    print(String(format: "4. %@ -90 dBFS sine x -3 dB -> 16-bit: fundamental %.3f LSB, H3 %.1f dBc, H5 %.1f dBc", label, fund, 20*log10(h3/fund), 20*log10(h5/fund)))
}
