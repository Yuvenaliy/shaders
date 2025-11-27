/// TextLayer.swift
/// Модуль генерации текстовых текстур для HDR-рендеринга в Metal.
///
/// Отвечает за:
/// - Растеризацию текста с правильной ориентацией.
/// - Кеширование текстур по содержимому и размеру.
/// - Поддержку Unicode (включая emoji).
/// - Оптимизацию памяти через автоматическую очистку кеша.
///
/// Важно: CGContext имеет систему координат с Y вверх (как в математике),
/// а Metal текстуры - с Y вниз. Этот модуль корректно обрабатывает эту разницу.

import Foundation
import Metal
import UIKit
import os

// MARK: - Логгер модуля
private let textLog = Logger(subsystem: "com.liquidintro", category: "text")

// MARK: - Ключ кеша
/// Структура для идентификации кешированных текстур.
private struct TextureCacheKey: Hashable {
    let text: String
    let width: Int
    let height: Int
}

// MARK: - Фабрика текстовых текстур
/// Генерирует текстовые текстуры для Metal и кеширует их для повторного использования.
/// Потокобезопасен - можно использовать из любого потока.
final class TextTextureFactory {
    
    // MARK: - Приватные свойства
    private let device: MTLDevice
    private let cache = NSCache<NSString, MTLTexture>()
    private let log = Logger(subsystem: "com.liquidintro", category: "text")
    private let cacheQueue = DispatchQueue(label: "com.liquidintro.textCache", attributes: .concurrent)
    
    // MARK: - Настройки рендеринга текста
    private struct TextRenderSettings {
        /// Вес шрифта.
        static let fontWeight: UIFont.Weight = .semibold
        
        /// Цвет текста (белый для наложения).
        static let textColor: UIColor = .white
        
        /// Максимальная ширина текста относительно экрана.
        static let maxWidthRatio: CGFloat = 0.85
        
        /// Вертикальное смещение текста (0.5 = центр).
        static let verticalPosition: CGFloat = 0.5
    }
    
    // MARK: - Инициализация
    /// Создаёт фабрику для заданного Metal устройства.
    /// - Parameter device: MTLDevice для создания текстур.
    init(device: MTLDevice) {
        self.device = device
        
        // Настройка кеша
        cache.countLimit = 10  // Максимум 10 текстур в кеше
        cache.totalCostLimit = 100 * 1024 * 1024  // ~100 MB
        
        log.debug("TextTextureFactory инициализирована для устройства: \(device.name)")
    }
    
    // MARK: - Публичные методы
    
    /// Получает или создаёт текстуру для заданного текста.
    /// - Parameters:
    ///   - text: Текст для рендеринга.
    ///   - drawableSize: Размер целевой области отрисовки.
    /// - Returns: Metal текстура с растеризованным текстом или nil при ошибке.
    func texture(for text: String, drawableSize: CGSize) -> MTLTexture? {
        let width = max(1, Int(drawableSize.width))
        let height = max(1, Int(drawableSize.height))
        
        // Ключ кеша
        let cacheKey = "\(text)-\(width)x\(height)" as NSString
        
        // Проверяем кеш
        if let cached = cache.object(forKey: cacheKey) {
            log.debug("Текстура для '\(text)' получена из кеша")
            return cached
        }
        
        // Создаём новую текстуру
        guard let texture = createTextTexture(text: text, width: width, height: height) else {
            log.error("Не удалось создать текстуру для '\(text)'")
            return nil
        }
        
        // Добавляем в кеш
        let cost = width * height * 4  // Приблизительный размер в байтах
        cache.setObject(texture, forKey: cacheKey, cost: cost)
        log.debug("Текстура для '\(text)' создана и закеширована (\(width)x\(height))")
        
        return texture
    }
    
    /// Очищает кеш текстур.
    /// Полезно при смене параметров или при предупреждении о памяти.
    func clearCache() {
        cache.removeAllObjects()
        log.debug("Кеш текстур очищен")
    }
    
    // MARK: - Приватные методы
    
    /// Создаёт новую текстуру с растеризованным текстом.
    private func createTextTexture(text: String, width: Int, height: Int) -> MTLTexture? {
        // Создаём буфер для пикселей (RGBA, 8 бит на канал)
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixelData = [UInt8](repeating: 0, count: height * bytesPerRow)
        
        // Создаём CGContext
        let context: CGContext? = {
            var created: CGContext?
            let renderBlock = {
                created = CGContext(
                    data: &pixelData,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
            }

            // UIKit требует основного потока для корректного рендеринга
            if Thread.isMainThread {
                renderBlock()
            } else {
                DispatchQueue.main.sync { renderBlock() }
            }
            return created
        }()

        guard let context else {
            log.error("Не удалось создать CGContext")
            return nil
        }
        
        // ИСПРАВЛЕНИЕ: Переворачиваем координаты для правильной ориентации
        // CGContext имеет Y вверх, а Metal текстуры - Y вниз
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1.0, y: -1.0)
        
        // Очищаем фон (прозрачный)
        context.setFillColor(UIColor.clear.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        
        // Рендерим текст через UIKit (обязательно на главном потоке)
        let renderBlock = {
            UIGraphicsPushContext(context)
            defer { UIGraphicsPopContext() }
            self.renderText(text, in: context, size: CGSize(width: width, height: height))
        }
        if Thread.isMainThread {
            renderBlock()
        } else {
            DispatchQueue.main.sync { renderBlock() }
        }
        
        // Создаём Metal текстуру
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            log.error("Не удалось создать Metal текстуру")
            return nil
        }
        
        // Копируем данные в текстуру
        let region = MTLRegionMake2D(0, 0, width, height)
        pixelData.withUnsafeBytes { ptr in
            texture.replace(region: region, mipmapLevel: 0, withBytes: ptr.baseAddress!, bytesPerRow: bytesPerRow)
        }
        
        return texture
    }
    
    /// Рендерит текст в CGContext.
    private func renderText(_ text: String, in context: CGContext, size: CGSize) {
        // Вычисляем размер шрифта
        let minDimension = min(size.width, size.height)
        let baseFontSize = minDimension * Config.fontSizeRatio
        
        // Создаём атрибуты текста
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        paragraphStyle.lineBreakMode = .byTruncatingTail
        
        // Адаптивный размер шрифта
        var fontSize = baseFontSize
        var attributes = createAttributes(fontSize: fontSize, paragraphStyle: paragraphStyle)
        
        // Измеряем текст и уменьшаем шрифт если нужно
        let maxWidth = size.width * TextRenderSettings.maxWidthRatio
        var textSize = measureText(text, with: attributes, constrainedTo: maxWidth)
        
        while textSize.width > maxWidth && fontSize > 12 {
            fontSize *= 0.95
            attributes = createAttributes(fontSize: fontSize, paragraphStyle: paragraphStyle)
            textSize = measureText(text, with: attributes, constrainedTo: maxWidth)
        }
        
        // Вычисляем позицию для центрирования
        let drawRect = CGRect(
            x: (size.width - textSize.width) / 2,
            y: (size.height - textSize.height) * TextRenderSettings.verticalPosition,
            width: textSize.width,
            height: textSize.height
        )
        
        // Рисуем текст
        let attributedString = NSAttributedString(string: text, attributes: attributes)
        attributedString.draw(in: drawRect)
        
        log.debug("Текст '\(text, privacy: .public)' отрендерен: шрифт \(Int(fontSize))pt, позиция x=\(drawRect.origin.x, format: .fixed(precision: 1)) y=\(drawRect.origin.y, format: .fixed(precision: 1)) w=\(drawRect.width, format: .fixed(precision: 1)) h=\(drawRect.height, format: .fixed(precision: 1))")
    }
    
    /// Создаёт атрибуты для рендеринга текста.
    private func createAttributes(fontSize: CGFloat, paragraphStyle: NSParagraphStyle) -> [NSAttributedString.Key: Any] {
        return [
            .font: UIFont.systemFont(ofSize: fontSize, weight: TextRenderSettings.fontWeight),
            .foregroundColor: TextRenderSettings.textColor,
            .paragraphStyle: paragraphStyle
        ]
    }
    
    /// Измеряет размер текста с заданными атрибутами.
    private func measureText(_ text: String, with attributes: [NSAttributedString.Key: Any], constrainedTo maxWidth: CGFloat) -> CGSize {
        let attributedString = NSAttributedString(string: text, attributes: attributes)
        let boundingRect = attributedString.boundingRect(
            with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        return CGSize(
            width: ceil(boundingRect.width),
            height: ceil(boundingRect.height)
        )
    }
    
    deinit {
        clearCache()
        log.debug("TextTextureFactory освобождена")
    }
}
