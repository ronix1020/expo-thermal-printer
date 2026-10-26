package expo.modules.thermalprinter

import android.Manifest
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothSocket
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.Base64
import android.os.Build
import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbDeviceConnection
import android.hardware.usb.UsbEndpoint
import android.hardware.usb.UsbInterface
import android.hardware.usb.UsbManager
import android.app.PendingIntent
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import expo.modules.kotlin.Promise
import expo.modules.kotlin.modules.Module
import expo.modules.kotlin.modules.ModuleDefinition
import java.util.ArrayList
import java.util.UUID
import java.util.concurrent.Executors
import java.io.ByteArrayOutputStream
import java.io.IOException

class ThermalPrinterModule : Module() {
    // Transporte activo ("bluetooth" | "usb" | null). Se usa para aplicar el
    // retardo de drenado solo en Bluetooth (ver AsyncFunction("print")).
    @Volatile private var currentConnectionType: String? = null
    private val context: Context
        get() = appContext.reactContext ?: throw IllegalStateException("React Context is null")

    // Transporte propio (antes, el .jar de XPrinter): socket SPP en Bluetooth, bulkTransfer en USB.
    // Todo el I/O pasa por un solo hilo: connect/write/disconnect no se pisan y un envío largo
    // no bloquea la cola de AsyncFunction de Expo, que comparten todos los módulos.
    private val io = Executors.newSingleThreadExecutor()
    @Volatile private var btSocket: BluetoothSocket? = null
    @Volatile private var usbConnection: UsbDeviceConnection? = null
    private var usbInterface: UsbInterface? = null
    private var usbEndpoint: UsbEndpoint? = null

    // print() de Bluetooth esperando el drenado (tick de progreso → promesa). Solo en el hilo principal;
    // si el enlace cae mientras esperan, se rechazan (ver watchLink).
    private val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())
    private val drains = HashMap<Runnable, Promise>()

    companion object {
        // BluetoothSocket.write() vuelve cuando el stack Bluetooth de Android tiene los bytes en
        // su buffer (~1 ms aunque sean 106 KB de raster), NO cuando la impresora los recibió, y
        // flush() no espera más. Si la app llama disconnect() justo después, el socket se cierra
        // antes de drenar y el ticket sale truncado. Esperamos ~ (bytes / DRAIN_BYTES_PER_MS) ms,
        // sin tope, antes de resolver. También es la velocidad de la barra de progreso.
        // Medido 2026-10-26: SAT AF330 + moto g75, raster de 76,553 B impreso en 4.5–5 s → ~16 B/ms.
        // 12 queda ~30% más lento que eso para dar margen a térmicas más lentas. Una sola medición:
        // si una impresora corta el ticket al desconectar justo después de print(), bajar este valor.
        private const val DRAIN_BYTES_PER_MS = 12.0
        private const val PROGRESS_TICK_MS = 200L
        private val SPP_UUID: UUID = UUID.fromString("00001101-0000-1000-8000-00805F9B34FB")
        private const val USB_CHUNK = 16384   // máximo de bulkTransfer antes de API 28
        private const val USB_TIMEOUT_MS = 5000
    }

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

        // { sent, total } en bytes mientras se imprime (en Bluetooth es estimado, ver print).
        Events("onPrintProgress")

        OnDestroy {
            io.execute { closeTransport() }
            io.shutdown()
        }

        AsyncFunction("scanDevices") { type: String, promise: Promise ->
            val bluetoothAdapter = BluetoothAdapter.getDefaultAdapter()
            if (bluetoothAdapter == null) {
                promise.reject("BLUETOOTH_NOT_READY", "Bluetooth not supported", null)
                return@AsyncFunction
            }

            if (!bluetoothAdapter.isEnabled) {
                 promise.reject("BLUETOOTH_NOT_READY", "Bluetooth is disabled", null)
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
            // API 34+ exige declarar la exportación del receiver o lanza SecurityException.
            // Solo escuchamos broadcasts del sistema para este proceso → NOT_EXPORTED.
            ContextCompat.registerReceiver(
                context, bluetoothReceiver, filter, ContextCompat.RECEIVER_NOT_EXPORTED
            )
            
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
            // Fail fast and clearly when Bluetooth isn't ready.
            val adapter = BluetoothAdapter.getDefaultAdapter()
            if (adapter == null || !adapter.isEnabled) {
                promise.reject("BLUETOOTH_NOT_READY", "Bluetooth is not enabled", null)
                return@AsyncFunction
            }

            io.execute {
                try {
                    closeTransport()
                    // Un discovery activo hace muy lento o falla el connect RFCOMM. Sin BLUETOOTH_SCAN lanza SecurityException.
                    runCatching { adapter.cancelDiscovery() }
                    val socket = adapter.getRemoteDevice(macAddress).createRfcommSocketToServiceRecord(SPP_UUID)
                    try {
                        socket.connect()
                    } catch (e: Exception) {
                        runCatching { socket.close() }
                        throw e
                    }
                    btSocket = socket
                    currentConnectionType = "bluetooth"
                    watchLink(socket)
                    promise.resolve(null)
                } catch (e: Exception) {
                    promise.reject("CONNECTION_FAILED", e.message ?: "Failed to connect to printer", e)
                }
            }
        }

        AsyncFunction("connectUsb") { promise: Promise ->
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
                promise.reject("DEVICE_NOT_FOUND", "No USB printer found", null)
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
                // API 34+ exige declarar la exportación del receiver o lanza SecurityException.
                // El PendingIntent es auto-dirigido (mismo proceso) → NOT_EXPORTED.
                ContextCompat.registerReceiver(
                    context, usbReceiver, filter, ContextCompat.RECEIVER_NOT_EXPORTED
                )
                usbManager.requestPermission(printerDevice, permissionIntent)
            } else {
                connectToUsbDevice(printerDevice, promise)
            }
        }

        AsyncFunction("disconnect") { promise: Promise ->
             // En el hilo de I/O: si hay un envío en curso, se cierra después de que termine.
             io.execute {
                 closeTransport()
                 promise.resolve(null)
             }
        }

        AsyncFunction("isConnected") { promise: Promise ->
             // Estado local del transporte: un BluetoothSocket no detecta que la impresora se apagó
             // hasta que falla un write, y entonces print() rechaza y limpia la conexión.
             promise.resolve(when (currentConnectionType) {
                 "bluetooth" -> btSocket?.isConnected == true
                 "usb" -> usbConnection != null
                 else -> false
             })
        }

        AsyncFunction("print") { items: List<Map<String, Any>>, width: Int, encoding: String, lineSpacing: Int, feedLines: Int, promise: Promise ->
            if (currentConnectionType == null) {
                promise.reject("NOT_CONNECTED", "Printer is not connected. Call connect() first.", null)
                return@AsyncFunction
            }

            try {
                val commands = ArrayList<ByteArray>()
                val charsetName = when(normalizeEncoding(encoding)) {
                    "gbk" -> "GBK"
                    "ascii" -> "US-ASCII"
                    "cp1258" -> "windows-1258"
                    "windows-1252" -> "windows-1252"
                    "iso-8859-1" -> "ISO-8859-1"
                    "pc850" -> "IBM850"
                    "userfont" -> "US-ASCII"
                    else -> "UTF-8"
                }
                val charset = java.nio.charset.Charset.forName(charsetName)

                // userfont: impresoras con la fuente ROM vacía (p.ej. SAT AF330 que solo dibuja # $ @ [ \ ] ^ ` { | } ~).
                // Se descarga una fuente propia con ESC & y los caracteres no-ASCII se reasignan a slots libres.
                val userFont = normalizeEncoding(encoding) == "userfont"
                val userFontMap = if (userFont) buildUserFontMap(items) else emptyMap()
                val printItems = if (userFont) items.map { remapUserFontItem(it, userFontMap) } else items

                // raster: el texto se dibuja como imagen (ESC *); no depende de fuentes ni encodings de la impresora.
                val raster = if (normalizeEncoding(encoding) == "raster") RasterText(width, lineSpacing) else null

                // Initialize Printer
                commands.add(byteArrayOf(0x1B, 0x40))

                // La AF330 traía el área de impresión en 384 puntos con papel de 80 mm (cortaba a 32 columnas).
                if (userFont || raster != null) commands.add(getPrintAreaCmd(width))

                // Set Code Page
                commands.add(getCodePageCmd(encoding))

                if (userFont) commands.add(getUserFontCmd(userFontMap))

                // Set Line Spacing
                commands.add(getLineSpacingCmd(lineSpacing))

                for (item in printItems) {
                    val type = item["type"] as? String ?: "text"
                    val content = item["content"] as? String ?: ""
                    val style = item["style"] as? Map<String, Any> ?: emptyMap()
                    
                    // 1. Alignment
                    val align = style["align"] as? String ?: "left"

                    // Raster: se reusa el acomodo en columnas de los helpers de texto y se dibuja; QR e imagen siguen nativos.
                    if (raster != null) {
                        val bold = style["bold"] as? Boolean ?: false
                        val size = resolveSize(style["size"])
                        when (type) {
                            "text" -> { raster.addText(content, bold, size, align); continue }
                            "table" -> {
                                val header = item["tableHeader"] as? List<String> ?: emptyList()
                                val columnWidths = item["columnWidths"] as? List<Number> ?: emptyList()
                                val columnAlignment = item["columnAlignment"] as? List<String> ?: emptyList()
                                val contentList = item["content"] as? List<List<String>> ?: emptyList()
                                if (columnWidths.isNotEmpty()) {
                                    val table = getTableCmd(header, columnWidths, columnAlignment, contentList, width, Charsets.UTF_8)
                                    raster.addText(String(table, Charsets.UTF_8).removeSuffix("\n"), false, 0, "left")
                                }
                                continue
                            }
                            "divider" -> {
                                val charToUse = (item["charToUse"] ?: item["char"] ?: item["content"]) as? String ?: "-"
                                val marginVertical = (item["marginVertical"] as? Number)?.toInt() ?: 0
                                raster.addFeed(marginVertical)
                                raster.addText(String(getDividerCmd(charToUse, width, Charsets.UTF_8), Charsets.UTF_8).removeSuffix("\n"), false, 0, "left")
                                raster.addFeed(marginVertical)
                                continue
                            }
                            "two-columns" -> {
                                val contentList = item["content"] as? List<String>
                                    ?: listOfNotNull(item["left"] as? String, item["right"] as? String)
                                if (contentList.size >= 2) {
                                    val line = getTwoColumnsCmd(contentList[0], contentList[1], width, Charsets.UTF_8, size, "primary")
                                    raster.addText(String(line, Charsets.UTF_8), bold, size, "left")
                                }
                                continue
                            }
                            "feed" -> { raster.addFeed((item["lines"] as? Number)?.toInt() ?: 1); continue }
                            else -> commands.add(raster.flush())
                        }
                    }

                    commands.add(getAlignCmd(align))

                    when (type) {
                        "text" -> {
                            // Bold
                            val bold = style["bold"] as? Boolean ?: false
                            commands.add(getBoldCmd(bold))
                            
                            // Size (numeric byte or semantic string)
                            val size = resolveSize(style["size"])
                            commands.add(getTextSizeCmd(size))
                            
                            // Adjust line spacing if size > 0 (height scaling)
                            // size & 0x0F is height multiplier - 1.
                            // 0 -> 1x, 1 -> 2x, etc.
                            // Base height ~24 dots. 1x=24, 2x=48.
                            // val heightMultiplier = (size and 0x0F) + 1
                            
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
                            // Try to get size from style, then from item root
                            val sizeObj = style["size"] ?: item["size"]
                            var size = when (sizeObj) {
                                is Number -> sizeObj.toInt()
                                is String -> sizeObj.toIntOrNull()
                                else -> null
                            } ?: 6
                            
                            // Clamp size to valid range (1-16) usually
                            size = size.coerceIn(1, 16)

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
                            val columnAlignment = item["columnAlignment"] as? List<String> ?: emptyList()
                            val contentList = item["content"] as? List<List<String>> ?: emptyList()
                            
                            if (columnWidths.isNotEmpty()) {
                                commands.add(getTableCmd(header, columnWidths, columnAlignment, contentList, width, charset))
                            }
                        }
                        "feed" -> {
                            val n = (item["lines"] as? Number)?.toInt() ?: 1
                            commands.add(getFeedLinesCmd(n))
                        }
                        "divider" -> {
                            // Accept charToUse plus char/content aliases.
                            val charToUse = (item["charToUse"] ?: item["char"] ?: item["content"]) as? String ?: "-"
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
                            // Accept canonical content:[l,r] plus left/right aliases.
                            val contentList = item["content"] as? List<String>
                                ?: listOfNotNull(item["left"] as? String, item["right"] as? String)
                            if (contentList.size >= 2) {
                                val leftText = contentList[0]
                                val rightText = contentList[1]

                                // Apply styles
                                val bold = style["bold"] as? Boolean ?: false
                                commands.add(getBoldCmd(bold))

                                val size = resolveSize(style["size"])
                                commands.add(getTextSizeCmd(size))
                                
                                val font = style["font"] as? String ?: "primary"
                                commands.add(getFontCmd(font))
                                
                                commands.add(getTwoColumnsCmd(leftText, rightText, width, charset, size, font))
                                commands.add(byteArrayOf(0x0A))
                                
                                // Reset styles
                                commands.add(getBoldCmd(false))
                                commands.add(getTextSizeCmd(0))
                                commands.add(getFontCmd("primary"))
                            }
                        }
                        else -> {
                            android.util.Log.w("ThermalPrinter", "Unknown item type: $type")
                        }
                    }
                    // Reset align to left
                    commands.add(getAlignCmd("left"))
                }
                
                if (raster != null) commands.add(raster.flush())

                // Reset to default line spacing
                commands.add(byteArrayOf(0x1B, 0x32))
                
                // Feed lines if requested
                if (feedLines > 0) {
                    commands.add(getFeedLinesCmd(feedLines))
                }
                
                val finalData = concatByteArrays(commands)
                logTxDump(finalData, width, encoding, currentConnectionType)
                val txStartedAt = android.os.SystemClock.elapsedRealtime()

                io.execute {
                    val total = finalData.size
                    try {
                        val usb = usbConnection
                        val ep = usbEndpoint
                        if (currentConnectionType == "usb" && usb != null && ep != null) {
                            // bulkTransfer es síncrono con el dispositivo: aquí el progreso es real y no hay que drenar.
                            var offset = 0
                            while (offset < total) {
                                val len = minOf(USB_CHUNK, total - offset)
                                val n = usb.bulkTransfer(ep, finalData, offset, len, USB_TIMEOUT_MS)
                                if (n <= 0) throw IOException("USB bulkTransfer failed ($n)")
                                offset += n
                                sendProgress(offset, total)
                            }
                            logTx("write USB tras ${android.os.SystemClock.elapsedRealtime() - txStartedAt} ms")
                            promise.resolve(null)
                            return@execute
                        }
                        val out = btSocket?.outputStream ?: throw IOException("Printer disconnected")
                        out.write(finalData)
                        out.flush()
                    } catch (e: Exception) {
                        logTx("write falló tras ${android.os.SystemClock.elapsedRealtime() - txStartedAt} ms: ${e.message}")
                        // Socket roto (p.ej. impresora apagada): se cierra para que isConnected() dé false.
                        closeTransport()
                        promise.reject("PRINT_FAILED", e.message ?: "Failed to send data", e)
                        return@execute
                    }
                    logTx("write BT tras ${android.os.SystemClock.elapsedRealtime() - txStartedAt} ms")
                    // En Bluetooth esperamos proporcional al tamaño para que el buffer del stack drene
                    // antes de un disconnect() de la app (ver DRAIN_BYTES_PER_MS). El progreso es ese
                    // mismo estimado: Android no informa cuánto recibió la impresora.
                    val drainMs = (total / DRAIN_BYTES_PER_MS).toLong()
                    val drainStartedAt = android.os.SystemClock.elapsedRealtime()
                    val tick = object : Runnable {
                        override fun run() {
                            val elapsed = android.os.SystemClock.elapsedRealtime() - drainStartedAt
                            if (elapsed >= drainMs) {
                                drains.remove(this)
                                sendProgress(total, total)
                                promise.resolve(null)
                                return
                            }
                            sendProgress((elapsed * DRAIN_BYTES_PER_MS).toInt(), total)
                            mainHandler.postDelayed(this, PROGRESS_TICK_MS)
                        }
                    }
                    mainHandler.post {
                        drains[tick] = promise
                        tick.run()
                    }
                }
            } catch (e: Exception) {
                promise.reject("PRINT_FAILED", e.message, e)
            }
        }
    }

    private fun sendProgress(sent: Int, total: Int) {
        sendEvent("onPrintProgress", mapOf("sent" to sent.coerceAtMost(total), "total" to total))
    }

    /**
     * write() no se entera si la impresora se apaga (el stack ya tiene los bytes), pero read() devuelve -1
     * o lanza cuando cae el enlace. La lib no usa nada de lo que manda la impresora, así que se descarta.
     */
    private fun watchLink(socket: BluetoothSocket) {
        kotlin.concurrent.thread(isDaemon = true, name = "ThermalPrinter-bt-link") {
            val buf = ByteArray(64)
            try {
                while (socket.inputStream.read(buf) >= 0) { }
            } catch (e: Exception) { }
            // Tras OnDestroy el executor ya no acepta tareas: nada que limpiar.
            runCatching {
                io.execute {
                    // Si el socket ya no es el activo, lo cerró disconnect()/connect(): no es una caída.
                    if (btSocket !== socket) return@execute
                    android.util.Log.w(LOG_TAG, "Bluetooth link lost")
                    closeTransport()
                    mainHandler.post {
                        for ((tick, promise) in drains) {
                            mainHandler.removeCallbacks(tick)
                            promise.reject("PRINT_FAILED", "Printer disconnected during print", null)
                        }
                        drains.clear()
                    }
                }
            }
        }
    }

    /** Solo desde el hilo `io`. Cierra lo que haya abierto; nunca lanza. */
    private fun closeTransport() {
        currentConnectionType = null
        btSocket?.let { runCatching { it.close() } }
        btSocket = null
        usbConnection?.let { conn ->
            usbInterface?.let { runCatching { conn.releaseInterface(it) } }
            runCatching { conn.close() }
        }
        usbConnection = null
        usbInterface = null
        usbEndpoint = null
    }

    private fun connectToUsbDevice(device: UsbDevice, promise: Promise?) {
        io.execute {
            try {
                closeTransport()
                // La interfaz de clase impresora primero; si no hay, cualquiera con un endpoint bulk OUT.
                val candidates = (0 until device.interfaceCount).map { device.getInterface(it) }
                    .sortedBy { if (it.interfaceClass == UsbConstants.USB_CLASS_PRINTER) 0 else 1 }
                var intf: UsbInterface? = null
                var endpoint: UsbEndpoint? = null
                for (candidate in candidates) {
                    endpoint = (0 until candidate.endpointCount).map { candidate.getEndpoint(it) }.firstOrNull {
                        it.type == UsbConstants.USB_ENDPOINT_XFER_BULK && it.direction == UsbConstants.USB_DIR_OUT
                    }
                    if (endpoint != null) { intf = candidate; break }
                }
                if (intf == null || endpoint == null) {
                    promise?.reject("CONNECTION_FAILED", "USB printer has no bulk OUT endpoint", null)
                    return@execute
                }
                val usbManager = context.getSystemService(Context.USB_SERVICE) as UsbManager
                val conn = usbManager.openDevice(device)
                if (conn == null) {
                    promise?.reject("CONNECTION_FAILED", "Failed to open USB printer", null)
                    return@execute
                }
                if (!conn.claimInterface(intf, true)) {
                    conn.close()
                    promise?.reject("CONNECTION_FAILED", "Failed to claim USB printer interface", null)
                    return@execute
                }
                usbConnection = conn
                usbInterface = intf
                usbEndpoint = endpoint
                currentConnectionType = "usb"
                promise?.resolve(device.deviceName)
            } catch (e: Exception) {
                promise?.reject("CONNECTION_FAILED", e.message ?: "Failed to connect to USB printer", e)
            }
        }
    }
}

// Helper Functions

private const val LOG_TAG = "ThermalPrinter"

/**
 * Diagnóstico: volcado hex del payload EXACTO que se manda al transporte en `print()`.
 *
 * Apagado por defecto (un ticket lleva datos del cliente y no debe caer en logcat
 * en un build normal). Se activa en el dispositivo, sin recompilar ni cambiar la
 * API, con el gate estándar de Android:
 *
 *     adb shell setprop log.tag.ThermalPrinter VERBOSE
 *     adb logcat -s ThermalPrinter
 *
 * Imprime cabecera (tamaño, CRC32, ancho, encoding, transporte) y líneas de 32
 * bytes con offset, hex y columna ASCII, para comparar byte a byte lo que sale
 * en distintas versiones de la app.
 */
fun logTxDump(data: ByteArray, width: Int, encoding: String, transport: String?) {
    if (!android.util.Log.isLoggable(LOG_TAG, android.util.Log.VERBOSE)) return
    val crc = java.util.zip.CRC32().apply { update(data) }.value
    android.util.Log.v(
        LOG_TAG,
        "TX ${data.size} bytes crc32=%08x width=$width encoding=$encoding transport=$transport".format(crc)
    )
    val perLine = 32
    var offset = 0
    while (offset < data.size) {
        val end = minOf(offset + perLine, data.size)
        val hex = StringBuilder(perLine * 3)
        val ascii = StringBuilder(perLine)
        for (i in offset until end) {
            val b = data[i].toInt() and 0xFF
            hex.append("%02X ".format(b))
            ascii.append(if (b in 0x20..0x7E) b.toChar() else '.')
        }
        android.util.Log.v(LOG_TAG, "%06X  %-96s |%s|".format(offset, hex.toString(), ascii.toString()))
        offset = end
    }
}

/** Traza corta bajo el mismo gate que [logTxDump] (resultado y tiempos del write). */
fun logTx(message: String) {
    if (!android.util.Log.isLoggable(LOG_TAG, android.util.Log.VERBOSE)) return
    android.util.Log.v(LOG_TAG, message)
}

fun getTableCmd(header: List<String>, columnWidths: List<Number>, columnAlignment: List<String>, content: List<List<String>>, printerWidth: Int, charset: java.nio.charset.Charset): ByteArray {
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
    
    // Calculate spacing
    val numColumns = columnWidths.size
    val totalSpacing = if (numColumns > 1) numColumns - 1 else 0
    val availableChars = maxChars - totalSpacing

    // Disambiguate columnWidths:
    //  - If the values sum to <= the paper's char width, treat them as ABSOLUTE
    //    char counts (use as-is, then fit to the available space).
    //  - Otherwise treat them as PERCENTAGES of the available width.
    val requestedSum = columnWidths.sumOf { it.toInt() }
    val colChars = if (requestedSum <= maxChars) {
        columnWidths.map { it.toInt() }.toMutableList()
    } else {
        columnWidths.map { (it.toDouble() / 100.0 * availableChars).toInt() }.toMutableList()
    }

    // Shrink from the last columns if we overflow the available space.
    var total = colChars.sum()
    var idx = colChars.lastIndex
    while (total > availableChars && idx >= 0) {
        val reducible = minOf(colChars[idx], total - availableChars)
        colChars[idx] -= reducible
        total -= reducible
        idx--
    }
    // Adjust last column to fill remaining space due to rounding/absolute slack.
    if (total < availableChars && colChars.isNotEmpty()) {
        colChars[colChars.lastIndex] += (availableChars - total)
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
                val align = if (j < columnAlignment.size) columnAlignment[j] else "left"
                
                // Pad text with spaces based on alignment
                val paddedText = when (align) {
                    "right" -> text.padStart(width)
                    "center" -> {
                        val totalSpaces = width - text.length
                        if (totalSpaces <= 0) text
                        else {
                            val leftSpaces = totalSpaces / 2
                            val rightSpaces = totalSpaces - leftSpaces
                            " ".repeat(leftSpaces) + text + " ".repeat(rightSpaces)
                        }
                    }
                    else -> text.padEnd(width) // left
                }
                
                // Truncate if somehow longer (shouldn't happen with splitText)
                val finalText = if (paddedText.length > width) paddedText.substring(0, width) else paddedText
                
                stream.write(finalText.toByteArray(charset))
                
                // Add spacing if not last column
                if (j < colChars.size - 1) {
                    stream.write(" ".toByteArray(charset))
                }
            }
            stream.write(byteArrayOf(0x0A)) // New line
        }
    }

    // Print Header
    if (header.isNotEmpty()) {
        printRow(header)
    }
    
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
    return if (bold) byteArrayOf(0x1B, 0x45, 0x01) else byteArrayOf(0x1B, 0x45, 0x00)
}

fun getTextSizeCmd(size: Int): ByteArray {
    // GS ! n
    val n = size.coerceIn(0, 255).toByte()
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

/**
 * Convierte un bitmap a comandos ESC/POS usando el modo bit-image `ESC *`
 * (0x1B 0x2A) en bandas de 24 puntos (modo 33, doble densidad).
 *
 * Antes se usaba el raster `GS v 0` (0x1D 0x76 0x30), pero muchas térmicas
 * económicas NO implementan ese comando: el payload del raster caía como TEXTO
 * (basura acentuada CP850) y desincronizaba el flujo -> avance de papel infinito.
 * `ESC *` es el bit-image original, soportado por prácticamente todas las
 * térmicas.
 *
 * La transparencia se aplana sobre BLANCO según el canal alfa: un PNG con fondo
 * transparente antes salía como recuadro negro porque se ignoraba el alfa.
 */
fun bitmapToBytes(bitmap: Bitmap): ByteArray {
    val width = bitmap.width
    val height = bitmap.height
    val stream = ByteArrayOutputStream()

    stream.write(byteArrayOf(0x1B, 0x33, 24)) // interlineado 24 pts (bandas pegadas)

    val nL = width % 256
    val nH = width / 256
    var y = 0
    while (y < height) {
        stream.write(byteArrayOf(0x1B, 0x2A, 33, nL.toByte(), nH.toByte())) // ESC * 33 nL nH
        for (x in 0 until width) {
            for (k in 0 until 3) {
                var slice = 0
                for (b in 0 until 8) {
                    val yy = y + k * 8 + b
                    if (yy < height) {
                        val p = bitmap.getPixel(x, yy)
                        val a = (p ushr 24) and 0xFF
                        // Aplanar sobre blanco: transparente = blanco, no negro.
                        val r = ((p ushr 16) and 0xFF) * a / 255 + (255 - a)
                        val g = ((p ushr 8) and 0xFF) * a / 255 + (255 - a)
                        val bl = (p and 0xFF) * a / 255 + (255 - a)
                        if (0.299 * r + 0.587 * g + 0.114 * bl < 128) {
                            slice = slice or (1 shl (7 - b))
                        }
                    }
                }
                stream.write(slice)
            }
        }
        stream.write(0x0A) // imprime la banda y avanza 24 pts
        y += 24
    }
    stream.write(byteArrayOf(0x1B, 0x32)) // restaura interlineado por defecto
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
    // GS ! n. Lower 4 bits are height, upper 4 bits are width.
    // Width multiplier = (n >> 4) + 1.
    val widthMultiplier = (size shr 4) + 1
    maxChars /= widthMultiplier
    
    val leftLen = leftText.length
    val rightLen = rightText.length
    
    if (leftLen + rightLen >= maxChars) {
        // If they don't fit, just print them with a single space or wrap?
        // Simple approach: Left + Space + Right (will wrap naturally)
        return "$leftText $rightText".toByteArray(charset)
    }
    
    val spaces = maxChars - leftLen - rightLen
    val spaceStr = " ".repeat(spaces)
    
    return "$leftText$spaceStr$rightText".toByteArray(charset)
}

fun getPrintAndFeedCmd(n: Int): ByteArray {
    // ESC J n
    val feed = n.coerceIn(0, 255).toByte()
    return byteArrayOf(0x1B, 0x4A, feed)
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
    val n = when(normalizeEncoding(encoding)) {
        "pc850" -> 0x02
        "windows-1252" -> 0x10 // 16
        "iso-8859-1" -> 0x10 // 16 (Map to 1252)
        "gbk" -> 0x00 // Usually handled by FS &
        else -> 0x00 // Default to PC437 or printer default
    }
    return byteArrayOf(0x1B, 0x74, n.toByte())
}

/** GS L 0 + GS W: área de impresión completa para el ancho de papel (576 puntos en 80 mm, 384 en 58 mm). */
fun getPrintAreaCmd(width: Int): ByteArray {
    val dots = if (width >= 80) 576 else 384
    return byteArrayOf(0x1D, 0x4C, 0x00, 0x00, 0x1D, 0x57, (dots and 0xFF).toByte(), (dots shr 8).toByte())
}

private fun collectStrings(value: Any?, out: StringBuilder) {
    when (value) {
        is String -> out.append(value)
        is Map<*, *> -> value.values.forEach { collectStrings(it, out) }
        is List<*> -> value.forEach { collectStrings(it, out) }
    }
}

/**
 * ESC & solo acepta 0x20-0x7E, así que cada carácter no-ASCII del ticket (á, Ñ, °, ¡...) se asigna a un
 * carácter ASCII que el ticket no usa, y en ese slot se dibuja su glifo. QR e imágenes no usan la fuente.
 */
fun buildUserFontMap(items: List<Map<String, Any>>): Map<Char, Char> {
    val text = StringBuilder()
    items.filter { it["type"] != "qr" && it["type"] != "image" }.forEach { collectStrings(it, text) }
    val used = text.filter { it.code in 0x21..0x7E }.toSet()
    val needed = text.filter { it.code > 0x7E }.toSortedSet()
    val free = (0x7E downTo 0x21).map { it.toChar() }.filter { it !in used }
    return needed.zip(free).toMap()
}

private fun remapUserFontString(s: String, map: Map<Char, Char>): String = buildString {
    for (c in s) {
        append(when {
            c.code <= 0x7E -> c
            else -> map[c]
                // Sin slots libres: se degrada a la letra sin acento.
                ?: java.text.Normalizer.normalize(c.toString(), java.text.Normalizer.Form.NFD).firstOrNull { it.code in 0x20..0x7E }
                ?: '?'
        })
    }
}

@Suppress("UNCHECKED_CAST")
fun remapUserFontItem(item: Map<String, Any>, map: Map<Char, Char>): Map<String, Any> {
    val type = item["type"]
    if (type == "qr" || type == "image") return item
    fun remap(value: Any?): Any? = when (value) {
        is String -> remapUserFontString(value, map)
        is Map<*, *> -> value.mapValues { remap(it.value) }
        is List<*> -> value.map { remap(it) }
        else -> value
    }
    val out = item.mapValues { (k, v) -> if (k == "type" || k == "style") v else remap(v)!! }.toMutableMap()
    // Solo se descarga la fuente A (12x24); con la fuente B los caracteres saldrían en blanco.
    val style = (item["style"] as? Map<String, Any> ?: emptyMap()) + ("font" to "primary")
    out["style"] = style
    return out
}

/** ESC & 3 0x20 0x7E con glifos monoespaciados de 12x24 (fuente A) + ESC % 1 para activarlos. */
fun getUserFontCmd(map: Map<Char, Char>): ByteArray {
    val w = 12
    val h = 24
    val glyphs = HashMap<Int, Char>()
    for (code in 0x20..0x7E) glyphs[code] = code.toChar()
    for ((orig, slot) in map) glyphs[slot.code] = orig
    val bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
    val canvas = android.graphics.Canvas(bmp)
    val paint = android.graphics.Paint().apply {
        typeface = android.graphics.Typeface.MONOSPACE
        textSize = 20f
        isAntiAlias = true
        color = android.graphics.Color.BLACK
    }
    val baseline = h - paint.descent() - 1f
    val out = java.io.ByteArrayOutputStream()
    out.write(byteArrayOf(0x1B, 0x26, 0x03, 0x20, 0x7E))
    for (code in 0x20..0x7E) {
        val ch = glyphs[code].toString()
        bmp.eraseColor(android.graphics.Color.WHITE)
        canvas.drawText(ch, (w - paint.measureText(ch)) / 2f, baseline, paint)
        out.write(w)
        // Columna a columna, 3 bytes de arriba hacia abajo, MSB arriba.
        for (x in 0 until w) for (yb in 0 until 3) {
            var b = 0
            for (bit in 0 until 8) {
                if (android.graphics.Color.red(bmp.getPixel(x, yb * 8 + bit)) < 128) b = b or (0x80 shr bit)
            }
            out.write(b)
        }
    }
    out.write(byteArrayOf(0x1B, 0x25, 0x01))
    return out.toByteArray()
}

/**
 * Acumula líneas de texto y las dibuja en la misma cuadrícula que la fuente A (12x24 por carácter,
 * 48/32/24 columnas), para que tablas y columnas queden igual que en modo texto. flush() las entrega
 * como bit-image ESC * vía bitmapToBytes.
 */
class RasterText(printerWidth: Int, private val lineSpacing: Int) {
    private class Line(val text: String, val bold: Boolean, val size: Int, val align: String)

    private val dots = when { printerWidth >= 80 -> 576; printerWidth >= 58 -> 384; else -> 288 }
    private val cols = dots / 12
    private val lines = ArrayList<Line>()

    fun addText(text: String, bold: Boolean, size: Int, align: String) {
        val perLine = cols / ((size shr 4) + 1)
        for (raw in text.split("\n")) {
            // Igual que la impresora: corta al llegar al ancho.
            if (raw.isEmpty()) lines.add(Line("", bold, size, align))
            else raw.chunked(perLine).forEach { lines.add(Line(it, bold, size, align)) }
        }
    }

    fun addFeed(n: Int) = repeat(n.coerceAtLeast(0)) { lines.add(Line("", false, 0, "left")) }

    private fun lineHeight(line: Line) = 24 * ((line.size and 0x0F) + 1) + (lineSpacing - 24).coerceAtLeast(0)

    fun flush(): ByteArray {
        if (lines.isEmpty()) return ByteArray(0)
        val height = lines.sumOf { lineHeight(it) }
        val bmp = Bitmap.createBitmap(dots, (height + 23) / 24 * 24, Bitmap.Config.ARGB_8888)
        bmp.eraseColor(android.graphics.Color.WHITE)
        val canvas = android.graphics.Canvas(bmp)
        val paint = android.graphics.Paint().apply { isAntiAlias = true; color = android.graphics.Color.BLACK }
        var y = 0
        for (line in lines) {
            val w = (line.size shr 4) + 1
            val h = (line.size and 0x0F) + 1
            // MONOSPACE avanza 0.6 em: textSize 20 da celdas de 12 px; textScaleX estira a lo ancho.
            paint.typeface = android.graphics.Typeface.create(android.graphics.Typeface.MONOSPACE,
                if (line.bold) android.graphics.Typeface.BOLD else android.graphics.Typeface.NORMAL)
            paint.textSize = 20f * h
            paint.textScaleX = w.toFloat() / h
            val lineWidth = line.text.length * 12 * w
            val x = when (line.align) {
                "center" -> (dots - lineWidth) / 2
                "right" -> dots - lineWidth
                else -> 0
            }.coerceAtLeast(0)
            canvas.drawText(line.text, x.toFloat(), y + 24f * h - paint.descent() - h, paint)
            y += lineHeight(line)
        }
        lines.clear()
        return bitmapToBytes(bmp)
    }
}

/**
 * Normalize encoding aliases to a canonical name before charset/code-page
 * selection. Keeps iso8859_1, latin1, utf8, win1252, etc. from silently
 * falling through to UTF-8.
 */
fun normalizeEncoding(encoding: String): String {
    return when (val e = encoding.lowercase().trim()) {
        "utf8" -> "utf-8"
        "iso8859_1", "iso88591", "latin1" -> "iso-8859-1"
        "win1252" -> "windows-1252"
        else -> e
    }
}

/**
 * Resolve a text size from either a raw ESC/POS `GS ! n` byte (Number) or a
 * semantic string. 'small'/'normal' -> 0, 'large' -> double height (0x01),
 * 'xlarge' -> double height + width (0x11).
 */
fun resolveSize(value: Any?): Int {
    return when (value) {
        is Number -> value.toInt()
        is String -> when (value.lowercase().trim()) {
            "small", "normal" -> 0x00
            "large" -> 0x01
            "xlarge" -> 0x11
            else -> value.toIntOrNull() ?: 0
        }
        else -> 0
    }
}
