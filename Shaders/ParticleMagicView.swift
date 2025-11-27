import SwiftUI
import MetalKit
import UIKit

// MARK: - Feature switches and shared constants

enum FeatureFlags {
    static let enableVelocityColor = true
    static let enableIdleNoiseBreathing = true
    static let enableMotionBlur = true
    static let enableMultiTouch = true
    static let useAdditiveBlending = true
    static let debugDrawBounds = false
}

enum MagicConstants {
    static let maxParticleCount = 400_000
    static let defaultParticleCount = 200_000
    static let maxTouches = 3
    static let basePointSize: Float = 2.0
    static let idleJitterAmplitude: Float = 0.002
    static let idleJitterFrequency: Float = 0.6
    static let baseCloudRadius: Float = 0.55
}

// MARK: - CPU-side data models

struct Particle {
    var position: SIMD2<Float>
    var velocity: SIMD2<Float>
    var home: SIMD2<Float>
    var mass: Float
    var life: Float
}

struct TouchUniformSwift {
    var position: SIMD2<Float> = .zero
    var radius: Float = 0
    var strength: Float = 0
}

struct SimulationUniformsSwift {
    var deltaTime: Float = 0
    var rise: Float = 0
    var decay: Float = 0
    var time: Float = 0
    var activeTouchCount: UInt32 = 0
    var activeParticleCount: UInt32 = UInt32(MagicConstants.defaultParticleCount)
    var padding0: UInt32 = 0
    var padding1: UInt32 = 0
    var touches: (TouchUniformSwift, TouchUniformSwift, TouchUniformSwift) = (
        TouchUniformSwift(), TouchUniformSwift(), TouchUniformSwift()
    )

    mutating func setTouches(_ values: [TouchUniformSwift], count: Int) {
        let safeCount = min(count, MagicConstants.maxTouches)
        var first = TouchUniformSwift()
        var second = TouchUniformSwift()
        var third = TouchUniformSwift()
        if safeCount > 0 { first = values[0] }
        if safeCount > 1 { second = values[1] }
        if safeCount > 2 { third = values[2] }
        touches = (first, second, third)
        activeTouchCount = UInt32(safeCount)
    }
}

typealias ParticleUniforms = SimulationUniformsSwift

final class ParticleSettings: ObservableObject {
    @Published var radius: Float = 0.2
    @Published var strength: Float = 5.0
    @Published var rise: Float = 8.0
    @Published var decay: Float = 2.5
    @Published var particleCount: Int = MagicConstants.defaultParticleCount
}

// MARK: - SwiftUI surface

struct ParticleMagicView: View {
    @StateObject private var settings = ParticleSettings()

    init() {
        // Localized slider cosmetics to keep everything self contained.
        let sliderAppearance = UISlider.appearance(whenContainedInInstancesOf: [UIHostingController<ParticleMagicView>.self])
        sliderAppearance.minimumTrackTintColor = UIColor.orange
        sliderAppearance.maximumTrackTintColor = UIColor.orange.withAlphaComponent(0.2)
        sliderAppearance.thumbTintColor = UIColor.systemPink
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                MetalParticleView(settings: settings)
                    .ignoresSafeArea(edges: .top)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                VStack(spacing: 12) {
                    Picker("", selection: $settings.particleCount) {
                        Text("200k").tag(200_000)
                        Text("400k").tag(400_000)
                    }
                    .pickerStyle(.segmented)
                    .colorMultiply(.pink.opacity(0.9))

                    sliderRow(title: "Radius", value: $settings.radius, range: 0.05...0.5)
                    sliderRow(title: "Strength", value: $settings.strength, range: 0...15)
                    sliderRow(title: "Rise", value: $settings.rise, range: 0...10)
                    sliderRow(title: "Decay", value: $settings.decay, range: 0...5)
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 20)
                .background(Color.black.opacity(0.15))
            }
        }
    }

    private func sliderRow(title: String, value: Binding<Float>, range: ClosedRange<Float>) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 78, alignment: .leading)

            Slider(value: value, in: range)
                .tint(Color.orange)

            Text(String(format: "%.2f", value.wrappedValue))
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 48, alignment: .trailing)
        }
    }
}

// MARK: - MTKView wrapper

struct MetalParticleView: UIViewRepresentable {
    @ObservedObject var settings: ParticleSettings

    func makeCoordinator() -> Coordinator {
        guard let coordinator = Coordinator(settings: settings) else {
            fatalError("Unable to create Metal coordinator (device unavailable).")
        }
        return coordinator
    }

    func makeUIView(context: Context) -> MTKView {
        let view = TouchMTKView(frame: .zero, device: context.coordinator.device)
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.preferredFramesPerSecond = 120
        view.framebufferOnly = false
        view.colorPixelFormat = .bgra8Unorm_srgb
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.isMultipleTouchEnabled = true
        view.delegate = context.coordinator
        view.touchDelegate = context.coordinator
        context.coordinator.attach(view: view)
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) { }
}

private protocol TouchForwardingDelegate: AnyObject {
    func handleTouchesBegan(_ touches: Set<UITouch>, in view: UIView)
    func handleTouchesMoved(_ touches: Set<UITouch>, in view: UIView)
    func handleTouchesEnded(_ touches: Set<UITouch>, in view: UIView)
    func handleTouchesCancelled(_ touches: Set<UITouch>, in view: UIView)
}

private final class TouchMTKView: MTKView {
    weak var touchDelegate: TouchForwardingDelegate?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        touchDelegate?.handleTouchesBegan(touches, in: self)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesMoved(touches, with: event)
        touchDelegate?.handleTouchesMoved(touches, in: self)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        touchDelegate?.handleTouchesEnded(touches, in: self)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        touchDelegate?.handleTouchesCancelled(touches, in: self)
    }
}

// MARK: - Coordinator driving Metal

final class Coordinator: NSObject, MTKViewDelegate, TouchForwardingDelegate {
    let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let computePipeline: MTLComputePipelineState
    private let renderPipeline: MTLRenderPipelineState
    private let particleBuffer: MTLBuffer
    private let uniformsBuffer: MTLBuffer
    private weak var view: MTKView?

    private let settings: ParticleSettings
    private var time: Float = 0
    private var activeParticleCount: Int = MagicConstants.defaultParticleCount
    private var lastFrameTimestamp: CFTimeInterval = 0
    private var shouldClearDrawable = true

    private var touchOrder: [UITouch] = []
    private var activePositions: [UITouch: SIMD2<Float>] = [:]
    private var packedTouches: [TouchUniformSwift] = Array(
        repeating: TouchUniformSwift(),
        count: MagicConstants.maxTouches
    )
    private var activeTouchCount: Int = 0

    init?(settings: ParticleSettings) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            return nil
        }

        self.device = device
        self.commandQueue = commandQueue
        self.settings = settings

        do {
            let library = try device.makeLibrary(source: particleShaderSource, options: nil)
            guard
                let computeFunction = library.makeFunction(name: "simulateParticles"),
                let vertexFunction = library.makeFunction(name: "vertexParticles"),
                let fragmentFunction = library.makeFunction(name: "fragmentParticles")
            else {
                return nil
            }

            computePipeline = try device.makeComputePipelineState(function: computeFunction)

            let renderDescriptor = MTLRenderPipelineDescriptor()
            renderDescriptor.label = "Particle Render Pipeline"
            renderDescriptor.vertexFunction = vertexFunction
            renderDescriptor.fragmentFunction = fragmentFunction
            renderDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
            renderDescriptor.colorAttachments[0].isBlendingEnabled = true
            if FeatureFlags.useAdditiveBlending {
                renderDescriptor.colorAttachments[0].sourceRGBBlendFactor = .one
                renderDescriptor.colorAttachments[0].destinationRGBBlendFactor = .one
                renderDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
                renderDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .one
            } else {
                renderDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
                renderDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
                renderDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
                renderDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }

            renderPipeline = try device.makeRenderPipelineState(descriptor: renderDescriptor)
        } catch {
            print("Metal pipeline error: \(error)")
            return nil
        }

        guard let particleBuffer = device.makeBuffer(
            length: MemoryLayout<Particle>.stride * MagicConstants.maxParticleCount,
            options: [.storageModeShared]
        ) else {
            return nil
        }

        guard let uniformsBuffer = device.makeBuffer(
            length: MemoryLayout<SimulationUniformsSwift>.stride,
            options: [.storageModeShared]
        ) else {
            return nil
        }

        self.particleBuffer = particleBuffer
        self.uniformsBuffer = uniformsBuffer

        super.init()
        seedParticles()
    }

    func attach(view: MTKView) {
        self.view = view
    }

    // MARK: Touch handling

    func handleTouchesBegan(_ touches: Set<UITouch>, in view: UIView) {
        guard FeatureFlags.enableMultiTouch || touchOrder.isEmpty else { return }
        for touch in touches {
            guard activePositions.count < MagicConstants.maxTouches else { break }
            activePositions[touch] = convert(touch: touch, in: view)
            touchOrder.append(touch)
        }
        refreshPackedTouches()
    }

    func handleTouchesMoved(_ touches: Set<UITouch>, in view: UIView) {
        for touch in touches {
            guard activePositions[touch] != nil else { continue }
            activePositions[touch] = convert(touch: touch, in: view)
        }
        refreshPackedTouches()
    }

    func handleTouchesEnded(_ touches: Set<UITouch>, in view: UIView) {
        for touch in touches {
            activePositions.removeValue(forKey: touch)
            touchOrder.removeAll { $0 == touch }
        }
        refreshPackedTouches()
    }

    func handleTouchesCancelled(_ touches: Set<UITouch>, in view: UIView) {
        handleTouchesEnded(touches, in: view)
    }

    private func convert(touch: UITouch, in view: UIView) -> SIMD2<Float> {
        let location = touch.location(in: view)
        guard view.bounds.width > 0, view.bounds.height > 0 else { return .zero }
        let x = Float((location.x / view.bounds.width) * 2 - 1)
        let y = Float(1 - (location.y / view.bounds.height) * 2)
        return SIMD2<Float>(x, y)
    }

    private func refreshPackedTouches() {
        let radius = settings.radius
        let strength = settings.strength
        var index = 0
        for touch in touchOrder {
            guard index < MagicConstants.maxTouches, let position = activePositions[touch] else { continue }
            packedTouches[index] = TouchUniformSwift(position: position, radius: radius, strength: strength)
            index += 1
        }
        activeTouchCount = index
        while index < MagicConstants.maxTouches {
            packedTouches[index] = TouchUniformSwift()
            index += 1
        }
    }

    // MARK: Particle setup

    private func seedParticles() {
        precondition(MemoryLayout<Particle>.stride == 32, "Unexpected Particle stride; update shader layout.")
        let pointer = particleBuffer.contents().bindMemory(to: Particle.self, capacity: MagicConstants.maxParticleCount)
        let baseRadius = MagicConstants.baseCloudRadius
        for index in 0..<MagicConstants.maxParticleCount {
            let theta = Float.random(in: 0...(.pi * 2))
            let radius = baseRadius * sqrt(Float.random(in: 0...1))
            let x = radius * cos(theta)
            let y = radius * sin(theta)
            pointer.advanced(by: index).pointee = Particle(
                position: SIMD2<Float>(x, y),
                velocity: .zero,
                home: SIMD2<Float>(x, y),
                mass: Float.random(in: 0.8...1.2),
                life: 1.0
            )
        }
    }

    // MARK: MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { }

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        if lastFrameTimestamp == 0 {
            lastFrameTimestamp = now
            return
        }

        var delta = Float(now - lastFrameTimestamp)
        delta = min(delta, 1.0 / 30.0)
        lastFrameTimestamp = now
        time += delta

        var uniforms = SimulationUniformsSwift()
        uniforms.deltaTime = delta
        uniforms.rise = settings.rise
        uniforms.decay = settings.decay
        uniforms.time = time
        activeParticleCount = min(max(settings.particleCount, 1), MagicConstants.maxParticleCount)
        uniforms.activeParticleCount = UInt32(activeParticleCount)
        uniforms.setTouches(packedTouches, count: activeTouchCount)

        memcpy(uniformsBuffer.contents(), &uniforms, MemoryLayout<SimulationUniformsSwift>.stride)

        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        encodeCompute(into: commandBuffer)
        encodeRender(into: commandBuffer, view: view)
        commandBuffer.commit()
    }

    // MARK: Encoding

    private func encodeCompute(into commandBuffer: MTLCommandBuffer) {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.label = "Particle Compute"
        encoder.setComputePipelineState(computePipeline)
        encoder.setBuffer(particleBuffer, offset: 0, index: 0)
        encoder.setBuffer(uniformsBuffer, offset: 0, index: 1)

        let particleCount = activeParticleCount
        let threadsPerThreadgroup = MTLSize(
            width: computePipeline.threadExecutionWidth,
            height: 1,
            depth: 1
        )
        let threadgroups = MTLSize(
            width: (particleCount + threadsPerThreadgroup.width - 1) / threadsPerThreadgroup.width,
            height: 1,
            depth: 1
        )

        encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerThreadgroup)
        encoder.endEncoding()
    }

    private func encodeRender(into commandBuffer: MTLCommandBuffer, view: MTKView) {
        guard let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable else { return }

        if FeatureFlags.enableMotionBlur && !shouldClearDrawable {
            descriptor.colorAttachments[0].loadAction = .load
        } else {
            descriptor.colorAttachments[0].loadAction = .clear
        }
        descriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        encoder.label = "Particle Render"
        encoder.setRenderPipelineState(renderPipeline)
        encoder.setVertexBuffer(particleBuffer, offset: 0, index: 0)
        encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: activeParticleCount)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        shouldClearDrawable = false
    }
}

// MARK: - Metal shader source

private let particleShaderSource = """
#include <metal_stdlib>
using namespace metal;

constant uint MagicMaxParticleCount = \(MagicConstants.maxParticleCount);
constant uint MagicMaxTouches = \(MagicConstants.maxTouches);
constant float MagicBasePointSize = \(MagicConstants.basePointSize);
constant float MagicIdleJitterAmplitude = \(MagicConstants.idleJitterAmplitude);
constant float MagicIdleJitterFrequency = \(MagicConstants.idleJitterFrequency);

constant bool FeatureEnableVelocityColor = \(FeatureFlags.enableVelocityColor ? "true" : "false");
constant bool FeatureEnableIdleNoise = \(FeatureFlags.enableIdleNoiseBreathing ? "true" : "false");
constant bool FeatureEnableMotionBlur = \(FeatureFlags.enableMotionBlur ? "true" : "false");

struct Particle {
    float2 position;
    float2 velocity;
    float2 home;
    float mass;
    float life;
};

struct TouchUniform {
    float2 position;
    float radius;
    float strength;
};

struct SimulationUniforms {
    float deltaTime;
    float rise;
    float decay;
    float time;
    uint activeTouchCount;
    uint activeParticleCount;
    uint pad0;
    uint pad1;
    TouchUniform touches[MagicMaxTouches];
};

struct VSOut {
    float4 position [[position]];
    float pointSize [[point_size]];
    float3 color;
    float alpha;
};

float random2d(float2 p) {
    return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453);
}

float noise2d(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float a = random2d(i);
    float b = random2d(i + float2(1.0, 0.0));
    float c = random2d(i + float2(0.0, 1.0));
    float d = random2d(i + float2(1.0, 1.0));
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(a, b, u.x) + (c - a) * u.y * (1.0 - u.x) + (d - b) * u.x * u.y;
}

float2 curlNoise2d(float2 p, float time) {
    float eps = 0.1;
    float2 timeOffset = float2(time, time);
    float n1 = noise2d(p + float2(0, eps) + timeOffset);
    float n2 = noise2d(p + float2(eps, 0) - timeOffset);
    float nx = n1 - n2;
    float ny = n1 + n2;
    return float2(nx, ny);
}

float3 baseColorForParticle(const Particle p, float time) {
    float y = clamp((p.home.y + 1.0) * 0.5, 0.0, 1.0);
    float warmBand = smoothstep(0.55, 0.05, y);
    float coolBand = smoothstep(0.3, 0.9, y);
    float midBand = 1.0 - abs(y - 0.5) * 1.4;
    float3 warm = float3(1.05, 0.65, 0.38);
    float3 mid = float3(1.05, 0.97, 0.88);
    float3 cool = float3(0.55, 0.86, 0.98);
    float3 color = (warm * warmBand + mid * midBand + cool * coolBand) / (warmBand + midBand + coolBand + 0.001);

    float hueNoise = noise2d(p.position * 4.0 + float2(time * 0.2));
    color += (hueNoise - 0.5) * 0.12;
    return saturate(color);
}

float2 forceFromTouch(const Particle p, const TouchUniform t) {
    float2 dir = p.position - t.position;
    float dist = length(dir) + 1e-4;
    float influence = exp(- (dist * dist) / (2.0 * t.radius * t.radius));
    return normalize(dir) * (t.strength * influence);
}

kernel void simulateParticles(
    device Particle *particles [[buffer(0)]],
    constant SimulationUniforms &u [[buffer(1)]],
    uint id [[thread_position_in_grid]]
) {
    if (id >= u.activeParticleCount || id >= MagicMaxParticleCount) { return; }

    Particle p = particles[id];
    float2 force = (p.home - p.position) * u.rise;

    for (uint i = 0; i < min(u.activeTouchCount, (uint)MagicMaxTouches); ++i) {
        force += forceFromTouch(p, u.touches[i]);
    }

    float2 acceleration = force / p.mass;
    p.velocity += acceleration * u.deltaTime;
    p.velocity *= 1.0 / (1.0 + u.decay * u.deltaTime);
    p.position += p.velocity * u.deltaTime;

    if (FeatureEnableIdleNoise && u.activeTouchCount == 0) {
        float2 jitter = curlNoise2d(p.home * 3.0, u.time * MagicIdleJitterFrequency);
        p.position += jitter * MagicIdleJitterAmplitude;
    }

    particles[id] = p;
}

vertex VSOut vertexParticles(uint vid [[vertex_id]], const device Particle *particles [[buffer(0)]]) {
    VSOut out;
    Particle p = particles[vid];
    float speed = length(p.velocity);
    float size = MagicBasePointSize + clamp(speed * 0.45, 0.0, MagicBasePointSize * 0.9);

    float3 color = baseColorForParticle(p, speed * 0.5);
    if (FeatureEnableVelocityColor) {
        color = mix(color, float3(1.1, 1.05, 0.95), clamp(speed * 0.12, 0.0, 0.65));
    }

    out.position = float4(p.position, 0.0, 1.0);
    out.pointSize = size;
    out.color = color;
    out.alpha = clamp(0.65 + speed * 0.15, 0.35, 1.0) * p.life;
    return out;
}

fragment float4 fragmentParticles(VSOut in [[stage_in]], float2 pointCoord [[point_coord]]) {
    float2 uv = pointCoord * 2.0 - 1.0;
    float r = length(uv);
    float falloff = smoothstep(1.0, 0.6, r);
    float alpha = in.alpha * falloff;
    return float4(in.color, alpha);
}
"""
