import Foundation
import AVFoundation

@objc(MKAudioRemoteBusRack)
@objcMembers
final class MKAudioRemoteBusRack: NSObject {
    private final class StageHost {
        let audioUnit: AVAudioUnit
        let auAudioUnit: AUAudioUnit
        let wetDryMix: Float
        let renderLock = NSLock()

        private(set) var configuredInputFormat: AVAudioFormat
        private(set) var configuredOutputFormat: AVAudioFormat
        private(set) var maximumFramesToRender: AUAudioFrameCount
        private let engine: AVAudioEngine
        private var sourceNode: AVAudioSourceNode!
        private var pullOffset: Int = 0
        private var inputBuffer: AVAudioPCMBuffer
        private var outputBuffer: AVAudioPCMBuffer!

        init(audioUnit: AVAudioUnit,
             wetDryMix: Float,
             preferredChannels: AVAudioChannelCount,
             sampleRate: Double,
             hostBufferFrames: Int) throws {
            self.audioUnit = audioUnit
            self.auAudioUnit = audioUnit.auAudioUnit
            self.wetDryMix = min(max(wetDryMix, 0.0), 1.0)
            self.engine = AVAudioEngine()

            let selectedFormats = try StageHost.configureFormats(
                for: audioUnit.auAudioUnit,
                preferredChannels: preferredChannels,
                sampleRate: sampleRate
            )
            configuredInputFormat = selectedFormats.input
            configuredOutputFormat = selectedFormats.output

            let requiredMaximumFrames = max(hostBufferFrames, Int(audioUnit.auAudioUnit.maximumFramesToRender), 4096)
            audioUnit.auAudioUnit.maximumFramesToRender = AUAudioFrameCount(requiredMaximumFrames)
            maximumFramesToRender = audioUnit.auAudioUnit.maximumFramesToRender

            guard let createdInputBuffer = AVAudioPCMBuffer(pcmFormat: configuredInputFormat, frameCapacity: maximumFramesToRender) else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudio_ParamError))
            }
            inputBuffer = createdInputBuffer
            try configureEngine()
        }

        deinit {
            engine.stop()
            engine.disableManualRenderingMode()
            if auAudioUnit.renderResourcesAllocated {
                auAudioUnit.deallocateRenderResources()
            }
        }

        func process(samples: UnsafeMutablePointer<Float>,
                     frameCount: Int,
                     hostChannels: Int) {
            if frameCount <= 0 || hostChannels <= 0 {
                return
            }

            renderLock.lock()
            defer { renderLock.unlock() }

            if frameCount > Int(maximumFramesToRender) || !engine.isRunning {
                return
            }

            inputBuffer.frameLength = AVAudioFrameCount(frameCount)
            outputBuffer.frameLength = AVAudioFrameCount(frameCount)

            StageHost.writeInterleaved(samples,
                                       frameCount: frameCount,
                                       sourceChannels: hostChannels,
                                       to: inputBuffer)
            StageHost.zero(buffer: outputBuffer, frameCount: frameCount)
            pullOffset = 0

            do {
                let status = try engine.renderOffline(AVAudioFrameCount(frameCount), to: outputBuffer)
                if status != .success {
                    let componentName = audioUnit.auAudioUnit.componentName ?? "Unknown AU"
                    print("MKAudioRack: Remote Bus stage render incomplete \(componentName) (\(status.rawValue))")
                    return
                }
            } catch {
                let componentName = audioUnit.auAudioUnit.componentName ?? "Unknown AU"
                print("MKAudioRack: Remote Bus stage render failed \(componentName): \(error)")
                return
            }

            if wetDryMix <= 0.0001 {
                return
            }
            if wetDryMix >= 0.9999 {
                StageHost.readInterleaved(from: outputBuffer,
                                          frameCount: frameCount,
                                          targetChannels: hostChannels,
                                          into: samples)
                return
            }

            let dryCopy = UnsafeMutablePointer<Float>.allocate(capacity: frameCount * hostChannels)
            dryCopy.initialize(from: samples, count: frameCount * hostChannels)
            defer {
                dryCopy.deinitialize(count: frameCount * hostChannels)
                dryCopy.deallocate()
            }

            StageHost.readInterleaved(from: outputBuffer,
                                      frameCount: frameCount,
                                      targetChannels: hostChannels,
                                      into: samples)
            let dryMix = 1.0 as Float - wetDryMix
            let sampleCount = frameCount * hostChannels
            for index in 0..<sampleCount {
                samples[index] = (dryCopy[index] * dryMix) + (samples[index] * wetDryMix)
            }
        }

        var probeSummary: String {
            let inLayout = configuredInputFormat.isInterleaved ? "i" : "ni"
            let outLayout = configuredOutputFormat.isInterleaved ? "i" : "ni"
            let manualFormat = engine.manualRenderingFormat
            let manualLayout = manualFormat.isInterleaved ? "i" : "ni"
            return "in=\(configuredInputFormat.channelCount)ch@\(Int(configuredInputFormat.sampleRate))/\(inLayout) out=\(configuredOutputFormat.channelCount)ch@\(Int(configuredOutputFormat.sampleRate))/\(outLayout) manual=\(manualFormat.channelCount)ch@\(Int(manualFormat.sampleRate))/\(manualLayout) max=\(maximumFramesToRender)"
        }

        private func configureEngine() throws {
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

        private static func configureFormats(for auAudioUnit: AUAudioUnit,
                                             preferredChannels: AVAudioChannelCount,
                                             sampleRate: Double) throws -> (input: AVAudioFormat, output: AVAudioFormat) {
            guard auAudioUnit.inputBusses.count > 0,
                  auAudioUnit.outputBusses.count > 0 else {
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
            AVAudioFormat(commonFormat: .pcmFormatFloat32,
                          sampleRate: sampleRate > 0 ? sampleRate : base.sampleRate,
                          channels: channels,
                          interleaved: base.isInterleaved)!
        }

        private static func zero(buffer: AVAudioPCMBuffer, frameCount: Int) {
            let bufferList = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            let bytesPerChannelFrame = MemoryLayout<Float>.size
            for audioBuffer in bufferList {
                guard let mData = audioBuffer.mData else { continue }
                let byteCount: Int
                if buffer.format.isInterleaved {
                    byteCount = frameCount * Int(buffer.format.channelCount) * bytesPerChannelFrame
                } else {
                    byteCount = frameCount * bytesPerChannelFrame
                }
                memset(mData, 0, byteCount)
            }
        }

        private static func writeInterleaved(_ source: UnsafePointer<Float>,
                                             frameCount: Int,
                                             sourceChannels: Int,
                                             to buffer: AVAudioPCMBuffer) {
            let targetChannels = Int(buffer.format.channelCount)
            let bufferList = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            if buffer.format.isInterleaved {
                guard let mData = bufferList[0].mData else { return }
                let target = mData.assumingMemoryBound(to: Float.self)
                for frame in 0..<frameCount {
                    for channel in 0..<targetChannels {
                        target[(frame * targetChannels) + channel] = remapSample(source: source,
                                                                                 frame: frame,
                                                                                 sourceChannels: sourceChannels,
                                                                                 targetChannel: channel,
                                                                                 targetChannels: targetChannels)
                    }
                }
            } else {
                for channel in 0..<targetChannels {
                    guard let mData = bufferList[channel].mData else { continue }
                    let target = mData.assumingMemoryBound(to: Float.self)
                    for frame in 0..<frameCount {
                        target[frame] = remapSample(source: source,
                                                    frame: frame,
                                                    sourceChannels: sourceChannels,
                                                    targetChannel: channel,
                                                    targetChannels: targetChannels)
                    }
                }
            }
        }

        private static func copyInputChunk(from buffer: AVAudioPCMBuffer,
                                           offset: Int,
                                           frameCount: Int,
                                           into inputData: UnsafeMutablePointer<AudioBufferList>) {
            let availableFrames = max(0, Int(buffer.frameLength) - offset)
            let framesToCopy = min(frameCount, availableFrames)
            let inputBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            let targetBuffers = UnsafeMutableAudioBufferListPointer(inputData)
            let bytesPerFrame = MemoryLayout<Float>.size
            let interleavedChannels = Int(buffer.format.channelCount)

            for bufferIndex in 0..<targetBuffers.count {
                guard let targetData = targetBuffers[bufferIndex].mData else { continue }
                let copyBytes: Int
                if buffer.format.isInterleaved {
                    copyBytes = framesToCopy * interleavedChannels * bytesPerFrame
                } else {
                    copyBytes = framesToCopy * bytesPerFrame
                }

                if framesToCopy > 0, let sourceData = inputBuffers[min(bufferIndex, inputBuffers.count - 1)].mData {
                    let sourceOffsetBytes: Int
                    if buffer.format.isInterleaved {
                        sourceOffsetBytes = offset * interleavedChannels * bytesPerFrame
                    } else {
                        sourceOffsetBytes = offset * bytesPerFrame
                    }
                    memcpy(targetData, sourceData.advanced(by: sourceOffsetBytes), copyBytes)
                }

                let totalBytes: Int
                if buffer.format.isInterleaved {
                    totalBytes = frameCount * interleavedChannels * bytesPerFrame
                } else {
                    totalBytes = frameCount * bytesPerFrame
                }
                if totalBytes > copyBytes {
                    memset(targetData.advanced(by: copyBytes), 0, totalBytes - copyBytes)
                }
                targetBuffers[bufferIndex].mDataByteSize = UInt32(totalBytes)
            }
        }

        private static func readInterleaved(from buffer: AVAudioPCMBuffer,
                                            frameCount: Int,
                                            targetChannels: Int,
                                            into target: UnsafeMutablePointer<Float>) {
            let sourceChannels = Int(buffer.format.channelCount)
            let bufferList = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            if buffer.format.isInterleaved {
                guard let mData = bufferList[0].mData else { return }
                let source = mData.assumingMemoryBound(to: Float.self)
                for frame in 0..<frameCount {
                    for channel in 0..<targetChannels {
                        target[(frame * targetChannels) + channel] = remapInterleavedOutput(source: source,
                                                                                            frame: frame,
                                                                                            sourceChannels: sourceChannels,
                                                                                            sourceChannel: channel,
                                                                                            targetChannels: targetChannels)
                    }
                }
            } else {
                for frame in 0..<frameCount {
                    for channel in 0..<targetChannels {
                        target[(frame * targetChannels) + channel] = remapPlanarOutput(buffers: bufferList,
                                                                                       frame: frame,
                                                                                       sourceChannels: sourceChannels,
                                                                                       sourceChannel: channel,
                                                                                       targetChannels: targetChannels)
                    }
                }
            }
        }

        private static func remapSample(source: UnsafePointer<Float>,
                                        frame: Int,
                                        sourceChannels: Int,
                                        targetChannel: Int,
                                        targetChannels: Int) -> Float {
            if sourceChannels <= 1 && targetChannels >= 1 {
                return source[frame * sourceChannels]
            }
            if targetChannels == 1 {
                var sum: Float = 0.0
                for channel in 0..<sourceChannels {
                    sum += source[(frame * sourceChannels) + channel]
                }
                return sum / Float(sourceChannels)
            }
            let sourceChannel = min(targetChannel, sourceChannels - 1)
            return source[(frame * sourceChannels) + sourceChannel]
        }

        private static func remapInterleavedOutput(source: UnsafePointer<Float>,
                                                   frame: Int,
                                                   sourceChannels: Int,
                                                   sourceChannel: Int,
                                                   targetChannels: Int) -> Float {
            if sourceChannels <= 1 && targetChannels >= 1 {
                return source[frame * sourceChannels]
            }
            if targetChannels == 1 {
                var sum: Float = 0.0
                for channel in 0..<sourceChannels {
                    sum += source[(frame * sourceChannels) + channel]
                }
                return sum / Float(sourceChannels)
            }
            let mappedChannel = min(sourceChannel, sourceChannels - 1)
            return source[(frame * sourceChannels) + mappedChannel]
        }

        private static func remapPlanarOutput(buffers: UnsafeMutableAudioBufferListPointer,
                                              frame: Int,
                                              sourceChannels: Int,
                                              sourceChannel: Int,
                                              targetChannels: Int) -> Float {
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

    private struct StageConfiguration {
        let audioUnit: AVAudioUnit
        let wetDryMix: Float
    }

    private let stateLock = NSLock()
    private var stageConfigurations: [StageConfiguration] = []
    private var stageHosts: [StageHost] = []
    private var previewGain: Float = 1.0
    private var previewEnabled = false
    private var hostBufferFrames: Int = 256
    private var configuredSampleRate: Double = 48000.0
    private var inputPeak: Float = 0.0
    private var outputPeak: Float = 0.0

    func setPreviewGain(_ gain: Float, enabled: Bool) {
        stateLock.lock()
        previewGain = max(gain, 0.0)
        previewEnabled = enabled
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

        withExtendedLifetime(oldHosts) {}
        let newHosts = buildStageHosts(from: normalized, sampleRate: rebuildSampleRate, hostBufferFrames: rebuildBufferFrames)

        stateLock.lock()
        stageHosts = newHosts
        stateLock.unlock()
    }

    func setHostBufferFrames(_ frames: UInt) {
        let normalizedFrames: Int
        switch Int(frames) {
        case 64, 128, 256, 512, 1024, 2048:
            normalizedFrames = Int(frames)
        default:
            normalizedFrames = 256
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

            withExtendedLifetime(oldHosts) {}
            let newHosts = buildStageHosts(from: rebuildConfigurations,
                                           sampleRate: rebuildSampleRate,
                                           hostBufferFrames: rebuildBufferFrames)

            stateLock.lock()
            stageHosts = newHosts
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

            withExtendedLifetime(oldHosts) {}
            let newHosts = buildStageHosts(from: rebuildConfigurations,
                                           sampleRate: rebuildSampleRate,
                                           hostBufferFrames: rebuildBufferFrames)

            stateLock.lock()
            stageHosts = newHosts
        }
        stateLock.unlock()
    }

    func processSamples(_ samples: UnsafeMutablePointer<Float>, frameCount: UInt, channels: UInt, sampleRate: UInt) {
        let localFrameCount = Int(frameCount)
        let localChannels = Int(channels)
        guard localFrameCount > 0, localChannels > 0 else {
            return
        }

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

                withExtendedLifetime(oldHosts) {}
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
        stateLock.unlock()

        let sampleCount = localFrameCount * localChannels
        inputPeak = computePeak(samples, sampleCount: sampleCount)

        if localPreviewEnabled && abs(localPreviewGain - 1.0) > 0.0001 {
            for index in 0..<sampleCount {
                samples[index] *= localPreviewGain
            }
        }

        if !hosts.isEmpty {
            var offset = 0
            while offset < localFrameCount {
                let framesThisPass = min(chunkFrames, localFrameCount - offset)
                let chunkPointer = samples.advanced(by: offset * localChannels)
                for host in hosts {
                    host.process(samples: chunkPointer,
                                 frameCount: framesThisPass,
                                 hostChannels: localChannels)
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
            "hosts": hostSummaries,
            "sampleRate": NSNumber(value: configuredSampleRate),
            "bufferFrames": NSNumber(value: hostBufferFrames)
        ]
        stateLock.unlock()
        return result
    }

    private func normalizeStages(_ stages: NSArray?) -> [StageConfiguration] {
        guard let stages else { return [] }
        var normalized: [StageConfiguration] = []
        for element in stages {
            if let audioUnit = element as? AVAudioUnit {
                normalized.append(StageConfiguration(audioUnit: audioUnit, wetDryMix: 1.0))
                continue
            }
            guard let dictionary = element as? NSDictionary,
                  let audioUnit = dictionary["audioUnit"] as? AVAudioUnit else {
                continue
            }
            let wetDryMix = (dictionary["mix"] as? NSNumber)?.floatValue ?? 1.0
            normalized.append(StageConfiguration(audioUnit: audioUnit,
                                                 wetDryMix: min(max(wetDryMix, 0.0), 1.0)))
        }
        return normalized
    }

    private func buildStageHosts(from configurations: [StageConfiguration],
                                 sampleRate: Double,
                                 hostBufferFrames: Int) -> [StageHost] {
        var hosts: [StageHost] = []
        for configuration in configurations {
            do {
                let host = try StageHost(audioUnit: configuration.audioUnit,
                                         wetDryMix: configuration.wetDryMix,
                                         preferredChannels: 2,
                                         sampleRate: sampleRate,
                                         hostBufferFrames: hostBufferFrames)
                hosts.append(host)
            } catch {
                let componentName = configuration.audioUnit.auAudioUnit.componentName ?? "Unknown AU"
                print("MKAudioRack: Failed to configure Remote Bus stage \(componentName): \(error)")
            }
        }
        return hosts
    }

    private func computePeak(_ samples: UnsafePointer<Float>, sampleCount: Int) -> Float {
        var peak: Float = 0.0
        if sampleCount <= 0 {
            return peak
        }
        for index in 0..<sampleCount {
            let value = fabsf(samples[index])
            if value > peak {
                peak = value
            }
        }
        return peak
    }
}
