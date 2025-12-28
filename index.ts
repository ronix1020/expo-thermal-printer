// Import the native module. On web, it will be resolved to null.
// This relies on the Expo Modules autolinking infrastructure.
// The name "ThermalPrinter" comes from the name defined in the expo-module.config.json or the class name.
// However, in the config we defined the package "expo.modules.thermalprinter" and module "ThermalPrinterModule"
// Expo modules create a native module accessible via requireNativeModule.

import { requireNativeModule } from "expo-modules-core";

const ThermalPrinterModule = requireNativeModule("ThermalPrinter");

export type Device = {
  name: string;
  macAddress: string;
};

export type PrinterEncoding = 'utf-8' | 'gbk' | 'ascii' | 'cp1258';
export type PrinterAlign = 'left' | 'center' | 'right';
export type PrinterFont = 'primary' | 'secondary';

export interface PrinterItemStyle {
  bold?: boolean;
  align?: PrinterAlign;
  size?: number; // 0-7 for text, module size for QR
  font?: PrinterFont;
  width?: number; // Image width in pixels
  height?: number; // Image height in pixels
}

interface BasePrinterItem {
  style?: PrinterItemStyle;
}

export interface TextItem extends BasePrinterItem {
  type: 'text';
  content: string;
}

export interface QrItem extends BasePrinterItem {
  type: 'qr';
  content: string;
}

export interface ImageItem extends BasePrinterItem {
  type: 'image';
  content: string; // Base64 or URL
}

export interface TableItem extends BasePrinterItem {
  type: 'table';
  tableHeader?: string[];
  columnWidths: number[];
  content: string[][];
}

export interface DividerItem extends BasePrinterItem {
  type: 'divider';
  charToUse?: string;
  marginVertical?: number;
}

export type PrinterItem = TextItem | QrItem | ImageItem | TableItem | DividerItem;

export interface PrintOptions {
  width?: number;
  encoding?: PrinterEncoding;
  lineSpacing?: number;
  feedLines?: number;
}

export async function scanDevices(type: 'paired' | 'all' = 'paired'): Promise<Device[]> {
  return await ThermalPrinterModule.scanDevices(type);
}

export async function connect(macAddress: string): Promise<void> {
  return await ThermalPrinterModule.connect(macAddress);
}

export async function connectUsb(): Promise<string> {
  return await ThermalPrinterModule.connectUsb();
}

export async function disconnect(): Promise<void> {
  return await ThermalPrinterModule.disconnect();
}

export async function print(
  items: PrinterItem[],
  options: PrintOptions = {}
): Promise<void> {
  return await ThermalPrinterModule.print(
    items,
    options.width || 58,
    options.encoding || "utf-8",
    options.lineSpacing || 30,
    options.feedLines || 0
  );
}

export async function isConnected(): Promise<boolean> {
  return await ThermalPrinterModule.isConnected();
}
