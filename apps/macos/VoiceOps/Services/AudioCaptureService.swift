@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio

final class AudioCaptureService: @unchecked Sendable {
    struct CaptureResult: Sendable {
        let wavURL: URL
        let totalFrames: AVAudioFramePosition
    }

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
    private var streamingEnabled = false
    private var targetFormat: AVAudioFormat?
    private var inputFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var streamingTotalFrames: AVAudioFramePosition = 0
    private var activeProvider: VoiceInputProvider?

    func start(
        provider: VoiceInputProvider = .usbAudio,
        streaming: Bool,
        chunkDuration: TimeInterval = 1.5,
        onTick: (() -> Void)? = nil,
        onChunk: ((Data, AVAudioFrameCount) -> Void)? = nil,
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
        chunkFrames = 0
        chunkFrameLimit = AVAudioFramePosition(target.sampleRate * chunkDuration)
        targetFormat = target
        streamingTotalFrames = 0
        activeProvider = provider

        inputFormat = nil
        converter = nil

        guard provider == .usbAudio else {
            NSLog("VoiceOps: receiving microphone audio from the wireless StopWatch provider")
            return
        }

        engine.stop()
        engine.reset()
        engine = AVAudioEngine()

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
        try stopAndDrain().wavURL
    }

    /// Stops capture and waits until every buffer already accepted by the tap
    /// has been written and scheduled for streaming delivery.
    func stopAndDrain() throws -> CaptureResult {
        if activeProvider == .usbAudio {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        converter = nil
        inputFormat = nil
        activeProvider = nil
        let result: CaptureResult? = audioQueue.sync {
            self.outputFile = nil
            guard let url = self.outputURL else { return nil }
            self.outputURL = nil
            return CaptureResult(wavURL: url, totalFrames: self.streamingTotalFrames)
        }
        guard let result else {
            throw NSError(domain: "AudioCaptureService", code: 1)
        }
        return result
    }

    func resetStreamingState() {
        streamingEnabled = false
        onTick = nil
        onChunk = nil
        chunkFrames = 0
        chunkFrameLimit = 0
        streamingTotalFrames = 0
    }

    func cancel() {
        if activeProvider == .usbAudio {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        activeProvider = nil
        let url: URL? = audioQueue.sync {
            self.outputFile = nil
            let url = self.outputURL
            self.outputURL = nil
            return url
        }
        if let url {
            try? FileManager.default.removeItem(at: url)
        }
        chunkFrames = 0
        converter = nil
        inputFormat = nil
        resetStreamingState()
    }

    func appendWirelessAudio(_ packet: WirelessVoiceAudioPacket) {
        guard activeProvider == .wirelessStopWatch,
              let format = AVAudioFormat(
                  commonFormat: .pcmFormatInt16,
                  sampleRate: Double(packet.sampleRate),
                  channels: 1,
                  interleaved: false
              ),
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(packet.sampleCount)
              ),
              let channel = buffer.int16ChannelData?[0] else {
            return
        }
        buffer.frameLength = AVAudioFrameCount(packet.sampleCount)
        packet.pcm16LE.withUnsafeBytes { bytes in
            guard let source = bytes.baseAddress else { return }
            memcpy(channel, source, bytes.count)
        }
        handleBuffer(buffer)
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

            self.streamingTotalFrames += AVAudioFramePosition(copy.frameLength)

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
