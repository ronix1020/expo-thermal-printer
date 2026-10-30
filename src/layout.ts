// Acomodo de texto en columnas, compartido por Android e iOS: el nativo recibe líneas que ya caben
// (table y two-columns llegan como `text`) y solo las codifica.

type Item = { type: string; style?: { align?: string; bold?: boolean; size?: number | string; font?: string }; [key: string]: any };

export interface LayoutOptions {
  width: number;
  encoding: string;
  unaccent?: boolean;
}

export function normalizeEncoding(encoding: string): string {
  const e = encoding.toLowerCase().trim();
  if (e === 'utf8') return 'utf-8';
  if (e === 'iso8859_1' || e === 'iso88591' || e === 'latin1') return 'iso-8859-1';
  if (e === 'win1252') return 'windows-1252';
  return e;
}

/** Igual que resolveSize nativo: byte `GS ! n` o 'small' | 'normal' | 'large' | 'xlarge'. */
export function resolveSize(value: unknown): number {
  if (typeof value === 'number') return value;
  if (typeof value === 'string') {
    const v = value.toLowerCase().trim();
    if (v === 'small' || v === 'normal') return 0x00;
    if (v === 'large') return 0x01;
    if (v === 'xlarge') return 0x11;
    return parseInt(v, 10) || 0;
  }
  return 0;
}

/** Columnas de la línea: fuente A 48/32/24, fuente B 64/42/32, divididas por el ancho de `GS ! n`. */
export function columnsFor(width: number, font: string | undefined, size: number): number {
  const base = font === 'secondary'
    ? (width >= 80 ? 64 : width >= 58 ? 42 : 32)
    : (width >= 80 ? 48 : width >= 58 ? 32 : 24);
  return Math.max(1, Math.floor(base / ((size >> 4) + 1)));
}

// Fuera de pc850/latin1 (y de 1252 salvo los que trae, ver CP1252_EXTRA).
const TRANSLIT: Record<string, string> = {
  '—': '-', '–': '-', '−': '-', '…': '...',
  '‘': "'", '’': "'", '“': '"', '”': '"',
  '•': '*', '→': '->', '€': 'EUR',
};
// Lo que windows-1252 tiene entre 0x80 y 0x9F.
const CP1252_EXTRA = new Set('€‚ƒ„…†‡ˆ‰Š‹ŒŽ‘’“”•–—˜™š›œžŸ');

/** ¿Cabe el carácter en la página de códigos? null = no se translitera (utf-8, gbk, raster, userfont). */
function encodableFor(encoding: string): ((c: string) => boolean) | null {
  switch (encoding) {
    case 'ascii':
      return (c) => c <= '\x7E';
    // pc850 contiene todo Latin-1 imprimible.
    case 'pc850':
    case 'iso-8859-1':
      return (c) => c <= '\x7E' || (c >= '\xA0' && c <= '\xFF');
    // shortcut: cp1258 se trata como 1252 (le faltan unas pocas letras de Latin-1), afinar si alguien imprime vietnamita.
    case 'windows-1252':
    case 'cp1258':
      return (c) => c <= '\x7E' || (c >= '\xA0' && c <= '\xFF') || CP1252_EXTRA.has(c);
    default:
      return null;
  }
}

/** Reemplaza lo que la página de códigos no trae: equivalente ASCII, letra sin acento o '?' (con aviso). */
export function transliterate(text: string, encoding: string): string {
  const fits = encodableFor(encoding);
  if (!fits) return text;
  let out = '';
  const missing = new Set<string>();
  for (const c of text) {
    if (c === '\n') { out += c; continue; }
    if (c < ' ') continue; // tab, \r: descuadran las columnas
    if (fits(c)) { out += c; continue; }
    const mapped: string = TRANSLIT[c] ?? c.normalize('NFD').replace(/[̀-ͯ]/g, '');
    if (mapped && [...mapped].every(fits)) { out += mapped; continue; }
    missing.add(c);
    out += '?';
  }
  if (missing.size) console.warn(`[ThermalPrinter] Sin equivalente en ${encoding}: ${[...missing].join(' ')}`);
  return out;
}

// En gbk los caracteres de doble byte ocupan dos columnas.
type CharWidth = (c: string) => number;
const single: CharWidth = () => 1;
const gbkWidth: CharWidth = (c) => (c > '\x7F' ? 2 : 1);
const textWidth = (s: string, cw: CharWidth) => [...s].reduce((n, c) => n + cw(c), 0);

function hardSplit(word: string, cols: number, cw: CharWidth): string[] {
  const out: string[] = [];
  let line = '';
  for (const c of word) {
    if (line && textWidth(line, cw) + cw(c) > cols) { out.push(line); line = ''; }
    line += c;
  }
  out.push(line);
  return out;
}

/** Corta por palabras; una palabra más larga que la línea se parte. `\n` es salto; '' da una línea vacía. */
export function wrap(text: string, cols: number, cw: CharWidth = single): string[] {
  const out: string[] = [];
  for (const para of text.split('\n')) {
    if (textWidth(para, cw) <= cols) { out.push(para); continue; }
    let line = '';
    for (const word of para.split(/ +/).filter(Boolean)) {
      if (line && textWidth(line, cw) + 1 + textWidth(word, cw) <= cols) { line += ' ' + word; continue; }
      if (line) out.push(line);
      const pieces = hardSplit(word, cols, cw);
      line = pieces.pop()!;
      out.push(...pieces);
    }
    out.push(line);
  }
  return out;
}

function pad(text: string, width: number, align: string | undefined, cw: CharWidth): string {
  const space = Math.max(0, width - textWidth(text, cw));
  if (align === 'right') return ' '.repeat(space) + text;
  if (align === 'center') return ' '.repeat(space >> 1) + text + ' '.repeat(space - (space >> 1));
  return text + ' '.repeat(space);
}

/**
 * Anchos de columna: absolutos si suman <= columnas del papel, si no porcentajes. Deben sumar
 * columnas − (n − 1) por el separador; si se pasan, el recorte se reparte entre todas.
 */
export function resolveColumnWidths(columnWidths: number[], maxChars: number): number[] {
  const n = columnWidths.length;
  const available = maxChars - Math.max(0, n - 1);
  const requested = columnWidths.reduce((a, b) => a + b, 0);
  let cols = requested <= maxChars
    ? columnWidths.map((w) => Math.floor(w))
    : columnWidths.map((w) => Math.floor((w / 100) * available));
  const total = cols.reduce((a, b) => a + b, 0);
  if (total > available) {
    console.warn(`[ThermalPrinter] columnWidths [${columnWidths}] suman ${total}; caben ${available} (${maxChars} − ${n - 1} separadores). Se recortan en proporción.`);
    cols = cols.map((w) => Math.max(1, Math.floor((w * available) / total)));
  }
  // Lo que sobra (redondeo, anchos absolutos cortos) va a la última columna.
  const used = cols.reduce((a, b) => a + b, 0);
  if (used < available) cols[n - 1] += available - used;
  return cols;
}

function tableLines(item: Item, width: number, cw: CharWidth): string[] {
  const columnWidths: number[] = item.columnWidths ?? [];
  const alignment: string[] = item.columnAlignment ?? [];
  const cols = resolveColumnWidths(columnWidths, columnsFor(width, 'primary', 0));
  const rows: string[][] = [...(item.tableHeader?.length ? [item.tableHeader] : []), ...(item.content ?? [])];
  const out: string[] = [];
  for (const row of rows) {
    // Fila sin texto: no imprime nada (igual que antes de 1.8.0).
    if (row.every((cell) => !cell)) continue;
    const cells = cols.map((w, j) => wrap(row[j] ?? '', w, cw));
    const height = Math.max(...cells.map((c) => c.length));
    for (let i = 0; i < height; i++) {
      out.push(cols.map((w, j) => pad(cells[j][i] ?? '', w, alignment[j], cw)).join(' '));
    }
  }
  return out;
}

/** Etiqueta a la izquierda, valor a la derecha; si no caben, la etiqueta se parte y el valor va al final, a la derecha. */
export function twoColumnsLines(left: string, right: string, cols: number, cw: CharWidth = single): string[] {
  const rw = textWidth(right, cw);
  const lines = wrap(left, cols, cw);
  const last = lines.pop()!;
  const lw = textWidth(last, cw);
  if (lw + rw + 1 <= cols || (!last && rw <= cols)) return [...lines, last + ' '.repeat(cols - lw - rw) + right];
  return [...lines, last, ...wrap(right, cols, cw).map((r) => pad(r, cols, 'right', cw))];
}

/** Convierte los items a lo que el nativo imprime tal cual. */
export function layoutItems(items: Item[], options: LayoutOptions): Item[] {
  const encoding = normalizeEncoding(options.encoding);
  const target = options.unaccent ? 'ascii' : encoding;
  const fix = (s: unknown) => (typeof s === 'string' ? transliterate(s, target) : s);
  const cw = encoding === 'gbk' ? gbkWidth : single;
  // raster y userfont dibujan siempre con la fuente A (12x24).
  const fontOf = (item: Item) => (encoding === 'raster' || encoding === 'userfont' ? 'primary' : item.style?.font);

  const out: Item[] = [];
  for (const item of items) {
    switch (item.type) {
      case 'text': {
        const style = item.style ?? {};
        const cols = columnsFor(options.width, fontOf(item), resolveSize(style.size));
        out.push({ ...item, content: wrap(fix(item.content ?? '') as string, cols, cw).join('\n') });
        break;
      }
      case 'table': {
        if (!item.columnWidths?.length) break;
        const fixed = {
          ...item,
          tableHeader: item.tableHeader?.map(fix),
          content: (item.content ?? []).map((row: string[]) => row.map(fix)),
        };
        const lines = tableLines(fixed, options.width, cw);
        if (lines.length) out.push({ type: 'text', content: lines.join('\n') });
        break;
      }
      case 'two-columns': {
        const [left, right] = (item.content ?? [item.left, item.right]).map(fix);
        if (typeof left !== 'string' || typeof right !== 'string') break;
        const style = item.style ?? {};
        const cols = columnsFor(options.width, fontOf(item), resolveSize(style.size));
        out.push({ type: 'text', content: twoColumnsLines(left, right, cols, cw).join('\n'), style: { ...style, align: 'left' } });
        break;
      }
      case 'divider':
        out.push({ ...item, charToUse: fix(item.charToUse), char: fix(item.char), content: fix(item.content) });
        break;
      default:
        out.push(item);
    }
  }
  return out;
}
