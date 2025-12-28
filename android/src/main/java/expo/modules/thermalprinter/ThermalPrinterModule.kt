package expo.modules.thermalprinter

import android.Manifest
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.ServiceConnection
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.Base64
import android.os.Build
import android.os.IBinder
import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbManager
import android.app.PendingIntent
import androidx.core.app.ActivityCompat
import expo.modules.kotlin.Promise
import expo.modules.kotlin.modules.Module
import expo.modules.kotlin.modules.ModuleDefinition
import net.posprinter.posprinterface.IMyBinder
import net.posprinter.posprinterface.UiExecute
import net.posprinter.service.PosprinterService
import java.util.ArrayList
import java.io.ByteArrayOutputStream

class ThermalPrinterModule : Module() {
    private var myBinder: IMyBinder? = null
    private var serviceConnection: ServiceConnection? = null
    private val context: Context
        get() = appContext.reactContext ?: throw IllegalStateException("React Context is null")

    // USB
    private val ACTION_USB_PERMISSION = "expo.modules.thermalprinter.USB_PERMISSION"
    private var usbPermissionPromise: Promise? = null
    
    private val usbReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (ACTION_USB_PERMISSION == intent.action) {
                synchronized(this) {
                    val device: UsbDevice? = intent.getParcelableExtra(UsbManager.EXTRA_DEVICE)
                    if (intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)) {
                        device?.let {
                            connectToUsbDevice(it, usbPermissionPromise)
                        }
                    } else {
                        usbPermissionPromise?.reject("PERMISSION_DENIED", "USB permission denied", null)
                    }
                    usbPermissionPromise = null
                    try {
                        context.unregisterReceiver(this)
                    } catch (e: Exception) {
                        // Ignore
                    }
                }
            }
        }
    }

    // Bluetooth Scanning
    private val foundDevices = ArrayList<Map<String, String>>()
    private var scanPromise: Promise? = null
    private var isScanning = false

    private val bluetoothReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val action = intent.action
            if (BluetoothDevice.ACTION_FOUND == action) {
                val device: BluetoothDevice? = intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE)
                device?.let {
                    val name = if (ActivityCompat.checkSelfPermission(context, Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED) {
                         it.name ?: "Unknown"
                    } else {
                        it.name ?: "Unknown" // Fallback or handle permission properly
                    }
                    val address = it.address
                    if (!foundDevices.any { d -> d["macAddress"] == address }) {
                        foundDevices.add(mapOf("name" to name, "macAddress" to address))
                    }
                }
            } else if (BluetoothAdapter.ACTION_DISCOVERY_FINISHED == action) {
                isScanning = false
                scanPromise?.resolve(foundDevices)
                scanPromise = null
                try {
                    context.unregisterReceiver(this)
                } catch (e: Exception) {
                    // Ignore if not registered
                }
            }
        }
    }

    override fun definition() = ModuleDefinition {
        Name("ThermalPrinter")

        OnCreate {
            val intent = Intent(context, PosprinterService::class.java)
            serviceConnection = object : ServiceConnection {
                override fun onServiceConnected(name: ComponentName?, service: IBinder?) {
                    myBinder = service as? IMyBinder
                }
                override fun onServiceDisconnected(name: ComponentName?) {
                    myBinder = null
                }
            }
            context.bindService(intent, serviceConnection!!, Context.BIND_AUTO_CREATE)
        }

        OnDestroy {
            serviceConnection?.let {
                context.unbindService(it)
            }
        }

        AsyncFunction("scanDevices") { type: String, promise: Promise ->
            val bluetoothAdapter = BluetoothAdapter.getDefaultAdapter()
            if (bluetoothAdapter == null) {
                promise.reject("NO_BLUETOOTH", "Bluetooth not supported", null)
                return@AsyncFunction
            }

            if (!bluetoothAdapter.isEnabled) {
                 promise.reject("BLUETOOTH_DISABLED", "Bluetooth is disabled", null)
                 return@AsyncFunction
            }

            // Simple permission check (module should handle requests efficiently or assume requester did it)
            // ideally we request permissions here if needed or assume App.tsx did it.

            if (isScanning) {
                promise.reject("ALREADY_SCANNING", "Scan already in progress", null)
                return@AsyncFunction
            }

            foundDevices.clear()
            // Add paired devices first
            if (ActivityCompat.checkSelfPermission(context, Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED) {
                bluetoothAdapter.bondedDevices.forEach { device ->
                     foundDevices.add(mapOf("name" to (device.name ?: "Unknown"), "macAddress" to device.address))
                }
            }

            if (type == "paired") {
                promise.resolve(foundDevices)
                return@AsyncFunction
            }
            
            scanPromise = promise
            isScanning = true
            
            val filter = IntentFilter(BluetoothDevice.ACTION_FOUND)
            filter.addAction(BluetoothAdapter.ACTION_DISCOVERY_FINISHED)
            context.registerReceiver(bluetoothReceiver, filter)
            
            if (ActivityCompat.checkSelfPermission(context, Manifest.permission.BLUETOOTH_SCAN) == PackageManager.PERMISSION_GRANTED) {
                 bluetoothAdapter.startDiscovery()
            } else {
                // If we don't have scan permission, just return paired devices
                context.unregisterReceiver(bluetoothReceiver)
                isScanning = false
                scanPromise = null
                promise.resolve(foundDevices)
            }
        }

        AsyncFunction("connect") { macAddress: String, promise: Promise ->
            if (myBinder == null) {
                promise.reject("SERVICE_NOT_BOUND", "Service not bound", null)
                return@AsyncFunction
            }
            
            myBinder?.connectBtPort(macAddress, object : UiExecute {
                override fun onsucess() { // Assuming method name based on typos common in these SDKs or standard naming
                     promise.resolve(null)
                }
                override fun onfailed() {
                     promise.reject("CONNECTION_FAILED", "Failed to connect to printer", null)
                }
            })
        }

        AsyncFunction("connectUsb") { promise: Promise ->
            if (myBinder == null) {
                promise.reject("SERVICE_NOT_BOUND", "Service not bound", null)
                return@AsyncFunction
            }

            val usbManager = context.getSystemService(Context.USB_SERVICE) as UsbManager
            val deviceList = usbManager.deviceList
            
            // Find first printer device
            val printerDevice = deviceList.values.find { device ->
                var isPrinter = device.deviceClass == UsbConstants.USB_CLASS_PRINTER
                if (!isPrinter) {
                    for (i in 0 until device.interfaceCount) {
                        if (device.getInterface(i).interfaceClass == UsbConstants.USB_CLASS_PRINTER) {
                            isPrinter = true
                            break
                        }
                    }
                }
                isPrinter
            }

            if (printerDevice == null) {
                promise.reject("NO_PRINTER_FOUND", "No USB printer found", null)
                return@AsyncFunction
            }

            if (!usbManager.hasPermission(printerDevice)) {
                usbPermissionPromise = promise
                val permissionIntent = PendingIntent.getBroadcast(
                    context, 
                    0, 
                    Intent(ACTION_USB_PERMISSION), 
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT else PendingIntent.FLAG_UPDATE_CURRENT
                )
                val filter = IntentFilter(ACTION_USB_PERMISSION)
                context.registerReceiver(usbReceiver, filter)
                usbManager.requestPermission(printerDevice, permissionIntent)
            } else {
                connectToUsbDevice(printerDevice, promise)
            }
        }

        AsyncFunction("disconnect") { promise: Promise ->
             if (myBinder == null) {
                 promise.resolve(null)
                 return@AsyncFunction
             }
             myBinder?.disconnectCurrentPort(object : UiExecute {
                 override fun onsucess() {
                     promise.resolve(null)
                 }
                 override fun onfailed() {
                     promise.reject("DISCONNECT_FAILED", "Failed to disconnect", null)
                 }
             })
        }

        AsyncFunction("isConnected") { promise: Promise ->
             // Implementation depends on SDK checking method, user mentioned checkLinkedState
             // checkLinkedState(UiExecute var1)
             // This might be async too.
             myBinder?.checkLinkedState(object: UiExecute {
                 override fun onsucess() {
                     promise.resolve(true)
                 }
                 override fun onfailed() {
                     promise.resolve(false)
                 }
             })
        }

        AsyncFunction("print") { items: List<Map<String, Any>>, width: Int, encoding: String, lineSpacing: Int, feedLines: Int, promise: Promise ->
            if (myBinder == null) {
                promise.reject("SERVICE_NOT_BOUND", "Service not bound", null)
                return@AsyncFunction
            }

            try {
                val commands = ArrayList<ByteArray>()
                val charsetName = when(encoding.lowercase()) {
                    "gbk" -> "GBK"
                    "ascii" -> "US-ASCII"
                    "cp1258" -> "windows-1258"
                    "windows-1252" -> "windows-1252"
                    "iso-8859-1" -> "ISO-8859-1"
                    "pc850" -> "IBM850"
                    else -> "UTF-8"
                }
                val charset = java.nio.charset.Charset.forName(charsetName)

                // Initialize Printer
                commands.add(byteArrayOf(0x1B, 0x40)) 

                // Set Code Page
                commands.add(getCodePageCmd(encoding))

                // Set Line Spacing
                commands.add(getLineSpacingCmd(lineSpacing))

                for (item in items) {
                    val type = item["type"] as? String ?: "text"
                    val content = item["content"] as? String ?: ""
                    val style = item["style"] as? Map<String, Any> ?: emptyMap()
                    
                    // 1. Alignment
                    val align = style["align"] as? String ?: "left"
                    commands.add(getAlignCmd(align))

                    when (type) {
                        "text" -> {
                            // Bold
                            val bold = style["bold"] as? Boolean ?: false
                            commands.add(getBoldCmd(bold))
                            
                            // Size
                            val size = (style["size"] as? Number)?.toInt() ?: 0
                            commands.add(getTextSizeCmd(size))
                            
                            // Font
                            val font = style["font"] as? String ?: "primary"
                            commands.add(getFontCmd(font))
                            
                            commands.add(content.toByteArray(charset))
                            commands.add(byteArrayOf(0x0A)) // Line feed
                            
                            // Reset styles
                            commands.add(getBoldCmd(false))
                            commands.add(getTextSizeCmd(0))
                            commands.add(getFontCmd("primary"))
                        }
                        "qr" -> {
                            val size = (style["size"] as? Number)?.toInt() ?: 6
                            commands.add(getQrCodeCmd(content, size))
                            commands.add(byteArrayOf(0x0A))
                        }
                        "image" -> {
                            try {
                                var bitmap: Bitmap? = null
                                if (content.startsWith("http://") || content.startsWith("https://")) {
                                    val url = java.net.URL(content)
                                    val connection = url.openConnection() as java.net.HttpURLConnection
                                    connection.doInput = true
                                    connection.connect()
                                    val responseCode = connection.responseCode
                                    if (responseCode == java.net.HttpURLConnection.HTTP_OK) {
                                        val input = connection.inputStream
                                        bitmap = BitmapFactory.decodeStream(input)
                                    } else {
                                        android.util.Log.e("ThermalPrinter", "Failed to download image. Response code: $responseCode")
                                    }
                                } else {
                                    val decodedString = Base64.decode(content, Base64.DEFAULT)
                                    bitmap = BitmapFactory.decodeByteArray(decodedString, 0, decodedString.size)
                                }

                                if (bitmap != null) {
                                    val styleWidth = (style["width"] as? Number)?.toInt()
                                    val styleHeight = (style["height"] as? Number)?.toInt()
                                    
                                    // Determine max dots based on printer width (mm)
                                    val printerMaxDots = when {
                                        width >= 80 -> 576
                                        width >= 58 -> 384
                                        else -> 288
                                    }

                                    var finalBitmap = bitmap
                                    
                                    if (styleWidth != null || styleHeight != null) {
                                        // User defined size
                                        val w = styleWidth ?: (bitmap.width * (styleHeight!!.toFloat() / bitmap.height)).toInt()
                                        val h = styleHeight ?: (bitmap.height * (styleWidth!!.toFloat() / bitmap.width)).toInt()
                                        finalBitmap = Bitmap.createScaledBitmap(bitmap, w, h, true)
                                    } else {
                                        // Default: Scale to fit printer width (only if larger)
                                        finalBitmap = scaleBitmap(bitmap, printerMaxDots)
                                    }
                                    
                                    commands.add(bitmapToBytes(finalBitmap))
                                    commands.add(byteArrayOf(0x0A))
                                } else {
                                    android.util.Log.e("ThermalPrinter", "Bitmap is null after decoding")
                                }
                            } catch (e: Exception) {
                                e.printStackTrace()
                                android.util.Log.e("ThermalPrinter", "Error processing image: ${e.message}")
                            }
                        }
                        "table" -> {
                            val header = item["tableHeader"] as? List<String> ?: emptyList()
                            val columnWidths = item["columnWidths"] as? List<Number> ?: emptyList()
                            val contentList = item["content"] as? List<List<String>> ?: emptyList()
                            
                            if (header.isNotEmpty() && columnWidths.isNotEmpty()) {
                                commands.add(getTableCmd(header, columnWidths, contentList, width, charset))
                            }
                        }
                        "divider" -> {
                            val charToUse = item["charToUse"] as? String ?: "-"
                            val marginVertical = (item["marginVertical"] as? Number)?.toInt() ?: 0
                            
                            if (marginVertical > 0) {
                                commands.add(getFeedLinesCmd(marginVertical))
                            }
                            
                            commands.add(getDividerCmd(charToUse, width, charset))
                            
                            if (marginVertical > 0) {
                                commands.add(getFeedLinesCmd(marginVertical))
                            }
                        }
                        "two-columns" -> {
                            val contentList = item["content"] as? List<String> ?: emptyList()
                            if (contentList.size >= 2) {
                                val leftText = contentList[0]
                                val rightText = contentList[1]
                                
                                // Apply styles
                                val bold = style["bold"] as? Boolean ?: false
                                commands.add(getBoldCmd(bold))
                                
                                val size = (style["size"] as? Number)?.toInt() ?: 0
                                commands.add(getTextSizeCmd(size))
                                
                                val font = style["font"] as? String ?: "primary"
                                commands.add(getFontCmd(font))
                                
                                commands.add(getTwoColumnsCmd(leftText, rightText, width, charset, size, font))
                                
                                // Reset styles
                                commands.add(getBoldCmd(false))
                                commands.add(getTextSizeCmd(0))
                                commands.add(getFontCmd("primary"))
                            }
                        }
                    }
                    // Reset align to left
                    commands.add(getAlignCmd("left"))
                }
                
                // Reset to default line spacing
                commands.add(byteArrayOf(0x1B, 0x32))
                
                // Feed lines if requested
                if (feedLines > 0) {
                    commands.add(getFeedLinesCmd(feedLines))
                }
                
                val finalData = concatByteArrays(commands)
                
                myBinder?.write(finalData, object : UiExecute {
                     override fun onsucess() {
                         promise.resolve(null)
                     }
                     override fun onfailed() {
                         promise.reject("PRINT_FAILED", "Failed to send data", null)
                     }
                })
            } catch (e: Exception) {
                promise.reject("PRINT_ERROR", e.message, e)
            }
        }
    }

    private fun connectToUsbDevice(device: UsbDevice, promise: Promise?) {
        try {
            myBinder?.connectUsbPort(context, device.deviceName, object : UiExecute {
                override fun onsucess() {
                    promise?.resolve(device.deviceName)
                }

                override fun onfailed() {
                    promise?.reject("CONNECTION_FAILED", "Failed to connect to USB printer", null)
                }
            })
        } catch (e: Exception) {
            promise?.reject("ERROR", e.message, e)
        }
    }
}

// Helper Functions

fun getTableCmd(header: List<String>, columnWidths: List<Number>, content: List<List<String>>, printerWidth: Int, charset: java.nio.charset.Charset): ByteArray {
    val stream = ByteArrayOutputStream()
    
    // Calculate max chars per line
    // 58mm (384 dots) -> ~32 chars (Font A 12x24)
    // 80mm (576 dots) -> ~48 chars (Font A 12x24)
    // 48mm (288 dots) -> ~24 chars (Font A 12x24)
    val maxChars = when {
        printerWidth >= 80 -> 48
        printerWidth >= 58 -> 32
        else -> 24
    }
    
    // Calculate column widths in chars
    val colChars = columnWidths.map { (it.toDouble() / 100.0 * maxChars).toInt() }.toMutableList()
    
    // Adjust last column to fill remaining space due to rounding
    val currentTotal = colChars.sum()
    if (currentTotal < maxChars && colChars.isNotEmpty()) {
        colChars[colChars.lastIndex] += (maxChars - currentTotal)
    }

    // Helper to print a row
    fun printRow(row: List<String>) {
        // We need to handle wrapping. A row might span multiple lines.
        // Split each cell into lines based on col width
        val cellLines = row.mapIndexed { index, text ->
            val width = if (index < colChars.size) colChars[index] else 0
            if (width > 0) splitText(text, width) else listOf("")
        }
        
        // Find max lines in this row
        val maxLines = cellLines.maxOfOrNull { it.size } ?: 0
        
        for (i in 0 until maxLines) {
            for (j in 0 until colChars.size) {
                val width = colChars[j]
                val lines = if (j < cellLines.size) cellLines[j] else emptyList()
                val text = if (i < lines.size) lines[i] else ""
                
                // Pad text with spaces
                val paddedText = text.padEnd(width)
                // Truncate if somehow longer (shouldn't happen with splitText)
                val finalText = if (paddedText.length > width) paddedText.substring(0, width) else paddedText
                
                stream.write(finalText.toByteArray(charset))
            }
            stream.write(byteArrayOf(0x0A)) // New line
        }
    }

    // Print Header
    printRow(header)
    
    // Print Content
    for (row in content) {
        printRow(row)
    }
    
    return stream.toByteArray()
}

fun splitText(text: String, width: Int): List<String> {
    val result = ArrayList<String>()
    var current = text
    while (current.length > width) {
        result.add(current.substring(0, width))
        current = current.substring(width)
    }
    if (current.isNotEmpty()) {
        result.add(current)
    }
    return result
}

fun getFeedLinesCmd(n: Int): ByteArray {
    // ESC d n
    val lines = n.coerceIn(0, 255).toByte()
    return byteArrayOf(0x1B, 0x64, lines)
}

fun getLineSpacingCmd(n: Int): ByteArray {
    // ESC 3 n
    val spacing = n.coerceIn(0, 255).toByte()
    return byteArrayOf(0x1B, 0x33, spacing)
}

fun getAlignCmd(align: String): ByteArray {
    return when (align.lowercase()) {
        "center" -> byteArrayOf(0x1B, 0x61, 0x01)
        "right" -> byteArrayOf(0x1B, 0x61, 0x02)
        else -> byteArrayOf(0x1B, 0x61, 0x00) // Left
    }
}

fun getBoldCmd(bold: Boolean): ByteArray {
    // ESC E n (Emphasized) + ESC G n (Double-strike)
    // Using both ensures bold appearance on more printers
    val n = if (bold) 0x01.toByte() else 0x00.toByte()
    return byteArrayOf(0x1B, 0x45, n, 0x1B, 0x47, n)
}

fun getTextSizeCmd(size: Int): ByteArray {
    // GS ! n
    // If size is small (0-7), assume proportional scaling (width = height)
    // size 0 = 1x, size 1 = 2x, etc.
    // Byte construction: (size << 4) | size
    // If size > 7, assume user provided specific byte (advanced usage)
    val n = if (size in 0..7) {
        ((size shl 4) or size).toByte()
    } else {
        size.toByte()
    }
    return byteArrayOf(0x1D, 0x21, n)
}

fun concatByteArrays(arrays: List<ByteArray>): ByteArray {
    val outputStream = ByteArrayOutputStream()
    for (array in arrays) {
        outputStream.write(array)
    }
    return outputStream.toByteArray()
}

fun getQrCodeCmd(text: String, size: Int): ByteArray {
    val stream = ByteArrayOutputStream()
    try {
        val textBytes = text.toByteArray(Charsets.UTF_8)
        val len = textBytes.size + 3
        val pL = (len % 256).toByte()
        val pH = (len / 256).toByte()

        // Model
        stream.write(byteArrayOf(0x1D, 0x28, 0x6B, 0x04, 0x00, 0x31, 0x41, 0x32, 0x00))
        // Size
        stream.write(byteArrayOf(0x1D, 0x28, 0x6B, 0x03, 0x00, 0x31, 0x43, size.toByte()))
        // Error Correction
        stream.write(byteArrayOf(0x1D, 0x28, 0x6B, 0x03, 0x00, 0x31, 0x45, 0x30))
        // Store Data
        stream.write(byteArrayOf(0x1D, 0x28, 0x6B, pL, pH, 0x31, 0x50, 0x30))
        stream.write(textBytes)
        // Print
        stream.write(byteArrayOf(0x1D, 0x28, 0x6B, 0x03, 0x00, 0x31, 0x51, 0x30))
    } catch (e: Exception) {
        e.printStackTrace()
    }
    return stream.toByteArray()
}

fun scaleBitmap(bitmap: Bitmap, maxWidth: Int): Bitmap {
    val width = bitmap.width
    val height = bitmap.height
    if (width <= maxWidth) return bitmap
    
    val ratio = maxWidth.toFloat() / width
    val newHeight = (height * ratio).toInt()
    return Bitmap.createScaledBitmap(bitmap, maxWidth, newHeight, true)
}

fun bitmapToBytes(bitmap: Bitmap): ByteArray {
    val width = bitmap.width
    val height = bitmap.height
    val stream = ByteArrayOutputStream()
    
    // ESC/POS Raster Bit Image command: GS v 0 m xL xH yL yH d1...dk
    stream.write(byteArrayOf(0x1D, 0x76, 0x30, 0x00))
    
    val bytesWidth = (width + 7) / 8
    stream.write(bytesWidth % 256)
    stream.write(bytesWidth / 256)
    stream.write(height % 256)
    stream.write(height / 256)
    
    for (y in 0 until height) {
        for (x in 0 until bytesWidth) {
            var byteVal = 0
            for (b in 0 until 8) {
                val px = x * 8 + b
                if (px < width) {
                    val pixel = bitmap.getPixel(px, y)
                    // Check if pixel is dark (simple threshold)
                    val r = (pixel shr 16) and 0xFF
                    val g = (pixel shr 8) and 0xFF
                    val b = pixel and 0xFF
                    val brightness = (0.299 * r + 0.587 * g + 0.114 * b)
                    if (brightness < 128) {
                        byteVal = byteVal or (1 shl (7 - b))
                    }
                }
            }
            stream.write(byteVal)
        }
    }
    return stream.toByteArray()
}

fun getDividerCmd(charToUse: String, printerWidth: Int, charset: java.nio.charset.Charset): ByteArray {
    val maxChars = when {
        printerWidth >= 80 -> 48
        printerWidth >= 58 -> 32
        else -> 24
    }
    val char = if (charToUse.isNotEmpty()) charToUse[0] else '-'
    val line = char.toString().repeat(maxChars)
    return (line + "\n").toByteArray(charset)
}

fun getTwoColumnsCmd(leftText: String, rightText: String, printerWidth: Int, charset: java.nio.charset.Charset, size: Int, font: String): ByteArray {
    // Calculate max chars based on width, font and size
    // Base chars for Font A (12x24)
    var maxChars = when {
        printerWidth >= 80 -> 48
        printerWidth >= 58 -> 32
        else -> 24
    }
    
    // Adjust for Font B (9x17) - approx 42 chars for 58mm
    if (font == "secondary") {
        maxChars = when {
            printerWidth >= 80 -> 64
            printerWidth >= 58 -> 42
            else -> 32
        }
    }
    
    // Adjust for Size (Width scaling)
    // If size is 0-7, we assume proportional scaling (width = height = size + 1)
    // If size > 7, we assume it's a raw byte, so width multiplier is (size >> 4) + 1
    val widthMultiplier = if (size in 0..7) {
        size + 1
    } else {
        (size shr 4) + 1
    }
    
    maxChars /= widthMultiplier
    
    val leftLen = leftText.length
    val rightLen = rightText.length
    
    if (leftLen + rightLen >= maxChars) {
        // If they don't fit, just print them with a single space or wrap?
        // Simple approach: Left + Space + Right (will wrap naturally)
        return "$leftText $rightText\n".toByteArray(charset)
    }
    
    val spaces = maxChars - leftLen - rightLen
    val spaceStr = " ".repeat(spaces)
    
    return "$leftText$spaceStr$rightText\n".toByteArray(charset)
}

fun getFontCmd(font: String): ByteArray {
    // ESC M n
    // n = 0, 48: Font A (12x24) -> primary
    // n = 1, 49: Font B (9x17) -> secondary
    return if (font == "secondary") byteArrayOf(0x1B, 0x4D, 0x01) else byteArrayOf(0x1B, 0x4D, 0x00)
}

fun getCodePageCmd(encoding: String): ByteArray {
    // ESC t n
    // Common mappings:
    // 0: PC437 (USA)
    // 2: PC850 (Multilingual)
    // 16: WPC1252
    // 255: Space Page (Empty)
    val n = when(encoding.lowercase()) {
        "pc850" -> 0x02
        "windows-1252" -> 0x10 // 16
        "iso-8859-1" -> 0x10 // 16 (Map to 1252)
        "gbk" -> 0x00 // Usually handled by FS &
        else -> 0x00 // Default to PC437 or printer default
    }
    return byteArrayOf(0x1B, 0x74, n.toByte())
}
