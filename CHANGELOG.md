# Changelog

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
