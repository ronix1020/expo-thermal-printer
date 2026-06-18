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

  override init() {
    super.init()
    centralManager = CBCentralManager(delegate: self, queue: nil)
  }
  
  func scanDevices(_ promise: Promise) {
    if centralManager.state != .poweredOn {
      promise.reject("BLUETOOTH_NOT_READY", "Bluetooth is not powered on")
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
        promise.reject("SERVICE_NOT_BOUND", "Not connected to any printer")
        return
    }

    // Evitar solapar impresiones: una escritura previa puede seguir en vuelo (esperando un
    // ACK o peripheralIsReady). Sobrescribir writePromise/pendingChunks colgaría la primera
    // promesa y mezclaría los chunks de ambos payloads.
    guard writePromise == nil else {
        promise.reject("ALREADY_PRINTING", "A previous print is still in progress")
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

    sendPendingChunks()
  }

  // Envía los chunks pendientes respetando el control de flujo de CoreBluetooth.
  private func sendPendingChunks() {
    guard let peripheral = connectedPeripheral, let characteristic = writeCharacteristic else {
        writePromise?.reject("SERVICE_NOT_BOUND", "Not connected to any printer")
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
        }
        writePromise?.resolve(nil)   // todos los chunks despachados
        writePromise = nil
    } else {
        // .withResponse: enviar uno y esperar el ACK (didWriteValueFor) para el siguiente.
        guard !pendingChunks.isEmpty else {
            writePromise?.resolve(nil)
            writePromise = nil
            return
        }
        let chunk = pendingChunks.removeFirst()
        peripheral.writeValue(chunk, for: characteristic, type: .withResponse)
    }
  }
  
  func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
     if let error = error {
         writePromise?.reject("PRINT_FAILED", error.localizedDescription)
         writePromise = nil
         pendingChunks.removeAll()
         return
     }
     // ACK de un chunk .withResponse: enviar el siguiente o resolver al terminar.
     if currentWriteType == .withResponse {
         if pendingChunks.isEmpty {
             writePromise?.resolve(nil)
             writePromise = nil
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
        promise.reject("DEVICE_NOT_FOUND", "Device with UUID \(uuid) not found in scan results")
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
        promise.reject("BLUETOOTH_NOT_READY", "Bluetooth is not ready")
      }
    default:
      promise.reject("BLUETOOTH_NOT_READY", "Bluetooth is not powered on")
    }
  }
  
  // Rechaza cualquier escritura en vuelo y limpia el estado para que la promesa de JS nunca
  // quede colgada: tras una desconexión no llegarán ni el ACK (.withResponse) ni
  // peripheralIsReady (.withoutResponse) que reanudarían sendPendingChunks().
  private func failPendingWrite(_ reason: String) {
    if writePromise != nil {
        writePromise?.reject("PRINT_FAILED", reason)
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
    peripheral.delegate = self
    peripheral.discoverServices(nil)
  }
  
  func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
    connectPromise?.reject("CONNECTION_FAILED", error?.localizedDescription ?? "Unknown error")
    connectPromise = nil
  }
  
  func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
    // Si el enlace cae con una escritura en vuelo, rechazar la promesa pendiente en lugar de
    // dejarla colgada para siempre (la impresión vieja truncaba; la nueva, sin esto, colgaría).
    failPendingWrite(error?.localizedDescription ?? "Peripheral disconnected during write")
    connectedPeripheral = nil
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
        connectPromise?.reject("CONNECTION_FAILED", error.localizedDescription)
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

      // Initialize Printer
      bytes.append(contentsOf: [0x1B, 0x40])

      // Set Code Page
      bytes.append(contentsOf: PrinterUtils.getCodePageCmd(encoding))

      // Set Line Spacing
      bytes.append(contentsOf: PrinterUtils.getLineSpacingCmd(lineSpacing))
      
      for item in items {
          let type = item["type"] as? String ?? "text"
          let content = item["content"] as? String ?? ""
          let style = item["style"] as? [String: Any] ?? [:]
          
          let align = style["align"] as? String ?? "left"
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
                   // Max dots
                   let printerMaxDots = (width >= 80) ? 576 : ((width >= 58) ? 384 : 288)
                   
                   let rasterBytes = PrinterUtils.bitmapToBytes(img, maxWidth: printerMaxDots)
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
              
          case "table":
              let header = item["tableHeader"] as? [String] ?? []
              let columnWidths = item["columnWidths"] as? [NSNumber] ?? []
              let columnAlignment = item["columnAlignment"] as? [String] ?? []
              let contentList = item["content"] as? [[String]] ?? []

              if !columnWidths.isEmpty {
                  let tableBytes = PrinterUtils.getTableCmd(
                      header: header,
                      columnWidths: columnWidths,
                      columnAlignment: columnAlignment,
                      content: contentList,
                      printerWidth: width,
                      encoding: resolvedEncoding
                  )
                  bytes.append(contentsOf: tableBytes)
              }

          case "two-columns":
             // Accept canonical content:[l,r] plus left/right aliases.
             let contentList = (item["content"] as? [String]) ?? [item["left"] as? String, item["right"] as? String].compactMap { $0 }
             if contentList.count >= 2 {
                 let left = contentList[0]
                 let right = contentList[1]

                 let bold = style["bold"] as? Bool ?? false
                 bytes.append(contentsOf: PrinterUtils.getBoldCmd(bold))

                 let size = PrinterUtils.resolveSize(style["size"])
                 bytes.append(contentsOf: PrinterUtils.getTextSizeCmd(size))

                 let font = style["font"] as? String ?? "primary"
                 bytes.append(contentsOf: PrinterUtils.getFontCmd(font))

                 bytes.append(contentsOf: PrinterUtils.getTwoColumnsCmd(left, right, width, resolvedEncoding, size, font))
                 bytes.append(0x0A)

                 // Reset
                 bytes.append(contentsOf: PrinterUtils.getBoldCmd(false))
                 bytes.append(contentsOf: PrinterUtils.getTextSizeCmd(0))
                 bytes.append(contentsOf: PrinterUtils.getFontCmd("primary"))
             }

          default:
              NSLog("[ThermalPrinter] Unknown item type: \(type)")
          }
          
          // Reset align
          bytes.append(contentsOf: PrinterUtils.getAlignCmd("left"))
      }
      
      // Feed
      if feedLines > 0 {
          bytes.append(contentsOf: PrinterUtils.getFeedLinesCmd(feedLines))
      }
      
      let data = Data(bytes)
      bluetoothManager.write(data, promise)
    }
  }
}
