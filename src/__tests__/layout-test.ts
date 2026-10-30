import { layoutItems, resolveColumnWidths, transliterate, twoColumnsLines, wrap } from '../layout';

const text = (items: any[]) => items.map((i) => i.content);

describe('wrap', () => {
  it('corta por palabras al ancho', () => {
    expect(wrap('ESTE DOCUMENTO NO ES UN COMPROBANTE FISCAL', 32)).toEqual(['ESTE DOCUMENTO NO ES UN', 'COMPROBANTE FISCAL']);
  });
  it('parte una palabra más larga que la línea', () => {
    expect(wrap('AAAAAAAAAA BB', 4)).toEqual(['AAAA', 'AAAA', 'AA', 'BB']);
  });
  it('respeta \\n y las líneas que ya caben', () => {
    expect(wrap('A  B\n\nC', 32)).toEqual(['A  B', '', 'C']);
  });
  it('cuenta doble columna en gbk', () => {
    expect(wrap('中文中文 ab', 6, (c) => (c > '\x7F' ? 2 : 1))).toEqual(['中文中', '文 ab']);
  });
});

describe('text', () => {
  it('xlarge usa la mitad de columnas; large (doble alto) no', () => {
    const t = 'UNO DOS TRES CUATRO CINCO SEIS SIETE';
    expect(text(layoutItems([{ type: 'text', content: t, style: { size: 'xlarge' } }], { width: 58, encoding: 'pc850' })))
      .toEqual(['UNO DOS TRES\nCUATRO CINCO\nSEIS SIETE']);
    expect(text(layoutItems([{ type: 'text', content: t, style: { size: 'large' } }], { width: 58, encoding: 'pc850' })))
      .toEqual(['UNO DOS TRES CUATRO CINCO SEIS\nSIETE']);
  });
  it('conserva el estilo', () => {
    const [item] = layoutItems([{ type: 'text', content: 'x', style: { align: 'center', bold: true } }], { width: 80, encoding: 'pc850' });
    expect(item.style).toEqual({ align: 'center', bold: true });
  });
});

describe('table', () => {
  it('corta las celdas por palabras y alinea los renglones', () => {
    const [item] = layoutItems([{
      type: 'table', columnWidths: [11, 4, 15], columnAlignment: ['left', 'right', 'right'],
      tableHeader: ['PRODUCTO', 'CANT', 'TOTAL'], content: [['PANADOL ULTRA', '2', '$3.50']],
    }], { width: 58, encoding: 'pc850' });
    expect(item.type).toBe('text');
    expect(item.content.split('\n')).toEqual([
      'PRODUCTO    CANT           TOTAL',
      'PANADOL        2           $3.50',
      'ULTRA                           ',
    ]);
  });
  it('reparte el recorte cuando columnWidths se pasan', () => {
    const warn = jest.spyOn(console, 'warn').mockImplementation(() => {});
    expect(resolveColumnWidths([16, 8, 8], 32)).toEqual([15, 7, 8]);
    expect(warn).toHaveBeenCalled();
    warn.mockRestore();
  });
  it('porcentajes', () => {
    expect(resolveColumnWidths([50, 25, 25], 48)).toEqual([23, 11, 12]);
  });
});

describe('two-columns', () => {
  it('cabe en una línea', () => {
    expect(twoColumnsLines('TOTAL', '$1.00', 32)).toEqual(['TOTAL' + ' '.repeat(22) + '$1.00']);
  });
  it('la etiqueta se parte y el valor va a la derecha en la última línea', () => {
    expect(twoColumnsLines('FOVIAL ($0.20 Ctvs. por galón) y más:', '$0.20', 32)).toEqual([
      'FOVIAL ($0.20 Ctvs. por galón) y',
      'más:                       $0.20',
    ]);
  });
  it('etiqueta de 32 exactas: el valor va en su propia línea', () => {
    expect(twoColumnsLines('COTRANS ($0.10 Ctvs. por galón):', '$0.10', 32)).toEqual([
      'COTRANS ($0.10 Ctvs. por galón):',
      '                           $0.10',
    ]);
  });
  it('si no cabe en la última línea, va sola a la derecha', () => {
    expect(twoColumnsLines('AAAA BBBBBBBBBB', '$9.99', 12)).toEqual(['AAAA', 'BBBBBBBBBB', '       $9.99']);
  });
  it('etiqueta vacía', () => {
    expect(twoColumnsLines('', '$0.10', 8)).toEqual(['   $0.10']);
  });
  it('sale como text con su estilo y alineado a la izquierda', () => {
    const [item] = layoutItems([{ type: 'two-columns', left: 'A', right: 'B', style: { bold: true, align: 'center' } }], { width: 58, encoding: 'pc850' });
    expect(item).toEqual({ type: 'text', content: 'A' + ' '.repeat(30) + 'B', style: { bold: true, align: 'left' } });
  });
});

describe('transliterate', () => {
  it('pc850: equivalentes ASCII, acentos y ñ intactos', () => {
    expect(transliterate('Sucursal: — “Ñandú” … • → 5€ ‘a’ –−', 'pc850')).toBe('Sucursal: - "Ñandú" ... * -> 5EUR \'a\' --');
  });
  it('windows-1252 conserva lo que trae', () => {
    expect(transliterate('— € “x” → −', 'windows-1252')).toBe('— € “x” -> -');
  });
  it('ascii quita acentos; sin equivalente da ? y avisa', () => {
    const warn = jest.spyOn(console, 'warn').mockImplementation(() => {});
    expect(transliterate('Año ☃ ok', 'ascii')).toBe('Ano ? ok');
    expect(warn).toHaveBeenCalledWith(expect.stringContaining('☃'));
    warn.mockRestore();
  });
  it('utf-8, gbk, raster y userfont no se tocan', () => {
    for (const e of ['utf-8', 'gbk', 'raster', 'userfont']) expect(transliterate('— ñ', e)).toBe('— ñ');
  });
  it('unaccent translitera a ascii en vez de borrar', () => {
    expect(text(layoutItems([{ type: 'text', content: 'Sucursal: — Año' }], { width: 58, encoding: 'utf8', unaccent: true })))
      .toEqual(['Sucursal: - Ano']);
  });
  it('se translitera antes de cortar', () => {
    expect(text(layoutItems([{ type: 'text', content: 'ABCDE…' }], { width: 58, encoding: 'pc850' }))).toEqual(['ABCDE...']);
  });
});
