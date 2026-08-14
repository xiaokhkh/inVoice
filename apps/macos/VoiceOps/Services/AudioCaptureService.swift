@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio

final class AudioCaptureService: @unchecked Sendable {
    private static let preferredInputDeviceName = "MLX Voice Mic"
    private static let preferredInputManufacturer = "MLX VoiceOps"

    private var engine = AVAudioEngine()
    private let audioQueue = DispatchQueue(label: "voiceops.audio.queue")
    private var outputURL: URL?
    private var outputFile: AVAudioFile?
    private var chunkFrames: AVAudioFramePosition = 0
    private var chunkFrameLimit: AVAudioFramePosition = 0
    private var onTick: (() -> Void)?
    private var onChunk: ((Data, AVAudioFrameCount) -> Void)?
    private var storeStreamingBuffers = true
    private var streamingEnabled = false
    private var bufferingEnabled = false
    private var targetFormat: AVAudioFormat?
    private var inputFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var streamingBuffers: [AVAudioPCMBuffer] = []
    private var streamingTotalFrames: AVAudioFramePosition = 0

    func start(
        streaming: Bool,
        chunkDuration: TimeInterval = 1.5,
        onTick: (() -> Void)? = nil,
        onChunk: ((Data, AVAudioFrameCount) -> Void)? = nil,
        storeBuffers: Bool = true,
        writeToFile: Bool = true
    ) throws {
        let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!

        if writeToFile {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("voiceops_\(UUID().uuidString).wav")
            let file = try AVAudioFile(
                forWriting: url,
                settings: target.settings,
                commonFormat: target.commonFormat,
                interleaved: target.isInterleaved
            )
            outputURL = url
            outputFile = file
        } else {
            outputURL = nil
            outputFile = nil
        }
        streamingEnabled = streaming
        self.onTick = onTick
        self.onChunk = onChunk
        storeStreamingBuffers = storeBuffers
        bufferingEnabled = storeBuffers
        chunkFrames = 0
        chunkFrameLimit = AVAudioFramePosition(target.sampleRate * chunkDuration)
        targetFormat = target
        streamingBuffers = []
        streamingTotalFrames = 0

        engine.stop()
        engine.reset()
        engine = AVAudioEngine()

        inputFormat = nil
        converter = nil

        let input = engine.inputNode
        selectPreferredInputDevice(for: input)
        let hardwareFormat = input.inputFormat(forBus: 0)
        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else {
            throw NSError(
                domain: "AudioCaptureService",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Selected microphone has no usable input format"]
            )
        }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: hardwareFormat) { [weak self] buffer, _ in
            self?.handleBuffer(buffer)
        }

        engine.prepare()
        try engine.start()
    }

    func stop() throws -> URL {
        guard let url = outputURL else {
            throw NSError(domain: "AudioCaptureService", code: 1)
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        outputFile = nil
        outputURL = nil
        converter = nil
        inputFormat = nil
        return url
    }

    func stopAndGetWavData() throws -> (Data, AVAudioFramePosition) {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        outputFile = nil
        outputURL = nil
        converter = nil
        inputFormat = nil

        guard bufferingEnabled, let format = targetFormat else {
            throw NSError(domain: "AudioCaptureService", code: 2)
        }

        let snapshot: ([AVAudioPCMBuffer], AVAudioFramePosition) = audioQueue.sync {
            return (self.streamingBuffers, self.streamingTotalFrames)
        }
        let buffers = snapshot.0
        let totalFrames = snapshot.1
        guard !buffers.isEmpty else {
            throw NSError(domain: "AudioCaptureService", code: 3)
        }

        let wavData = buildWavData(buffers: buffers, format: format)
        return (wavData, totalFrames)
    }

    func stopStreaming() throws {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        outputFile = nil
        outputURL = nil
        converter = nil
        inputFormat = nil
    }

    func snapshotStreamingAudio() async throws -> (URL, AVAudioFramePosition)? {
        guard streamingEnabled, let format = targetFormat else { return nil }

        let snapshot: ([AVAudioPCMBuffer], AVAudioFramePosition) = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<([AVAudioPCMBuffer], AVAudioFramePosition), Error>) in
            audioQueue.async { [weak self] in
                guard let self else {
                    cont.resume(throwing: NSError(domain: "AudioCaptureService", code: 2))
                    return
                }
                cont.resume(returning: (self.streamingBuffers, self.streamingTotalFrames))
            }
        }

        let buffers = snapshot.0
        let totalFrames = snapshot.1
        guard !buffers.isEmpty else { return nil }

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(URL, AVAudioFramePosition), Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let url = FileManager.default.temporaryDirectory
                        .appendingPathComponent("voiceops_stream_\(UUID().uuidString).wav")
                    let file = try AVAudioFile(
                        forWriting: url,
                        settings: format.settings,
                        commonFormat: format.commonFormat,
                        interleaved: format.isInterleaved
                    )
                    for buffer in buffers {
                        try file.write(from: buffer)
                    }
                    cont.resume(returning: (url, totalFrames))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    func resetStreamingState() {
        streamingEnabled = false
        onTick = nil
        onChunk = nil
        storeStreamingBuffers = true
        bufferingEnabled = false
        chunkFrames = 0
        chunkFrameLimit = 0
        streamingBuffers = []
        streamingTotalFrames = 0
    }

    func cancel() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        if let url = outputURL {
            try? FileManager.default.removeItem(at: url)
        }
        outputFile = nil
        outputURL = nil
        chunkFrames = 0
        converter = nil
        inputFormat = nil
        resetStreamingState()
    }

    private func handleBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let format = targetFormat else { return }
        guard buffer.frameLength > 0 else { return }
        refreshConverterIfNeeded(input: buffer.format, target: format)

        let copy: AVAudioPCMBuffer
        if let converter {
            let ratio = format.sampleRate / buffer.format.sampleRate
            let outFrames = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
            let outBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: outFrames)!
            var error: NSError?
            var consumed = false
            let status = converter.convert(to: outBuffer, error: &error) { _, outStatus in
                if consumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                consumed = true
                outStatus.pointee = .haveData
                return buffer
            }
            if status == .haveData || (status == .inputRanDry && outBuffer.frameLength > 0) {
                copy = outBuffer
            } else {
                return
            }
        } else {
            let outBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameCapacity)!
            outBuffer.frameLength = buffer.frameLength
            if let src = buffer.floatChannelData, let dst = outBuffer.floatChannelData {
                let bytes = Int(buffer.frameLength) * MemoryLayout<Float>.size
                memcpy(dst[0], src[0], bytes)
            }
            copy = outBuffer
        }

        audioQueue.async { [weak self] in
            guard let self else { return }
            try? self.outputFile?.write(from: copy)

            if self.bufferingEnabled {
                if self.storeStreamingBuffers {
                    self.streamingBuffers.append(copy)
                }
                self.streamingTotalFrames += AVAudioFramePosition(copy.frameLength)
            }

            guard self.streamingEnabled else { return }
            self.chunkFrames += AVAudioFramePosition(copy.frameLength)

            if let onChunk, let channel = copy.floatChannelData {
                let frames = Int(copy.frameLength)
                if frames > 0 {
                    let byteCount = frames * MemoryLayout<Float>.size
                    let data = Data(bytes: channel[0], count: byteCount)
                    DispatchQueue.main.async {
                        onChunk(data, copy.frameLength)
                    }
                }
            }

            if self.chunkFrames >= self.chunkFrameLimit {
                self.chunkFrames = 0
                DispatchQueue.main.async { [weak self] in
                    self?.onTick?()
                }
            }
        }
    }

    private func buildWavData(buffers: [AVAudioPCMBuffer], format: AVAudioFormat) -> Data {
        let channels = Int(format.channelCount)
        let sampleRate = Int(format.sampleRate)
        let bitsPerSample = 32
        let bytesPerSample = bitsPerSample / 8

        var dataSize = 0
        for buffer in buffers {
            dataSize += Int(buffer.frameLength) * bytesPerSample
        }

        var data = Data()
        data.reserveCapacity(44 + dataSize)

        func append<T: FixedWidthInteger>(_ value: T) {
            var v = value.littleEndian
            data.append(Data(bytes: &v, count: MemoryLayout<T>.size))
        }

        data.append("RIFF".data(using: .ascii)!)
        append(UInt32(36 + dataSize))
        data.append("WAVE".data(using: .ascii)!)
        data.append("fmt ".data(using: .ascii)!)
        append(UInt32(16))
        append(UInt16(3)) // IEEE float
        append(UInt16(channels))
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * channels * bytesPerSample))
        append(UInt16(channels * bytesPerSample))
        append(UInt16(bitsPerSample))
        data.append("data".data(using: .ascii)!)
        append(UInt32(dataSize))

        for buffer in buffers {
            guard let channel = buffer.floatChannelData else { continue }
            let frames = Int(buffer.frameLength)
            let byteCount = frames * bytesPerSample
            data.append(Data(bytes: channel[0], count: byteCount))
        }

        return data
    }

    private func refreshConverterIfNeeded(input: AVAudioFormat, target: AVAudioFormat) {
        if let current = inputFormat,
           current.sampleRate == input.sampleRate,
           current.channelCount == input.channelCount,
           current.commonFormat == input.commonFormat {
            return
        }

        inputFormat = input
        if input.sampleRate != target.sampleRate || input.channelCount != target.channelCount || input.commonFormat != target.commonFormat {
            converter = AVAudioConverter(from: input, to: target)
        } else {
            converter = nil
        }
    }

    /// Prefer the dedicated ESP32-S3 microphone while keeping the system input
    /// as a transparent fallback when the board is disconnected.
    private func selectPreferredInputDevice(for input: AVAudioInputNode) {
        guard let deviceID = Self.inputDevice(named: Self.preferredInputDeviceName) else {
            NSLog(
                "VoiceOps: %@ is not connected; using the current system input",
                Self.preferredInputDeviceName
            )
            return
        }
        guard let audioUnit = input.audioUnit else {
            return
        }

        var selectedDeviceID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &selectedDeviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status != noErr {
            NSLog("VoiceOps: unable to select %@ (CoreAudio status %d); using the system input", Self.preferredInputDeviceName, status)
        } else {
            NSLog(
                "VoiceOps: selected microphone %@ device_id=%u",
                Self.preferredInputDeviceName,
                selectedDeviceID
            )
        }
    }

    private static func inputDevice(named requestedName: String) -> AudioDeviceID? {
        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(
            systemObject,
            &devicesAddress,
            0,
            nil,
            &dataSize
        ) == noErr else {
            return nil
        }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: count)
        let listStatus = devices.withUnsafeMutableBytes { bytes in
            AudioObjectGetPropertyData(
                systemObject,
                &devicesAddress,
                0,
                nil,
                &dataSize,
                bytes.baseAddress!
            )
        }
        guard listStatus == noErr else {
            return nil
        }

        return devices.first { deviceID in
            hasInputStreams(deviceID) && (
                deviceName(deviceID) == requestedName ||
                deviceManufacturer(deviceID) == preferredInputManufacturer
            )
        }
    }

    private static func hasInputStreams(_ deviceID: AudioDeviceID) -> Bool {
        var streamsAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var streamsSize: UInt32 = 0
        return AudioObjectGetPropertyDataSize(
            deviceID,
            &streamsAddress,
            0,
            nil,
            &streamsSize
        ) == noErr && streamsSize > 0
    }

    private static func deviceName(_ deviceID: AudioDeviceID) -> String? {
        stringProperty(kAudioObjectPropertyName, of: deviceID)
    }

    private static func deviceManufacturer(_ deviceID: AudioDeviceID) -> String? {
        stringProperty(kAudioObjectPropertyManufacturer, of: deviceID)
    }

    private static func stringProperty(
        _ selector: AudioObjectPropertySelector,
        of deviceID: AudioDeviceID
    ) -> String? {
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(
            deviceID,
            &nameAddress,
            0,
            nil,
            &nameSize,
            &name
        ) == noErr else {
            return nil
        }
        guard let name else { return nil }
        return name.takeUnretainedValue() as String
    }
}
