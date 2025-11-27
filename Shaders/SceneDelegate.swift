/// SceneDelegate.swift
/// Делегат сцены для управления окном приложения.
///
/// Отвечает за:
/// - Создание и настройку главного окна.
/// - Интеграцию SwiftUI с UIKit.
/// - Обработку переходов между состояниями сцены.

import SwiftUI
import UIKit
import os

/// Делегат сцены приложения.
class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    
    var window: UIWindow?
    private let log = Logger(subsystem: "com.liquidintro", category: "scene")
    
    // MARK: - Scene Lifecycle
    
    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        log.debug("Сцена подключается к сессии")
        
        guard let windowScene = scene as? UIWindowScene else {
            log.error("Не удалось получить UIWindowScene")
            return
        }
        
        // Создаём окно
        let window = UIWindow(windowScene: windowScene)
        
        // Устанавливаем корневой контроллер с SwiftUI view
        let rootView = ParticleMagicView()
        window.rootViewController = UIHostingController(rootView: rootView)
        
        // Настраиваем окно
        window.makeKeyAndVisible()
        self.window = window
        
        log.debug("Окно создано и отображено")
    }
    
    func sceneDidDisconnect(_ scene: UIScene) {
        log.debug("Сцена отключена")
        // Освобождаем ресурсы, специфичные для этой сцены
    }
    
    func sceneDidBecomeActive(_ scene: UIScene) {
        log.debug("Сцена стала активной")
        // Возобновляем приостановленные задачи
    }
    
    func sceneWillResignActive(_ scene: UIScene) {
        log.debug("Сцена становится неактивной")
        // Приостанавливаем задачи при переходе в фон
    }
    
    func sceneWillEnterForeground(_ scene: UIScene) {
        log.debug("Сцена переходит на передний план")
    }
    
    func sceneDidEnterBackground(_ scene: UIScene) {
        log.debug("Сцена перешла в фон")
        // Сохраняем состояние при необходимости
    }
}
