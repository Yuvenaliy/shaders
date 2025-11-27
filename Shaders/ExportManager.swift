/// ExportManager.swift
/// Модуль экспорта видео-интро в высоком качестве (4K 60fps).
///
/// Отвечает за:
/// - Офф-скрин рендеринг в Metal текстуры.
/// - Кодирование кадров через AVAssetWriter.
/// - Управление прогрессом и отменой экспорта.
/// - Сохранение в Photo Library с запросом разрешений.
///
/// Архитектура экспорта:
/// ```
/// FluidRenderer → MTLTexture → CVPixelBuffer → AVAssetWriterInput → .mp4
/// ```

import Foundation
import Metal
import MetalKit
import AVFoundation
import Photos
import VideoToolbox
import QuartzCore
import os

// MARK: - Логгер модуля
private let exportLog = Logger(subsystem: "com.liquidintro", category: "export")

// MARK: - Статус экспорта
/// Текущее состояние процесса экспорта.
enum ExportStatus: Equatable {
    case idle
    case preparing
    case rendering(progress: Float)
    case encoding
    case saving
    case completed(URL)
    case failed(String)
    case cancelled
    
    var isActive: Bool {
        switch self {
        case .preparing, .rendering, .encoding, .saving:
            return true
        default:
            return false
        }
    }
}

// MARK: - Настройки экспорта
/// Конфигурация параметров экспортируемого видео.
struct ExportSettings {
    let width: Int
    let height: Int
    let fps: Double
    let duration: Double
    let bitrate: Int
    
    /// Настройки по умолчанию: 4K вертикальный формат, 60 fps, 5 секунд.
    static let `default` = ExportSettings(
        width: Config.exportWidth,
        height: Config.exportHeight,
        fps: Config.exportFPS,
        duration: Double(Config.timelineTotalDuration),
        bitrate: Config.exportBitrate
    )
    
    /// Настройки для быстрого превью: 1080p, 30 fps.
    static let preview = ExportSettings(
        width: 1080,
        height: 1920,
        fps: 30,
        duration: Double(Config.timelineTotalDuration),
        bitrate: 15_000_000
    )
    
    /// Общее количество кадров для экспорта.
    var totalFrames: Int {
        Int(ceil(duration * fps))
    }
}

// MARK: - Делегат экспорта
/// Протокол для получения уведомлений о прогрессе экспорта.
protocol ExportManagerDelegate: AnyObject {
    func exportManager(_ manager: ExportManager, didUpdateStatus status: ExportStatus)
}

// MARK: - Менеджер экспорта
/// Управляет процессом офф-скрин рендеринга и кодирования видео.
final class ExportManager {
    
    // MARK: - Публичные свойства
    weak var delegate: ExportManagerDelegate?
    private(set) var status: ExportStatus = .idle {
        didSet {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.exportManager(self, didUpdateStatus: self.status)
            }
        }
    }
    
    // MARK: - Metal ресурсы
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var offscreenRenderer: OffscreenRenderer?
    
    // MARK: - AVFoundation компоненты
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    
    // MARK: - Состояние
    private var isCancelled = false
    private let exportQueue = DispatchQueue(label: "com.liquidintro.export", qos: .userInitiated)
    private let log = Logger(subsystem: "com.liquidintro", category: "export")
    
    // MARK: - Инициализация
    init() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            fatalError("Metal не поддерживается")
        }
        self.device = device
        self.commandQueue = commandQueue
        log.debug("ExportManager инициализирован")
    }
    
    // MARK: - Публичные методы
    
    /// Запускает экспорт видео с заданными параметрами.
    /// - Parameters:
    ///   - parameters: Параметры интро (текст, пресет, аудио).
    ///   - settings: Настройки экспорта (разрешение, fps).
    func startExport(parameters: IntroParameters, settings: ExportSettings = .default) {
        guard !status.isActive else {
            log.warning("Экспорт уже выполняется")
            return
        }
        
        isCancelled = false
        status = .preparing
        
        exportQueue.async { [weak self] in
            self?.performExport(parameters: parameters, settings: settings)
        }
    }
    
    /// Отменяет текущий экспорт.
    func cancelExport() {
        guard status.isActive else { return }
        
        isCancelled = true
        log.debug("Запрошена отмена экспорта")
    }
    
    // MARK: - Приватные методы
    
    private func performExport(parameters: IntroParameters, settings: ExportSettings) {
        log.debug("Начинаем экспорт: \(settings.width)x\(settings.height) @ \(settings.fps)fps")
        
        // 1. Создаём офф-скрин рендерер
        guard let renderer = OffscreenRenderer(device: device, parameters: parameters, size: CGSize(width: settings.width, height: settings.height)) else {
            status = .failed("Не удалось создать рендерер")
            return
        }
        self.offscreenRenderer = renderer
        
        // 2. Создаём временный файл
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("liquid_intro_\(Date().timeIntervalSince1970).mp4")
        
        // 3. Настраиваем AVAssetWriter
        guard setupAssetWriter(url: outputURL, settings: settings) else {
            status = .failed("Не удалось настроить AVAssetWriter")
            return
        }
        
        guard assetWriter?.startWriting() == true else {
            status = .failed("Не удалось начать запись: \(assetWriter?.error?.localizedDescription ?? "unknown")")
            return
        }
        
        assetWriter?.startSession(atSourceTime: .zero)
        
        // 4. Рендерим и кодируем кадры
        status = .rendering(progress: 0)
        
        let frameDuration = 1.0 / settings.fps
        var currentFrame = 0
        
        while currentFrame < settings.totalFrames && !isCancelled {
            let time = Double(currentFrame) * frameDuration
            
            // Ожидаем готовности input
            while !videoInput!.isReadyForMoreMediaData && !isCancelled {
                Thread.sleep(forTimeInterval: 0.001)
            }
            
            if isCancelled { break }
            
            // Рендерим кадр
            guard let texture = renderer.renderFrame(at: Float(time), commandQueue: commandQueue) else {
                log.error("Не удалось отрендерить кадр \(currentFrame)")
                currentFrame += 1
                continue
            }
            
            // Конвертируем в pixel buffer и добавляем
            guard let pixelBuffer = createPixelBuffer(from: texture, settings: settings) else {
                log.error("Не удалось создать pixel buffer для кадра \(currentFrame)")
                currentFrame += 1
                continue
            }
            
            let presentationTime = CMTime(value: CMTimeValue(currentFrame), timescale: CMTimeScale(settings.fps))
            pixelBufferAdaptor?.append(pixelBuffer, withPresentationTime: presentationTime)
            
            currentFrame += 1
            
            // Обновляем прогресс
            let progress = Float(currentFrame) / Float(settings.totalFrames)
            if currentFrame % 10 == 0 {
                status = .rendering(progress: progress)
                log.debug("Экспорт: \(Int(progress * 100))% (\(currentFrame)/\(settings.totalFrames))")
            }
        }
        
        // 5. Финализация
        if isCancelled {
            assetWriter?.cancelWriting()
            try? FileManager.default.removeItem(at: outputURL)
            status = .cancelled
            log.debug("Экспорт отменён")
            return
        }
        
        status = .encoding
        videoInput?.markAsFinished()
        
        assetWriter?.finishWriting { [weak self] in
            guard let self = self else { return }
            
            if let error = self.assetWriter?.error {
                self.status = .failed("Ошибка кодирования: \(error.localizedDescription)")
                return
            }
            
            self.status = .saving
            self.saveToPhotoLibrary(url: outputURL)
        }
    }
    
    private func setupAssetWriter(url: URL, settings: ExportSettings) -> Bool {
        do {
            assetWriter = try AVAssetWriter(url: url, fileType: .mp4)
        } catch {
            log.error("Не удалось создать AVAssetWriter: \(error.localizedDescription)")
            return false
        }
        
        // Настройки видео
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: settings.width,
            AVVideoHeightKey: settings.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: settings.bitrate,
                AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main_AutoLevel,
                AVVideoExpectedSourceFrameRateKey: settings.fps
            ]
        ]
        
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput?.expectsMediaDataInRealTime = false
        
        // Pixel buffer adaptor
        let sourcePixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: settings.width,
            kCVPixelBufferHeightKey as String: settings.height,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        
        pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput!,
            sourcePixelBufferAttributes: sourcePixelBufferAttributes
        )
        
        if assetWriter!.canAdd(videoInput!) {
            assetWriter!.add(videoInput!)
            return true
        }
        
        return false
    }
    
    private func createPixelBuffer(from texture: MTLTexture, settings: ExportSettings) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            settings.width,
            settings.height,
            kCVPixelFormatType_32BGRA,
            [
                kCVPixelBufferMetalCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [:]
            ] as CFDictionary,
            &pixelBuffer
        )
        
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            return nil
        }
        
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        
        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else {
            return nil
        }
        
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let region = MTLRegionMake2D(0, 0, texture.width, texture.height)
        
        texture.getBytes(baseAddress, bytesPerRow: bytesPerRow, from: region, mipmapLevel: 0)
        
        return buffer
    }
    
    private func saveToPhotoLibrary(url: URL) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
            guard let self = self else { return }
            
            guard status == .authorized || status == .limited else {
                self.status = .failed("Нет разрешения на сохранение в галерею")
                return
            }
            
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            } completionHandler: { success, error in
                // Удаляем временный файл
                try? FileManager.default.removeItem(at: url)
                
                if success {
                    self.status = .completed(url)
                    self.log.debug("Видео сохранено в галерею")
                } else {
                    self.status = .failed("Ошибка сохранения: \(error?.localizedDescription ?? "unknown")")
                }
            }
        }
    }
    
    deinit {
        log.debug("ExportManager освобождён")
    }
}

// MARK: - Офф-скрин рендерер
/// Вспомогательный класс для рендеринга кадров без экрана.
private final class OffscreenRenderer {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let parameters: IntroParameters
    
    // Pipelines
    private var particleComputePipeline: MTLComputePipelineState!
    private var diffusePipeline: MTLComputePipelineState!
    private var downsamplePipeline: MTLComputePipelineState!
    private var blurPipeline: MTLComputePipelineState!
    private var particleRenderPipeline: MTLRenderPipelineState!
    private var textRenderPipeline: MTLRenderPipelineState!
    private var compositePipeline: MTLRenderPipelineState!
    
    // Buffers
    private var particlesBuffer: MTLBuffer!
    private var computeUniformsBuffer: MTLBuffer!
    
    // Textures
    private var trailTextures: [MTLTexture?] = [nil, nil]
    private var bloomDownsampleTexture: MTLTexture?
    private var bloomTempTexture: MTLTexture?
    private var bloomBlurredTexture: MTLTexture?
    private var textTexture: MTLTexture?
    private var trailIndex = 0
    
    // Sampler
    private var linearSampler: MTLSamplerState!
    
    // Subsystems
    private let timelineDirector = TimelineDirector()
    private let audioEngine: LoFiEngine
    private let textFactory: TextTextureFactory
    private var paletteUniforms: PaletteUniforms
    private var textUniforms = TextUniforms(visibility: 0, glowIntensity: 1.2)
    
    // Timing
    private var time: Float = 0
    private var lastFrameTime: CFTimeInterval = 0
    private var lastSimulatedTime: Float = 0
    private let size: CGSize
    
    init?(device: MTLDevice, parameters: IntroParameters, size: CGSize) {
        self.device = device
        self.size = size
        self.parameters = parameters
        guard let queue = device.makeCommandQueue() else { return nil }
        self.commandQueue = queue
        self.audioEngine = LoFiEngine(parameters: parameters)
        self.textFactory = TextTextureFactory(device: device)
        
        let palette = parameters.preset.palette
        self.paletteUniforms = PaletteUniforms(
            deep: palette.deep,
            mid: palette.mid,
            hot: palette.hot,
            midMix: palette.midMix
        )
        
        guard setupPipelines() else { return nil }
        createBuffers()
        createSampler()
    }
    
    /// Рендерит один кадр в off-screen текстуру для экспорта.
    /// - Parameters:
    ///   - time: Время в секундах внутри таймлайна (зациклено).
    ///   - commandQueue: Внешняя очередь (не используется, оставлена для совместимости API).
    /// - Returns: BGRA8 текстура с финальным изображением или nil при ошибке.
    func renderFrame(at time: Float, commandQueue: MTLCommandQueue) -> MTLTexture? {
        _ = commandQueue // внешняя очередь не используется, но оставлена для совместимости
        guard size.width > 0, size.height > 0 else { return nil }
        
        guard let commandBuffer = self.commandQueue.makeCommandBuffer() else { return nil }
        
        ensureTextures()
        updateTextTextureIfNeeded()
        
        let now = CACurrentMediaTime()
        let wallDelta = lastFrameTime == 0 ? Float(1.0 / 60.0) : Float(now - lastFrameTime)
        lastFrameTime = now
        self.time = time
        
        let simDelta = lastSimulatedTime == 0 ? wallDelta : max(self.time - lastSimulatedTime, 1.0 / 120.0)
        lastSimulatedTime = self.time
        
        let loopedTime = fmodf(self.time, Config.timelineTotalDuration)
        let audioSnapshot = audioEngine.pullMetrics(deltaTime: simDelta)
        let timelineState = timelineDirector.state(for: loopedTime, amplitude: audioSnapshot.amplitude)
        
        textUniforms.visibility = timelineState.textVisibility
        textUniforms.glowIntensity = 1.2 + audioSnapshot.amplitude * 0.5
        
        let forceGain = parameters.preset.forceResponse * timelineState.forceMultiplier *
        (1.0 + audioSnapshot.kickPulse * 0.4 + audioSnapshot.snarePulse * 0.2 + audioSnapshot.amplitude * 0.3)
        let noiseJitter = timelineState.noiseJitter * parameters.preset.noiseScale
        
        var computeUniforms = ComputeUniforms(
            deltaTime: simDelta,
            forcePosition: SIMD2<Float>(0, 0),
            forceActive: 0,
            time: self.time,
            forceGain: forceGain,
            noiseJitter: noiseJitter,
            kickPulse: audioSnapshot.kickPulse,
            snarePulse: audioSnapshot.snarePulse,
            amplitude: audioSnapshot.amplitude,
            beatPhase: audioSnapshot.beatPhase,
            presetNoiseScale: parameters.preset.noiseScale,
            _padding: 0
        )
        memcpy(computeUniformsBuffer.contents(), &computeUniforms, MemoryLayout<ComputeUniforms>.stride)
        
        encodeParticleCompute(commandBuffer: commandBuffer)
        
        guard let sourceTexture = trailTextures[trailIndex],
              let targetTexture = trailTextures[1 - trailIndex],
              let bloomDown = bloomDownsampleTexture,
              let bloomTemp = bloomTempTexture,
              let bloomBlurred = bloomBlurredTexture else {
            commandBuffer.commit()
            return nil
        }
        
        encodeDiffuse(commandBuffer: commandBuffer, source: sourceTexture, target: targetTexture)
        
        if textUniforms.visibility > 0.001, let textTex = textTexture {
            encodeTextOverlay(commandBuffer: commandBuffer, target: targetTexture, textTexture: textTex)
        }
        
        encodeParticleRender(commandBuffer: commandBuffer, target: targetTexture)
        encodeBloom(commandBuffer: commandBuffer, source: targetTexture, downsample: bloomDown, temp: bloomTemp, blurred: bloomBlurred)
        
        // Composite на BGRA8 текстуру
        let outputDesc = MTLRenderPassDescriptor()
        guard let outputTexture = createOutputTexture() else {
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            return nil
        }
        outputDesc.colorAttachments[0].texture = outputTexture
        outputDesc.colorAttachments[0].loadAction = .clear
        outputDesc.colorAttachments[0].storeAction = .store
        outputDesc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        
        encodeComposite(commandBuffer: commandBuffer,
                        descriptor: outputDesc,
                        base: targetTexture,
                        bloom: bloomBlurred,
                        timelineState: timelineState,
                        audioSnapshot: audioSnapshot)
        
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return outputTexture
    }

    // MARK: - Setup
    
    private func setupPipelines() -> Bool {
        guard let library = try? device.makeLibrary(source: metalShaderSource, options: nil) else {
            exportLog.error("OffscreenRenderer: не удалось собрать шейдеры")
            return false
        }
        do {
            particleComputePipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "updateParticles")!)
            diffusePipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "diffuseTrails")!)
            downsamplePipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "downsampleBright")!)
            blurPipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "gaussianBlur")!)
        } catch {
            exportLog.error("OffscreenRenderer: ошибка compute pipeline \(error.localizedDescription)")
            return false
        }
        
        particleRenderPipeline = createParticlePipeline(library: library, pixelFormat: .rgba16Float)
        textRenderPipeline = createTextPipeline(library: library, pixelFormat: .rgba16Float)
        compositePipeline = createCompositePipeline(library: library, pixelFormat: .bgra8Unorm)
        return particleRenderPipeline != nil && textRenderPipeline != nil && compositePipeline != nil
    }
    
    private func createBuffers() {
        particlesBuffer = device.makeBuffer(
            length: MemoryLayout<Particle>.stride * Config.particleCount,
            options: .storageModeShared
        )
        computeUniformsBuffer = device.makeBuffer(
            length: MemoryLayout<ComputeUniforms>.stride,
            options: .storageModeShared
        )
        
        let pointer = particlesBuffer.contents().bindMemory(to: Particle.self, capacity: Config.particleCount)
        for i in 0..<Config.particleCount {
            let x = Float(i % Config.gridSize) / Float(Config.gridSize) * 2.0 - 1.0
            let y = Float(i / Config.gridSize) / Float(Config.gridSize) * 2.0 - 1.0
            pointer[i] = Particle(position: SIMD2<Float>(x, y), velocity: .zero)
        }
    }
    
    private func createSampler() {
        let desc = MTLSamplerDescriptor()
        desc.minFilter = .linear
        desc.magFilter = .linear
        desc.sAddressMode = .clampToEdge
        desc.tAddressMode = .clampToEdge
        linearSampler = device.makeSamplerState(descriptor: desc)
    }
    
    // MARK: - Encoding
    
    private func encodeParticleCompute(commandBuffer: MTLCommandBuffer) {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.setComputePipelineState(particleComputePipeline)
        encoder.setBuffer(particlesBuffer, offset: 0, index: 0)
        encoder.setBuffer(computeUniformsBuffer, offset: 0, index: 1)
        
        let threadWidth = particleComputePipeline.threadExecutionWidth
        let threads = MTLSize(width: threadWidth, height: 1, depth: 1)
        let groups = MTLSize(width: (Config.particleCount + threadWidth - 1) / threadWidth, height: 1, depth: 1)
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threads)
        encoder.endEncoding()
    }
    
    private func encodeDiffuse(commandBuffer: MTLCommandBuffer, source: MTLTexture, target: MTLTexture) {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.setComputePipelineState(diffusePipeline)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(target, index: 1)
        
        var uniforms = DiffuseUniforms(
            dissipation: Config.dissipation,
            diffusion: Config.diffusion,
            texelSize: SIMD2<Float>(1.0 / Float(source.width), 1.0 / Float(source.height))
        )
        encoder.setBytes(&uniforms, length: MemoryLayout<DiffuseUniforms>.stride, index: 0)
        
        let threads = MTLSize(width: 16, height: 16, depth: 1)
        let groups = MTLSize(width: (source.width + 15) / 16,
                             height: (source.height + 15) / 16,
                             depth: 1)
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threads)
        encoder.endEncoding()
    }
    
    private func encodeTextOverlay(commandBuffer: MTLCommandBuffer, target: MTLTexture, textTexture: MTLTexture) {
        let passDesc = MTLRenderPassDescriptor()
        passDesc.colorAttachments[0].texture = target
        passDesc.colorAttachments[0].loadAction = .load
        passDesc.colorAttachments[0].storeAction = .store
        
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDesc) else { return }
        encoder.setRenderPipelineState(textRenderPipeline)
        encoder.setFragmentTexture(textTexture, index: 0)
        encoder.setFragmentSamplerState(linearSampler, index: 0)
        
        var tu = textUniforms
        encoder.setFragmentBytes(&tu, length: MemoryLayout<TextUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }
    
    private func encodeParticleRender(commandBuffer: MTLCommandBuffer, target: MTLTexture) {
        let passDesc = MTLRenderPassDescriptor()
        passDesc.colorAttachments[0].texture = target
        passDesc.colorAttachments[0].loadAction = .load
        passDesc.colorAttachments[0].storeAction = .store
        
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDesc) else { return }
        encoder.setRenderPipelineState(particleRenderPipeline)
        encoder.setVertexBuffer(particlesBuffer, offset: 0, index: 0)
        
        var palette = paletteUniforms
        encoder.setFragmentBytes(&palette, length: MemoryLayout<PaletteUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: Config.particleCount)
        encoder.endEncoding()
    }
    
    private func encodeBloom(commandBuffer: MTLCommandBuffer, source: MTLTexture,
                             downsample: MTLTexture, temp: MTLTexture, blurred: MTLTexture) {
        if let encoder = commandBuffer.makeComputeCommandEncoder() {
            encoder.setComputePipelineState(downsamplePipeline)
            encoder.setTexture(source, index: 0)
            encoder.setTexture(downsample, index: 1)
            var threshold = Config.bloomThreshold
            encoder.setBytes(&threshold, length: MemoryLayout<Float>.stride, index: 0)
            
            let threads = MTLSize(width: 16, height: 16, depth: 1)
            let groups = MTLSize(width: (downsample.width + 15) / 16,
                                 height: (downsample.height + 15) / 16,
                                 depth: 1)
            encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threads)
            encoder.endEncoding()
        }
        
        if let encoder = commandBuffer.makeComputeCommandEncoder() {
            encoder.setComputePipelineState(blurPipeline)
            encoder.setTexture(downsample, index: 0)
            encoder.setTexture(temp, index: 1)
            var uniforms = BlurUniforms(
                direction: SIMD2<Float>(1.0 / Float(downsample.width), 0),
                radius: Config.blurRadius,
                sigma: Config.blurSigma
            )
            encoder.setBytes(&uniforms, length: MemoryLayout<BlurUniforms>.stride, index: 0)
            
            let threads = MTLSize(width: 16, height: 16, depth: 1)
            let groups = MTLSize(width: (downsample.width + 15) / 16,
                                 height: (downsample.height + 15) / 16,
                                 depth: 1)
            encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threads)
            encoder.endEncoding()
        }
        
        if let encoder = commandBuffer.makeComputeCommandEncoder() {
            encoder.setComputePipelineState(blurPipeline)
            encoder.setTexture(temp, index: 0)
            encoder.setTexture(blurred, index: 1)
            var uniforms = BlurUniforms(
                direction: SIMD2<Float>(0, 1.0 / Float(temp.height)),
                radius: Config.blurRadius,
                sigma: Config.blurSigma
            )
            encoder.setBytes(&uniforms, length: MemoryLayout<BlurUniforms>.stride, index: 0)
            
            let threads = MTLSize(width: 16, height: 16, depth: 1)
            let groups = MTLSize(width: (temp.width + 15) / 16,
                                 height: (temp.height + 15) / 16,
                                 depth: 1)
            encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threads)
            encoder.endEncoding()
        }
    }
    
    private func encodeComposite(commandBuffer: MTLCommandBuffer,
                                 descriptor: MTLRenderPassDescriptor,
                                 base: MTLTexture,
                                 bloom: MTLTexture,
                                 timelineState: TimelineState,
                                 audioSnapshot: AudioReactiveSnapshot) {
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        encoder.setRenderPipelineState(compositePipeline)
        encoder.setFragmentTexture(base, index: 0)
        encoder.setFragmentTexture(bloom, index: 1)
        encoder.setFragmentSamplerState(linearSampler, index: 0)
        
        let bloomBoost = Config.baseBloomBoost * timelineState.bloomGain *
        (1.0 + audioSnapshot.kickPulse * 0.5 + audioSnapshot.snarePulse * 0.25 + audioSnapshot.amplitude * 0.35)
        
        var uniforms = CompositeUniforms(
            bloomStrength: Config.bloomStrength * parameters.preset.baseBloom,
            bloomBoost: bloomBoost,
            toneMapGamma: Config.toneMapGamma,
            _padding: 0
        )
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<CompositeUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }
    
    // MARK: - Texture helpers
    
    private func ensureTextures() {
        let width = max(1, Int(size.width))
        let height = max(1, Int(size.height))
        guard trailTextures[0]?.width != width || trailTextures[0]?.height != height else { return }
        
        let trailDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: width,
            height: height,
            mipmapped: false
        )
        trailDesc.usage = [.renderTarget, .shaderRead, .shaderWrite]
        trailTextures[0] = device.makeTexture(descriptor: trailDesc)
        trailTextures[1] = device.makeTexture(descriptor: trailDesc)
        
        let bloomWidth = max(1, width / 2)
        let bloomHeight = max(1, height / 2)
        let bloomDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: bloomWidth,
            height: bloomHeight,
            mipmapped: false
        )
        bloomDesc.usage = [.shaderRead, .shaderWrite]
        bloomDownsampleTexture = device.makeTexture(descriptor: bloomDesc)
        bloomTempTexture = device.makeTexture(descriptor: bloomDesc)
        bloomBlurredTexture = device.makeTexture(descriptor: bloomDesc)
        
        trailIndex = 0
        textTexture = nil
    }
    
    private func updateTextTextureIfNeeded() {
        guard textTexture == nil else { return }
        textTexture = textFactory.texture(for: parameters.text, drawableSize: size)
    }
    
    private func createParticlePipeline(library: MTLLibrary, pixelFormat: MTLPixelFormat) -> MTLRenderPipelineState? {
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "particleVertex")
        desc.fragmentFunction = library.makeFunction(name: "particleFragment")
        desc.colorAttachments[0].pixelFormat = pixelFormat
        desc.colorAttachments[0].isBlendingEnabled = true
        desc.colorAttachments[0].rgbBlendOperation = .add
        desc.colorAttachments[0].alphaBlendOperation = .add
        desc.colorAttachments[0].sourceRGBBlendFactor = .one
        desc.colorAttachments[0].destinationRGBBlendFactor = .one
        desc.colorAttachments[0].sourceAlphaBlendFactor = .one
        desc.colorAttachments[0].destinationAlphaBlendFactor = .one
        return try? device.makeRenderPipelineState(descriptor: desc)
    }
    
    private func createTextPipeline(library: MTLLibrary, pixelFormat: MTLPixelFormat) -> MTLRenderPipelineState? {
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "fullscreenVertex")
        desc.fragmentFunction = library.makeFunction(name: "textOverlayFragment")
        desc.colorAttachments[0].pixelFormat = pixelFormat
        desc.colorAttachments[0].isBlendingEnabled = true
        desc.colorAttachments[0].rgbBlendOperation = .add
        desc.colorAttachments[0].alphaBlendOperation = .add
        desc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        desc.colorAttachments[0].destinationRGBBlendFactor = .one
        desc.colorAttachments[0].sourceAlphaBlendFactor = .one
        desc.colorAttachments[0].destinationAlphaBlendFactor = .one
        return try? device.makeRenderPipelineState(descriptor: desc)
    }
    
    private func createCompositePipeline(library: MTLLibrary, pixelFormat: MTLPixelFormat) -> MTLRenderPipelineState? {
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "fullscreenVertex")
        desc.fragmentFunction = library.makeFunction(name: "compositeFragment")
        desc.colorAttachments[0].pixelFormat = pixelFormat
        return try? device.makeRenderPipelineState(descriptor: desc)
    }
    
    private func createOutputTexture() -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: Int(size.width),
            height: Int(size.height),
            mipmapped: false
        )
        desc.usage = [.renderTarget, .shaderRead]
        return device.makeTexture(descriptor: desc)
    }
}
