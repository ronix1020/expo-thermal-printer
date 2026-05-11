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
    
    static func getCodePageCmd(_ encoding: String) -> [UInt8] {
        // ESC t n
        let n: UInt8
        switch encoding.lowercased() {
        case "pc850": n = 0x02
        case "windows-1252", "iso-8859-1": n = 0x10 // 16
        case "gbk": n = 0x00
        default: n = 0x00
        }
        return [0x1B, 0x74, n]
    }
    
    static func stringToBytes(_ text: String, encoding: String.Encoding) -> [UInt8] {
        if let data = text.data(using: encoding) {
            return [UInt8](data)
        }
        return []
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

        var colChars: [Int] = columnWidths.map {
            Int(floor($0.doubleValue / 100.0 * Double(availableChars)))
        }
        let currentTotal = colChars.reduce(0, +)
        if currentTotal < availableChars, let last = colChars.indices.last {
            colChars[last] += (availableChars - currentTotal)
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

        static func bitmapToBytes(_ image: UIImage, maxWidth: Int) -> [UInt8] {
        var finalImage = image
        let width = Int(image.size.width)
        _ = Int(image.size.height)
        
        if width > maxWidth {
             let ratio = CGFloat(maxWidth) / image.size.width
             let newHeight = image.size.height * ratio
             UIGraphicsBeginImageContext(CGSize(width: CGFloat(maxWidth), height: newHeight))
             image.draw(in: CGRect(x: 0, y: 0, width: CGFloat(maxWidth), height: newHeight))
             finalImage = UIGraphicsGetImageFromCurrentImageContext() ?? image
             UIGraphicsEndImageContext()
        }
        
        guard let cgImage = finalImage.cgImage else { return [] }
        let scaledWidth = cgImage.width
        let scaledHeight = cgImage.height
        
        var bytes: [UInt8] = []
        // ESC/POS Raster Bit Image command: GS v 0 m xL xH yL yH d1...dk
        bytes.append(contentsOf: [0x1D, 0x76, 0x30, 0x00])
        
        let bytesWidth = (scaledWidth + 7) / 8
        bytes.append(UInt8(bytesWidth % 256))
        bytes.append(UInt8(bytesWidth / 256))
        bytes.append(UInt8(scaledHeight % 256))
        bytes.append(UInt8(scaledHeight / 256))
        
        // Pixel data access
        guard let data = cgImage.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else { return [] }
            
        let bytesPerPixel = cgImage.bitsPerPixel / 8
        let bytesPerRow = cgImage.bytesPerRow
        
        for y in 0..<scaledHeight {
            for x in 0..<bytesWidth {
                var byteVal: UInt8 = 0
                for b in 0..<8 {
                    let px = x * 8 + b
                    if px < scaledWidth {
                        let offset = y * bytesPerRow + px * bytesPerPixel
                        // Assume RGBA or similar. Simple luminance check.
                        // Swift's memory layout for pixels is usually R G B A
                        let r = ptr[offset]
                        let g = ptr[offset+1]
                        let bVal = ptr[offset+2]
                        // let a = ptr[offset+3] // Ignore alpha for now, assume white background
                       
                        let brightness = (0.299 * Double(r) + 0.587 * Double(g) + 0.114 * Double(bVal))
                        if brightness < 128 {
                             byteVal |= (1 << (7 - b))
                        }
                    }
                }
                bytes.append(byteVal)
            }
        }
        return bytes
    }

    static func getTwoColumnsCmd(_ leftText: String, _ rightText: String, _ width: Int, _ encoding: String.Encoding) -> [UInt8] {
         // Simple implementation: text + space + text
         // Need to calculate spaces based on width (font A approx 32 chars for 58mm)
         let maxChars = (width >= 80) ? 48 : 32
         
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
