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
  
  override init() {
    super.init()
    centralManager = CBCentralManager(delegate: self, queue: nil)
  }
  
  func scanDevices(_ promise: Promise) {
    if centralManager.state != .poweredOn {
      promise.reject("BLUETOOTH_OFF", "Bluetooth is not powered on")
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
        promise.reject("NOT_CONNECTED", "Not connected to any printer")
        return
    }
    
    writePromise = promise
    
    let type: CBCharacteristicWriteType = characteristic.properties.contains(.write) ? .withResponse : .withoutResponse
    
    // Chunking might be needed for large data (MTU size), but CoreBluetooth often handles it or we can implement simple chunking.
    // For now, let's try sending all. If it fails, we need to chunk.
    let mtu = peripheral.maximumWriteValueLength(for: type)
    if data.count > mtu {
        // Simple chunking
        var offset = 0
        while offset < data.count {
            let chunkLength = min(mtu, data.count - offset)
            let chunk = data.subdata(in: offset..<offset + chunkLength)
            peripheral.writeValue(chunk, for: characteristic, type: type)
            offset += chunkLength
        }
    } else {
        peripheral.writeValue(data, for: characteristic, type: type)
    }
    
    if type == .withoutResponse {
        promise.resolve(nil)
        writePromise = nil
    }
  }
  
  func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
     if let error = error {
         writePromise?.reject("WRITE_FAILED", error.localizedDescription)
     } else {
         writePromise?.resolve(nil)
     }
     writePromise = nil
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
    guard let peripheral = discoveredPeripherals.first(where: { $0.identifier.uuidString == uuid }) else {
      promise.reject("DEVICE_NOT_FOUND", "Device with UUID \(uuid) not found in scan results")
      return
    }
    
    connectPromise = promise
    centralManager.connect(peripheral, options: nil)
  }
  
  func disconnect(_ promise: Promise) {
    if let peripheral = connectedPeripheral {
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
    connectPromise?.reject("CONNECT_FAILED", error?.localizedDescription ?? "Unknown error")
    connectPromise = nil
  }
  
  func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
    connectedPeripheral = nil
  }
  
  // MARK: - CBPeripheralDelegate
  
  func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    if let error = error {
        connectPromise?.reject("SERVICE_DISCOVERY_FAILED", error.localizedDescription)
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
              
              let size = style["size"] as? Int ?? 0
              bytes.append(contentsOf: PrinterUtils.getTextSizeCmd(size))
              
              let font = style["font"] as? String ?? "primary"
              bytes.append(contentsOf: PrinterUtils.getFontCmd(font))
              
              if let textData = content.data(using: .utf8) { // Simply utf8 for now, ideally handle encoding mapping
                  bytes.append(contentsOf: [UInt8](textData))
              }
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
              
          case "divider":
              let charToUse = item["charToUse"] as? String ?? "-"
              let marginVertical = (item["marginVertical"] as? NSNumber)?.intValue ?? 0
              
              if marginVertical > 0 {
                  bytes.append(contentsOf: PrinterUtils.getFeedLinesCmd(marginVertical))
              }
              
              // Calculate divider line
              let maxChars = (width >= 80) ? 48 : ((width >= 58) ? 32 : 24)
              let charStr = String(charToUse.prefix(1))
              let line = String(repeating: charStr, count: maxChars)
              if let d = line.data(using: .utf8) {
                   bytes.append(contentsOf: [UInt8](d))
              }
              bytes.append(0x0A)
              
              if marginVertical > 0 {
                  bytes.append(contentsOf: PrinterUtils.getFeedLinesCmd(marginVertical))
              }
              
          case "two-columns":
             let contentList = item["content"] as? [String] ?? []
             if contentList.count >= 2 {
                 let left = contentList[0]
                 let right = contentList[1]
                 
                 let bold = style["bold"] as? Bool ?? false
                 bytes.append(contentsOf: PrinterUtils.getBoldCmd(bold))
                  
                 let size = style["size"] as? Int ?? 0
                 bytes.append(contentsOf: PrinterUtils.getTextSizeCmd(size))
                  
                 let font = style["font"] as? String ?? "primary"
                 bytes.append(contentsOf: PrinterUtils.getFontCmd(font))
                 
                 bytes.append(contentsOf: PrinterUtils.getTwoColumnsCmd(left, right, width, .utf8))
                 bytes.append(0x0A)
                 
                 // Reset
                 bytes.append(contentsOf: PrinterUtils.getBoldCmd(false))
                 bytes.append(contentsOf: PrinterUtils.getTextSizeCmd(0))
                 bytes.append(contentsOf: PrinterUtils.getFontCmd("primary"))
             }

          default:
              break
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
