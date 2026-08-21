# Changelog

## 1.5.3

- Android: `print()` e `isConnected()` ahora verifican una conexión real antes
  de invocar el SDK nativo, evitando su `NullPointerException` no atrapable
  cuando aún no hay puerto abierto.
- Android: `isConnected()` devuelve `false` cuando el binder no está disponible,
  en lugar de dejar la promesa pendiente.
- Android: los receivers de Bluetooth y USB se registran como no exportados,
  compatible con los requisitos de Android API 34+.
