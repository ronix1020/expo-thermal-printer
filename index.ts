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

/**
 * Supported encodings plus accepted aliases. Aliases are normalized natively
 * before charset/code-page selection:
 *   utf8 -> utf-8
 *   iso8859_1 | iso88591 | latin1 -> iso-8859-1
 *   win1252 -> windows-1252
 */
export type PrinterEncoding =
  | 'utf-8' | 'utf8'
  | 'gbk'
  | 'ascii'
  | 'cp1258'
  | 'windows-1252' | 'win1252'
  | 'iso-8859-1' | 'iso8859_1' | 'iso88591' | 'latin1'
  | 'pc850';
export type PrinterAlign = 'left' | 'center' | 'right';
export type PrinterFont = 'primary' | 'secondary';

/**
 * Semantic text sizes. Mapped natively to ESC/POS `GS ! n`:
 *   'small' | 'normal' -> 0x00 (1x)
 *   'large'            -> 0x01 (double height only — safe on 58mm)
 *   'xlarge'           -> 0x11 (double height + double width)
 */
export type PrinterTextSize = 'small' | 'normal' | 'large' | 'xlarge';

export interface PrinterItemStyle {
  bold?: boolean;
  align?: PrinterAlign;
  /**
   * Text size. Accepts either a raw ESC/POS `GS ! n` byte (number, e.g. `0x11`)
   * or a semantic string (`'small' | 'normal' | 'large' | 'xlarge'`).
   * For QR items this is the module size (1-16).
   */
  size?: number | PrinterTextSize;
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
  /**
   * Column widths. Interpreted natively in one of two ways:
   *   - **Absolute char counts** when `sum(columnWidths) <= maxChars` for the
   *     paper (32 for 58mm, 48 for 80mm). Values are used as-is.
   *   - **Percentages** otherwise (e.g. summing ~100). Each value is taken as a
   *     percentage of the available width.
   */
  columnWidths: number[];
  columnAlignment?: PrinterAlign[]; // Alignment for each column
  content: string[][];
}

export interface DividerItem extends BasePrinterItem {
  type: 'divider';
  /** Canonical divider character field. `char`/`content` accepted as aliases. */
  charToUse?: string;
  char?: string;
  content?: string;
  marginVertical?: number;
}

export interface TwoColumnsItem extends BasePrinterItem {
  type: 'two-columns';
  /** Canonical form: `[LeftText, RightText]`. `left`/`right` accepted as aliases. */
  content?: [string, string];
  left?: string;
  right?: string;
}

export interface FeedItem {
  type: 'feed';
  /** Number of blank lines to feed. Defaults to 1. */
  lines?: number;
}

export type PrinterItem =
  | TextItem
  | QrItem
  | ImageItem
  | TableItem
  | DividerItem
  | TwoColumnsItem
  | FeedItem;

export interface PrintOptions {
  width?: number;
  encoding?: PrinterEncoding;
  lineSpacing?: number;
  feedLines?: number;
  unaccent?: boolean;
}

const normalizeText = (text: string) => {
  return text
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .replace(/[^\x20-\x7E\n]/g, ""); // Keep printable ASCII and newlines
};

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
  let itemsToPrint = items;

  if (options.unaccent) {
    itemsToPrint = items.map(item => {
      const newItem = { ...item };
      
      if (newItem.type === 'text') {
        newItem.content = normalizeText(newItem.content);
      } else if (newItem.type === 'two-columns') {
        // Canonical [left, right] and the left/right aliases are both normalized.
        if (newItem.content) {
          newItem.content = [normalizeText(newItem.content[0]), normalizeText(newItem.content[1])];
        }
        if (typeof newItem.left === 'string') newItem.left = normalizeText(newItem.left);
        if (typeof newItem.right === 'string') newItem.right = normalizeText(newItem.right);
      } else if (newItem.type === 'table') {
        if (newItem.tableHeader) {
          newItem.tableHeader = newItem.tableHeader.map(h => normalizeText(h));
        }
        newItem.content = newItem.content.map(row => row.map(cell => normalizeText(cell)));
      } else if (newItem.type === 'divider') {
        // charToUse plus the char/content aliases are all normalized.
        if (newItem.charToUse) newItem.charToUse = normalizeText(newItem.charToUse);
        if (newItem.char) newItem.char = normalizeText(newItem.char);
        if (typeof newItem.content === 'string') newItem.content = normalizeText(newItem.content);
      }
      // We generally don't normalize QR codes or Images as they are data/binary
      
      return newItem;
    });
  }

  return await ThermalPrinterModule.print(
    itemsToPrint,
    options.width || 58,
    options.encoding || "utf-8",
    options.lineSpacing || 30,
    options.feedLines || 0
  );
}

export async function isConnected(): Promise<boolean> {
  return await ThermalPrinterModule.isConnected();
}
