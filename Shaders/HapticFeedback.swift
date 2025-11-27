/// HapticFeedback.swift
/// Модуль управления тактильной отдачей (хаптиками).
///
/// Отвечает за:
/// - Обратную связь при взаимодействии с UI.
/// - Синхронизацию хаптиков с аудио-событиями.
/// - Оптимизацию батареи через throttling.

import UIKit
import os

// MARK: - Логгер модуля
private let hapticLog = Logger(subsystem: "com.liquidintro", category: "haptic")

// MARK: - Типы хаптиков
/// Предустановленные типы тактильной отдачи.
enum HapticType {
    /// Лёгкий тап (выбор элемента).
    case selection
    
    /// Успешное действие.
    case success
    
    /// Предупреждение.
    case warning
    
    /// Ошибка.
    case error
    
    /// Лёгкий удар (kick drum).
    case lightImpact
    
    /// Средний удар (snare).
    case mediumImpact
    
    /// Тяжёлый удар.
    case heavyImpact
    
    /// Мягкий удар (hi-hat).
    case softImpact
    
    /// Жёсткий удар.
    case rigidImpact
}

// MARK: - Менеджер хаптиков
/// Централизованное управление тактильной отдачей.
/// Использует паттерн Singleton для глобального доступа.
final class HapticManager {
    
    // MARK: - Singleton
    static let shared = HapticManager()
    
    // MARK: - Генераторы
    private let selectionGenerator = UISelectionFeedbackGenerator()
    private let notificationGenerator = UINotificationFeedbackGenerator()
    private let lightImpactGenerator = UIImpactFeedbackGenerator(style: .light)
    private let mediumImpactGenerator = UIImpactFeedbackGenerator(style: .medium)
    private let heavyImpactGenerator = UIImpactFeedbackGenerator(style: .heavy)
    private let softImpactGenerator = UIImpactFeedbackGenerator(style: .soft)
    private let rigidImpactGenerator = UIImpactFeedbackGenerator(style: .rigid)
    
    // MARK: - Throttling
    private var lastHapticTime: CFTimeInterval = 0
    private let minimumInterval: CFTimeInterval = 0.05  // 50ms между хаптиками
    
    // MARK: - Состояние
    private(set) var isEnabled = true
    private let log = Logger(subsystem: "com.liquidintro", category: "haptic")
    
    // MARK: - Инициализация
    private init() {
        // Подготавливаем генераторы для быстрого отклика
        prepareGenerators()
        log.debug("HapticManager инициализирован")
    }
    
    // MARK: - Публичные методы
    
    /// Включает или выключает хаптики.
    /// - Parameter enabled: `true` для включения.
    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        log.debug("Хаптики \(enabled ? "включены" : "выключены")")
    }
    
    /// Воспроизводит тактильную отдачу указанного типа.
    /// - Parameter type: Тип хаптика.
    func play(_ type: HapticType) {
        guard isEnabled else { return }
        guard shouldPlayHaptic() else { return }
        
        switch type {
        case .selection:
            selectionGenerator.selectionChanged()
            
        case .success:
            notificationGenerator.notificationOccurred(.success)
            
        case .warning:
            notificationGenerator.notificationOccurred(.warning)
            
        case .error:
            notificationGenerator.notificationOccurred(.error)
            
        case .lightImpact:
            lightImpactGenerator.impactOccurred()
            
        case .mediumImpact:
            mediumImpactGenerator.impactOccurred()
            
        case .heavyImpact:
            heavyImpactGenerator.impactOccurred()
            
        case .softImpact:
            softImpactGenerator.impactOccurred()
            
        case .rigidImpact:
            rigidImpactGenerator.impactOccurred()
        }
        
        lastHapticTime = CACurrentMediaTime()
    }
    
    /// Воспроизводит импакт с заданной интенсивностью.
    /// - Parameters:
    ///   - style: Стиль импакта.
    ///   - intensity: Интенсивность (0.0 - 1.0).
    func playImpact(style: UIImpactFeedbackGenerator.FeedbackStyle, intensity: CGFloat) {
        guard isEnabled else { return }
        guard shouldPlayHaptic() else { return }
        
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.impactOccurred(intensity: intensity)
        
        lastHapticTime = CACurrentMediaTime()
    }
    
    /// Воспроизводит хаптик для kick drum.
    func playKick() {
        playImpact(style: .heavy, intensity: 0.8)
    }
    
    /// Воспроизводит хаптик для snare.
    func playSnare() {
        playImpact(style: .medium, intensity: 0.6)
    }
    
    /// Подготавливает генераторы для быстрого отклика.
    /// Вызывать перед ожидаемым взаимодействием.
    func prepareGenerators() {
        selectionGenerator.prepare()
        notificationGenerator.prepare()
        lightImpactGenerator.prepare()
        mediumImpactGenerator.prepare()
        heavyImpactGenerator.prepare()
        softImpactGenerator.prepare()
        rigidImpactGenerator.prepare()
    }
    
    // MARK: - Приватные методы
    
    /// Проверяет, можно ли воспроизвести хаптик (throttling).
    private func shouldPlayHaptic() -> Bool {
        let now = CACurrentMediaTime()
        return now - lastHapticTime >= minimumInterval
    }
}

// MARK: - Расширение для SwiftUI
import SwiftUI

extension View {
    /// Добавляет тактильную отдачу при тапе.
    /// - Parameter type: Тип хаптика.
    func hapticFeedback(_ type: HapticType) -> some View {
        self.onTapGesture {
            HapticManager.shared.play(type)
        }
    }
}
