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
    private var sequencer: AVAudioSequencer?
    private let kickSampler = AVAudioUnitSampler()
    private let snareSampler = AVAudioUnitSampler()
    private let hatSampler = AVAudioUnitSampler()
    
    // MARK: - Состояние
    private var settings: EngineSettings
    private var isPrepared = false
    private var isRunning = false
    
    // MARK: - Метрики для рендера
    private var lastStepIndex: Int = -1
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
        sequencer = nil
        isPrepared = false
        isRunning = false
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
        
        sequencer?.stop()
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
        
        guard let sequencer = sequencer, isRunning else {
            return .silent
        }
        
        // Позиция в битах (1 бит = 1 четвертная нота)
        let beatPosition = sequencer.currentPositionInBeats
        
        // Текущий шаг (16th note)
        let stepDurationBeats = 0.25  // 1/4 бита = 16th нота
        let stepIndex = Int(floor(beatPosition / stepDurationBeats)) % 16
        
        // Детекция новых ударов
        if stepIndex != lastStepIndex {
            // Kick
            if kickPattern.contains(stepIndex) {
                kickImpulse = 1.0
                log.debug("KICK на шаге \(stepIndex)")
            }
            // Snare
            if snarePattern.contains(stepIndex) {
                snareImpulse = 1.0
                log.debug("SNARE на шаге \(stepIndex)")
            }
            lastStepIndex = stepIndex
        }
        
        // ИСПРАВЛЕНО: Корректное экспоненциальное затухание
        // Формула: value * exp(-ln(2) * deltaTime / halfLife)
        let decayFactor = exp(-0.693 * deltaTime / impulseHalfLife)
        kickImpulse *= decayFactor
        snareImpulse *= decayFactor
        
        // Сглаживание RMS (экспоненциальное скользящее среднее)
        smoothedRMS = mix(smoothedRMS, rawRMS, rmsSmoothingFactor)
        
        // Фаза внутри бита для пульсации
        let beatPhase = Float(beatPosition.truncatingRemainder(dividingBy: 1.0))
        
        // Номер такта
        let barIndex = Int(floor(beatPosition / 4.0))
        
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
    
    /// Настраивает MIDI секвенцер с паттерном.
    private func setupSequencer() {
        let seq = AVAudioSequencer(audioEngine: engine)
        self.sequencer = seq
        
        // Создаём треки для каждого инструмента
        guard let kickTrack = seq.newTrack(),
              let snareTrack = seq.newTrack(),
              let hatTrack = seq.newTrack() else {
            log.error("Не удалось создать MIDI треки")
            return
        }
        
        // Привязываем треки к сэмплерам
        kickTrack.destinationAudioUnit = kickSampler
        snareTrack.destinationAudioUnit = snareSampler
        hatTrack.destinationAudioUnit = hatSampler
        
        // Добавляем ноты в паттерн
        let stepDuration: MusicTimeStamp = 0.25  // 16th нота
        let swingAmount = settings.groove * 0.08  // Свинг для нечётных шагов
        
        for step in 0..<16 {
            // Свинг: нечётные шаги немного сдвигаются вперёд
            let swingOffset: MusicTimeStamp = (step % 2 == 1) ? swingAmount : 0
            let position = MusicTimeStamp(Double(step) * stepDuration + swingOffset)
            
            // Kick
            if kickPattern.contains(step) {
                kickTrack.addMIDINoteEvent(
                    note: 36,  // C1 (стандарт для kick)
                    velocity: 110,
                    channel: 0,
                    position: position,
                    duration: stepDuration * 0.9
                )
            }
            
            // Snare
            if snarePattern.contains(step) {
                snareTrack.addMIDINoteEvent(
                    note: 38,  // D1 (стандарт для snare)
                    velocity: 120,
                    channel: 1,
                    position: position,
                    duration: stepDuration * 0.7
                )
            }
            
            // Hi-hat на каждый шаг
            hatTrack.addMIDINoteEvent(
                note: 42,  // F#1 (closed hi-hat)
                velocity: UInt8(step % 4 == 0 ? 80 : 60),  // Акцент на сильные доли
                channel: 2,
                position: position,
                duration: stepDuration * 0.2
            )
        }
        
        // Настройка зацикливания
        [kickTrack, snareTrack, hatTrack].forEach { track in
            track.setLoopInfo(duration: 4.0, numberOfLoops: AVMusicTrackLoopCountForever)
        }
        
        // Настройка темпа
        seq.currentPositionInBeats = 0
        seq.rate = Float(settings.bpm / 120.0)  // 120 BPM = базовый темп
        seq.prepareToPlay()
        
        log.debug("Секвенсер настроен: \(kickPattern.count) kick, \(snarePattern.count) snare, 16 hi-hat")
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
    
    /// Запускает AVAudioEngine и секвенцер.
    private func startEngine() -> Bool {
        do {
            // Настройка аудио-сессии
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            
            // Запуск движка
            try engine.start()
            try sequencer?.start()
            
            return true
        } catch {
            log.error("Ошибка запуска аудио: \(error.localizedDescription)")
            return false
        }
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
