# @ronix1020/react-native-ultimate-thermal-printer

Un módulo de Expo potente y fácil de usar para impresión térmica en Android. Esta librería soporta conexiones por **Bluetooth** y **USB**, y proporciona una API completa para imprimir texto, imágenes, códigos QR, tablas y divisores con estilos personalizables.

## Características

- 🖨️ **Conectividad Dual**: Soporte para impresoras térmicas Bluetooth (Clásico y BLE) y USB.
- 📝 **Contenido Rico**: Imprime texto, imágenes (Base64/URL), códigos QR, tablas y divisores.
- 🎨 **Estilos**: Personaliza la alineación del texto, tamaño, negrita y fuentes.
- 🚀 **Compatible con Expo**: Construido como un Módulo Nativo de Expo.

## Instalación

### Desde GitHub
Si deseas instalar la última versión directamente desde el repositorio:

```bash
npm install git+https://github.com/ronix1020/expo-thermal-printer.git
```

### ⚠️ Importante: Requisito de SDK Propietario

Esta librería depende de un SDK propietario (`posprinterconnectandsendsdk.jar`) que no puede ser distribuido vía NPM ni GitHub debido a restricciones de licencia. Debes obtener este archivo y añadirlo a tu proyecto manualmente.

1. **Descarga** el archivo `posprinterconnectandsendsdk.jar` (usualmente proporcionado por el fabricante de tu impresora).
2. **Colócalo** en una carpeta segura de tu proyecto (ej. `assets/libs/`).

**Automatización Recomendada (Script Postinstall):**
Para asegurar que el archivo se copie correctamente a la librería cada vez que instales dependencias (especialmente útil si instalas desde GitHub donde la carpeta `libs` no existe), añade este script a tu `package.json`:

```json
"scripts": {
  "postinstall": "mkdir -p node_modules/@ronix1020/react-native-ultimate-thermal-printer/android/libs && cp ./assets/libs/posprinterconnectandsendsdk.jar node_modules/@ronix1020/react-native-ultimate-thermal-printer/android/libs/"
}
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
        style: { align: 'center', size: 1, bold: true }
      },
      {
        type: 'divider',
        charToUse: '-'
      },
      {
        type: 'text',
        content: 'Fecha: 2023-10-27\nHora: 10:30 AM\n',
        style: { align: 'left' }
      },
      {
        type: 'table',
        columnWidths: [20, 6, 6], // Anchos en caracteres
        content: [
          ['Producto A', '1', '$10'],
          ['Producto B', '2', '$20'],
        ]
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
        type: 'text',
        content: '\n\n\n' // Líneas de alimentación (feed)
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
  Verifica si una impresora está conectada actualmente.
- **`print(items: PrinterItem[], options?: PrintOptions): Promise<void>`**
  Envía datos a la impresora.

### Tipos

#### `PrinterItem`
Puede ser uno de: `TextItem`, `ImageItem`, `QrItem`, `TableItem`, `DividerItem`, `TwoColumnsItem`.

**Propiedades de Estilo Comunes (`PrinterItemStyle`):**
- `align`: `'left' | 'center' | 'right'` (izquierda, centro, derecha)
- `bold`: `boolean` (negrita)
- `size`: `number` (0-7 para texto, tamaño de módulo para QR)
- `font`: `'primary' | 'secondary'` (fuente primaria o secundaria)

**Ejemplo de `TwoColumnsItem`:**
```typescript
{
  type: 'two-columns',
  content: ['Izquierda', 'Derecha'], // Se imprimirán en la misma línea con espacio entre ellos
  style: { bold: true } // Opcional
}
```

#### `PrintOptions`
- `width`: `number` (por defecto: 58)
- `encoding`: `'utf-8' | 'gbk' | 'ascii' | 'cp1258' | 'windows-1252' | 'iso-8859-1' | 'pc850'` (por defecto: 'utf-8')
  > **Nota sobre acentos:** Si tienes problemas con caracteres especiales (á, ñ, etc.), intenta usar `windows-1252` o `pc850`.
- `lineSpacing`: `number` (por defecto: 30)
- `feedLines`: `number` (por defecto: 0)

## Licencia

MIT
