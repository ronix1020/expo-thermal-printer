import ExpoModulesCore
import CoreBluetooth
import UIKit

class BluetoothManager: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
  private var centralManager: CBCentralManager!
  private var discoveredPeripherals: [CBPeripheral] = []
  private var connectedPeripheral: CBPeripheral?
  private var writeCharacteristic: CBCharacteristic?
  private var scanPromise: Promise?
  private var connectPromise: Promise?
  private var writePromise: Promise?
  private var pendingChunks: [Data] = []
  private var currentWriteType: CBCharacteristicWriteType = .withResponse
  // Progreso del envío en bytes; se avisa solo cuando cambia el porcentaje.
  var onProgress: ((Int, Int) -> Void)?
  // El enlace cayó solo (no por disconnect()): ms desde el último print que resolvió, 0 si había
  // uno en vuelo (ese ya rechaza), nil si no hubo print en esta conexión.
  var onConnectionLost: ((Int?) -> Void)?
  private var lastPrintDoneAt: TimeInterval?
  private var totalBytes = 0
  private var sentBytes = 0
  private var lastPercent = -1

  private func reportProgress(_ bytes: Int) {
    sentBytes += bytes
    let percent = totalBytes > 0 ? sentBytes * 100 / totalBytes : 100
    if percent != lastPercent {
      lastPercent = percent
      onProgress?(sentBytes, totalBytes)
    }
  }

  override init() {
    super.init()
    centralManager = CBCentralManager(delegate: self, queue: nil)
  }
  
  func scanDevices(_ promise: Promise) {
    if centralManager.state != .poweredOn {
      promise.reject(PrinterException("BLUETOOTH_NOT_READY", "Bluetooth is not powered on"))
      return
    }
    
    scanPromise = promise
    discoveredPeripherals.removeAll()
    
    // Scan for all peripherals - ideally we'd filter by service UUIDs if known, 
    // but for generic thermal printers we often scan all.
    centralManager.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    
    // Stop scanning after 5 seconds to return results
    DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
      if self.centralManager.isScanning {
        self.centralManager.stopScan()
        self.resolveScan()
      }
    }
  }
  
  func write(_ data: Data, _ promise: Promise) {
    guard let peripheral = connectedPeripheral, let characteristic = writeCharacteristic else {
        promise.reject(PrinterException("SERVICE_NOT_BOUND", "Not connected to any printer"))
        return
    }

    // Evitar solapar impresiones: una escritura previa puede seguir en vuelo (esperando un
    // ACK o peripheralIsReady). Sobrescribir writePromise/pendingChunks colgaría la primera
    // promesa y mezclaría los chunks de ambos payloads.
    guard writePromise == nil else {
        promise.reject(PrinterException("ALREADY_PRINTING", "A previous print is still in progress"))
        return
    }

    writePromise = promise

    // Preferir .withResponse cuando la característica lo soporta (entrega garantizada +
    // control de flujo por ACK). Si solo soporta writeWithoutResponse, usar esa ruta con
    // control de flujo explícito.
    currentWriteType = characteristic.properties.contains(.write) ? .withResponse : .withoutResponse

    // Partir el payload en chunks del tamaño máximo permitido por la MTU negociada.
    let mtu = max(1, peripheral.maximumWriteValueLength(for: currentWriteType))
    var chunks: [Data] = []
    var offset = 0
    while offset < data.count {
        let len = min(mtu, data.count - offset)
        chunks.append(data.subdata(in: offset..<offset + len))
        offset += len
    }
    pendingChunks = chunks
    totalBytes = data.count
    sentBytes = 0
    lastPercent = -1

    sendPendingChunks()
  }

  // Envía los chunks pendientes respetando el control de flujo de CoreBluetooth.
  private func sendPendingChunks() {
    guard let peripheral = connectedPeripheral, let characteristic = writeCharacteristic else {
        writePromise?.reject(PrinterException("SERVICE_NOT_BOUND", "Not connected to any printer"))
        writePromise = nil
        pendingChunks.removeAll()
        return
    }

    if currentWriteType == .withoutResponse {
        // writeWithoutResponse NO se encola: esperar a que el periférico pueda recibir más.
        while !pendingChunks.isEmpty {
            if !peripheral.canSendWriteWithoutResponse {
                // Se reanuda en peripheralIsReady(toSendWriteWithoutResponse:)
                return
            }
            let chunk = pendingChunks.removeFirst()
            peripheral.writeValue(chunk, for: characteristic, type: .withoutResponse)
            reportProgress(chunk.count)
        }
        resolveWrite()   // todos los chunks despachados
    } else {
        // .withResponse: enviar uno y esperar el ACK (didWriteValueFor) para el siguiente.
        guard !pendingChunks.isEmpty else {
            resolveWrite()
            return
        }
        let chunk = pendingChunks.removeFirst()
        inFlightBytes = chunk.count
        peripheral.writeValue(chunk, for: characteristic, type: .withResponse)
    }
  }

  private func resolveWrite() {
    writePromise?.resolve(nil)
    writePromise = nil
    lastPrintDoneAt = ProcessInfo.processInfo.systemUptime
  }

  // Bytes del chunk .withResponse que espera su ACK; cuenta como enviado al llegar el ACK.
  private var inFlightBytes = 0
  
  func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
     if let error = error {
         writePromise?.reject(PrinterException("PRINT_FAILED", error.localizedDescription))
         writePromise = nil
         pendingChunks.removeAll()
         return
     }
     // ACK de un chunk .withResponse: enviar el siguiente o resolver al terminar.
     if currentWriteType == .withResponse {
         reportProgress(inFlightBytes)
         inFlightBytes = 0
         if pendingChunks.isEmpty {
             resolveWrite()
         } else {
             sendPendingChunks()
         }
     }
  }

  private func resolveScan() {
    guard let promise = scanPromise else { return }
    
    let devices = discoveredPeripherals.map { peripheral in
      return [
        "name": peripheral.name ?? "Unknown Device",
        "macAddress": peripheral.identifier.uuidString // iOS doesn't expose MAC, use UUID
      ]
    }
    
    promise.resolve(devices)
    scanPromise = nil
  }
  
  // MARK: - CMCentralManagerDelegate
  
  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    switch central.state {
    case .poweredOn:
      print("Bluetooth is on")
    case .poweredOff:
      print("Bluetooth is off")
    case .unauthorized:
      print("Bluetooth is unauthorized")
    case .unknown, .resetting, .unsupported:
      print("Bluetooth state unknown/unsupported")
    @unknown default:
      break
    }
  }
  
  func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
    if !discoveredPeripherals.contains(where: { $0.identifier == peripheral.identifier }) {
      // Filter for device names that look like printers if possible, or just add all
      // Many thermal printers have names like "MTP...", "Printer...", etc.
      if let name = peripheral.name, !name.isEmpty {
         discoveredPeripherals.append(peripheral)
      }
    }
  }
  func connect(_ uuid: String, _ promise: Promise) {
    attemptConnect(uuid, promise, retriesLeft: 3)
  }

  // The central manager initializes its state asynchronously; on a cold start
  // the state may still be .unknown/.resetting. Retry briefly before giving up.
  private func attemptConnect(_ uuid: String, _ promise: Promise, retriesLeft: Int) {
    switch centralManager.state {
    case .poweredOn:
      guard let peripheral = discoveredPeripherals.first(where: { $0.identifier.uuidString == uuid }) else {
        promise.reject(PrinterException("DEVICE_NOT_FOUND", "Device with UUID \(uuid) not found in scan results"))
        return
      }
      connectPromise = promise
      centralManager.connect(peripheral, options: nil)
    case .unknown, .resetting:
      if retriesLeft > 0 {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
          self.attemptConnect(uuid, promise, retriesLeft: retriesLeft - 1)
        }
      } else {
        promise.reject(PrinterException("BLUETOOTH_NOT_READY", "Bluetooth is not ready"))
      }
    default:
      promise.reject(PrinterException("BLUETOOTH_NOT_READY", "Bluetooth is not powered on"))
    }
  }
  
  // Rechaza cualquier escritura en vuelo y limpia el estado para que la promesa de JS nunca
  // quede colgada: tras una desconexión no llegarán ni el ACK (.withResponse) ni
  // peripheralIsReady (.withoutResponse) que reanudarían sendPendingChunks().
  private func failPendingWrite(_ reason: String) {
    if writePromise != nil {
        writePromise?.reject(PrinterException("PRINT_FAILED", reason))
        writePromise = nil
    }
    pendingChunks.removeAll()
  }

  func disconnect(_ promise: Promise) {
    if let peripheral = connectedPeripheral {
      failPendingWrite("Disconnected during write")
      centralManager.cancelPeripheralConnection(peripheral)
      connectedPeripheral = nil
      promise.resolve()
    } else {
      promise.resolve() // Already disconnected
    }
  }

  // MARK: - CBCentralManagerDelegate Extensions

  func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    connectedPeripheral = peripheral
    lastPrintDoneAt = nil
    peripheral.delegate = self
    peripheral.discoverServices(nil)
  }
  
  func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
    connectPromise?.reject(PrinterException("CONNECTION_FAILED", error?.localizedDescription ?? "Unknown error"))
    connectPromise = nil
  }
  
  func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
    // Si el enlace cae con una escritura en vuelo, rechazar la promesa pendiente en lugar de
    // dejarla colgada para siempre (la impresión vieja truncaba; la nueva, sin esto, colgaría).
    // disconnect() ya puso connectedPeripheral en nil: solo es caída si este era el periférico activo.
    let spontaneous = connectedPeripheral == peripheral
    let printing = writePromise != nil
    failPendingWrite(error?.localizedDescription ?? "Peripheral disconnected during write")
    connectedPeripheral = nil
    if spontaneous {
      let ms: Int? = printing ? 0 : lastPrintDoneAt.map { Int((ProcessInfo.processInfo.systemUptime - $0) * 1000) }
      onConnectionLost?(ms)
    }
  }
  
  // MARK: - CBPeripheralDelegate

  // CoreBluetooth avisa que el periférico vuelve a aceptar writeWithoutResponse.
  func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
    if currentWriteType == .withoutResponse && !pendingChunks.isEmpty {
        sendPendingChunks()
    }
  }

  func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    if let error = error {
        connectPromise?.reject(PrinterException("CONNECTION_FAILED", error.localizedDescription))
        connectPromise = nil
        return
    }
    
    guard let services = peripheral.services else { return }
    
    for service in services {
      peripheral.discoverCharacteristics(nil, for: service)
    }
  }
  
  func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
    if let characteristics = service.characteristics {
      for characteristic in characteristics {
        if characteristic.properties.contains(.write) || characteristic.properties.contains(.writeWithoutResponse) {
          writeCharacteristic = characteristic
          connectPromise?.resolve(nil)
          connectPromise = nil
          return 
        }
      }
    }
  }
}



public class ThermalPrinterModule: Module {
  private let bluetoothManager = BluetoothManager()

  public func definition() -> ModuleDefinition {
    Name("ThermalPrinter")

    // { sent, total } en bytes mientras se envía (ACKs reales de BLE).
    // { msSinceLastPrint: number | null } cuando el enlace cae solo (no por disconnect()).
    Events("onPrintProgress", "onConnectionLost")

    OnCreate {
      self.bluetoothManager.onProgress = { [weak self] sent, total in
        self?.sendEvent("onPrintProgress", ["sent": sent, "total": total])
      }
      self.bluetoothManager.onConnectionLost = { [weak self] ms in
        self?.sendEvent("onConnectionLost", ["msSinceLastPrint": ms])
      }
    }

    AsyncFunction("scanDevices") { (type: String, promise: Promise) in
      bluetoothManager.scanDevices(promise)
    }
    
    AsyncFunction("connect") { (uuid: String, promise: Promise) in
      bluetoothManager.connect(uuid, promise)
    }
    
    AsyncFunction("disconnect") { (promise: Promise) in
      bluetoothManager.disconnect(promise)
    }

    AsyncFunction("print") { (items: [[String: Any]], width: Int, encoding: String, lineSpacing: Int, feedLines: Int, promise: Promise) in
      var bytes: [UInt8] = []

      let resolvedEncoding = PrinterUtils.resolveEncoding(encoding)

      // userfont: impresoras con la fuente ROM vacía (p.ej. SAT AF330 que solo dibuja # $ @ [ \ ] ^ ` { | } ~).
      // Se descarga una fuente propia con ESC & y los caracteres no-ASCII se reasignan a slots libres.
      let userFont = PrinterUtils.normalizeEncoding(encoding) == "userfont"
      let userFontMap = userFont ? PrinterUtils.buildUserFontMap(items) : [:]
      let printItems = userFont ? items.map { PrinterUtils.remapUserFontItem($0, userFontMap) } : items

      // raster: el texto se dibuja como imagen (ESC *); no depende de fuentes ni encodings de la impresora.
      let raster = PrinterUtils.normalizeEncoding(encoding) == "raster" ? RasterText(printerWidth: width, lineSpacing: lineSpacing) : nil

      // Initialize Printer
      bytes.append(contentsOf: [0x1B, 0x40])

      // La AF330 traía el área de impresión en 384 puntos con papel de 80 mm (cortaba a 32 columnas).
      if userFont || raster != nil { bytes.append(contentsOf: PrinterUtils.getPrintAreaCmd(width)) }

      // Set Code Page
      bytes.append(contentsOf: PrinterUtils.getCodePageCmd(encoding))

      if userFont { bytes.append(contentsOf: PrinterUtils.getUserFontCmd(userFontMap)) }

      // Set Line Spacing
      bytes.append(contentsOf: PrinterUtils.getLineSpacingCmd(lineSpacing))

      for item in printItems {
          let type = item["type"] as? String ?? "text"
          let content = item["content"] as? String ?? ""
          let style = item["style"] as? [String: Any] ?? [:]

          let align = style["align"] as? String ?? "left"

          // Raster: el texto (table y two-columns llegan ya como text desde src/layout.ts) se dibuja; QR e imagen siguen nativos.
          if let raster = raster {
              let bold = style["bold"] as? Bool ?? false
              let size = PrinterUtils.resolveSize(style["size"])
              switch type {
              case "text":
                  raster.addText(content, bold: bold, size: size, align: align)
                  continue
              case "divider":
                  let charToUse = (item["charToUse"] as? String) ?? (item["char"] as? String) ?? (item["content"] as? String) ?? "-"
                  let marginVertical = (item["marginVertical"] as? NSNumber)?.intValue ?? 0
                  let maxChars = (width >= 80) ? 48 : ((width >= 58) ? 32 : 24)
                  raster.addFeed(marginVertical)
                  raster.addText(String(repeating: String(charToUse.prefix(1)), count: maxChars), bold: false, size: 0, align: "left")
                  raster.addFeed(marginVertical)
                  continue
              case "feed":
                  raster.addFeed((item["lines"] as? NSNumber)?.intValue ?? 1)
                  continue
              default:
                  bytes.append(contentsOf: raster.flush())
              }
          }

          bytes.append(contentsOf: PrinterUtils.getAlignCmd(align))
          
          switch type {
          case "text":
              let bold = style["bold"] as? Bool ?? false
              bytes.append(contentsOf: PrinterUtils.getBoldCmd(bold))

              let size = PrinterUtils.resolveSize(style["size"])
              bytes.append(contentsOf: PrinterUtils.getTextSizeCmd(size))

              let font = style["font"] as? String ?? "primary"
              bytes.append(contentsOf: PrinterUtils.getFontCmd(font))

              bytes.append(contentsOf: PrinterUtils.stringToBytes(content, encoding: resolvedEncoding))
              bytes.append(0x0A) // LF
              
              // Reset
              bytes.append(contentsOf: PrinterUtils.getBoldCmd(false))
              bytes.append(contentsOf: PrinterUtils.getTextSizeCmd(0))
              bytes.append(contentsOf: PrinterUtils.getFontCmd("primary"))
              
          case "qr":
              let sizeObj = style["size"] ?? item["size"]
              var size = 6
              if let s = sizeObj as? Int { size = s }
              else if let s = sizeObj as? String, let i = Int(s) { size = i }
              
              if size < 1 { size = 1 }
              if size > 16 { size = 16 }
              
              bytes.append(contentsOf: PrinterUtils.getQrCodeCmd(content, size: size))
              bytes.append(0x0A)
              
          case "image":
              var image: UIImage?
              if content.hasPrefix("http") {
                  if let url = URL(string: content), let data = try? Data(contentsOf: url) {
                      image = UIImage(data: data)
                  }
              } else {
                  if let data = Data(base64Encoded: content, options: .ignoreUnknownCharacters) {
                      image = UIImage(data: data)
                  }
              }
              
              if let img = image {
                   // Máximo de puntos del cabezal según el ancho de papel.
                   let printerMaxDots = (width >= 80) ? 576 : ((width >= 58) ? 384 : 288)
                   // Respetar el ancho pedido por la app (style.width), acotado al cabezal.
                   let styleWidth = (style["width"] as? NSNumber)?.intValue
                   let target = min(styleWidth ?? printerMaxDots, printerMaxDots)

                   let rasterBytes = PrinterUtils.bitmapToBytes(img, maxWidth: target)
                   bytes.append(contentsOf: rasterBytes)
                   bytes.append(0x0A)
              }
              
          case "feed":
              let n = (item["lines"] as? NSNumber)?.intValue ?? 1
              bytes.append(contentsOf: PrinterUtils.getFeedLinesCmd(n))

          case "divider":
              // Accept charToUse plus char/content aliases.
              let charToUse = (item["charToUse"] as? String) ?? (item["char"] as? String) ?? (item["content"] as? String) ?? "-"
              let marginVertical = (item["marginVertical"] as? NSNumber)?.intValue ?? 0
              
              if marginVertical > 0 {
                  bytes.append(contentsOf: PrinterUtils.getFeedLinesCmd(marginVertical))
              }
              
              // Calculate divider line
              let maxChars = (width >= 80) ? 48 : ((width >= 58) ? 32 : 24)
              let charStr = String(charToUse.prefix(1))
              let line = String(repeating: charStr, count: maxChars)
              bytes.append(contentsOf: PrinterUtils.stringToBytes(line, encoding: resolvedEncoding))
              bytes.append(0x0A)
              
              if marginVertical > 0 {
                  bytes.append(contentsOf: PrinterUtils.getFeedLinesCmd(marginVertical))
              }
              
          default:
              NSLog("[ThermalPrinter] Unknown item type: \(type)")
          }
          
          // Reset align
          bytes.append(contentsOf: PrinterUtils.getAlignCmd("left"))
      }

      if let raster = raster { bytes.append(contentsOf: raster.flush()) }

      // Feed
      if feedLines > 0 {
          bytes.append(contentsOf: PrinterUtils.getFeedLinesCmd(feedLines))
      }
      
      let data = Data(bytes)
      bluetoothManager.write(data, promise)
    }
  }
}

// Promise.reject(code, description) de Expo deja el mensaje en JS como "undefined reason":
// el texto viaja en `reason`, así que se sobreescribe aquí.
final class PrinterException: Exception {
  private let message: String

  init(_ code: String, _ message: String) {
    self.message = message
    super.init(name: code, description: message, code: code)
  }

  override var reason: String { message }
}
