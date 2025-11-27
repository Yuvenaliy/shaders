/// ParticleMagicView.swift
/// Основной модуль HDR-рендеринга жидких частиц с аудио-реактивной логикой.
///
/// Архитектура рендеринга (каждый кадр):
/// ```
/// 1. Compute: Обновление позиций/скоростей частиц
/// 2. Diffuse: Размытие + затухание следов (ping-pong)
/// 3. Text: Наложение текста (опционально)
/// 4. Particles: Рендеринг частиц поверх следов
/// 5. Bloom: Downsample → Blur H → Blur V
/// 6. Composite: Base + Bloom → Tone mapping → Screen
/// ```
///
/// Форматы текстур:
/// - Trail/Base: RGBA16Float (HDR)
/// - Bloom: RGBA16Float (уменьшенный размер)
/// - Screen: BGRA8Unorm_sRGB

import SwiftUI
import MetalKit
import UIKit
import os

// MARK: - Логгер модуля
private let renderLog = Logger(subsystem: "com.liquidintro", category: "render")

// MARK: - Структуры данных для GPU

/// Частица с позицией и скоростью.
struct Particle {
    var position: SIMD2<Float>
    var velocity: SIMD2<Float>
}

/// Униформы для compute шейдера частиц.
struct ComputeUniforms {
    var deltaTime: Float
    var forcePosition: SIMD2<Float>
    var forceActive: UInt32
    var time: Float
    var forceGain: Float
    var noiseJitter: Float
    var kickPulse: Float
    var snarePulse: Float
    var amplitude: Float
    var beatPhase: Float
    var presetNoiseScale: Float
    var _padding: Float = 0  // Выравнивание до 48 байт
}

/// Униформы для диффузии/затухания следов.
struct DiffuseUniforms {
    var dissipation: Float
    var diffusion: Float
    var texelSize: SIMD2<Float>
}

/// Униформы для Gaussian blur.
struct BlurUniforms {
    var direction: SIMD2<Float>
    var radius: UInt32
    var sigma: Float
}

/// Униформы для финального композитинга.
struct CompositeUniforms {
    var bloomStrength: Float
    var bloomBoost: Float
    var toneMapGamma: Float
    var _padding: Float = 0
}

/// Униформы цветовой палитры.
struct PaletteUniforms {
    var deep: SIMD3<Float>
    var _pad1: Float = 0
    var mid: SIMD3<Float>
    var _pad2: Float = 0
    var hot: SIMD3<Float>
    var midMix: Float
}

/// Униформы текстового слоя.
struct TextUniforms {
    var visibility: Float
    var glowIntensity: Float
    var _padding: SIMD2<Float> = .zero
}

// MARK: - SwiftUI Views

/// Главная витрина приложения с полным UI для настройки интро.
struct ParticleMagicView: View {
    @State private var parameters = IntroParameters.default
    @State private var showingSettings = false
    
    var body: some View {
        ZStack {
            // Рендерер на весь экран
            FluidMetalView(parameters: parameters)
                .ignoresSafeArea()
            
            // Оверлей с UI
            VStack {
                // Верхняя панель
                HStack {
                    Spacer()
                    Button(action: { showingSettings = true }) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.title2)
                            .foregroundColor(.white)
                            .padding(12)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .padding()
                }
                
                Spacer()
                
                // Нижняя панель с вводом текста
                VStack(spacing: 16) {
                    // Поле ввода текста
                    TextField("@nickname", text: $parameters.text)
                        .textFieldStyle(.plain)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                        .padding(.horizontal, 32)
                    
                    // Выбор пресета
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(VisualPresetLibrary.allPresets, id: \.name) { preset in
                                PresetButton(
                                    preset: preset,
                                    isSelected: parameters.preset.name == preset.name
                                ) {
                                    withAnimation(.easeInOut(duration: 0.3)) {
                                        parameters.preset = preset
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 32)
                    }
                }
                .padding(.bottom, 40)
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(parameters: $parameters)
        }
        .preferredColorScheme(.dark)
    }
}

/// Кнопка выбора пресета.
struct PresetButton: View {
    let preset: VisualPreset
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                // Цветовой индикатор
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: Double(preset.palette.deep.x),
                                      green: Double(preset.palette.deep.y),
                                      blue: Double(preset.palette.deep.z)),
                                Color(red: Double(preset.palette.hot.x),
                                      green: Double(preset.palette.hot.y),
                                      blue: Double(preset.palette.hot.z))
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 44, height: 44)
                    .overlay(
                        Circle()
                            .stroke(isSelected ? Color.white : Color.clear, lineWidth: 2)
                    )
                
                Text(preset.name)
                    .font(.caption)
                    .foregroundColor(isSelected ? .white : .gray)
            }
        }
        .buttonStyle(.plain)
    }
}

/// Экран настроек.
struct SettingsView: View {
    @Binding var parameters: IntroParameters
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            Form {
                Section("Аудио") {
                    HStack {
                        Text("BPM")
                        Spacer()
                        Text("\(Int(parameters.bpm))")
                            .foregroundColor(.secondary)
                    }
                    Slider(value: $parameters.bpm, in: 60...140, step: 1)
                    
                    HStack {
                        Text("Groove")
                        Spacer()
                        Text("\(Int(parameters.groove * 100))%")
                            .foregroundColor(.secondary)
                    }
                    Slider(value: $parameters.groove, in: 0...1)
                }
                
                Section("О приложении") {
                    Text("Liquid Intro Studio")
                        .font(.headline)
                    Text("Создавайте виральные видео-интро с эффектом жидкого неона")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
    }
}

/// Полноэкранная витрина без UI (для экспорта).
struct FluidWallpaperView: View {
    var parameters: IntroParameters = .default
    
    var body: some View {
        FluidMetalView(parameters: parameters)
            .ignoresSafeArea()
    }
}

// MARK: - MTKView Bridge

/// UIViewRepresentable мост между SwiftUI и Metal рендерером.
struct FluidMetalView: UIViewRepresentable {
    var parameters: IntroParameters
    
    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        
        guard let device = MTLCreateSystemDefaultDevice() else {
            renderLog.error("Metal не поддерживается на этом устройстве")
            return view
        }
        
        // Конфигурация MTKView
        view.device = device
        view.preferredFramesPerSecond = 120
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.framebufferOnly = false
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.colorPixelFormat = .bgra8Unorm_srgb
        
        // Создаём и настраиваем рендерер
        let renderer = FluidRenderer(device: device, parameters: parameters)
        view.delegate = renderer
        renderer.setup(view: view)
        context.coordinator.renderer = renderer
        
        renderLog.debug("FluidMetalView создан")
        return view
    }
    
    func updateUIView(_ uiView: MTKView, context: Context) {
        // Обновляем параметры рендерера при изменении
        context.coordinator.renderer?.updateParameters(parameters)
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    class Coordinator {
        var renderer: FluidRenderer?
    }
}

// MARK: - Core Renderer

/// Основной Metal-рендерер с аудио-реактивной частью и текстовым слоем.
final class FluidRenderer: NSObject, MTKViewDelegate {
    
    // MARK: - Core Metal objects
    private let device: MTLDevice
    private var commandQueue: MTLCommandQueue!
    
    // MARK: - Pipeline states
    private var particleComputePipeline: MTLComputePipelineState!
    private var diffusePipeline: MTLComputePipelineState!
    private var downsamplePipeline: MTLComputePipelineState!
    private var blurPipeline: MTLComputePipelineState!
    private var particleRenderPipeline: MTLRenderPipelineState!
    private var textRenderPipeline: MTLRenderPipelineState!
    private var compositePipeline: MTLRenderPipelineState!
    
    // MARK: - Buffers
    private var particlesBuffer: MTLBuffer!
    private var computeUniformsBuffer: MTLBuffer!
    
    // MARK: - Textures
    private var trailTextures: [MTLTexture?] = [nil, nil]
    private var bloomDownsampleTexture: MTLTexture?
    private var bloomTempTexture: MTLTexture?
    private var bloomBlurredTexture: MTLTexture?
    private var textTexture: MTLTexture?
    private var trailIndex = 0
    
    // MARK: - Sampler
    private var linearSampler: MTLSamplerState!
    
    // MARK: - Parameters & State
    private var parameters: IntroParameters
    private var paletteUniforms: PaletteUniforms
    private var textUniforms = TextUniforms(visibility: 0, glowIntensity: 1.2)
    
    // MARK: - Subsystems
    private let timelineDirector = TimelineDirector()
    private let audioEngine: LoFiEngine
    private let textFactory: TextTextureFactory
    private let log = Logger(subsystem: "com.liquidintro", category: "render")
    
    // MARK: - Timing
    private var time: Float = 0
    private var frameCounter: Int = 0
    private var lastFrameTime: CFTimeInterval = 0
    
    // MARK: - Touch interaction
    private var touchPosition = SIMD2<Float>(0, 0)
    private var touchActive = false
    
    // MARK: - Texture management
    private var needsTextureClear = true
    private var drawableSize = CGSize.zero
    private var parametersChanged = false
    
    // MARK: - Initialization
    
    init(device: MTLDevice, parameters: IntroParameters) {
        self.device = device
        self.parameters = parameters
        self.audioEngine = LoFiEngine(parameters: parameters)
        self.textFactory = TextTextureFactory(device: device)
        
        // Инициализация палитры
        let palette = parameters.preset.palette
        self.paletteUniforms = PaletteUniforms(
            deep: palette.deep,
            mid: palette.mid,
            hot: palette.hot,
            midMix: palette.midMix
        )
        
        super.init()
        
        self.commandQueue = device.makeCommandQueue()
        log.debug("FluidRenderer инициализирован")
    }
    
    // MARK: - Setup
    
    func setup(view: MTKView) {
        log.debug("Начинаем настройку Metal пайплайна...")
        
        // Компилируем шейдеры
        guard let library = try? device.makeLibrary(source: metalShaderSource, options: nil) else {
            log.error("Не удалось скомпилировать шейдеры")
            return
        }
        
        // Создаём compute pipelines
        do {
            particleComputePipeline = try device.makeComputePipelineState(
                function: library.makeFunction(name: "updateParticles")!
            )
            diffusePipeline = try device.makeComputePipelineState(
                function: library.makeFunction(name: "diffuseTrails")!
            )
            downsamplePipeline = try device.makeComputePipelineState(
                function: library.makeFunction(name: "downsampleBright")!
            )
            blurPipeline = try device.makeComputePipelineState(
                function: library.makeFunction(name: "gaussianBlur")!
            )
        } catch {
            log.error("Ошибка создания compute pipeline: \(error.localizedDescription)")
            return
        }
        
        // Создаём render pipelines
        particleRenderPipeline = createParticlePipeline(library: library, pixelFormat: .rgba16Float)
        textRenderPipeline = createTextPipeline(library: library, pixelFormat: .rgba16Float)
        compositePipeline = createCompositePipeline(library: library, pixelFormat: view.colorPixelFormat)
        
        // Создаём буферы
        createBuffers()
        
        // Создаём sampler
        createSampler()
        
        // Настраиваем touch handling
        setupTouchHandling(view: view)
        
        log.debug("Metal пайплайн настроен успешно")
    }
    
    func updateParameters(_ newParameters: IntroParameters) {
        guard parameters != newParameters else { return }
        
        parameters = newParameters
        parametersChanged = true
        
        // Обновляем палитру
        let palette = parameters.preset.palette
        paletteUniforms = PaletteUniforms(
            deep: palette.deep,
            mid: palette.mid,
            hot: palette.hot,
            midMix: palette.midMix
        )
        
        // Сбрасываем текстовую текстуру
        textTexture = nil
        
        // Обновляем аудио-движок под новые BPM/groove
        audioEngine.update(parameters: parameters)
        
        log.debug("Параметры обновлены: '\(self.parameters.text)' preset=\(self.parameters.preset.name)")
    }
    
    // MARK: - Pipeline Creation Helpers
    
    private func createParticlePipeline(library: MTLLibrary, pixelFormat: MTLPixelFormat) -> MTLRenderPipelineState? {
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "particleVertex")
        desc.fragmentFunction = library.makeFunction(name: "particleFragment")
        desc.colorAttachments[0].pixelFormat = pixelFormat
        
        // Additive blending для свечения
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
        
        // Additive blending для свечения текста
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
    
    private func createBuffers() {
        // Буфер частиц
        particlesBuffer = device.makeBuffer(
            length: MemoryLayout<Particle>.stride * Config.particleCount,
            options: .storageModeShared
        )
        
        // Инициализация частиц в сетке
        let pointer = particlesBuffer.contents().bindMemory(to: Particle.self, capacity: Config.particleCount)
        for i in 0..<Config.particleCount {
            let x = Float(i % Config.gridSize) / Float(Config.gridSize) * 2.0 - 1.0
            let y = Float(i / Config.gridSize) / Float(Config.gridSize) * 2.0 - 1.0
            pointer[i] = Particle(position: SIMD2<Float>(x, y), velocity: .zero)
        }
        
        // Буфер униформ
        computeUniformsBuffer = device.makeBuffer(
            length: MemoryLayout<ComputeUniforms>.stride,
            options: .storageModeShared
        )
        
        log.debug("Буферы созданы: \(Config.particleCount) частиц")
    }
    
    private func createSampler() {
        let desc = MTLSamplerDescriptor()
        desc.minFilter = .linear
        desc.magFilter = .linear
        desc.sAddressMode = .clampToEdge
        desc.tAddressMode = .clampToEdge
        linearSampler = device.makeSamplerState(descriptor: desc)
    }
    
    private func setupTouchHandling(view: MTKView) {
        view.isUserInteractionEnabled = true
        let panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
        view.addGestureRecognizer(panGesture)
    }
    
    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let view = gesture.view as? MTKView,
              view.bounds.width > 0, view.bounds.height > 0 else { return }
        
        let location = gesture.location(in: view)
        let x = Float(location.x / view.bounds.width) * 2.0 - 1.0
        let y = Float(1.0 - location.y / view.bounds.height) * 2.0 - 1.0
        touchPosition = SIMD2<Float>(x, y)
        
        switch gesture.state {
        case .began:
            touchActive = true
            log.debug("Touch began: (\(x), \(y))")
        case .changed:
            touchActive = true
        default:
            if touchActive {
                log.debug("Touch ended")
            }
            touchActive = false
        }
    }
    
    // MARK: - MTKViewDelegate
    
    func draw(in view: MTKView) {
        guard view.drawableSize.width > 0, view.drawableSize.height > 0,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        
        // Обновляем текстуры при необходимости
        ensureTextures(for: view.drawableSize)
        updateTextTextureIfNeeded()
        
        if needsTextureClear {
            clearTrailTextures(commandBuffer: commandBuffer)
            needsTextureClear = false
        }
        
        // Обновляем время
        let now = CACurrentMediaTime()
        let deltaTime = lastFrameTime == 0 ? Float(1.0 / 60.0) : Float(now - lastFrameTime)
        lastFrameTime = now
        time += deltaTime
        
        // Получаем состояние таймлайна и аудио
        let loopedTime = fmodf(time, Config.timelineTotalDuration)
        let audioSnapshot = audioEngine.pullMetrics(deltaTime: deltaTime)
        let timelineState = timelineDirector.state(for: loopedTime, amplitude: audioSnapshot.amplitude)
        
        // Обновляем униформы текста
        textUniforms.visibility = timelineState.textVisibility
        textUniforms.glowIntensity = 1.2 + audioSnapshot.amplitude * 0.5
        
        // Вычисляем модификаторы на основе аудио
        let forceGain = parameters.preset.forceResponse * timelineState.forceMultiplier *
            (1.0 + audioSnapshot.kickPulse * 0.4 + audioSnapshot.snarePulse * 0.2 + audioSnapshot.amplitude * 0.3)
        let noiseJitter = timelineState.noiseJitter * parameters.preset.noiseScale
        
        // Логирование (каждые N кадров)
        frameCounter += 1
        if Config.enablePerformanceLogging && frameCounter % Config.debugLogInterval == 0 {
            log.debug("Frame \(self.frameCounter): amp=\(audioSnapshot.amplitude, format: .fixed(precision: 2)) kick=\(audioSnapshot.kickPulse, format: .fixed(precision: 2)) text=\(self.textUniforms.visibility, format: .fixed(precision: 2)) phase=\(timelineState.currentPhase)")
        }
        
        // Обновляем униформы compute шейдера
        var computeUniforms = ComputeUniforms(
            deltaTime: deltaTime,
            forcePosition: touchPosition,
            forceActive: touchActive ? 1 : 0,
            time: time,
            forceGain: forceGain,
            noiseJitter: noiseJitter,
            kickPulse: audioSnapshot.kickPulse,
            snarePulse: audioSnapshot.snarePulse,
            amplitude: audioSnapshot.amplitude,
            beatPhase: audioSnapshot.beatPhase,
            presetNoiseScale: parameters.preset.noiseScale
        )
        memcpy(computeUniformsBuffer.contents(), &computeUniforms, MemoryLayout<ComputeUniforms>.stride)
        
        // === RENDERING PASSES ===
        
        // 1. Compute: Обновление частиц
        encodeParticleCompute(commandBuffer: commandBuffer)
        
        guard let sourceTexture = trailTextures[trailIndex],
              let targetTexture = trailTextures[1 - trailIndex],
              let bloomDown = bloomDownsampleTexture,
              let bloomTemp = bloomTempTexture,
              let bloomBlurred = bloomBlurredTexture,
              let drawable = view.currentDrawable else {
            commandBuffer.commit()
            return
        }
        
        // 2. Diffuse: Размытие + затухание следов
        encodeDiffuse(commandBuffer: commandBuffer, source: sourceTexture, target: targetTexture)
        
        // 3. Text: Наложение текста (до частиц, чтобы bloom захватил свечение)
        if textUniforms.visibility > 0.001, let textTex = textTexture {
            encodeTextOverlay(commandBuffer: commandBuffer, target: targetTexture, textTexture: textTex)
        }
        
        // 4. Particles: Рендеринг частиц
        encodeParticleRender(commandBuffer: commandBuffer, target: targetTexture)
        
        // 5. Bloom: Downsample → Blur H → Blur V
        encodeBloom(commandBuffer: commandBuffer, source: targetTexture,
                    downsample: bloomDown, temp: bloomTemp, blurred: bloomBlurred)
        
        // 6. Composite: Финальный вывод на экран
        if let passDescriptor = view.currentRenderPassDescriptor {
            encodeComposite(commandBuffer: commandBuffer, descriptor: passDescriptor,
                          base: targetTexture, bloom: bloomBlurred, timelineState: timelineState, audioSnapshot: audioSnapshot)
            commandBuffer.present(drawable)
        }
        
        commandBuffer.commit()
        trailIndex = 1 - trailIndex
    }
    
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        if size != drawableSize {
            drawableSize = size
            trailTextures = [nil, nil]
            bloomDownsampleTexture = nil
            bloomTempTexture = nil
            bloomBlurredTexture = nil
            textTexture = nil
            needsTextureClear = true
            log.debug("Drawable size changed to \(Int(size.width))x\(Int(size.height))")
        }
    }
    
    // MARK: - Encoding Helpers
    
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
        let groups = MTLSize(
            width: (source.width + 15) / 16,
            height: (source.height + 15) / 16,
            depth: 1
        )
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
        // Downsample bright areas
        if let encoder = commandBuffer.makeComputeCommandEncoder() {
            encoder.setComputePipelineState(downsamplePipeline)
            encoder.setTexture(source, index: 0)
            encoder.setTexture(downsample, index: 1)
            
            var threshold = Config.bloomThreshold
            encoder.setBytes(&threshold, length: MemoryLayout<Float>.stride, index: 0)
            
            let threads = MTLSize(width: 16, height: 16, depth: 1)
            let groups = MTLSize(
                width: (downsample.width + 15) / 16,
                height: (downsample.height + 15) / 16,
                depth: 1
            )
            encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threads)
            encoder.endEncoding()
        }
        
        // Horizontal blur
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
            let groups = MTLSize(
                width: (downsample.width + 15) / 16,
                height: (downsample.height + 15) / 16,
                depth: 1
            )
            encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threads)
            encoder.endEncoding()
        }
        
        // Vertical blur
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
            let groups = MTLSize(
                width: (temp.width + 15) / 16,
                height: (temp.height + 15) / 16,
                depth: 1
            )
            encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threads)
            encoder.endEncoding()
        }
    }
    
    private func encodeComposite(commandBuffer: MTLCommandBuffer, descriptor: MTLRenderPassDescriptor,
                                base: MTLTexture, bloom: MTLTexture,
                                timelineState: TimelineState, audioSnapshot: AudioReactiveSnapshot) {
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        
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
            toneMapGamma: Config.toneMapGamma
        )
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<CompositeUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }
    
    // MARK: - Texture Management
    
    private func ensureTextures(for size: CGSize) {
        guard size != drawableSize || trailTextures[0] == nil else { return }
        drawableSize = size
        
        let width = max(1, Int(size.width))
        let height = max(1, Int(size.height))
        
        // Trail textures (full resolution, HDR)
        let trailDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: width,
            height: height,
            mipmapped: false
        )
        trailDesc.usage = [.renderTarget, .shaderRead, .shaderWrite]
        trailTextures[0] = device.makeTexture(descriptor: trailDesc)
        trailTextures[1] = device.makeTexture(descriptor: trailDesc)
        
        // Bloom textures (half resolution)
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
        
        textTexture = nil
        trailIndex = 0
        needsTextureClear = true
        
        log.debug("Текстуры пересозданы: \(width)x\(height)")
    }
    
    private func clearTrailTextures(commandBuffer: MTLCommandBuffer) {
        for texture in trailTextures.compactMap({ $0 }) {
            let passDesc = MTLRenderPassDescriptor()
            passDesc.colorAttachments[0].texture = texture
            passDesc.colorAttachments[0].loadAction = .clear
            passDesc.colorAttachments[0].storeAction = .store
            passDesc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            commandBuffer.makeRenderCommandEncoder(descriptor: passDesc)?.endEncoding()
        }
        log.debug("Trail текстуры очищены")
    }
    
    private func updateTextTextureIfNeeded() {
        guard (textTexture == nil || parametersChanged),
              drawableSize.width > 0, drawableSize.height > 0 else { return }
        
        textTexture = textFactory.texture(for: parameters.text, drawableSize: drawableSize)
        parametersChanged = false
        
        if textTexture != nil {
            log.debug("Текстовая текстура обновлена: '\(self.parameters.text)'")
        }
    }
    
    deinit {
        audioEngine.stop()
        log.debug("FluidRenderer освобождён")
    }
}

// MARK: - Metal Shaders

let metalShaderSource = """
#include <metal_stdlib>
using namespace metal;

// === STRUCTURES ===

struct Particle {
    float2 position;
    float2 velocity;
};

struct ComputeUniforms {
    float deltaTime;
    float2 forcePosition;
    uint forceActive;
    float time;
    float forceGain;
    float noiseJitter;
    float kickPulse;
    float snarePulse;
    float amplitude;
    float beatPhase;
    float presetNoiseScale;
    float _padding;
};

struct DiffuseUniforms {
    float dissipation;
    float diffusion;
    float2 texelSize;
};

struct BlurUniforms {
    float2 direction;
    uint radius;
    float sigma;
};

struct CompositeUniforms {
    float bloomStrength;
    float bloomBoost;
    float toneMapGamma;
    float _padding;
};

struct PaletteUniforms {
    float3 deep;
    float _pad1;
    float3 mid;
    float _pad2;
    float3 hot;
    float midMix;
};

struct TextUniforms {
    float visibility;
    float glowIntensity;
    float2 _padding;
};

// === CONSTANTS ===

constant int PARTICLE_COUNT = \(Config.particleCount);
constant float FORCE_RADIUS = \(Config.forceRadius);
constant float FORCE_STRENGTH = \(Config.forceStrength);
constant float VISCOSITY = \(Config.viscosity);
constant float BASE_SIZE = \(Config.baseSize);

// === SAMPLERS ===

constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);

// === COMPUTE SHADERS ===

/// Обновление позиций и скоростей частиц.
kernel void updateParticles(
    device Particle *particles [[buffer(0)]],
    constant ComputeUniforms &u [[buffer(1)]],
    uint id [[thread_position_in_grid]]
) {
    if (id >= uint(PARTICLE_COUNT)) return;
    
    Particle p = particles[id];
    float2 force = float2(0.0);
    
    // Сила касания (если активно)
    if (u.forceActive == 1) {
        float2 toTouch = u.forcePosition - p.position;
        float dist = length(toTouch) + 1e-4;
        float falloff = 1.0 - smoothstep(0.0, FORCE_RADIUS, dist);
        float strength = FORCE_STRENGTH * u.forceGain;
        // ИСПРАВЛЕНО: Более физичная модель силы
        force = normalize(toTouch) * strength * falloff / (dist + 0.1);
    }
    
    // Пульсация от бита
    float beatPulse = 0.6 + 0.4 * sin(u.beatPhase * 6.28318);
    
    // Шум для органичного движения
    float noiseAmount = (0.005 + u.noiseJitter * 0.003) * max(u.presetNoiseScale, 0.25) * beatPulse;
    float2 noise = float2(
        sin(p.position.y * 5.0 + u.time * 0.8 + float(id) * 0.001),
        cos(p.position.x * 5.0 + u.time * 0.7 + float(id) * 0.001)
    ) * noiseAmount * (1.0 + u.amplitude * 0.3);
    
    // Обновление скорости
    p.velocity = p.velocity * VISCOSITY + force * u.deltaTime + noise;
    
    // Аудио-реактивные импульсы
    float2 radial = normalize(p.position + float2(1e-4));
    float2 tangent = float2(-p.position.y, p.position.x);
    p.velocity += (radial * u.kickPulse * 0.4 + tangent * u.snarePulse * 0.25) * u.deltaTime;
    
    // Обновление позиции
    p.position += p.velocity * u.deltaTime;
    
    // ИСПРАВЛЕНО: Корректное отражение от границ
    if (p.position.x > 1.0) {
        p.position.x = 2.0 - p.position.x;
        p.velocity.x *= -0.6;
    } else if (p.position.x < -1.0) {
        p.position.x = -2.0 - p.position.x;
        p.velocity.x *= -0.6;
    }
    
    if (p.position.y > 1.0) {
        p.position.y = 2.0 - p.position.y;
        p.velocity.y *= -0.6;
    } else if (p.position.y < -1.0) {
        p.position.y = -2.0 - p.position.y;
        p.velocity.y *= -0.6;
    }
    
    particles[id] = p;
}

/// Диффузия и затухание следов (ping-pong).
/// ИСПРАВЛЕНО: Правильный 5-point stencil kernel.
kernel void diffuseTrails(
    texture2d<float, access::read> source [[texture(0)]],
    texture2d<float, access::write> target [[texture(1)]],
    constant DiffuseUniforms &u [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint w = target.get_width();
    uint h = target.get_height();
    if (gid.x >= w || gid.y >= h) return;
    
    int2 coord = int2(gid);
    int2 maxCoord = int2(int(w) - 1, int(h) - 1);
    
    // Читаем центр и соседей
    float4 center = source.read(uint2(clamp(coord, int2(0), maxCoord)));
    float4 right  = source.read(uint2(clamp(coord + int2(1, 0), int2(0), maxCoord)));
    float4 left   = source.read(uint2(clamp(coord + int2(-1, 0), int2(0), maxCoord)));
    float4 up     = source.read(uint2(clamp(coord + int2(0, 1), int2(0), maxCoord)));
    float4 down   = source.read(uint2(clamp(coord + int2(0, -1), int2(0), maxCoord)));
    
    // ИСПРАВЛЕНО: Правильное усреднение (сумма соседей / 4)
    float4 neighbors = (right + left + up + down) * 0.25;
    
    // Смешивание центра с соседями по коэффициенту диффузии
    float4 diffused = mix(center, neighbors, u.diffusion);
    
    // Применяем затухание
    target.write(diffused * u.dissipation, gid);
}

/// Выделение ярких областей для bloom.
kernel void downsampleBright(
    texture2d<float, access::sample> source [[texture(0)]],
    texture2d<float, access::write> target [[texture(1)]],
    constant float &threshold [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint w = target.get_width();
    uint h = target.get_height();
    if (gid.x >= w || gid.y >= h) return;
    
    float2 uv = (float2(gid) + 0.5) / float2(w, h);
    float3 color = source.sample(linearSampler, uv).rgb;
    
    // Выделяем только яркие области
    float3 bright = max(color - threshold, float3(0.0));
    target.write(float4(bright, 1.0), gid);
}

/// Сепарабельный Gaussian blur.
kernel void gaussianBlur(
    texture2d<float, access::sample> source [[texture(0)]],
    texture2d<float, access::write> target [[texture(1)]],
    constant BlurUniforms &u [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint w = target.get_width();
    uint h = target.get_height();
    if (gid.x >= w || gid.y >= h) return;
    
    float2 uv = (float2(gid) + 0.5) / float2(w, h);
    
    float3 accum = float3(0.0);
    float weightSum = 0.0;
    int radius = int(u.radius);
    float sigmaSq = u.sigma * u.sigma + 1e-4;
    
    for (int i = -radius; i <= radius; ++i) {
        float weight = exp(-0.5 * float(i * i) / sigmaSq);
        float2 sampleUV = uv + u.direction * float(i);
        accum += source.sample(linearSampler, sampleUV).rgb * weight;
        weightSum += weight;
    }
    
    float3 result = accum / max(weightSum, 1e-5);
    target.write(float4(result, 1.0), gid);
}

// === VERTEX SHADERS ===

struct ParticleVertexOut {
    float4 position [[position]];
    float pointSize [[point_size]];
    float speed;
};

vertex ParticleVertexOut particleVertex(
    uint id [[vertex_id]],
    device const Particle *particles [[buffer(0)]]
) {
    ParticleVertexOut out;
    Particle p = particles[id];
    out.position = float4(p.position, 0.0, 1.0);
    out.speed = length(p.velocity);
    out.pointSize = BASE_SIZE + out.speed * 3.0;
    return out;
}

struct FullscreenVertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex FullscreenVertexOut fullscreenVertex(uint vid [[vertex_id]]) {
    // Fullscreen triangle
    float2 positions[3] = { {-1.0, -1.0}, {3.0, -1.0}, {-1.0, 3.0} };
    FullscreenVertexOut out;
    out.position = float4(positions[vid], 0.0, 1.0);
    out.uv = out.position.xy * 0.5 + 0.5;
    return out;
}

// === FRAGMENT SHADERS ===

fragment float4 particleFragment(
    ParticleVertexOut in [[stage_in]],
    float2 pointCoord [[point_coord]],
    constant PaletteUniforms &pal [[buffer(0)]]
) {
    // Круглая частица с мягким краем
    float2 uv = pointCoord * 2.0 - 1.0;
    float dist = length(uv);
    float alpha = smoothstep(1.0, 0.3, dist);
    
    // Цвет на основе скорости
    float glow = clamp(in.speed * 1.5, 0.0, 1.0);
    float3 baseColor = mix(pal.deep, pal.mid, clamp(glow * pal.midMix, 0.0, 1.0));
    float3 color = mix(baseColor, pal.hot, glow);
    
    // HDR интенсивность
    float intensity = alpha * (1.0 + glow * 1.5);
    return float4(color * intensity, alpha);
}

fragment float4 textOverlayFragment(
    FullscreenVertexOut in [[stage_in]],
    texture2d<float, access::sample> textTex [[texture(0)]],
    constant TextUniforms &u [[buffer(0)]],
    sampler smp [[sampler(0)]]
) {
    float2 uv = clamp(in.uv, float2(0.0), float2(1.0));
    float4 text = textTex.sample(smp, uv);
    
    float visibility = clamp(u.visibility, 0.0, 1.0);
    float glow = u.glowIntensity;
    
    // HDR свечение текста
    return float4(text.rgb * visibility * glow, text.a * visibility);
}

fragment float4 compositeFragment(
    FullscreenVertexOut in [[stage_in]],
    texture2d<float, access::sample> baseTex [[texture(0)]],
    texture2d<float, access::sample> bloomTex [[texture(1)]],
    constant CompositeUniforms &c [[buffer(0)]],
    sampler smp [[sampler(0)]]
) {
    float2 uv = clamp(in.uv, float2(0.0), float2(1.0));
    
    float3 base = baseTex.sample(smp, uv).rgb;
    float3 bloom = bloomTex.sample(smp, uv).rgb * (c.bloomStrength + c.bloomBoost);
    
    // HDR композитинг
    float3 hdr = base + bloom;
    
    // Reinhard tone mapping
    float3 mapped = hdr / (hdr + 1.0);
    
    // Гамма-коррекция
    float gamma = max(c.toneMapGamma, 0.1);
    mapped = pow(mapped, float3(1.0 / gamma));
    
    return float4(mapped, 1.0);
}
"""
