// VoxrtAsr.swift — idiomatic Swift wrapper over the
// `voxrt_asr_streaming_*` C ABI exposed by `crates/asr`.
//
// Mirrors the surface of the Kotlin `VoxrtAsrStreamingEngine`:
//
//   - opaque session class with handle reclaimed in `deinit`
//   - `throws` instead of C status codes
//   - Swift `String` instead of caller-allocated UTF-8 buffers
//   - per-stage + per-Conformer-sub-block timing snapshots so
//     consumer apps can render the same metrics the Android demo
//     surfaces
//
// Threading: per-instance, **not** thread-safe. Serialise
// `processPcm` / `stop` / `reset` against each other on the same
// session — exactly the contract `VoxrtSileroVadEngine` follows.
//
// The Swift surface intentionally hides the buffer-too-small retry
// protocol of the C API: every text-returning call dynamically
// re-sizes a private scratch and runs the underlying C function
// twice when needed, so callers get a Swift `String` back.

import Foundation
import VoxrtAsrNative

// ─── Public types ─────────────────────────────────────────────────────────

/// Errors raised by `VoxrtAsrStreamingEngine`. Each case maps 1:1
/// to a `VOXRT_ERR_*` status code from the C ABI, plus a couple of
/// Swift-side conditions.
public enum VoxrtAsrError: Error, Equatable, CustomStringConvertible {
    case invalidArgument
    case invalidHandle
    case modelDeserialize
    case modelShape
    /// Decode mode unsupported by this model (e.g. TDT on the
    /// streaming-medium-pc model — which has no duration head).
    case decodeUnsupported
    case oom
    case bufferTooSmall
    case internalError
    case resourceNotFound(name: String, extension: String, bundle: String)
    case unknown(Int32)

    fileprivate init(_ status: voxrt_status_t) {
        switch status {
        case VOXRT_ERR_INVALID_ARG:        self = .invalidArgument
        case VOXRT_ERR_INVALID_HANDLE:     self = .invalidHandle
        case VOXRT_ERR_MODEL_DESERIALIZE:  self = .modelDeserialize
        case VOXRT_ERR_MODEL_SHAPE:        self = .modelShape
        case VOXRT_ERR_DECODE_UNSUPPORTED: self = .decodeUnsupported
        case VOXRT_ERR_OOM:                self = .oom
        case VOXRT_ERR_BUFFER_TOO_SMALL:   self = .bufferTooSmall
        case VOXRT_ERR_INTERNAL:           self = .internalError
        default:                           self = .unknown(status)
        }
    }

    public var description: String {
        switch self {
        case .invalidArgument:
            return "invalidArgument (null pointer or bad length crossed the FFI boundary)"
        case .invalidHandle:
            return "invalidHandle (closed or never-built session)"
        case .modelDeserialize:
            return "modelDeserialize (.vxrt bytes failed to parse)"
        case .modelShape:
            return "modelShape (model loaded but doesn't match the streaming-medium-pc graph)"
        case .decodeUnsupported:
            return "decodeUnsupported (the chosen decode mode isn't available on this model)"
        case .oom:
            return "oom (allocation failure inside the runtime)"
        case .bufferTooSmall:
            // Should never escape — `processPcm` retries internally.
            return "bufferTooSmall (caller buffer underflow — should never escape Swift surface)"
        case .internalError:
            return "internalError (unexpected condition / caught Rust panic)"
        case .resourceNotFound(let name, let ext, let bundle):
            return "resourceNotFound — '\(name).\(ext)' is not in \(bundle). "
                + "Confirm the file is included in the app target's "
                + "*Copy Bundle Resources* build phase."
        case .unknown(let code):
            return "unknown(\(code))"
        }
    }
}

/// Decode mode passed at session creation. Streaming-medium-pc
/// supports both CTC and RNN-T heads; TDT is rejected at create
/// time (this model has no duration head).
public enum VoxrtAsrDecodeMode: Equatable {
    case ctc
    case rnnt

    fileprivate var rawValue: Int32 {
        switch self {
        case .ctc:  return Int32(VOXRT_ASR_DECODE_CTC)
        case .rnnt: return Int32(VOXRT_ASR_DECODE_RNNT)
        }
    }
}

/// Per-stage timing accumulators (microseconds). Each pair carries
/// the cumulative `total` micros AND the call `count`, so dividing
/// gives the average cost per call. Reset when the session is
/// reset or via `resetStageTimings()`.
public struct VoxrtAsrStageTimings: Equatable {
    public let melTotalUs: UInt64
    public let melCount: UInt64
    public let subsamplingTotalUs: UInt64
    public let subsamplingCount: UInt64
    public let encoderTotalUs: UInt64
    public let encoderCount: UInt64
    public let decoderTotalUs: UInt64
    public let decoderCount: UInt64

    public var melAvgUs: UInt64 { melCount > 0 ? melTotalUs / melCount : 0 }
    public var subsamplingAvgUs: UInt64 { subsamplingCount > 0 ? subsamplingTotalUs / subsamplingCount : 0 }
    public var encoderAvgUs: UInt64 { encoderCount > 0 ? encoderTotalUs / encoderCount : 0 }
    public var decoderAvgUs: UInt64 { decoderCount > 0 ? decoderTotalUs / decoderCount : 0 }

    public static let zero = VoxrtAsrStageTimings(
        melTotalUs: 0, melCount: 0,
        subsamplingTotalUs: 0, subsamplingCount: 0,
        encoderTotalUs: 0, encoderCount: 0,
        decoderTotalUs: 0, decoderCount: 0,
    )
}

/// Encoder sub-block timings (averaged per layer-per-chunk). Pairs
/// map 1:1 to the Conformer Macaron blocks.
public struct VoxrtAsrEncoderSubTimings: Equatable {
    public let ffn1TotalUs: UInt64
    public let ffn1Count: UInt64
    public let mhaTotalUs: UInt64
    public let mhaCount: UInt64
    public let convTotalUs: UInt64
    public let convCount: UInt64
    public let ffn2TotalUs: UInt64
    public let ffn2Count: UInt64

    /// Average cost per (layer × chunk) in microseconds. Multiply
    /// by the number of layers (16 for streaming-medium-pc) and the
    /// chunk count to derive total encoder time.
    public var ffn1AvgUs: UInt64 { ffn1Count > 0 ? ffn1TotalUs / ffn1Count : 0 }
    public var mhaAvgUs: UInt64 { mhaCount > 0 ? mhaTotalUs / mhaCount : 0 }
    public var convAvgUs: UInt64 { convCount > 0 ? convTotalUs / convCount : 0 }
    public var ffn2AvgUs: UInt64 { ffn2Count > 0 ? ffn2TotalUs / ffn2Count : 0 }

    public static let zero = VoxrtAsrEncoderSubTimings(
        ffn1TotalUs: 0, ffn1Count: 0,
        mhaTotalUs: 0, mhaCount: 0,
        convTotalUs: 0, convCount: 0,
        ffn2TotalUs: 0, ffn2Count: 0,
    )
}

// ─── Version helpers ──────────────────────────────────────────────────────

public func voxrtAsrVersion() -> String {
    guard let p = voxrt_asr_version() else { return "" }
    return String(cString: p)
}

public struct VoxrtAsrABIVersion: Equatable {
    public let major: UInt16
    public let minor: UInt16
}

public func voxrtAsrABIVersion() -> VoxrtAsrABIVersion {
    let raw = voxrt_asr_abi_version()
    return VoxrtAsrABIVersion(
        major: UInt16((raw >> 16) & 0xFFFF),
        minor: UInt16(raw & 0xFFFF),
    )
}

// ─── Streaming session ────────────────────────────────────────────────────

/// Cache-aware streaming ASR session. Accepts arbitrary-length
/// `[Float]` chunks of mono 16 kHz PCM; emits transcript fragments
/// as chunks complete.
public final class VoxrtAsrStreamingEngine {

    /// Audio samples consumed per encoder step in steady state
    /// (`17 920` for streaming-medium-pc). The session emits at
    /// least one chunk's worth of text once enough samples have
    /// been buffered.
    public static var chunkAudioSamples: Int {
        Int(voxrt_asr_streaming_chunk_audio_samples())
    }

    /// Look-ahead the session peeks past the chunk boundary
    /// (= `96` = `N_FFT/2 - HOP`).
    public static var lookAheadSamples: Int {
        Int(voxrt_asr_streaming_look_ahead_samples())
    }

    /// Load the `.vxrt` model directly from a `URL`, memory-mapping
    /// the file via `Data(contentsOf:options: .mappedIfSafe)`. This
    /// is the recommended path for bundled assets and downloaded
    /// files on iOS — avoids reading the whole file into RAM and
    /// matches Android's `VoxrtAsrStreamingEngine.fromAssetFd(afd)`
    /// pattern.
    public convenience init(
        modelURL url: URL,
        decodeMode: VoxrtAsrDecodeMode = .rnnt,
        readingOptions options: Data.ReadingOptions = .mappedIfSafe
    ) throws {
        let data = try Data(contentsOf: url, options: options)
        try self.init(modelBytes: data, decodeMode: decodeMode)
    }

    /// Resolve a bundled `.vxrt` resource by name + extension and
    /// build a session. Convenience wrapper around
    /// `init(modelURL:decodeMode:)` that uses `Bundle.url(forResource:)`
    /// to locate the file. Defaults to `silero_vad`-style naming.
    public static func fromBundleResource(
        named name: String = "streaming_medium_pc",
        extension ext: String = "vxrt",
        decodeMode: VoxrtAsrDecodeMode = .rnnt,
        in bundle: Bundle = .main
    ) throws -> VoxrtAsrStreamingEngine {
        guard let url = bundle.url(forResource: name, withExtension: ext) else {
            throw VoxrtAsrError.resourceNotFound(
                name: name, extension: ext, bundle: bundle.bundleURL.lastPathComponent,
            )
        }
        return try VoxrtAsrStreamingEngine(modelURL: url, decodeMode: decodeMode)
    }

    private var handle: OpaquePointer?
    /// Reused across `processPcm` / `stop`. Starts at 4 KiB; grows
    /// when the C side reports a longer buffer is required.
    private var textBuf = [UInt8](repeating: 0, count: 4_096)

    public init(modelBytes: Data, decodeMode: VoxrtAsrDecodeMode) throws {
        var handlePtr: OpaquePointer? = nil
        let status = modelBytes.withUnsafeBytes { raw -> voxrt_status_t in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return VOXRT_ERR_INVALID_ARG
            }
            return voxrt_asr_streaming_create(
                base, raw.count, decodeMode.rawValue, &handlePtr,
            )
        }
        if status != VOXRT_OK {
            throw VoxrtAsrError(status)
        }
        guard let h = handlePtr else {
            throw VoxrtAsrError.internalError
        }
        self.handle = h
    }

    deinit {
        if let h = handle {
            voxrt_asr_streaming_destroy(h)
        }
    }

    /// Zero every per-utterance buffer + cache + decoder state +
    /// CTC carry-over. Call before starting a new utterance on the
    /// same session.
    public func reset() {
        guard let h = handle else { return }
        voxrt_asr_streaming_reset(h)
    }

    /// Feed `pcm` samples (mono, 16 kHz, `[Float]` in [-1, 1]).
    /// Returns the incremental UTF-8 transcript text emitted by
    /// any chunks that completed during this call (empty until
    /// enough audio has accumulated).
    public func processPcm(_ pcm: [Float]) throws -> String {
        guard let h = handle else { throw VoxrtAsrError.invalidHandle }
        return try pcm.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return "" }
            return try callTextProducer { textPtr, cap, written in
                voxrt_asr_streaming_push_audio(h, base, buf.count, textPtr, cap, written)
            }
        }
    }

    /// Flush whatever audio remains buffered and emit the final
    /// transcript tail. Reset the session before starting a new
    /// utterance.
    public func stop() throws -> String {
        guard let h = handle else { throw VoxrtAsrError.invalidHandle }
        return try callTextProducer { textPtr, cap, written in
            voxrt_asr_streaming_stop(h, textPtr, cap, written)
        }
    }

    /// Snapshot per-stage accumulators (mel, sub, enc, dec).
    public func stageTimings() -> VoxrtAsrStageTimings {
        guard let h = handle else { return .zero }
        var out = [UInt64](repeating: 0, count: 8)
        let status = out.withUnsafeMutableBufferPointer { buf in
            voxrt_asr_streaming_stage_timings(h, buf.baseAddress)
        }
        if status != VOXRT_OK { return .zero }
        return VoxrtAsrStageTimings(
            melTotalUs: out[0], melCount: out[1],
            subsamplingTotalUs: out[2], subsamplingCount: out[3],
            encoderTotalUs: out[4], encoderCount: out[5],
            decoderTotalUs: out[6], decoderCount: out[7],
        )
    }

    /// Snapshot per-Conformer-sub-block accumulators (ffn1, mha,
    /// conv, ffn2 — each is total micros across all 16 layers per
    /// chunk).
    public func encoderSubTimings() -> VoxrtAsrEncoderSubTimings {
        guard let h = handle else { return .zero }
        var out = [UInt64](repeating: 0, count: 8)
        let status = out.withUnsafeMutableBufferPointer { buf in
            voxrt_asr_streaming_encoder_sub_timings(h, buf.baseAddress)
        }
        if status != VOXRT_OK { return .zero }
        return VoxrtAsrEncoderSubTimings(
            ffn1TotalUs: out[0], ffn1Count: out[1],
            mhaTotalUs: out[2], mhaCount: out[3],
            convTotalUs: out[4], convCount: out[5],
            ffn2TotalUs: out[6], ffn2Count: out[7],
        )
    }

    /// Zero the per-stage accumulators without touching inference state.
    /// Useful between warmup and the real measurement window.
    public func resetStageTimings() {
        guard let h = handle else { return }
        voxrt_asr_streaming_reset_stage_timings(h)
    }

    // ─── private helpers ──────────────────────────────────────────────

    /// Run a `(buf, cap, &written) -> status` C function with the
    /// session's reusable text buffer; transparently grow + retry
    /// on `VOXRT_ERR_BUFFER_TOO_SMALL`.
    private func callTextProducer(
        _ call: (UnsafeMutablePointer<CChar>?, Int, UnsafeMutablePointer<Int>?) -> voxrt_status_t,
    ) throws -> String {
        var written: Int = 0
        var status: voxrt_status_t = VOXRT_OK
        for _ in 0..<2 {
            status = textBuf.withUnsafeMutableBufferPointer { buf -> voxrt_status_t in
                guard let base = buf.baseAddress else { return VOXRT_ERR_INVALID_ARG }
                return base.withMemoryRebound(to: CChar.self, capacity: buf.count) { textPtr in
                    call(textPtr, buf.count, &written)
                }
            }
            if status == VOXRT_OK { break }
            if status == VOXRT_ERR_BUFFER_TOO_SMALL {
                // `written` carries the required byte count (excluding NUL).
                let needed = written + 1
                if needed > textBuf.count {
                    textBuf = [UInt8](repeating: 0, count: max(needed, textBuf.count * 2))
                }
                continue
            }
            throw VoxrtAsrError(status)
        }
        if status != VOXRT_OK {
            throw VoxrtAsrError(status)
        }
        // `written` is byte count excluding NUL. Slice the buffer to
        // that length and turn it into a Swift `String`.
        if written == 0 { return "" }
        let bytes = textBuf.prefix(written)
        return String(decoding: bytes, as: UTF8.self)
    }
}
