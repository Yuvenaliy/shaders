/// Preset.swift
/// Модуль описания визуальных пресетов и параметров интро.
///
/// Содержит:
/// - `IntroParameters`: Основные параметры для генерации интро (текст, пресет, аудио).
/// - `VisualPreset`: Описание визуального стиля (палитра, bloom, силы).
/// - `Palette`: Набор цветов для градиента частиц.
/// - `VisualPresetLibrary`: Коллекция готовых пресетов.

import Foundation
import simd
import os

// MARK: - Логгер модуля
private let presetLog = Logger(subsystem: "com.liquidintro", category: "preset")

// MARK: - Основные параметры интро
/// Полное описание параметров для генерации видео-интро.
/// Включает текст, визуальный пресет и настройки аудио-реактивности.
struct IntroParameters: Equatable {
    /// Текст для отображения (никнейм или короткая фраза).
    var text: String
    
    /// Визуальный пресет, определяющий цвета и интенсивность эффектов.
    var preset: VisualPreset
    
    /// Темп музыки в ударах в минуту (BPM).
    /// Влияет на скорость пульсации и синхронизацию эффектов.
    var bpm: Double
    
    /// Коэффициент свинга (0.0 - 1.0).
    /// Контролирует неровность ритма в стиле lo-fi.
    var groove: Double
    
    /// Параметры по умолчанию для быстрого запуска.
    static let `default` = IntroParameters(
        text: "@liquid",
        preset: VisualPresetLibrary.pulsar,
        bpm: Config.defaultBPM,
        groove: Config.defaultGroove
    )
    
    /// Валидация параметров с логированием.
    /// - Returns: `true` если параметры корректны.
    func validate() -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            presetLog.warning("Текст интро пуст")
            return false
        }
        guard bpm >= 40 && bpm <= 200 else {
            presetLog.warning("BPM вне допустимого диапазона: \(bpm)")
            return false
        }
        guard groove >= 0 && groove <= 1 else {
            presetLog.warning("Groove вне диапазона 0-1: \(groove)")
            return false
        }
        presetLog.debug("Параметры интро валидны: '\(text)' bpm=\(bpm) groove=\(groove)")
        return true
    }
}

// MARK: - Визуальный пресет
/// Описание визуального стиля для управляемого рендера.
/// Определяет цветовую палитру, интенсивность bloom и реактивность на аудио.
struct VisualPreset: Equatable {
    /// Уникальное имя пресета для отображения в UI.
    let name: String
    
    /// Локализованное описание для пользователя.
    let localizedDescription: String
    
    /// Цветовая палитра для градиента частиц.
    let palette: Palette
    
    /// Базовый множитель bloom-эффекта.
    /// Значение 1.0 = стандартная яркость свечения.
    let baseBloom: Float
    
    /// Коэффициент реакции bloom на аудио (0.0 - 1.0).
    /// Чем выше, тем сильнее свечение пульсирует с музыкой.
    let bloomResponse: Float
    
    /// Коэффициент реакции силы касания (0.0 - 2.0).
    /// Влияет на интенсивность взаимодействия с частицами.
    let forceResponse: Float
    
    /// Масштаб шума для джиттера частиц.
    /// Больше = более хаотичное движение.
    let noiseScale: Float
    
    /// Идентификатор набора ударных для аудио-движка.
    let kitName: String
}

// MARK: - Цветовая палитра
/// Набор базовых цветов для шейдера частиц.
/// Определяет градиент от "холодных" к "горячим" цветам в зависимости от скорости частиц.
struct Palette: Equatable {
    /// Глубокий цвет для медленных частиц (обычно тёмный/холодный).
    let deep: SIMD3<Float>
    
    /// Средний цвет для перехода.
    let mid: SIMD3<Float>
    
    /// Горячий цвет для быстрых частиц (яркий, насыщенный).
    let hot: SIMD3<Float>
    
    /// Коэффициент смешивания среднего цвета (0.0 - 1.0).
    /// Определяет, насколько рано начинается переход к среднему цвету.
    let midMix: Float
    
    /// Создание палитры из HEX-цветов для удобства.
    /// - Parameters:
    ///   - deepHex: HEX-код глубокого цвета (например, 0x0A2E8C).
    ///   - midHex: HEX-код среднего цвета.
    ///   - hotHex: HEX-код горячего цвета.
    ///   - midMix: Коэффициент смешивания.
    init(deepHex: UInt32, midHex: UInt32, hotHex: UInt32, midMix: Float) {
        self.deep = Self.hexToSIMD(deepHex)
        self.mid = Self.hexToSIMD(midHex)
        self.hot = Self.hexToSIMD(hotHex)
        self.midMix = midMix
    }
    
    /// Прямая инициализация из SIMD3 значений.
    init(deep: SIMD3<Float>, mid: SIMD3<Float>, hot: SIMD3<Float>, midMix: Float) {
        self.deep = deep
        self.mid = mid
        self.hot = hot
        self.midMix = midMix
    }
    
    /// Конвертация HEX в SIMD3<Float> (нормализованные значения 0-1).
    private static func hexToSIMD(_ hex: UInt32) -> SIMD3<Float> {
        let r = Float((hex >> 16) & 0xFF) / 255.0
        let g = Float((hex >> 8) & 0xFF) / 255.0
        let b = Float(hex & 0xFF) / 255.0
        return SIMD3<Float>(r, g, b)
    }
}

// MARK: - Библиотека пресетов
/// Коллекция готовых визуальных пресетов.
/// Каждый пресет настроен для определённого настроения и стиля.
enum VisualPresetLibrary {
    
    /// "Пульсар" - энергичный неоновый стиль с синими и оранжевыми акцентами.
    /// Подходит для динамичного контента, музыки с выраженным битом.
    static let pulsar = VisualPreset(
        name: "Pulsar",
        localizedDescription: "Энергичный неоновый пульс",
        palette: Palette(
            deep: SIMD3<Float>(0.04, 0.18, 0.55),   // Глубокий синий
            mid: SIMD3<Float>(0.24, 0.60, 1.05),    // Яркий голубой (HDR > 1.0)
            hot: SIMD3<Float>(1.40, 0.75, 0.36),    // Огненный оранжевый (HDR)
            midMix: 0.65
        ),
        baseBloom: 1.35,
        bloomResponse: 0.35,
        forceResponse: 1.1,
        noiseScale: 1.0,
        kitName: "PulsarKit"
    )
    
    /// "Мечтательный" - мягкий, пастельный стиль для спокойного контента.
    /// Подходит для медленной музыки, lo-fi, ambient.
    static let dreamy = VisualPreset(
        name: "Dreamy",
        localizedDescription: "Мягкая пастельная туманность",
        palette: Palette(
            deep: SIMD3<Float>(0.03, 0.12, 0.32),   // Тёмно-синий
            mid: SIMD3<Float>(0.36, 0.64, 0.82),    // Нежно-голубой
            hot: SIMD3<Float>(1.25, 1.10, 1.40),    // Пастельно-фиолетовый (HDR)
            midMix: 0.50
        ),
        baseBloom: 1.20,
        bloomResponse: 0.28,
        forceResponse: 0.94,
        noiseScale: 1.2,
        kitName: "DreamyKit"
    )
    
    /// "Холодная туманность" - минималистичный холодный стиль.
    /// Подходит для технологичного контента, cyberpunk эстетики.
    static let coldNebula = VisualPreset(
        name: "Cold Nebula",
        localizedDescription: "Холодное космическое свечение",
        palette: Palette(
            deep: SIMD3<Float>(0.02, 0.08, 0.18),   // Почти чёрный
            mid: SIMD3<Float>(0.10, 0.35, 0.65),    // Тёмно-бирюзовый
            hot: SIMD3<Float>(0.80, 1.20, 1.50),    // Ледяной голубой (HDR)
            midMix: 0.45
        ),
        baseBloom: 1.50,
        bloomResponse: 0.40,
        forceResponse: 0.85,
        noiseScale: 0.8,
        kitName: "ColdKit"
    )
    
    /// "Закат" - тёплый градиент от фиолетового к оранжевому.
    /// Подходит для романтичного/эмоционального контента.
    static let sunset = VisualPreset(
        name: "Sunset",
        localizedDescription: "Тёплый закатный градиент",
        palette: Palette(
            deep: SIMD3<Float>(0.15, 0.05, 0.25),   // Фиолетовый
            mid: SIMD3<Float>(0.85, 0.30, 0.45),    // Розово-красный
            hot: SIMD3<Float>(1.50, 0.90, 0.40),    // Золотой (HDR)
            midMix: 0.55
        ),
        baseBloom: 1.30,
        bloomResponse: 0.32,
        forceResponse: 1.0,
        noiseScale: 0.9,
        kitName: "SunsetKit"
    )
    
    /// Все доступные пресеты для итерации в UI.
    static let allPresets: [VisualPreset] = [pulsar, dreamy, coldNebula, sunset]
}
