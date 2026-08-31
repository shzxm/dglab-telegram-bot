import type { V2Frame } from "./waveform-compiler.js";

export interface ImportedSection {
  a: number;
  b: number;
  c: number;
  j: number;
  mode: number;
  enabled: boolean;
  points: number[];
}

export interface ImportedWaveform {
  id: string;
  name: string;
  rest: number;
  sections: [ImportedSection, ImportedSection, ImportedSection];
}

// Exported from DG-Lab Unlocker. Values are kept in the original slider/index units.
export const IMPORTED_WAVEFORMS: ImportedWaveform[] = [
  { id: "imported_0", name: "波浪", rest: 0, sections: [
    { a: 0, b: 20, c: 2, j: 29, mode: 1, enabled: true, points: [7.98723, 8.498633] },
    { a: 0, b: 20, c: 2, j: 29, mode: 1, enabled: true, points: [14.872263, 20] },
    { a: 0, b: 20, c: 2, j: 20, mode: 1, enabled: false, points: [0.01, 20] },
  ] },
  { id: "imported_1", name: "持续跳跃", rest: 0, sections: [
    { a: 0, b: 20, c: 2, j: 44, mode: 1, enabled: true, points: [9.981752, 20] },
    { a: 0, b: 20, c: 2, j: 29, mode: 1, enabled: false, points: [20, 20] },
    { a: 0, b: 20, c: 2, j: 20, mode: 1, enabled: false, points: [0.01, 20] },
  ] },
  { id: "imported_2", name: "渐强持续", rest: 0, sections: [
    { a: 0, b: 20, c: 15, j: 29, mode: 1, enabled: true, points: [0, 2.5656953, 0, 4.7562294, 0, 6.1857753, 0, 8.262771, 0, 10.233573, 0, 12.135036, 0, 14.97167, 0] },
    { a: 0, b: 20, c: 2, j: 29, mode: 1, enabled: true, points: [20, 20] },
    { a: 0, b: 20, c: 2, j: 20, mode: 1, enabled: false, points: [0.01, 20] },
  ] },
  { id: "imported_3", name: "最爱", rest: 0, sections: [
    { a: 0, b: 27, c: 11, j: 4, mode: 2, enabled: true, points: [20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20] },
    { a: 0, b: 20, c: 10, j: 0, mode: 1, enabled: true, points: [20, 20, 20, 20, 20, 20, 20, 20, 20, 20] },
    { a: 0, b: 20, c: 2, j: 20, mode: 1, enabled: false, points: [0.01, 20] },
  ] },
  { id: "imported_4", name: "按揉", rest: 0, sections: [
    { a: 0, b: 20, c: 11, j: 23, mode: 1, enabled: true, points: [4.8357663, 12.410586, 7.5, 13.803328, 8.734033, 15.224449, 10.492701, 17.569344, 11.5437975, 18.616787, 0] },
    { a: 0, b: 20, c: 2, j: 29, mode: 1, enabled: false, points: [20, 20] },
    { a: 0, b: 20, c: 2, j: 20, mode: 1, enabled: false, points: [0.01, 20] },
  ] },
  { id: "imported_5", name: "跳强", rest: 0, sections: [
    { a: 0, b: 20, c: 10, j: 0, mode: 1, enabled: true, points: [0, 4, 8, 12, 16, 20, 20, 20, 20, 20] },
    { a: 0, b: 20, c: 2, j: 29, mode: 1, enabled: false, points: [20, 20] },
    { a: 0, b: 20, c: 2, j: 20, mode: 1, enabled: false, points: [0.01, 20] },
  ] },
];

export function importedById(id: string): ImportedWaveform | undefined {
  return IMPORTED_WAVEFORMS.find((waveform) => waveform.id === id);
}
