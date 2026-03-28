import Foundation
import AVFoundation

@objc(MKAudioRemoteTrackRack)
@objcMembers
final class MKAudioRemoteTrackRack: NSObject {
    // Sidechain provider callback type
    public typealias SidechainProvider = (_ key: String) -> (UnsafePointer<Float>, Int, Int)?

    private final class StageHost {
        let audioUnit: AVAudioUnit
        let auAudioUnit: AUAudioUnit
        let wetDryMix: Float
        let renderLock = NSLock()
        private var isShutdown = false

        private(set) var configuredInputFormat: AVAudioFormat
        private(set) var configuredOutputFormat: AVAudioFormat
        private(set) var maximumFramesToRender: AUAudioFrameCount
        private let engine: AVAudioEngine
        private var usesDirectRenderHost = false
        private var directRenderBlock: AURenderBlock?
        private var renderSampleTime: Int64 = 0
        private var sourceNode: AVAudioSourceNode!
        private var pullOffset: Int = 0
        private var inputBuffer: AVAudioPCMBuffer
        private var inputPullBuffer: AVAudioPCMBuffer
        private var outputBuffer: AVAudioPCMBuffer!

        // Sidechain properties
        var sidechainSourceKey: String?
        var sidechainProvider: SidechainProvider?
        private var sidechainSourceNode: AVAudioSourceNode?
        private var sidechainBuffer: AVAudioPCMBuffer?
        private var sidechainPullOffset: Int = 0

        init(audioUnit: AVAudioUnit,
             wetDryMix: Float,
             preferredChannels: AVAudioChannelCount,
             sampleRate: Double,
             hostBufferFrames: Int,
             sidechainSourceKey: String? = nil,
             sidechainProvider: SidechainProvider? = nil) throws {
            self.audioUnit = audioUnit
            self.auAudioUnit = audioUnit.auAudioUnit
            self.wetDryMix = min(max(wetDryMix, 0.0), 1.0)
            self.engine = AVAudioEngine()
            self.sidechainSourceKey = sidechainSourceKey
            self.sidechainProvider = sidechainProvider

            let selectedFormats = try StageHost.configureFormats(for: audioUnit.auAudioUnit, preferredChannels: preferredChannels, sampleRate: sampleRate)
            configuredInputFormat = selectedFormats.input
            configuredOutputFormat = selectedFormats.output
            let requiredMaximumFrames = max(hostBufferFrames, Int(audioUnit.auAudioUnit.maximumFramesToRender), 4096)
            audioUnit.auAudioUnit.maximumFramesToRender = AUAudioFrameCount(requiredMaximumFrames)
            maximumFramesToRender = audioUnit.auAudioUnit.maximumFramesToRender

            guard let createdInputBuffer = AVAudioPCMBuffer(pcmFormat: configuredInputFormat, frameCapacity: maximumFramesToRender) else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudio_ParamError))
            }
            inputBuffer = createdInputBuffer
            guard let createdInputPullBuffer = AVAudioPCMBuffer(pcmFormat: configuredInputFormat, frameCapacity: maximumFramesToRender) else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudio_ParamError))
            }
            inputPullBuffer = createdInputPullBuffer
            try configureHost()
        }

        func shutdown() {
            renderLock.lock()
            defer { renderLock.unlock() }
            guard !isShutdown else { return }
            isShutdown = true

            if !usesDirectRenderHost {
                if engine.isRunning {
                    engine.stop()
                }
                engine.disconnectNodeOutput(audioUnit)
                engine.disconnectNodeInput(audioUnit)
                if let sidechainSourceNode {
                    engine.disconnectNodeOutput(sidechainSourceNode)
                    engine.detach(sidechainSourceNode)
                }
                if let sourceNode {
                    engine.disconnectNodeOutput(sourceNode)
                    engine.detach(sourceNode)
                }
                engine.detach(audioUnit)
            }
            sidechainSourceNode = nil
            sidechainBuffer = nil
            if !usesDirectRenderHost {
                engine.disableManualRenderingMode()
            }
            if auAudioUnit.renderResourcesAllocated {
                auAudioUnit.deallocateRenderResources()
            }
        }

        deinit {
            shutdown()
        }

        func process(samples: UnsafeMutablePointer<Float>, frameCount: Int, hostChannels: Int) {
            if frameCount <= 0 || hostChannels <= 0 { return }
            renderLock.lock()
            defer { renderLock.unlock() }
            if frameCount > Int(maximumFramesToRender) { return }
            inputBuffer.frameLength = AVAudioFrameCount(frameCount)
            outputBuffer.frameLength = AVAudioFrameCount(frameCount)
            StageHost.writeInterleaved(samples, frameCount: frameCount, sourceChannels: hostChannels, to: inputBuffer)
            StageHost.zero(buffer: outputBuffer, frameCount: frameCount)
            pullOffset = 0
            sidechainPullOffset = 0

            if usesDirectRenderHost {
                guard let renderBlock = directRenderBlock else { return }
                var actionFlags = AudioUnitRenderActionFlags(rawValue: 0)
                var timestamp = AudioTimeStamp()
                timestamp.mSampleTime = Float64(renderSampleTime)
                timestamp.mFlags = .sampleTimeValid

                let pullInputBlock: AURenderPullInputBlock = { [unowned self] _, _, requestedFrameCount, inputBusNumber, inputData in
                    let requestFrames = Int(requestedFrameCount)
                    switch Int(inputBusNumber) {
                    case 0:
                        StageHost.prepareAudioBufferList(inputData,
                                                         with: self.inputPullBuffer,
                                                         frameCount: requestFrames)
                        StageHost.copyInputChunk(from: self.inputBuffer,
                                                 offset: self.pullOffset,
                                                 frameCount: requestFrames,
                                                 into: inputData)
                        self.pullOffset += requestFrames
                        return noErr
                    case 1:
                        guard let sidechainBuffer = self.sidechainBuffer else {
                            StageHost.zero(audioBufferList: inputData)
                            return noErr
                        }
                        StageHost.prepareAudioBufferList(inputData,
                                                         with: sidechainBuffer,
                                                         frameCount: requestFrames)
                        self.pullSidechainData(frameCount: requestFrames, into: inputData)
                        return noErr
                    default:
                        StageHost.zero(audioBufferList: inputData)
                        return noErr
                    }
                }

                let status = renderBlock(&actionFlags,
                                         &timestamp,
                                         AUAudioFrameCount(frameCount),
                                         0,
                                         outputBuffer.mutableAudioBufferList,
                                         pullInputBlock)
                if status != noErr {
                    let componentName = audioUnit.auAudioUnit.componentName ?? "Unknown AU"
                    print("MKAudioRack: Remote Track direct render failed \(componentName): \(status)")
                    return
                }
                renderSampleTime += Int64(frameCount)
            } else {
                guard engine.isRunning else { return }
                do {
                    let status = try engine.renderOffline(AVAudioFrameCount(frameCount), to: outputBuffer)
                    if status != .success {
                        let componentName = audioUnit.auAudioUnit.componentName ?? "Unknown AU"
                        print("MKAudioRack: Remote Track stage render incomplete \(componentName) (\(status.rawValue))")
                        return
                    }
                } catch {
                    let componentName = audioUnit.auAudioUnit.componentName ?? "Unknown AU"
                    print("MKAudioRack: Remote Track stage render failed \(componentName): \(error)")
                    return
                }
            }

            if wetDryMix <= 0.0001 { return }
            if wetDryMix >= 0.9999 {
                StageHost.readInterleaved(from: outputBuffer, frameCount: frameCount, targetChannels: hostChannels, into: samples)
                return
            }
            let dryCopy = UnsafeMutablePointer<Float>.allocate(capacity: frameCount * hostChannels)
            dryCopy.initialize(from: samples, count: frameCount * hostChannels)
            defer {
                dryCopy.deinitialize(count: frameCount * hostChannels)
                dryCopy.deallocate()
            }
            StageHost.readInterleaved(from: outputBuffer, frameCount: frameCount, targetChannels: hostChannels, into: samples)
            let dryMix = 1.0 as Float - wetDryMix
            let sampleCount = frameCount * hostChannels
            for index in 0..<sampleCount {
                samples[index] = (dryCopy[index] * dryMix) + (samples[index] * wetDryMix)
            }
        }

        var probeSummary: String {
            let inLayout = configuredInputFormat.isInterleaved ? "i" : "ni"
            let outLayout = configuredOutputFormat.isInterleaved ? "i" : "ni"
            let scInfo = sidechainSourceKey.map { " sc=\($0)" } ?? ""
            let hostMode = usesDirectRenderHost ? "direct" : "engine"
            return "in=\(configuredInputFormat.channelCount)ch@\(Int(configuredInputFormat.sampleRate))/\(inLayout) out=\(configuredOutputFormat.channelCount)ch@\(Int(configuredOutputFormat.sampleRate))/\(outLayout) host=\(hostMode) max=\(maximumFramesToRender)\(scInfo)"
        }

        private func configureHost() throws {
            try configureSidechainBusIfNeeded()
            if sidechainBuffer != nil {
                try configureDirectRenderHost()
                return
            }
            try configureEngineGraph()
        }

        private func configureDirectRenderHost() throws {
            usesDirectRenderHost = true
            directRenderBlock = auAudioUnit.renderBlock
            renderSampleTime = 0

            if !auAudioUnit.renderResourcesAllocated {
                try auAudioUnit.allocateRenderResources()
            }

            guard let createdOutputBuffer = AVAudioPCMBuffer(pcmFormat: configuredOutputFormat,
                                                             frameCapacity: maximumFramesToRender) else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudio_ParamError))
            }
            outputBuffer = createdOutputBuffer
        }

        private func configureEngineGraph() throws {
            sourceNode = AVAudioSourceNode { [unowned self] _, _, frameCount, audioBufferList -> OSStatus in
                StageHost.copyInputChunk(from: self.inputBuffer,
                                         offset: self.pullOffset,
                                         frameCount: Int(frameCount),
                                         into: audioBufferList)
                self.pullOffset += Int(frameCount)
                return noErr
            }

            engine.attach(sourceNode)
            engine.attach(audioUnit)
            engine.connect(sourceNode, to: audioUnit, format: configuredInputFormat)
            engine.connect(audioUnit, to: engine.mainMixerNode, format: configuredOutputFormat)

            if sidechainBuffer != nil {
                sidechainSourceNode = AVAudioSourceNode { [unowned self] _, _, frameCount, audioBufferList -> OSStatus in
                    self.pullSidechainData(frameCount: Int(frameCount), into: audioBufferList)
                    return noErr
                }
                engine.attach(sidechainSourceNode!)
                engine.connect(sidechainSourceNode!, to: audioUnit, fromBus: 0, toBus: 1, format: sidechainBuffer!.format)
            }

            try engine.enableManualRenderingMode(.offline,
                                                 format: configuredOutputFormat,
                                                 maximumFrameCount: maximumFramesToRender)
            engine.prepare()
            try engine.start()

            guard let createdOutputBuffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                                             frameCapacity: maximumFramesToRender) else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudio_ParamError))
            }
            outputBuffer = createdOutputBuffer
        }

        private func configureSidechainBusIfNeeded() throws {
            guard let scKey = sidechainSourceKey, !scKey.isEmpty, auAudioUnit.inputBusses.count > 1 else {
                return
            }

            let scBus = auAudioUnit.inputBusses[1]
            let scFormat: AVAudioFormat
            do {
                try scBus.setFormat(configuredInputFormat)
                scFormat = scBus.format
            } catch {
                let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                sampleRate: configuredInputFormat.sampleRate,
                                                channels: 1,
                                                interleaved: true)!
                do {
                    try scBus.setFormat(monoFormat)
                    scFormat = scBus.format
                } catch {
                    scFormat = scBus.format
                }
            }

            guard let scInputBuf = AVAudioPCMBuffer(pcmFormat: scFormat, frameCapacity: maximumFramesToRender) else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudio_ParamError))
            }
            sidechainBuffer = scInputBuf
            print("[Sidechain] AU '\(audioUnit.auAudioUnit.componentName ?? "Unknown")' configured with sidechain source='\(scKey)', bus1 format=\(scFormat.channelCount)ch @ \(Int(scFormat.sampleRate))Hz")
        }

        private static func configureFormats(for auAudioUnit: AUAudioUnit, preferredChannels: AVAudioChannelCount, sampleRate: Double) throws -> (input: AVAudioFormat, output: AVAudioFormat) {
            guard auAudioUnit.inputBusses.count > 0, auAudioUnit.outputBusses.count > 0 else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_InvalidElement))
            }
            let inputBus = auAudioUnit.inputBusses[0]
            let outputBus = auAudioUnit.outputBusses[0]
            let defaultInputChannels = max(AVAudioChannelCount(1), inputBus.format.channelCount)
            let defaultOutputChannels = max(AVAudioChannelCount(1), outputBus.format.channelCount)
            var candidates: [(AVAudioChannelCount, AVAudioChannelCount)] = []
            func append(_ inputChannels: AVAudioChannelCount, _ outputChannels: AVAudioChannelCount) {
                if !candidates.contains(where: { $0.0 == inputChannels && $0.1 == outputChannels }) {
                    candidates.append((inputChannels, outputChannels))
                }
            }
            append(preferredChannels, preferredChannels)
            append(defaultInputChannels, defaultOutputChannels)
            append(defaultInputChannels, preferredChannels)
            append(preferredChannels, defaultOutputChannels)
            append(1, 1)
            append(1, 2)
            append(2, 1)
            append(2, 2)
            var lastError: Error?
            for candidate in candidates {
                let proposedInput = makeFormat(from: inputBus.format, sampleRate: sampleRate, channels: candidate.0)
                let proposedOutput = makeFormat(from: outputBus.format, sampleRate: sampleRate, channels: candidate.1)
                do {
                    try inputBus.setFormat(proposedInput)
                    try outputBus.setFormat(proposedOutput)
                    return (inputBus.format, outputBus.format)
                } catch {
                    lastError = error
                }
            }
            throw lastError ?? NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_FormatNotSupported))
        }

        private static func makeFormat(from base: AVAudioFormat, sampleRate: Double, channels: AVAudioChannelCount) -> AVAudioFormat {
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate > 0 ? sampleRate : base.sampleRate, channels: channels, interleaved: base.isInterleaved)!
        }

        private static func zero(buffer: AVAudioPCMBuffer, frameCount: Int) {
            let bufferList = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            let bytesPerChannelFrame = MemoryLayout<Float>.size
            for audioBuffer in bufferList {
                guard let mData = audioBuffer.mData else { continue }
                let byteCount = buffer.format.isInterleaved ? frameCount * Int(buffer.format.channelCount) * bytesPerChannelFrame : frameCount * bytesPerChannelFrame
                memset(mData, 0, byteCount)
            }
        }

        private static func writeInterleaved(_ source: UnsafePointer<Float>, frameCount: Int, sourceChannels: Int, to buffer: AVAudioPCMBuffer) {
            let targetChannels = Int(buffer.format.channelCount)
            let bufferList = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            if buffer.format.isInterleaved {
                guard let mData = bufferList[0].mData else { return }
                let target = mData.assumingMemoryBound(to: Float.self)
                for frame in 0..<frameCount {
                    for channel in 0..<targetChannels {
                        target[(frame * targetChannels) + channel] = remapSample(source: source, frame: frame, sourceChannels: sourceChannels, targetChannel: channel, targetChannels: targetChannels)
                    }
                }
            } else {
                for channel in 0..<targetChannels {
                    guard let mData = bufferList[channel].mData else { continue }
                    let target = mData.assumingMemoryBound(to: Float.self)
                    for frame in 0..<frameCount {
                        target[frame] = remapSample(source: source, frame: frame, sourceChannels: sourceChannels, targetChannel: channel, targetChannels: targetChannels)
                    }
                }
            }
        }

        private static func copyInputChunk(from buffer: AVAudioPCMBuffer, offset: Int, frameCount: Int, into inputData: UnsafeMutablePointer<AudioBufferList>) {
            let availableFrames = max(0, Int(buffer.frameLength) - offset)
            let framesToCopy = min(frameCount, availableFrames)
            let inputBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            let targetBuffers = UnsafeMutableAudioBufferListPointer(inputData)
            let bytesPerFrame = MemoryLayout<Float>.size
            let interleavedChannels = Int(buffer.format.channelCount)
            for bufferIndex in 0..<targetBuffers.count {
                guard let targetData = targetBuffers[bufferIndex].mData else { continue }
                let copyBytes = buffer.format.isInterleaved ? framesToCopy * interleavedChannels * bytesPerFrame : framesToCopy * bytesPerFrame
                if framesToCopy > 0, let sourceData = inputBuffers[min(bufferIndex, inputBuffers.count - 1)].mData {
                    let sourceOffsetBytes = buffer.format.isInterleaved ? offset * interleavedChannels * bytesPerFrame : offset * bytesPerFrame
                    memcpy(targetData, sourceData.advanced(by: sourceOffsetBytes), copyBytes)
                }
                let totalBytes = buffer.format.isInterleaved ? frameCount * interleavedChannels * bytesPerFrame : frameCount * bytesPerFrame
                if totalBytes > copyBytes {
                    memset(targetData.advanced(by: copyBytes), 0, totalBytes - copyBytes)
                }
                targetBuffers[bufferIndex].mDataByteSize = UInt32(totalBytes)
            }
        }

        private static func prepareAudioBufferList(_ audioBufferList: UnsafeMutablePointer<AudioBufferList>,
                                                   with buffer: AVAudioPCMBuffer,
                                                   frameCount: Int) {
            let targetBuffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let backingBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            let bytesPerFrame = MemoryLayout<Float>.size
            let targetChannels = Int(buffer.format.channelCount)

            for bufferIndex in 0..<targetBuffers.count {
                if targetBuffers[bufferIndex].mData == nil {
                    targetBuffers[bufferIndex].mData = backingBuffers[min(bufferIndex, backingBuffers.count - 1)].mData
                }
                let totalBytes = buffer.format.isInterleaved
                    ? frameCount * targetChannels * bytesPerFrame
                    : frameCount * bytesPerFrame
                targetBuffers[bufferIndex].mDataByteSize = UInt32(totalBytes)
            }
        }

        private static func zero(audioBufferList: UnsafeMutablePointer<AudioBufferList>) {
            let targetBuffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            for bufferIndex in 0..<targetBuffers.count {
                guard let targetData = targetBuffers[bufferIndex].mData else { continue }
                memset(targetData, 0, Int(targetBuffers[bufferIndex].mDataByteSize))
            }
        }

        private func pullSidechainData(frameCount: Int, into audioBufferList: UnsafeMutablePointer<AudioBufferList>) {
            let targetBuffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard let scKey = sidechainSourceKey,
                  let provider = sidechainProvider,
                  let (srcPtr, srcFrames, srcChannels) = provider(scKey) else {
                // No source available — fill with silence
                for bufIdx in 0..<targetBuffers.count {
                    guard let data = targetBuffers[bufIdx].mData else { continue }
                    memset(data, 0, Int(targetBuffers[bufIdx].mDataByteSize))
                }
                return
            }

            // Copy source data into sidechain bus, handling channel mismatch and offset
            guard let scBuf = sidechainBuffer else {
                for bufIdx in 0..<targetBuffers.count {
                    guard let data = targetBuffers[bufIdx].mData else { continue }
                    memset(data, 0, Int(targetBuffers[bufIdx].mDataByteSize))
                }
                return
            }

            guard srcFrames > 0 else {
                for bufIdx in 0..<targetBuffers.count {
                    guard let data = targetBuffers[bufIdx].mData else { continue }
                    memset(data, 0, Int(targetBuffers[bufIdx].mDataByteSize))
                }
                return
            }

            let scChannels = Int(scBuf.format.channelCount)
            let bytesPerFrame = MemoryLayout<Float>.size
            let srcOffset = min(sidechainPullOffset, srcFrames)
            let framesToCopy = min(frameCount, max(0, srcFrames - srcOffset))

            if scBuf.format.isInterleaved {
                guard let targetData = targetBuffers[0].mData else { return }
                let dst = targetData.assumingMemoryBound(to: Float.self)
                memset(dst, 0, frameCount * scChannels * bytesPerFrame)
                for f in 0..<framesToCopy {
                    let srcFrame = srcOffset + f
                    for c in 0..<scChannels {
                        let srcCh = min(c, srcChannels - 1)
                        dst[f * scChannels + c] = srcPtr[srcFrame * srcChannels + srcCh]
                    }
                }
                targetBuffers[0].mDataByteSize = UInt32(frameCount * scChannels * bytesPerFrame)
            } else {
                for bufIdx in 0..<targetBuffers.count {
                    guard let data = targetBuffers[bufIdx].mData else { continue }
                    let dst = data.assumingMemoryBound(to: Float.self)
                    let srcCh = min(bufIdx, srcChannels - 1)
                    memset(dst, 0, frameCount * bytesPerFrame)
                    for f in 0..<framesToCopy {
                        let srcFrame = srcOffset + f
                        dst[f] = srcPtr[srcFrame * srcChannels + srcCh]
                    }
                    targetBuffers[bufIdx].mDataByteSize = UInt32(frameCount * bytesPerFrame)
                }
            }

            sidechainPullOffset = srcOffset + framesToCopy
        }

        private static func readInterleaved(from buffer: AVAudioPCMBuffer, frameCount: Int, targetChannels: Int, into target: UnsafeMutablePointer<Float>) {
            let sourceChannels = Int(buffer.format.channelCount)
            let bufferList = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            if buffer.format.isInterleaved {
                guard let mData = bufferList[0].mData else { return }
                let source = mData.assumingMemoryBound(to: Float.self)
                for frame in 0..<frameCount {
                    for channel in 0..<targetChannels {
                        target[(frame * targetChannels) + channel] = remapInterleavedOutput(source: source, frame: frame, sourceChannels: sourceChannels, sourceChannel: channel, targetChannels: targetChannels)
                    }
                }
            } else {
                for frame in 0..<frameCount {
                    for channel in 0..<targetChannels {
                        target[(frame * targetChannels) + channel] = remapPlanarOutput(buffers: bufferList, frame: frame, sourceChannels: sourceChannels, sourceChannel: channel, targetChannels: targetChannels)
                    }
                }
            }
        }

        private static func remapSample(source: UnsafePointer<Float>, frame: Int, sourceChannels: Int, targetChannel: Int, targetChannels: Int) -> Float {
            if sourceChannels <= 1 && targetChannels >= 1 { return source[frame * sourceChannels] }
            if targetChannels == 1 {
                var sum: Float = 0.0
                for channel in 0..<sourceChannels { sum += source[(frame * sourceChannels) + channel] }
                return sum / Float(sourceChannels)
            }
            let sourceChannel = min(targetChannel, sourceChannels - 1)
            return source[(frame * sourceChannels) + sourceChannel]
        }

        private static func remapInterleavedOutput(source: UnsafePointer<Float>, frame: Int, sourceChannels: Int, sourceChannel: Int, targetChannels: Int) -> Float {
            if sourceChannels <= 1 && targetChannels >= 1 { return source[frame * sourceChannels] }
            if targetChannels == 1 {
                var sum: Float = 0.0
                for channel in 0..<sourceChannels { sum += source[(frame * sourceChannels) + channel] }
                return sum / Float(sourceChannels)
            }
            let mappedChannel = min(sourceChannel, sourceChannels - 1)
            return source[(frame * sourceChannels) + mappedChannel]
        }

        private static func remapPlanarOutput(buffers: UnsafeMutableAudioBufferListPointer, frame: Int, sourceChannels: Int, sourceChannel: Int, targetChannels: Int) -> Float {
            if sourceChannels <= 1 && targetChannels >= 1 {
                guard let data = buffers[0].mData else { return 0.0 }
                return data.assumingMemoryBound(to: Float.self)[frame]
            }
            if targetChannels == 1 {
                var sum: Float = 0.0
                for channel in 0..<sourceChannels {
                    guard let data = buffers[channel].mData else { continue }
                    sum += data.assumingMemoryBound(to: Float.self)[frame]
                }
                return sum / Float(sourceChannels)
            }
            let mappedChannel = min(sourceChannel, sourceChannels - 1)
            guard let data = buffers[mappedChannel].mData else { return 0.0 }
            return data.assumingMemoryBound(to: Float.self)[frame]
        }
    }

    private enum AnyStageHost {
        case audioUnit(StageHost)

        func process(samples: UnsafeMutablePointer<Float>, frameCount: Int, hostChannels: Int) {
            switch self {
            case .audioUnit(let host):
                host.process(samples: samples, frameCount: frameCount, hostChannels: hostChannels)
            }
        }

        var probeSummary: String {
            switch self {
            case .audioUnit(let host):
                return host.probeSummary
            }
        }

        func shutdown() {
            switch self {
            case .audioUnit(let host):
                host.shutdown()
            }
        }
    }

    private enum StageProcessor {
        case audioUnit(AVAudioUnit)
    }

    private struct StageConfiguration {
        let processor: StageProcessor
        let wetDryMix: Float
        let sidechainSourceKey: String?
    }

    private let stateLock = NSLock()
    private var stageConfigurations: [StageConfiguration] = []
    private var stageHosts: [AnyStageHost] = []
    private var previewGain: Float = 1.0
    private var previewEnabled = false
    private var hostBufferFrames: Int = 256
    private var configuredSampleRate: Double = 48000.0
    private var inputPeak: Float = 0.0
    private var outputPeak: Float = 0.0
    private var frameCount: UInt = 0

    // Sidechain provider callback
    public var sidechainProvider: SidechainProvider? = nil
    private var sendSourceKeys: [String] = []

    private func shutdownStageHosts(_ hosts: [AnyStageHost]) {
        guard !hosts.isEmpty else { return }
        for host in hosts {
            host.shutdown()
        }
    }

    func setSidechainProvider(_ provider: Any?) {
        guard let block = provider as? (String) -> NSDictionary? else {
            stateLock.lock()
            sidechainProvider = nil
            let rebuildConfigurations = stageConfigurations
            let rebuildSampleRate = configuredSampleRate
            let rebuildBufferFrames = hostBufferFrames
            let oldHosts = stageHosts
            stageHosts = []
            stateLock.unlock()

            shutdownStageHosts(oldHosts)
            let newHosts = buildStageHosts(from: rebuildConfigurations,
                                           sampleRate: rebuildSampleRate,
                                           hostBufferFrames: rebuildBufferFrames)
            stateLock.lock()
            stageHosts = newHosts
            stateLock.unlock()
            return
        }
        let translatedProvider: SidechainProvider = { key in
            guard let dict = block(key),
                  let ptrValue = dict["ptr"] as? NSValue,
                  let frames = dict["frames"] as? Int,
                  let channels = dict["channels"] as? Int else {
                return nil
            }
            let ptr = ptrValue.pointerValue!.assumingMemoryBound(to: Float.self)
            return (UnsafePointer(ptr), frames, channels)
        }

        stateLock.lock()
        sidechainProvider = translatedProvider
        let rebuildConfigurations = stageConfigurations
        let rebuildSampleRate = configuredSampleRate
        let rebuildBufferFrames = hostBufferFrames
        let oldHosts = stageHosts
        stageHosts = []
        stateLock.unlock()

        shutdownStageHosts(oldHosts)
        let newHosts = buildStageHosts(from: rebuildConfigurations,
                                       sampleRate: rebuildSampleRate,
                                       hostBufferFrames: rebuildBufferFrames)
        stateLock.lock()
        stageHosts = newHosts
        stateLock.unlock()
    }

    func setPreviewGain(_ gain: Float, enabled: Bool) {
        stateLock.lock()
        previewGain = max(gain, 0.0)
        previewEnabled = enabled
        stateLock.unlock()
    }

    func setSendSourceKeys(_ sourceKeys: NSArray?) {
        let normalized = Self.normalizeSendSourceKeys(sourceKeys)
        stateLock.lock()
        sendSourceKeys = normalized
        stateLock.unlock()
    }

    func updateAudioUnitChain(_ stages: NSArray?, sampleRate: UInt) {
        let normalized = normalizeStages(stages)
        stateLock.lock()
        stageConfigurations = normalized
        configuredSampleRate = sampleRate > 0 ? Double(sampleRate) : configuredSampleRate
        let rebuildSampleRate = configuredSampleRate
        let rebuildBufferFrames = hostBufferFrames
        let oldHosts = stageHosts
        stageHosts = []
        stateLock.unlock()

        shutdownStageHosts(oldHosts)
        let newHosts = buildStageHosts(from: normalized, sampleRate: rebuildSampleRate, hostBufferFrames: rebuildBufferFrames)
        stateLock.lock()
        stageHosts = newHosts
        stateLock.unlock()
    }

    func setHostBufferFrames(_ frames: UInt) {
        let normalizedFrames: Int
        switch Int(frames) {
        case 64, 128, 256, 512, 1024, 2048: normalizedFrames = Int(frames)
        default: normalizedFrames = 256
        }
        stateLock.lock()
        if hostBufferFrames != normalizedFrames {
            hostBufferFrames = normalizedFrames
            let rebuildConfigurations = stageConfigurations
            let rebuildSampleRate = configuredSampleRate
            let rebuildBufferFrames = hostBufferFrames
            let oldHosts = stageHosts
            stageHosts = []
            stateLock.unlock()

            shutdownStageHosts(oldHosts)
            let newHosts = buildStageHosts(from: rebuildConfigurations,
                                           sampleRate: rebuildSampleRate,
                                           hostBufferFrames: rebuildBufferFrames)
            stateLock.lock()
            stageHosts = newHosts
            stateLock.unlock()
            return
        }
        stateLock.unlock()
    }

    func updateProcessingSampleRate(_ sampleRate: UInt) {
        guard sampleRate > 0 else { return }
        stateLock.lock()
        let targetRate = Double(sampleRate)
        if abs(configuredSampleRate - targetRate) > 0.5 {
            configuredSampleRate = targetRate
            let rebuildConfigurations = stageConfigurations
            let rebuildSampleRate = configuredSampleRate
            let rebuildBufferFrames = hostBufferFrames
            let oldHosts = stageHosts
            stageHosts = []
            stateLock.unlock()

            shutdownStageHosts(oldHosts)
            let newHosts = buildStageHosts(from: rebuildConfigurations,
                                           sampleRate: rebuildSampleRate,
                                           hostBufferFrames: rebuildBufferFrames)
            stateLock.lock()
            stageHosts = newHosts
            stateLock.unlock()
            return
        }
        stateLock.unlock()
    }

    func processSamples(_ samples: UnsafeMutablePointer<Float>, frameCount: UInt, channels: UInt, sampleRate: UInt) {
        let localFrameCount = Int(frameCount)
        let localChannels = Int(channels)
        guard localFrameCount > 0, localChannels > 0 else { return }
        stateLock.lock()
        if sampleRate > 0 {
            let targetRate = Double(sampleRate)
            if abs(configuredSampleRate - targetRate) > 0.5 {
                configuredSampleRate = targetRate
                let rebuildConfigurations = stageConfigurations
                let rebuildSampleRate = configuredSampleRate
                let rebuildBufferFrames = hostBufferFrames
                let oldHosts = stageHosts
                stageHosts = []
                stateLock.unlock()

                shutdownStageHosts(oldHosts)
                let newHosts = buildStageHosts(from: rebuildConfigurations,
                                               sampleRate: rebuildSampleRate,
                                               hostBufferFrames: rebuildBufferFrames)
                stateLock.lock()
                stageHosts = newHosts
            }
        }
        let hosts = stageHosts
        let localPreviewGain = previewGain
        let localPreviewEnabled = previewEnabled
        let chunkFrames = max(1, hostBufferFrames)
        let localSendSourceKeys = sendSourceKeys
        let localSidechainProvider = sidechainProvider
        stateLock.unlock()

        let sampleCount = localFrameCount * localChannels
        Self.mixTrackSends(into: samples,
                           frameCount: localFrameCount,
                           hostChannels: localChannels,
                           sourceKeys: localSendSourceKeys,
                           provider: localSidechainProvider)
        inputPeak = computePeak(samples, sampleCount: sampleCount)
        self.frameCount = frameCount
        if localPreviewEnabled && abs(localPreviewGain - 1.0) > 0.0001 {
            for index in 0..<sampleCount { samples[index] *= localPreviewGain }
        }
        if !hosts.isEmpty {
            var offset = 0
            while offset < localFrameCount {
                let framesThisPass = min(chunkFrames, localFrameCount - offset)
                let chunkPointer = samples.advanced(by: offset * localChannels)
                for host in hosts {
                    host.process(samples: chunkPointer, frameCount: framesThisPass, hostChannels: localChannels)
                }
                offset += framesThisPass
            }
        }
        outputPeak = computePeak(samples, sampleCount: sampleCount)
    }

    func currentStatus() -> NSDictionary {
        stateLock.lock()
        let hostSummaries = stageHosts.map { $0.probeSummary }
        let result: NSDictionary = [
            "inputPeak": NSNumber(value: inputPeak),
            "outputPeak": NSNumber(value: outputPeak),
            "lastRenderStatus": NSNumber(value: noErr),
            "frameCount": NSNumber(value: frameCount),
            "hosts": hostSummaries,
            "sampleRate": NSNumber(value: configuredSampleRate),
            "bufferFrames": NSNumber(value: hostBufferFrames)
        ]
        stateLock.unlock()
        return result
    }

    private static func normalizeSendSourceKeys(_ sourceKeys: NSArray?) -> [String] {
        guard let sourceKeys else { return [] }
        var normalized: [String] = []
        var seen: Set<String> = []
        for case let key as String in sourceKeys {
            guard !key.isEmpty, !seen.contains(key) else { continue }
            normalized.append(key)
            seen.insert(key)
        }
        return normalized
    }

    private static func mixTrackSends(into samples: UnsafeMutablePointer<Float>,
                                      frameCount: Int,
                                      hostChannels: Int,
                                      sourceKeys: [String],
                                      provider: SidechainProvider?) {
        guard frameCount > 0,
              hostChannels > 0,
              !sourceKeys.isEmpty,
              let provider else {
            return
        }

        for key in sourceKeys {
            guard let (srcPtr, srcFrames, srcChannels) = provider(key),
                  srcFrames > 0,
                  srcChannels > 0 else {
                continue
            }

            for frame in 0..<frameCount {
                let srcFrame = frame % srcFrames
                for channel in 0..<hostChannels {
                    let dstIndex = frame * hostChannels + channel
                    let srcChannel = srcChannels == 1 ? 0 : min(channel, srcChannels - 1)
                    samples[dstIndex] += srcPtr[srcFrame * srcChannels + srcChannel]
                }
            }
        }
    }

    private func normalizeStages(_ stages: NSArray?) -> [StageConfiguration] {
        guard let stages else { return [] }
        var normalized: [StageConfiguration] = []
        for element in stages {
            if let audioUnit = element as? AVAudioUnit {
                normalized.append(StageConfiguration(processor: .audioUnit(audioUnit), wetDryMix: 1.0, sidechainSourceKey: nil))
                continue
            }
            guard let dictionary = element as? NSDictionary else {
                continue
            }
            let wetDryMix = (dictionary["mix"] as? NSNumber)?.floatValue ?? 1.0
            let sidechainSource = dictionary["sidechainSource"] as? String
            if let audioUnit = dictionary["audioUnit"] as? AVAudioUnit {
                normalized.append(StageConfiguration(processor: .audioUnit(audioUnit), wetDryMix: min(max(wetDryMix, 0.0), 1.0), sidechainSourceKey: sidechainSource))
            }
        }
        return normalized
    }

    private func buildStageHosts(from configurations: [StageConfiguration], sampleRate: Double, hostBufferFrames: Int) -> [AnyStageHost] {
        var hosts: [AnyStageHost] = []
        for configuration in configurations {
            do {
                switch configuration.processor {
                case .audioUnit(let audioUnit):
                    let host = try StageHost(audioUnit: audioUnit,
                                             wetDryMix: configuration.wetDryMix,
                                             preferredChannels: 2,
                                             sampleRate: sampleRate,
                                             hostBufferFrames: hostBufferFrames,
                                             sidechainSourceKey: configuration.sidechainSourceKey,
                                             sidechainProvider: sidechainProvider)
                    hosts.append(.audioUnit(host))
                }
            } catch {
                let componentName: String
                switch configuration.processor {
                case .audioUnit(let audioUnit):
                    componentName = audioUnit.auAudioUnit.componentName ?? "Unknown AU"
                }
                print("MKAudioRack: Failed to configure Remote Track stage \(componentName): \(error)")
            }
        }
        return hosts
    }

    private func computePeak(_ samples: UnsafePointer<Float>, sampleCount: Int) -> Float {
        var peak: Float = 0.0
        if sampleCount <= 0 { return peak }
        for index in 0..<sampleCount {
            let value = fabsf(samples[index])
            if value > peak { peak = value }
        }
        return peak
    }
}
