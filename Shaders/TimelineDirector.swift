/// TimelineDirector.swift
/// Модуль управления фазами короткого видео-интро.
///
/// Отвечает за:
/// - Определение текущей фазы интро (хаос → текст → растворение).
/// - Вычисление интерполированного состояния для шейдеров.
/// - Синхронизацию с аудио-реактивными параметрами.
///
/// Схема таймлайна (5 секунд):
/// ```
/// [0.0s]------ ХАОС ------[1.0s]------ ТЕКСТ ------[3.5s]-- РАСТВОРЕНИЕ --[5.0s]
///   ↓                        ↓                         ↓
///   Частицы хаотичны      Текст появляется          Текст исчезает
///   Максимум энергии      Стабилизация              Финальная вспышка
/// ```

import Foundation
import os

// MARK: - Логгер модуля
private let timelineLog = Logger(subsystem: "com.liquidintro", category: "timeline")

// MARK: - Состояние таймлайна
/// Интерполированное состояние для текущего момента времени.
/// Передаётся в шейдеры для управления визуальными параметрами.
struct TimelineState {
    /// Множитель силы воздействия на частицы (0.5 - 1.5).
    let forceMultiplier: Float
    
    /// Усиление bloom-эффекта (1.0 - 1.3).
    let bloomGain: Float
    
    /// Видимость текста (0.0 - 1.0).
    /// 0 = полностью невидим, 1 = полностью видим.
    let textVisibility: Float
    
    /// Интенсивность шума/джиттера частиц (0.0 - 0.2).
    let noiseJitter: Float
    
    /// Текущая фаза для отладки.
    let currentPhase: TimelinePhaseKind
}

// MARK: - Виды фаз
/// Перечисление типов фаз интро.
enum TimelinePhaseKind: String, CustomStringConvertible {
    /// Начальная фаза хаоса - частицы движутся хаотично.
    case chaos = "Хаос"
    
    /// Фаза формирования текста - частицы стабилизируются.
    case text = "Текст"
    
    /// Финальная фаза растворения - текст исчезает.
    case dissolve = "Растворение"
    
    var description: String { rawValue }
}

// MARK: - Описание фазы
/// Полное описание одной фазы таймлайна с параметрами интерполяции.
struct TimelinePhase {
    /// Время начала фазы (включительно).
    let startTime: Float
    
    /// Время окончания фазы (исключительно).
    let endTime: Float
    
    /// Тип фазы.
    let kind: TimelinePhaseKind
    
    // Начальные и конечные значения для интерполяции
    let textVisibilityStart: Float
    let textVisibilityEnd: Float
    let forceMultiplierStart: Float
    let forceMultiplierEnd: Float
    let bloomGainStart: Float
    let bloomGainEnd: Float
    let noiseJitterStart: Float
    let noiseJitterEnd: Float
    
    /// Длительность фазы в секундах.
    var duration: Float {
        max(endTime - startTime, 0.0001)
    }
    
    /// Вычисление нормализованного прогресса внутри фазы.
    /// - Parameter time: Текущее время в секундах.
    /// - Returns: Значение от 0.0 (начало) до 1.0 (конец).
    func progress(at time: Float) -> Float {
        let t = (time - startTime) / duration
        return clamp01(t)
    }
    
    /// Интерполяция состояния для заданного времени.
    /// - Parameters:
    ///   - time: Текущее время в секундах.
    ///   - audioAmplitude: Амплитуда аудио для реактивных модификаций.
    /// - Returns: Интерполированное состояние.
    func interpolatedState(at time: Float, audioAmplitude: Float) -> TimelineState {
        let t = progress(at: time)
        
        // Плавная интерполяция с easing (smoothstep)
        let smoothT = smoothstep(t)
        
        let textVisibility = mix(textVisibilityStart, textVisibilityEnd, smoothT)
        let forceMultiplier = mix(forceMultiplierStart, forceMultiplierEnd, smoothT)
        let noiseJitter = mix(noiseJitterStart, noiseJitterEnd, smoothT)
        
        // Bloom реагирует на аудио
        let baseBloom = mix(bloomGainStart, bloomGainEnd, smoothT)
        let audioBloomBoost = audioAmplitude * 0.2
        let bloomGain = baseBloom + audioBloomBoost
        
        return TimelineState(
            forceMultiplier: forceMultiplier,
            bloomGain: bloomGain,
            textVisibility: textVisibility,
            noiseJitter: noiseJitter + audioAmplitude * 0.08,
            currentPhase: kind
        )
    }
}

// MARK: - Режиссёр таймлайна
/// Управляет фазами 3–5 секундного интро: хаос → формирование текста → растворение.
/// Выдаёт интерполированное состояние для каждого кадра рендера.
final class TimelineDirector {
    
    // MARK: - Приватные свойства
    private let phases: [TimelinePhase]
    private let log = Logger(subsystem: "com.liquidintro", category: "timeline")
    private var lastLoggedPhase: TimelinePhaseKind?
    
    // MARK: - Инициализация
    /// Создаёт режиссёра с предустановленными фазами.
    init() {
        // Фаза 1: Хаос (0.0 - 1.0 сек)
        // Частицы движутся хаотично, текст невидим
        let chaosPhase = TimelinePhase(
            startTime: 0.0,
            endTime: Config.timelinePhaseOneEnd,
            kind: .chaos,
            textVisibilityStart: 0.0,
            textVisibilityEnd: 0.0,
            forceMultiplierStart: 1.3,
            forceMultiplierEnd: 1.15,
            bloomGainStart: 1.0,
            bloomGainEnd: 1.05,
            noiseJitterStart: 0.16,
            noiseJitterEnd: 0.10
        )
        
        // Фаза 2: Текст (1.0 - 3.5 сек)
        // Текст появляется, частицы стабилизируются
        let textPhase = TimelinePhase(
            startTime: Config.timelinePhaseOneEnd,
            endTime: Config.timelinePhaseTwoEnd,
            kind: .text,
            textVisibilityStart: 0.0,
            textVisibilityEnd: 1.0,
            forceMultiplierStart: 1.15,
            forceMultiplierEnd: 1.0,
            bloomGainStart: 1.05,
            bloomGainEnd: 1.1,
            noiseJitterStart: 0.10,
            noiseJitterEnd: 0.06
        )
        
        // Фаза 3: Растворение (3.5 - 5.0 сек)
        // Текст исчезает, финальная вспышка
        let dissolvePhase = TimelinePhase(
            startTime: Config.timelinePhaseTwoEnd,
            endTime: Config.timelineTotalDuration,
            kind: .dissolve,
            textVisibilityStart: 1.0,  // ИСПРАВЛЕНО: начинаем с полной видимости
            textVisibilityEnd: 0.0,
            forceMultiplierStart: 1.0,
            forceMultiplierEnd: 0.75,
            bloomGainStart: 1.1,
            bloomGainEnd: 1.25,  // Финальная вспышка
            noiseJitterStart: 0.06,
            noiseJitterEnd: 0.14
        )
        
        self.phases = [chaosPhase, textPhase, dissolvePhase]
        log.debug("TimelineDirector инициализирован с \(self.phases.count) фазами")
    }
    
    // MARK: - Публичные методы
    /// Вычисляет состояние для заданного времени.
    /// - Parameters:
    ///   - time: Текущее время в секундах (автоматически зацикливается).
    ///   - amplitude: Амплитуда аудио для реактивных модификаций.
    /// - Returns: Интерполированное состояние для шейдеров.
    func state(for time: Float, amplitude: Float) -> TimelineState {
        // Зацикливание времени
        let loopedTime = fmodf(time, Config.timelineTotalDuration)
        
        // Поиск текущей фазы (используем < для endTime, чтобы избежать перекрытий)
        let currentPhase = self.phases.first { phase in
            loopedTime >= phase.startTime && loopedTime < phase.endTime
        } ?? phases.last!  // Fallback на последнюю фазу
        
        // Логирование смены фазы
        if currentPhase.kind != lastLoggedPhase {
            log.debug("Фаза изменена: \(currentPhase.kind.description) t=\(loopedTime, format: .fixed(precision: 2))s")
            lastLoggedPhase = currentPhase.kind
        }
        
        return currentPhase.interpolatedState(at: loopedTime, audioAmplitude: amplitude)
    }
    
    /// Сброс состояния для нового цикла.
    func reset() {
        lastLoggedPhase = nil
        log.debug("TimelineDirector сброшен")
    }
}

// MARK: - Вспомогательные функции
/// Ограничивает значение диапазоном [0, 1].
/// - Parameter value: Входное значение.
/// - Returns: Значение, ограниченное диапазоном [0, 1].
func clamp01(_ value: Float) -> Float {
    min(1, max(0, value))
}

/// Линейная интерполяция между двумя значениями.
/// - Parameters:
///   - a: Начальное значение.
///   - b: Конечное значение.
///   - t: Коэффициент интерполяции (0.0 - 1.0).
/// - Returns: Интерполированное значение.
func mix(_ a: Float, _ b: Float, _ t: Float) -> Float {
    a + (b - a) * t
}

/// Плавная интерполяция (smoothstep) для более естественных переходов.
/// - Parameter t: Линейный коэффициент (0.0 - 1.0).
/// - Returns: Сглаженный коэффициент.
func smoothstep(_ t: Float) -> Float {
    let clamped = clamp01(t)
    return clamped * clamped * (3.0 - 2.0 * clamped)
}
