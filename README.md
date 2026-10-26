# @ronix1020/react-native-ultimate-thermal-printer

Un módulo de Expo potente y fácil de usar para impresión térmica en Android. Esta librería soporta conexiones por **Bluetooth** y **USB**, y proporciona una API completa para imprimir texto, imágenes, códigos QR, tablas y divisores con estilos personalizables.

## Características

- 🖨️ **Conectividad Dual**: Soporte para impresoras térmicas Bluetooth (Clásico y BLE) y USB.
- 📝 **Contenido Rico**: Imprime texto, imágenes (Base64/URL), códigos QR, tablas, divisores, dos columnas y avance de papel (`feed`).
- 🎨 **Estilos**: Personaliza la alineación del texto, tamaño (numérico o semántico), negrita y fuentes.
- 🤝 **Paridad iOS ↔ Android**: El mismo payload produce el mismo resultado en ambas plataformas.
- 🚀 **Compatible con Expo**: Construido como un Módulo Nativo de Expo.

## Instalación

### Desde GitHub
Si deseas instalar la última versión directamente desde el repositorio:

```bash
npm install git+https://github.com/ronix1020/expo-thermal-printer.git
```

## Configuración

### Permisos de Android

Añade los siguientes permisos a tu `app.json` o `AndroidManifest.xml`:

```json
{
  "android": {
    "permissions": [
      "android.permission.BLUETOOTH",
      "android.permission.BLUETOOTH_ADMIN",
      "android.permission.BLUETOOTH_CONNECT",
      "android.permission.BLUETOOTH_SCAN",
      "android.permission.ACCESS_FINE_LOCATION"
    ]
  }
}
```

*Nota: El permiso de ubicación es requerido para el escaneo Bluetooth en Android.*

## Uso

### Importar

```typescript
import * as ThermalPrinter from "@ronix1020/react-native-ultimate-thermal-printer";
```

### Escanear Dispositivos (Bluetooth)

```typescript
const escanear = async () => {
  try {
    // 'paired' para dispositivos vinculados, 'all' para escanear dispositivos cercanos
    const dispositivos = await ThermalPrinter.scanDevices('paired');
    console.log(dispositivos);
  } catch (error) {
    console.error(error);
  }
};
```

### Conectar

**Bluetooth:**
```typescript
await ThermalPrinter.connect("00:11:22:33:44:55");
```

**USB:**
```typescript
const nombreDispositivo = await ThermalPrinter.connectUsb();
console.log(`Conectado a dispositivo USB: ${nombreDispositivo}`);
```

### Imprimir

La función `print` toma un array de ítems para imprimir y un objeto de configuración opcional.

```typescript
const imprimirTicket = async () => {
  try {
    await ThermalPrinter.print([
      {
        type: 'text',
        content: 'MI TIENDA\n',
        style: { align: 'center', size: 'large', bold: true } // tamaño semántico
      },
      {
        type: 'divider',
        content: '-' // 'charToUse', 'char' o 'content' son válidos
      },
      {
        type: 'text',
        content: 'Fecha: 2023-10-27\nHora: 10:30 AM\n',
        style: { align: 'left' }
      },
      {
        type: 'table',
        columnWidths: [20, 6, 6], // Conteos absolutos (suman 32 = 58mm)
        content: [
          ['Producto A', '1', '$10'],
          ['Producto B', '2', '$20'],
        ]
      },
      {
        type: 'two-columns',
        left: 'No.',
        right: '0001' // alias left/right (equivale a content: ['No.', '0001'])
      },
      {
        type: 'divider'
      },
      {
        type: 'text',
        content: 'Total: $50.00\n',
        style: { align: 'right', bold: true }
      },
      {
        type: 'qr',
        content: 'https://ejemplo.com',
        style: { align: 'center', size: 8 }
      },
      {
        type: 'feed',
        lines: 3 // avanza 3 líneas en blanco
      }
    ], {
      width: 58, // Ancho de la impresora en mm (58 u 80)
      encoding: 'utf-8'
    });
  } catch (error) {
    console.error("Error al imprimir:", error);
  }
};
```

### Desconectar

```typescript
await ThermalPrinter.disconnect();
```

## Referencia de la API

### Métodos

- **`scanDevices(type: 'paired' | 'all'): Promise<Device[]>`**
  Escanea dispositivos Bluetooth disponibles.
- **`connect(macAddress: string): Promise<void>`**
  Conecta a un dispositivo Bluetooth por dirección MAC.
- **`connectUsb(): Promise<string>`**
  Conecta a la primera impresora USB disponible. Retorna el nombre del dispositivo.
- **`disconnect(): Promise<void>`**
  Cierra la conexión actual.
- **`isConnected(): Promise<boolean>`**
  Verifica si una impresora está conectada actualmente. Devuelve `false` si el
  servicio aún no está ligado o no hay una conexión activa; no queda pendiente.
- **`print(items: PrinterItem[], options?: PrintOptions): Promise<void>`**
  Envía datos a la impresora. Rechaza con `NOT_CONNECTED` si se invoca antes de
  `connect()` o `connectUsb()`.
- **`addPrintProgressListener(listener: (e: { sent: number; total: number }) => void): { remove(): void }`**
  Avance en bytes de `print()`. En iOS cuenta los bytes confirmados por BLE y en
  Android/USB los transferidos por `bulkTransfer`; en Android/Bluetooth es un estimado a ~12 KB/s (Android no informa cuánto recibió la impresora) y
  `print()` resuelve cuando el estimado llega al 100%. Llama `remove()` al terminar.

### Tipos

#### `PrinterItem`
Puede ser uno de: `TextItem`, `ImageItem`, `QrItem`, `TableItem`, `DividerItem`, `TwoColumnsItem`, `FeedItem`.

**Propiedades de Estilo Comunes (`PrinterItemStyle`):**
- `align`: `'left' | 'center' | 'right'` (izquierda, centro, derecha)
- `bold`: `boolean` (negrita)
- `size`: `number | 'small' | 'normal' | 'large' | 'xlarge'`
  - **Numérico**: byte ESC/POS `GS ! n` (p. ej. `0x11`). Para QR es el tamaño de módulo (1-16).
  - **Semántico**: `'small'`/`'normal'` → normal, `'large'` → doble alto (seguro en 58mm), `'xlarge'` → doble alto + ancho.
- `font`: `'primary' | 'secondary'` (fuente primaria o secundaria)

#### `TwoColumnsItem` — alias `left`/`right`
Se aceptan dos formas equivalentes (la canónica `content` y los alias `left`/`right`):
```typescript
{ type: 'two-columns', content: ['Izquierda', 'Derecha'], style: { bold: true } }
// equivalente a:
{ type: 'two-columns', left: 'Izquierda', right: 'Derecha', style: { bold: true } }
```

#### `DividerItem` — alias `char`/`content`
El carácter del divisor puede indicarse con `charToUse` (canónico) o con los alias `char`/`content`:
```typescript
{ type: 'divider', charToUse: '-' }
{ type: 'divider', char: '=' }
{ type: 'divider', content: '*' } // todos válidos
```
Opcional: `marginVertical` (líneas en blanco antes y después).

#### `FeedItem` — avance de papel
```typescript
{ type: 'feed', lines: 2 } // deja 2 líneas en blanco. `lines` por defecto: 1
```

#### `TableItem` — semántica de `columnWidths`
`columnWidths` se interpreta automáticamente:
- **Conteos absolutos de caracteres** cuando la suma es ≤ el ancho del papel en caracteres (32 para 58mm, 48 para 80mm). Los valores se usan tal cual y se ajustan al espacio disponible.
- **Porcentajes** cuando la suma es mayor (p. ej. ~100). Cada valor se toma como porcentaje del ancho disponible.

```typescript
// Absoluto (suma 32 = 58mm): cada número es la cantidad de caracteres por columna
{ type: 'table', columnWidths: [14, 3, 7, 8], content: [['Producto', '1', '$5', '$5']] }

// Porcentaje (suma 100): cada número es el % del ancho
{ type: 'table', columnWidths: [60, 15, 25], content: [['Producto', '1', '$5']] }
```

#### `PrintOptions`
- `width`: `number` (por defecto: 58)
- `encoding`: `'utf-8' | 'gbk' | 'ascii' | 'cp1258' | 'windows-1252' | 'iso-8859-1' | 'pc850' | 'userfont' | 'raster'` (por defecto: 'utf-8')
  - **Alias aceptados** (normalizados internamente): `utf8` → `utf-8`; `iso8859_1`, `iso88591`, `latin1` → `iso-8859-1`; `win1252` → `windows-1252`.
  > **Nota sobre acentos:** Si tienes problemas con caracteres especiales (á, ñ, etc.), intenta usar `windows-1252` o `pc850`.
  > **`userfont`:** para impresoras cuya fuente ROM no imprime letras (p. ej. SAT AF330, que solo dibuja `# $ @ [ \ ] ^ \` { | } ~`). Descarga una fuente monoespaciada 12x24 con `ESC &` y la activa con `ESC % 1`; fija además el área de impresión a 576 puntos (80 mm) o 384 (58 mm). Los caracteres no-ASCII del ticket se dibujan en slots ASCII que el ticket no usa; si se acaban, se imprimen sin acento. Fuerza la fuente A. Envía ~3.5 KB extra por ticket.
  > **`raster` (respaldo):** dibuja el texto, las tablas, los divisores y las dos columnas como imagen (`ESC *`) en la misma cuadrícula de 12x24 (48 columnas en 80 mm, 32 en 58 mm), así que no depende de fuentes ni de encodings de la impresora. Respeta alineación, negrita y tamaño; QR e imágenes siguen por su camino nativo. Mucho más pesado y lento (~100 KB por ticket contra ~6 KB de `userfont`); por BLE en iOS es muy lento.
- `lineSpacing`: `number` (por defecto: 30)
- `feedLines`: `number` (por defecto: 0)
- `unaccent`: `boolean` — si es `true`, elimina acentos/diacríticos en JS antes de enviar (útil con codificaciones limitadas).

### Diagnóstico: volcado hex del payload (Android)

Para ver los bytes exactos que `print()` entrega al SDK (cabecera con tamaño,
CRC32, ancho, encoding y transporte, más líneas de 32 bytes con hex y ASCII),
activa el log en el dispositivo y léelo con logcat. No requiere recompilar ni
cambia la API; apagado por defecto para no exponer datos del ticket.

```bash
adb shell setprop log.tag.ThermalPrinter VERBOSE
adb logcat -s ThermalPrinter
# para apagarlo:
adb shell setprop log.tag.ThermalPrinter ""
```

### Códigos de Error

`connect()`, `print()` y demás métodos rechazan con códigos estables e idénticos en iOS y Android. Los mensajes están en inglés (cortos) para que el consumidor los traduzca:

| Código | Significado |
|---|---|
| `BLUETOOTH_NOT_READY` | Bluetooth apagado, no autorizado o no listo. |
| `DEVICE_NOT_FOUND` | El dispositivo solicitado no se encontró (no emparejado / fuera del escaneo). |
| `CONNECTION_FAILED` | Falló el intento de conexión o el descubrimiento de servicios. |
| `SERVICE_NOT_BOUND` | El servicio/transporte de impresión aún no está disponible (sin conexión activa). |
| `NOT_CONNECTED` | No hay una conexión de impresora activa; llama a `connect()` o `connectUsb()` antes de imprimir. |
| `PRINT_FAILED` | Falló el envío de datos a la impresora (p. ej. impresora apagada a mitad). |

## Licencia

MIT
