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
        case "userfont":
            return .ascii
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

}

// MARK: - Modos de compatibilidad (userfont / raster)

extension PrinterUtils {

    /// GS L 0 + GS W: área de impresión completa para el ancho de papel (576 puntos en 80 mm, 384 en 58 mm).
    static func getPrintAreaCmd(_ width: Int) -> [UInt8] {
        let dots = width >= 80 ? 576 : 384
        return [0x1D, 0x4C, 0x00, 0x00, 0x1D, 0x57, UInt8(dots & 0xFF), UInt8(dots >> 8)]
    }

    static func monoFont(_ size: CGFloat, bold: Bool) -> UIFont {
        return UIFont(name: bold ? "Menlo-Bold" : "Menlo-Regular", size: size)
            ?? UIFont.monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular)
    }

    /// Contexto gris 1:1, fondo blanco y origen arriba a la izquierda para dibujar con UIKit.
    static func grayContext(width: Int, height: Int, _ draw: (CGContext) -> Void) -> CGContext? {
        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        ctx.setFillColor(gray: 1.0, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(ctx)
        draw(ctx)
        UIGraphicsPopContext()
        return ctx
    }

    /// Dibuja cada carácter centrado en su celda, así la cuadrícula no depende del ancho de la fuente.
    static func drawCells(_ ctx: CGContext, _ text: String, x: CGFloat, baseline: CGFloat, cellW: CGFloat, font: UIFont, scaleX: CGFloat) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.black]
        var cx = x
        for ch in text {
            let s = String(ch) as NSString
            let w = s.size(withAttributes: attrs).width * scaleX
            ctx.saveGState()
            ctx.translateBy(x: cx + (cellW - w) / 2, y: 0)
            ctx.scaleBy(x: scaleX, y: 1)
            s.draw(at: CGPoint(x: 0, y: baseline - font.ascender), withAttributes: attrs)
            ctx.restoreGState()
            cx += cellW
        }
    }

    private static func collectStrings(_ value: Any?, _ out: inout String) {
        if let s = value as? String { out += s }
        else if let d = value as? [String: Any] { d.values.forEach { collectStrings($0, &out) } }
        else if let a = value as? [Any] { a.forEach { collectStrings($0, &out) } }
    }

    /// ESC & solo acepta 0x20-0x7E, así que cada carácter no-ASCII del ticket (á, Ñ, °, ¡...) se asigna a un
    /// carácter ASCII que el ticket no usa, y en ese slot se dibuja su glifo. QR e imágenes no usan la fuente.
    static func buildUserFontMap(_ items: [[String: Any]]) -> [Character: Character] {
        var text = ""
        for item in items {
            let type = item["type"] as? String
            if type != "qr" && type != "image" { collectStrings(item, &text) }
        }
        var used = Set<Character>()
        var needed = Set<Character>()
        for c in text {
            if let a = c.asciiValue { if a >= 0x21 && a <= 0x7E { used.insert(c) } }
            else { needed.insert(c) }
        }
        let free = (0x21...0x7E).reversed().map { Character(UnicodeScalar(UInt8($0))) }.filter { !used.contains($0) }
        let sortedNeeded = needed.sorted { $0.unicodeScalars.first!.value < $1.unicodeScalars.first!.value }
        var map: [Character: Character] = [:]
        for (orig, slot) in zip(sortedNeeded, free) { map[orig] = slot }
        return map
    }

    private static func remapUserFontString(_ s: String, _ map: [Character: Character]) -> String {
        var out = ""
        for c in s {
            if c.asciiValue != nil { out.append(c); continue }
            if let slot = map[c] { out.append(slot); continue }
            // Sin slots libres: se degrada a la letra sin acento.
            let base = String(c).decomposedStringWithCanonicalMapping.unicodeScalars.first { $0.value >= 0x20 && $0.value <= 0x7E }
            out.append(base.map { Character($0) } ?? "?")
        }
        return out
    }

    static func remapUserFontItem(_ item: [String: Any], _ map: [Character: Character]) -> [String: Any] {
        let type = item["type"] as? String
        if type == "qr" || type == "image" { return item }
        func remap(_ value: Any) -> Any {
            if let s = value as? String { return remapUserFontString(s, map) }
            if let d = value as? [String: Any] { return d.mapValues(remap) }
            if let a = value as? [Any] { return a.map(remap) }
            return value
        }
        var out: [String: Any] = [:]
        for (k, v) in item { out[k] = (k == "type" || k == "style") ? v : remap(v) }
        // Solo se descarga la fuente A (12x24); con la fuente B los caracteres saldrían en blanco.
        var style = item["style"] as? [String: Any] ?? [:]
        style["font"] = "primary"
        out["style"] = style
        return out
    }

    /// ESC & 3 0x20 0x7E con glifos monoespaciados de 12x24 (fuente A) + ESC % 1 para activarlos.
    static func getUserFontCmd(_ map: [Character: Character]) -> [UInt8] {
        let w = 12, h = 24
        var glyphs = (0x20...0x7E).map { Character(UnicodeScalar(UInt8($0))) }
        for (orig, slot) in map { glyphs[Int(slot.asciiValue!) - 0x20] = orig }
        let font = monoFont(20, bold: false)
        guard let ctx = grayContext(width: w * glyphs.count, height: h, { ctx in
            for (i, g) in glyphs.enumerated() {
                drawCells(ctx, String(g), x: CGFloat(i * w), baseline: CGFloat(h) + font.descender - 1,
                          cellW: CGFloat(w), font: font, scaleX: 1)
            }
        }), let buffer = ctx.data else { return [] }
        let bpr = ctx.bytesPerRow
        let ptr = buffer.bindMemory(to: UInt8.self, capacity: bpr * h)

        var bytes: [UInt8] = [0x1B, 0x26, 0x03, 0x20, 0x7E]
        for i in 0..<glyphs.count {
            bytes.append(UInt8(w))
            // Columna a columna, 3 bytes de arriba hacia abajo, MSB arriba.
            for x in 0..<w {
                for yb in 0..<3 {
                    var b: UInt8 = 0
                    for bit in 0..<8 where ptr[(yb * 8 + bit) * bpr + i * w + x] < 128 {
                        b |= (0x80 >> UInt8(bit))
                    }
                    bytes.append(b)
                }
            }
        }
        bytes.append(contentsOf: [0x1B, 0x25, 0x01])
        return bytes
    }
}

/// Acumula líneas de texto y las dibuja en la misma cuadrícula que la fuente A (12x24 por carácter,
/// 48/32/24 columnas), para que tablas y columnas queden igual que en modo texto. flush() las entrega
/// como bit-image ESC * vía bitmapToBytes.
class RasterText {
    private struct Line { let text: String; let bold: Bool; let size: Int; let align: String }

    private let dots: Int
    private let cols: Int
    private let lineSpacing: Int
    private var lines: [Line] = []

    init(printerWidth: Int, lineSpacing: Int) {
        dots = printerWidth >= 80 ? 576 : (printerWidth >= 58 ? 384 : 288)
        cols = dots / 12
        self.lineSpacing = lineSpacing
    }

    func addText(_ text: String, bold: Bool, size: Int, align: String) {
        let perLine = max(1, cols / ((size >> 4) + 1))
        for raw in text.components(separatedBy: "\n") {
            // Igual que la impresora: corta al llegar al ancho.
            var rest = Substring(raw)
            repeat {
                lines.append(Line(text: String(rest.prefix(perLine)), bold: bold, size: size, align: align))
                rest = rest.dropFirst(perLine)
            } while !rest.isEmpty
        }
    }

    func addFeed(_ n: Int) {
        for _ in 0..<max(0, n) { lines.append(Line(text: "", bold: false, size: 0, align: "left")) }
    }

    private func lineHeight(_ line: Line) -> Int {
        return 24 * ((line.size & 0x0F) + 1) + max(lineSpacing - 24, 0)
    }

    func flush() -> [UInt8] {
        if lines.isEmpty { return [] }
        let pending = lines
        lines.removeAll()
        let height = (pending.reduce(0) { $0 + lineHeight($1) } + 23) / 24 * 24
        guard let ctx = PrinterUtils.grayContext(width: dots, height: height, { ctx in
            var y = 0
            for line in pending {
                let w = (line.size >> 4) + 1
                let h = (line.size & 0x0F) + 1
                let font = PrinterUtils.monoFont(CGFloat(20 * h), bold: line.bold)
                let lineWidth = line.text.count * 12 * w
                let x: Int
                switch line.align.lowercased() {
                case "center": x = (dots - lineWidth) / 2
                case "right": x = dots - lineWidth
                default: x = 0
                }
                PrinterUtils.drawCells(ctx, line.text, x: CGFloat(max(x, 0)),
                                       baseline: CGFloat(y + 24 * h - h) + font.descender,
                                       cellW: CGFloat(12 * w), font: font, scaleX: CGFloat(w) / CGFloat(h))
                y += lineHeight(line)
            }
        }), let cg = ctx.makeImage() else { return [] }
        return PrinterUtils.bitmapToBytes(UIImage(cgImage: cg), maxWidth: dots)
    }
}
