/// LoFiEngine.swift
/// Минимальный lo-fi аудио-движок на AVAudioEngine + AVAudioSequencer.
///
/// Отвечает за:
/// - Генерацию простых ударных сэмплов (kick, snare, hi-hat).
/// - MIDI-секвенцию с поддержкой свинга.
/// - Вычисление метрик для аудио-реактивного рендера (RMS, kick/snare pulse).
///
/// Архитектура:
/// ```
/// AVAudioEngine
///     ├── kickSampler ──┐
///     ├── snareSampler ─┼── mainMixerNode ── outputNode
///     └── hatSampler ───┘
///                  ↑
///            installTap (RMS)
/// ```

import AVFoundation
import AudioToolbox
import os

// MARK: - Логгер модуля
private let audioLog = Logger(subsystem: "com.liquidintro", category: "audio")

// MARK: - Снимок аудио-метрик
/// Мгновенный снимок аудио-состояния для передачи в рендерер.
/// Все значения нормализованы в диапазоне [0, 1] для удобства использования в шейдерах.
struct AudioReactiveSnapshot {
    /// Сглаженная RMS амплитуда (0.0 - 1.0).
    let amplitude: Float
    
    /// Импульс кика - резкий всплеск на момент удара (0.0 - 1.0).
    let kickPulse: Float
    
    /// Импульс снэйра - резкий всплеск на момент удара (0.0 - 1.0).
    let snarePulse: Float
    
    /// Фаза внутри бита (0.0 - 1.0), используется для пульсации.
    let beatPhase: Float
    
    /// Номер текущего такта (для синхронизации событий).
    let barIndex: Int
    
    /// Номер текущего шага в паттерне (0-15).
    let stepIndex: Int
    
    /// Статический снимок "тишины" для использования при ошибках.
    static let silent = AudioReactiveSnapshot(
        amplitude: 0,
        kickPulse: 0,
        snarePulse: 0,
        beatPhase: 0,
        barIndex: 0,
        stepIndex: 0
    )
}

// MARK: - Фабрика сэмплов ударных
/// Генерирует минимальные синтетические сэмплы ударных.
/// Сэмплы создаются программно без внешних файлов.
enum DrumSampleFactory {
    
    /// Генерирует kick-drum сэмпл.
    /// Использует синусоиду с понижающейся частотой (pitch sweep) для характерного "удара".
    /// - Parameter format: Формат аудио для буфера.
    /// - Returns: PCM буфер с сэмплом или nil при ошибке.
    static func kick(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        return makeBuffer(format: format, frames: 4096) { data, frames, sampleRate in
            for i in 0..<frames {
                let progress = Double(i) / Double(frames)
                
                // Экспоненциальная огибающая амплитуды
                let envelope = pow(1.0 - progress, 3.0)
                
                // Частота понижается от 150 Hz до 40 Hz
                let startFreq = 150.0
                let endFreq = 40.0
                let freq = startFreq - progress * (startFreq - endFreq)
                
                // Накопление фазы для корректной частоты
                let phase = 2.0 * .pi * freq * Double(i) / sampleRate
                let sample = sin(phase) * envelope * 0.9
                
                // Добавляем немного гармоник для "тела" звука
                let harmonic = sin(phase * 2.0) * envelope * 0.15
                
                data[i] = Float(sample + harmonic)
            }
            audioLog.debug("Kick сэмпл сгенерирован: \(frames) семплов")
        }
    }
    
    /// Генерирует snare-drum сэмпл.
    /// Комбинирует шум (пружины) с тональным компонентом (мембрана).
    /// - Parameter format: Формат аудио для буфера.
    /// - Returns: PCM буфер с сэмплом или nil при ошибке.
    static func snare(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        return makeBuffer(format: format, frames: 4096) { data, frames, sampleRate in
            for i in 0..<frames {
                let progress = Double(i) / Double(frames)
                
                // Быстрое затухание для резкости
                let envelope = pow(1.0 - progress, 2.2)
                
                // Шумовой компонент (пружины)
                let noise = Float.random(in: -1...1) * Float(envelope) * 0.55
                
                // Тональный компонент (мембрана ~180 Hz)
                let tonePhase = 2.0 * .pi * 180.0 * Double(i) / sampleRate
                let tone = sin(tonePhase) * envelope * 0.2
                
                data[i] = noise + Float(tone)
            }
            audioLog.debug("Snare сэмпл сгенерирован: \(frames) семплов")
        }
    }
    
    /// Генерирует hi-hat сэмпл.
    /// Высокочастотный шум с очень быстрым затуханием.
    /// - Parameter format: Формат аудио для буфера.
    /// - Returns: PCM буфер с сэмплом или nil при ошибке.
    static func hat(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        return makeBuffer(format: format, frames: 2048) { data, frames, _ in
            for i in 0..<frames {
                let progress = Double(i) / Double(frames)
                
                // Очень быстрое затухание
                let envelope = pow(1.0 - progress, 4.0)
                
                // Высокочастотный шум
                let noise = Float.random(in: -1...1) * Float(envelope) * 0.35
                
                data[i] = noise
            }
            audioLog.debug("Hi-hat сэмпл сгенерирован: \(frames) семплов")
        }
    }
    
    /// Записывает буфер во временный CAF файл для загрузки в сэмплер.
    /// - Parameters:
    ///   - buffer: PCM буфер для записи.
    ///   - name: Имя файла (без расширения).
    /// - Returns: URL записанного файла или nil при ошибке.
    static func writeToTemp(buffer: AVAudioPCMBuffer, name: String) -> URL? {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(name).caf")
        
        do {
            // Удаляем старый файл если существует
            try? FileManager.default.removeItem(at: url)
            
            let file = try AVAudioFile(forWriting: url, settings: buffer.format.settings)
            try file.write(from: buffer)
            audioLog.debug("Сэмпл '\(name)' записан: \(url.lastPathComponent)")
            return url
        } catch {
            audioLog.error("Ошибка записи сэмпла '\(name)': \(error.localizedDescription)")
            return nil
        }
    }
    
    // MARK: - Приватные методы
    
    /// Создаёт PCM буфер и заполняет его данными через замыкание.
    private static func makeBuffer(
        format: AVAudioFormat,
        frames: Int,
        fill: (_ data: UnsafeMutablePointer<Float>, _ frames: Int, _ sampleRate: Double) -> Void
    ) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let channelData = buffer.floatChannelData?[0] else {
            audioLog.error("Не удалось создать PCM буфер")
            return nil
        }
        
        fill(channelData, frames, format.sampleRate)
        buffer.frameLength = AVAudioFrameCount(frames)
        return buffer
    }
}

// MARK: - Lo-Fi аудио движок
/// Минимальный аудио-движок для генерации lo-fi бита и метрик для рендера.
/// Не требует внешних аудио-файлов - все звуки синтезируются программно.
final class LoFiEngine {
    
    // MARK: - Настройки
    private struct EngineSettings {
        let bpm: Double
        let groove: Double
        let preset: VisualPreset
        
        /// Длительность одного 16th шага в секундах.
        var stepDurationSeconds: Double {
            60.0 / bpm / 4.0
        }
    }
    
    // MARK: - Audio компоненты
    private let engine = AVAudioEngine()
    private let kickSampler = AVAudioUnitSampler()
    private let snareSampler = AVAudioUnitSampler()
    private let hatSampler = AVAudioUnitSampler()
    
    // MARK: - Состояние
    private var settings: EngineSettings
    private var isPrepared = false
    private var isRunning = false
    private var stepTimer: DispatchSourceTimer?
    private var stepCounter: Int = 0
    
    // MARK: - Метрики для рендера
    private var lastStepIndex: Int = -1
    private var lastStepTimestamp: CFTimeInterval = 0
    private var kickImpulse: Float = 0
    private var snareImpulse: Float = 0
    private var rawRMS: Float = 0
    private var smoothedRMS: Float = 0
    
    // MARK: - Паттерны ударных (индексы шагов 0-15)
    /// Паттерн кика: классический 4-on-the-floor.
    private let kickPattern: Set<Int> = [0, 4, 8, 12]
    
    /// Паттерн снэйра: на 2 и 4 долю.
    private let snarePattern: Set<Int> = [4, 12]
    
    // MARK: - Константы затухания
    /// Время полураспада импульса в секундах.
    private let impulseHalfLife: Float = 0.08
    
    /// Коэффициент сглаживания RMS (0.0 - 1.0, больше = медленнее).
    private let rmsSmoothingFactor: Float = 0.15
    
    private let log = Logger(subsystem: "com.liquidintro", category: "audio")
    
    // MARK: - Инициализация
    /// Создаёт движок с заданными параметрами интро.
    /// - Parameter parameters: Параметры интро (BPM, groove, пресет).
    init(parameters: IntroParameters) {
        self.settings = EngineSettings(
            bpm: parameters.bpm,
            groove: parameters.groove,
            preset: parameters.preset
        )
        log.debug("LoFiEngine создан: bpm=\(parameters.bpm) groove=\(parameters.groove)")
    }

    /// Обновляет параметры (bpm/groove/preset) с перезапуском графа.
    /// - Parameter parameters: Новые параметры интро.
    func update(parameters: IntroParameters) {
        log.debug("LoFiEngine обновление параметров: bpm=\(parameters.bpm) groove=\(parameters.groove) preset=\(parameters.preset.name)")
        stop()
        settings = EngineSettings(
            bpm: parameters.bpm,
            groove: parameters.groove,
            preset: parameters.preset
        )
        isPrepared = false
        isRunning = false
        stepTimer?.cancel()
        stepTimer = nil
        startIfNeeded()
    }
    
    // MARK: - Публичные методы
    
    /// Запускает движок если ещё не запущен.
    /// Безопасно вызывать многократно.
    func startIfNeeded() {
        guard !isPrepared else { return }
        
        log.debug("Инициализация аудио-графа...")
        prepareAudioGraph()
        loadDrumKit()
        setupSequencer()
        
        if startEngine() {
            isPrepared = true
            isRunning = true
            log.debug("LoFiEngine успешно запущен")
        } else {
            log.error("Не удалось запустить LoFiEngine")
        }
    }
    
    /// Останавливает движок и освобождает ресурсы.
    func stop() {
        guard isRunning else { return }
        
        stepTimer?.cancel()
        stepTimer = nil
        engine.stop()
        engine.mainMixerNode.removeTap(onBus: 0)
        
        isRunning = false
        log.debug("LoFiEngine остановлен")
    }
    
    /// Получает текущие метрики для аудио-реактивного рендера.
    /// - Parameter deltaTime: Время с прошлого кадра в секундах.
    /// - Returns: Снимок аудио-метрик.
    func pullMetrics(deltaTime: Float) -> AudioReactiveSnapshot {
        // Ленивый запуск
        startIfNeeded()
        
        guard isRunning else {
            return .silent
        }
        
        // ИСПРАВЛЕНО: Корректное экспоненциальное затухание
        // Формула: value * exp(-ln(2) * deltaTime / halfLife)
        let decayFactor = exp(-0.693 * deltaTime / impulseHalfLife)
        kickImpulse *= decayFactor
        snareImpulse *= decayFactor
        
        // Сглаживание RMS (экспоненциальное скользящее среднее)
        smoothedRMS = mix(smoothedRMS, rawRMS, rmsSmoothingFactor)
        
        // Фаза внутри бита для пульсации
        let now = CACurrentMediaTime()
        let elapsed = lastStepTimestamp > 0 ? now - lastStepTimestamp : 0
        let beatPhase = Float(min(max(elapsed / settings.stepDurationSeconds, 0), 1))
        
        // Номер такта
        let barIndex = stepCounter / 16
        let stepIndex = lastStepIndex
        
        return AudioReactiveSnapshot(
            amplitude: min(smoothedRMS * 2.5, 1.0),  // Нормализация с усилением
            kickPulse: min(kickImpulse, 1.0),
            snarePulse: min(snareImpulse, 1.0),
            beatPhase: beatPhase,
            barIndex: barIndex,
            stepIndex: stepIndex
        )
    }
    
    // MARK: - Приватные методы
    
    /// Подготавливает граф AVAudioEngine.
    private func prepareAudioGraph() {
        // Подключаем сэмплеры к миксеру
        [kickSampler, snareSampler, hatSampler].forEach { sampler in
            engine.attach(sampler)
            engine.connect(sampler, to: engine.mainMixerNode, format: nil)
        }
        
        // Общая громкость
        engine.mainMixerNode.outputVolume = 0.75
        
        // Устанавливаем tap для измерения RMS
        installRMSTap()
    }
    
    /// Загружает синтетические сэмплы в сэмплеры.
    private func loadDrumKit() {
        let format = engine.outputNode.outputFormat(forBus: 0)
        
        guard let kickBuffer = DrumSampleFactory.kick(format: format),
              let snareBuffer = DrumSampleFactory.snare(format: format),
              let hatBuffer = DrumSampleFactory.hat(format: format) else {
            log.error("Не удалось сгенерировать сэмплы")
            return
        }
        
        guard let kickURL = DrumSampleFactory.writeToTemp(buffer: kickBuffer, name: "kick"),
              let snareURL = DrumSampleFactory.writeToTemp(buffer: snareBuffer, name: "snare"),
              let hatURL = DrumSampleFactory.writeToTemp(buffer: hatBuffer, name: "hat") else {
            log.error("Не удалось записать сэмплы во временные файлы")
            return
        }
        
        do {
            try kickSampler.loadAudioFiles(at: [kickURL])
            try snareSampler.loadAudioFiles(at: [snareURL])
            try hatSampler.loadAudioFiles(at: [hatURL])
            log.debug("Набор ударных загружен успешно")
        } catch {
            log.error("Ошибка загрузки сэмплов: \(error.localizedDescription)")
        }
    }
    
    /// Настраивает таймерный паттерн вместо MIDI секвенсера.
    private func setupSequencer() {
        log.debug("Таймерный паттерн для ударных настроен")
    }
    
    /// Устанавливает tap на миксер для измерения RMS.
    private func installRMSTap() {
        engine.mainMixerNode.removeTap(onBus: 0)
        
        let format = engine.mainMixerNode.outputFormat(forBus: 0)
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self = self else { return }
            self.rawRMS = Self.calculateRMS(buffer: buffer)
        }
    }
    
    /// Запускает AVAudioEngine и таймер.
    private func startEngine() -> Bool {
        do {
            // Настройка аудио-сессии
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            
            // Запуск движка
            try engine.start()
            startStepTimer()
            
            return true
        } catch {
            log.error("Ошибка запуска аудио: \(error.localizedDescription)")
            return false
        }
    }

    private func startStepTimer() {
        stepTimer?.cancel()
        stepTimer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.liquidintro.lofi.step", qos: .userInitiated))
        let interval = settings.stepDurationSeconds
        stepCounter = 0
        lastStepIndex = -1
        lastStepTimestamp = CACurrentMediaTime()
        stepTimer?.schedule(deadline: .now(), repeating: interval)
        stepTimer?.setEventHandler { [weak self] in
            self?.performStep()
        }
        stepTimer?.resume()
    }
    
    private func performStep() {
        let step = stepCounter % 16
        lastStepIndex = step
        lastStepTimestamp = CACurrentMediaTime()
        
        if kickPattern.contains(step) {
            kickImpulse = 1.0
            kickSampler.startNote(36, withVelocity: 110, onChannel: 0)
            log.debug("KICK на шаге \(step)")
        }
        if snarePattern.contains(step) {
            snareImpulse = 1.0
            snareSampler.startNote(38, withVelocity: 120, onChannel: 1)
            log.debug("SNARE на шаге \(step)")
        }
        // Hi-hat на каждый шаг
        let hatVelocity: UInt8 = step % 4 == 0 ? 80 : 60
        hatSampler.startNote(42, withVelocity: hatVelocity, onChannel: 2)
        
        stepCounter += 1
    }
    
    /// Вычисляет RMS (среднеквадратичное значение) буфера.
    private static func calculateRMS(buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        
        let channel = channelData[0]
        let frameCount = Int(buffer.frameLength)
        
        guard frameCount > 0 else { return 0 }
        
        var sumOfSquares: Float = 0
        for i in 0..<frameCount {
            let sample = channel[i]
            sumOfSquares += sample * sample
        }
        
        let meanSquare = sumOfSquares / Float(frameCount)
        return sqrt(meanSquare)
    }
    
    deinit {
        stop()
        log.debug("LoFiEngine освобождён")
    }
}
