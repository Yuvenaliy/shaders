/// AppDelegate.swift
/// Точка входа приложения Liquid Intro Studio.
///
/// Отвечает за:
/// - Инициализацию глобальных сервисов.
/// - Настройку аудио-сессии.
/// - Обработку жизненного цикла приложения.

import UIKit
import AVFoundation
import os

/// Делегат приложения.
@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    
    private let log = Logger(subsystem: "com.liquidintro", category: "app")
    
    // MARK: - Application Lifecycle
    
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        log.debug("Приложение запускается...")
        
        // Настройка аудио-сессии для фоновой работы
        configureAudioSession()
        
        // Настройка внешнего вида
        configureAppearance()
        
        log.debug("Приложение готово к работе")
        return true
    }
    
    // MARK: - UISceneSession Lifecycle
    
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        log.debug("Создание новой сцены")
        return UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }
    
    func application(
        _ application: UIApplication,
        didDiscardSceneSessions sceneSessions: Set<UISceneSession>
    ) {
        log.debug("Сцены отброшены: \(sceneSessions.count)")
    }
    
    // MARK: - Memory Warning
    
    func applicationDidReceiveMemoryWarning(_ application: UIApplication) {
        log.warning("Получено предупреждение о памяти")
        
        // Очищаем кеши
        NotificationCenter.default.post(name: .didReceiveMemoryWarning, object: nil)
    }
    
    // MARK: - Private Methods
    
    /// Настраивает аудио-сессию для работы с AVAudioEngine.
    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            
            // Категория playback позволяет воспроизводить звук даже при выключенном звуке
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            
            // Активируем сессию
            try session.setActive(true)
            
            log.debug("Аудио-сессия настроена: \(session.category.rawValue)")
        } catch {
            log.error("Ошибка настройки аудио-сессии: \(error.localizedDescription)")
        }
    }
    
    /// Настраивает глобальный внешний вид UI элементов.
    private func configureAppearance() {
        // Тёмная тема по умолчанию
        if #available(iOS 15.0, *) {
            let appearance = UINavigationBarAppearance()
            appearance.configureWithOpaqueBackground()
            appearance.backgroundColor = .systemBackground
            
            UINavigationBar.appearance().standardAppearance = appearance
            UINavigationBar.appearance().scrollEdgeAppearance = appearance
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    /// Уведомление о предупреждении памяти для очистки кешей.
    static let didReceiveMemoryWarning = Notification.Name("com.liquidintro.memoryWarning")
}
