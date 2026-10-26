# Changelog

## 1.7.0

- Android: se elimina el SDK propietario de XPrinter (`posprinterconnectandsendsdk.jar`).
  Ya no hay que copiarlo a `android/libs` ni mantener el `postinstall` que lo hacía;
  las apps pueden quitarlo, junto con cualquier regla ProGuard de `PosprinterService`.
- Android: transporte propio. Bluetooth con un `BluetoothSocket` SPP; USB con
  `UsbManager` y `bulkTransfer`. Cualquier impresora USB con interfaz de impresora
  o endpoint bulk OUT conecta: el SDK solo aceptaba 8 fabricantes.
- Android: los errores de conexión y envío llegan a la promesa con el mensaje del
  sistema, y no hay más `NullPointerException` no atrapables en hilos del SDK. Si un
  envío falla, se cierra la conexión e `isConnected()` devuelve `false`.
- Android: en USB, `onPrintProgress` es real (por bloque de `bulkTransfer`). En
  Bluetooth sigue la espera estimada: `write()` vuelve en cuanto el stack de Android
  tiene los bytes en buffer, igual que con el SDK.
- Android/Bluetooth: si la impresora se apaga o se pierde el enlace mientras `print()`
  espera el drenado, la promesa rechaza con `PRINT_FAILED` ("Printer disconnected
  during print"), el progreso se detiene e `isConnected()` devuelve `false`. Antes
  `print()` resolvía igual, porque `write()` no se entera.
- `disconnect()` ya no rechaza con `DISCONNECT_FAILED`; siempre resuelve.
- La API JS no cambia.

## 1.6.0

- Nuevo encoding opt-in `userfont` (Android e iOS) para impresoras con la fuente
  ROM vacía (caso SAT AF330). Descarga una fuente 12x24 con `ESC &`, reasigna
  los caracteres no-ASCII a slots ASCII libres y fija el área de impresión con
  `GS L`/`GS W`.
- Nuevo encoding opt-in `raster` de respaldo (Android e iOS): el texto se
  imprime como imagen `ESC *` con el mismo acomodo en columnas que el modo
  texto; QR e imágenes siguen nativos.
- Nuevo evento de progreso: `addPrintProgressListener(({ sent, total }) => ...)`.
  Real en iOS (bytes confirmados por BLE); estimado en Android/Bluetooth.
- Android: `print()` por Bluetooth ya no tiene el tope de 8 s de espera de
  drenado (`write()` vuelve en ~1 ms aunque sean 100 KB); espera tamaño/2.5 ms
  en todos los encodings.
- iOS: los rechazos ahora llegan a JS con su mensaje (`"PRINT_FAILED: ..."`) en
  lugar de `"undefined reason"`.
- Los demás encodings no cambian.

## 1.5.4

- Android: volcado hex de diagnóstico del payload que `print()` entrega al SDK,
  con CRC32, transporte y tiempos del `write`. Apagado por defecto; se activa en
  el dispositivo con `adb shell setprop log.tag.ThermalPrinter VERBOSE` y se lee
  con `adb logcat -s ThermalPrinter`. No cambia la API.

## 1.5.3

- Android: `print()` e `isConnected()` ahora verifican una conexión real antes
  de invocar el SDK nativo, evitando su `NullPointerException` no atrapable
  cuando aún no hay puerto abierto.
- Android: `isConnected()` devuelve `false` cuando el binder no está disponible,
  en lugar de dejar la promesa pendiente.
- Android: los receivers de Bluetooth y USB se registran como no exportados,
  compatible con los requisitos de Android API 34+.
