import Foundation
import UIKit

class PrinterUtils {
    
    static func getAlignCmd(_ align: String) -> [UInt8] {
        switch align.lowercased() {
        case "center": return [0x1B, 0x61, 0x01]
        case "right": return [0x1B, 0x61, 0x02]
        default: return [0x1B, 0x61, 0x00] // Left
        }
    }
    
    static func getBoldCmd(_ bold: Bool) -> [UInt8] {
        return bold ? [0x1B, 0x45, 0x01] : [0x1B, 0x45, 0x00]
    }
    
    static func getTextSizeCmd(_ size: Int) -> [UInt8] {
        // GS ! n
        let n = UInt8(clamping: size)
        return [0x1D, 0x21, n]
    }
    
    static func getFontCmd(_ font: String) -> [UInt8] {
        // ESC M n
        // n = 0: Font A (12x24), n = 1: Font B (9x17)
        return font == "secondary" ? [0x1B, 0x4D, 0x01] : [0x1B, 0x4D, 0x00]
    }
    
    static func getLineSpacingCmd(_ n: Int) -> [UInt8] {
        // ESC 3 n
        let spacing = UInt8(clamping: n)
        return [0x1B, 0x33, spacing]
    }
    
    static func getFeedLinesCmd(_ n: Int) -> [UInt8] {
        // ESC d n
        let lines = UInt8(clamping: n)
        return [0x1B, 0x64, lines]
    }
    
    /// Normalize encoding aliases to a canonical name before charset/code-page
    /// selection. Keeps iso8859_1, latin1, utf8, win1252, etc. from silently
    /// falling through to UTF-8.
    static func normalizeEncoding(_ encoding: String) -> String {
        let e = encoding.lowercased().trimmingCharacters(in: .whitespaces)
        switch e {
        case "utf8": return "utf-8"
        case "iso8859_1", "iso88591", "latin1": return "iso-8859-1"
        case "win1252": return "windows-1252"
        default: return e
        }
    }

    /// Resolve a text size from either a raw ESC/POS `GS ! n` byte (number) or a
    /// semantic string. 'small'/'normal' -> 0, 'large' -> double height (0x01),
    /// 'xlarge' -> double height + width (0x11).
    static func resolveSize(_ value: Any?) -> Int {
        if let n = value as? NSNumber { return n.intValue }
        if let n = value as? Int { return n }
        if let s = value as? String {
            switch s.lowercased().trimmingCharacters(in: .whitespaces) {
            case "small", "normal": return 0x00
            case "large": return 0x01
            case "xlarge": return 0x11
            default: return Int(s) ?? 0
            }
        }
        return 0
    }

    static func getCodePageCmd(_ encoding: String) -> [UInt8] {
        // ESC t n
        let n: UInt8
        switch normalizeEncoding(encoding) {
        case "pc850": n = 0x02
        case "windows-1252", "iso-8859-1": n = 0x10 // 16
        case "gbk": n = 0x00
        default: n = 0x00
        }
        return [0x1B, 0x74, n]
    }

    static func resolveEncoding(_ encoding: String) -> String.Encoding {
        switch normalizeEncoding(encoding) {
        case "pc850":
            let cf = CFStringEncoding(CFStringEncodings.dosLatin1.rawValue)
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
        case "windows-1252":
            return .windowsCP1252
        case "iso-8859-1":
            return .isoLatin1
        case "gbk":
            let cf = CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
        case "utf-8":
            return .utf8
        default:
            return .utf8
        }
    }

    static func stringToBytes(_ text: String, encoding: String.Encoding) -> [UInt8] {
        // allowLossyConversion mirrors Kotlin's String.toByteArray(charset): chars outside
        // the target encoding become '?' instead of failing the whole conversion.
        if let data = text.data(using: encoding, allowLossyConversion: true) {
            return [UInt8](data)
        }
        return [UInt8](text.data(using: .utf8) ?? Data())
    }
    
    static func getQrCodeCmd(_ text: String, size: Int) -> [UInt8] {
        var bytes: [UInt8] = []
        guard let textData = text.data(using: .utf8) else { return bytes }
        
        let len = textData.count + 3
        let pL = UInt8(len % 256)
        let pH = UInt8(len / 256)
        
        // Model
        bytes.append(contentsOf: [0x1D, 0x28, 0x6B, 0x04, 0x00, 0x31, 0x41, 0x32, 0x00])
        // Size
        bytes.append(contentsOf: [0x1D, 0x28, 0x6B, 0x03, 0x00, 0x31, 0x43, UInt8(clamping: size)])
        // Error Correction
        bytes.append(contentsOf: [0x1D, 0x28, 0x6B, 0x03, 0x00, 0x31, 0x45, 0x30])
        // Store Data
        bytes.append(contentsOf: [0x1D, 0x28, 0x6B, pL, pH, 0x31, 0x50, 0x30])
        bytes.append(contentsOf: [UInt8](textData))
        // Print
        bytes.append(contentsOf: [0x1D, 0x28, 0x6B, 0x03, 0x00, 0x31, 0x51, 0x30])
        
        return bytes
    }
    
    static func splitText(_ text: String, width: Int) -> [String] {
        var result: [String] = []
        var current = text
        while current.count > width {
            let index = current.index(current.startIndex, offsetBy: width)
            result.append(String(current[..<index]))
            current = String(current[index...])
        }
        if !current.isEmpty {
            result.append(current)
        }
        return result
    }

    static func getTableCmd(header: [String],
                            columnWidths: [NSNumber],
                            columnAlignment: [String],
                            content: [[String]],
                            printerWidth: Int,
                            encoding: String.Encoding) -> [UInt8] {
        var bytes: [UInt8] = []

        if header.isEmpty && content.isEmpty { return bytes }

        let numColumns = columnWidths.count
        if numColumns == 0 { return bytes }

        let maxChars: Int
        if printerWidth >= 80 { maxChars = 48 }
        else if printerWidth >= 58 { maxChars = 32 }
        else { maxChars = 24 }

        let totalSpacing = numColumns > 1 ? numColumns - 1 : 0
        let availableChars = maxChars - totalSpacing
        if availableChars <= 0 { return bytes }

        // Disambiguate columnWidths:
        //  - If the values sum to <= the paper's char width, treat them as
        //    ABSOLUTE char counts (use as-is, then fit to the available space).
        //  - Otherwise treat them as PERCENTAGES of the available width.
        let requestedSum = columnWidths.reduce(0) { $0 + $1.intValue }
        var colChars: [Int]
        if requestedSum <= maxChars {
            colChars = columnWidths.map { $0.intValue }
        } else {
            colChars = columnWidths.map { Int(floor($0.doubleValue / 100.0 * Double(availableChars))) }
        }

        // Shrink from the last columns if we overflow the available space.
        var total = colChars.reduce(0, +)
        var idx = colChars.count - 1
        while total > availableChars && idx >= 0 {
            let reducible = min(colChars[idx], total - availableChars)
            colChars[idx] -= reducible
            total -= reducible
            idx -= 1
        }
        // Adjust last column to fill remaining space due to rounding/absolute slack.
        if total < availableChars, let last = colChars.indices.last {
            colChars[last] += (availableChars - total)
        }

        func pad(_ text: String, width: Int, align: String) -> String {
            if text.count >= width {
                if text.count == width { return text }
                let endIdx = text.index(text.startIndex, offsetBy: width)
                return String(text[..<endIdx])
            }
            let totalSpaces = width - text.count
            switch align.lowercased() {
            case "right":
                return String(repeating: " ", count: totalSpaces) + text
            case "center":
                let leftSpaces = totalSpaces / 2
                let rightSpaces = totalSpaces - leftSpaces
                return String(repeating: " ", count: leftSpaces) + text + String(repeating: " ", count: rightSpaces)
            default:
                return text + String(repeating: " ", count: totalSpaces)
            }
        }

        func appendRow(_ row: [String]) {
            var cellLines: [[String]] = []
            for index in 0..<colChars.count {
                let text = index < row.count ? row[index] : ""
                let width = colChars[index]
                if width > 0 {
                    cellLines.append(splitText(text, width: width))
                } else {
                    cellLines.append([""])
                }
            }
            let maxLines = cellLines.map { $0.count }.max() ?? 0
            if maxLines == 0 { return }

            for i in 0..<maxLines {
                for j in 0..<colChars.count {
                    let width = colChars[j]
                    let lines = cellLines[j]
                    let cellText = i < lines.count ? lines[i] : ""
                    let align = j < columnAlignment.count ? columnAlignment[j] : "left"
                    let finalText = pad(cellText, width: width, align: align)

                    bytes.append(contentsOf: stringToBytes(finalText, encoding: encoding))

                    if j < colChars.count - 1 {
                        bytes.append(contentsOf: stringToBytes(" ", encoding: encoding))
                    }
                }
                bytes.append(0x0A)
            }
        }

        if !header.isEmpty { appendRow(header) }
        for row in content { appendRow(row) }

        return bytes
    }

    /// Convierte una imagen a comandos ESC/POS usando el modo bit-image `ESC *`
    /// (0x1B 0x2A) en bandas de 24 puntos (modo 33, doble densidad).
    ///
    /// Antes se usaba el raster `GS v 0` (0x1D 0x76 0x30), pero muchas térmicas
    /// económicas NO lo implementan: el payload caía como texto (basura) y
    /// desincronizaba el flujo. `ESC *` es el bit-image original, soportado por
    /// prácticamente todas las térmicas.
    ///
    /// La imagen se re-renderiza en un contexto de ESCALA DE GRISES de formato
    /// conocido, con fondo blanco y escala 1:1. Esto corrige de una vez:
    ///  - el resize a escala del dispositivo (2x/3x) del antiguo
    ///    `UIGraphicsBeginImageContext`, que hacía el raster 2-3x más ancho que el
    ///    cabezal;
    ///  - la transparencia (se aplana sobre blanco; ya no sale recuadro negro),
    ///    en TODOS los casos y no solo cuando había que redimensionar;
    ///  - la ambigüedad de orden de canales (BGRA/ARGB premultiplicado) del
    ///    cgImage origen, que podía invertir los colores.
    static func bitmapToBytes(_ image: UIImage, maxWidth: Int) -> [UInt8] {
        guard let srcCg = image.cgImage else { return [] }
        let srcW = srcCg.width
        let srcH = srcCg.height
        if srcW == 0 || srcH == 0 { return [] }

        // Escalar solo hacia abajo, respetando el ancho pedido (nunca ampliar).
        let targetW = min(srcW, max(1, maxWidth))
        let targetH = max(1, Int((Double(srcH) * Double(targetW) / Double(srcW)).rounded()))

        // Contexto en escala de grises: 1 byte por píxel = luminancia directa,
        // fondo blanco, escala 1:1. bytesPerRow 0 -> Core Graphics calcula el
        // stride óptimo (puede padear cada fila, por eso se lee ctx.bytesPerRow).
        guard let ctx = CGContext(
            data: nil,
            width: targetW,
            height: targetH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return [] }

        ctx.setFillColor(gray: 1.0, alpha: 1.0) // blanco
        ctx.fill(CGRect(x: 0, y: 0, width: targetW, height: targetH))
        ctx.interpolationQuality = .high
        ctx.draw(srcCg, in: CGRect(x: 0, y: 0, width: targetW, height: targetH))

        guard let buffer = ctx.data else { return [] }
        let bpr = ctx.bytesPerRow
        let ptr = buffer.bindMemory(to: UInt8.self, capacity: bpr * targetH)

        let width = targetW
        let height = targetH
        var bytes: [UInt8] = [0x1B, 0x33, 24] // interlineado 24 pts (bandas pegadas)
        let nL = UInt8(width % 256), nH = UInt8(width / 256)
        var y = 0
        while y < height {
            bytes.append(contentsOf: [0x1B, 0x2A, 33, nL, nH]) // ESC * 33 nL nH
            for x in 0..<width {
                for k in 0..<3 {
                    var slice: UInt8 = 0
                    for b in 0..<8 {
                        let yy = y + k * 8 + b
                        if yy < height && Int(ptr[yy * bpr + x]) < 128 {
                            slice |= (1 << (7 - b))
                        }
                    }
                    bytes.append(slice)
                }
            }
            bytes.append(0x0A) // imprime la banda y avanza 24 pts
            y += 24
        }
        bytes.append(contentsOf: [0x1B, 0x32]) // restaura interlineado
        return bytes
    }

    static func getTwoColumnsCmd(_ leftText: String, _ rightText: String, _ width: Int, _ encoding: String.Encoding, _ size: Int, _ font: String) -> [UInt8] {
         // Mirror the Android char-budget calculation so both platforms align
         // the two columns identically.
         // Base chars for Font A (12x24).
         var maxChars = (width >= 80) ? 48 : ((width >= 58) ? 32 : 24)

         // Font B (9x17) fits more characters per line.
         if font == "secondary" {
             maxChars = (width >= 80) ? 64 : ((width >= 58) ? 42 : 32)
         }

         // GS ! n: upper 4 bits are the width multiplier - 1.
         let widthMultiplier = (size >> 4) + 1
         maxChars /= widthMultiplier

         let leftLen = leftText.count
         let rightLen = rightText.count

         if leftLen + rightLen >= maxChars {
             return stringToBytes(leftText + " " + rightText, encoding: encoding)
         }

         let spaces = maxChars - leftLen - rightLen
         let spaceStr = String(repeating: " ", count: spaces)
         return stringToBytes(leftText + spaceStr + rightText, encoding: encoding)
    }

}
