import { IMPORTED_WAVEFORMS, type ImportedSection, type ImportedWaveform } from "./imported-waveforms.js";

export type V2Frame = [number, number, number];

export const FREQ_SLIDER_VALUE_MAP = [
  ...Array.from({ length: 40 }, (_, index) => 10 + index),
  50, 52, 54, 56, 58, 60, 62, 64, 66, 68, 70, 72, 74, 76, 78, 80, 85, 90, 95,
  100, 110, 120, 130, 140, 150, 160, 170, 180, 190, 200, 233, 266, 300, 333, 366,
  400, 450, 500, 550, 600, 700, 800, 900, 1000,
];

export const OLD_SECTION_TIME_MAP = [
  0.1,0.1,0.1,0.1,0.1, 0.2,0.2,0.2, 0.3,0.3,0.3, 0.4,0.4, 0.5,0.5, 0.6,0.6, 0.7,0.7, 0.8, 0.9,0.9, 1, 1.1,1.1, 1.2, 1.3,1.3, 1.4,1.5, 1.6,1.6, 1.7,1.8,1.9,2.0, 2.1,2.1, 2.2,2.3,2.4,2.5, 2.6,2.7,2.8,2.9,3.0, 3.1,3.2,3.3,3.4,3.5, 3.6,3.7,3.8,3.9,4.1, 4.2,4.3,4.4,4.5,4.6, 4.7,4.9,5.0,5.1,5.2, 5.4,5.5,5.6,5.7,5.9, 6.0,6.1,6.3,6.4,6.5, 6.7,6.8,6.9,7.1,7.2, 7.4,7.5,7.6,7.8,7.9, 8.1,8.2,8.4,8.5,8.7, 8.8,9.0,9.1,9.3,9.4, 9.6,9.7,9.9,10.0,
];

function frequencyXY(frequency: number): [number, number] {
  // Follow the V2 guide's X/Y ratio; preserve its documented 10ms example.
  const x = frequency <= 10 ? 1 : Math.max(1, Math.min(31, Math.round(Math.sqrt(frequency / 1000) * 15)));
  return [x, frequency - x];
}

function sectionFrames(section: ImportedSection): V2Frame[] {
  if (!section.enabled || section.c <= 0 || section.points.length === 0) return [];
  const targetSeconds = OLD_SECTION_TIME_MAP[section.j] ?? 0.1;
  const pulseCount = Math.max(1, Math.min(31, section.c));
  const points = section.points.slice(0, pulseCount);
  while (points.length < pulseCount) points.push(points[points.length - 1] ?? 0);
  const repeatTimes = Math.max(1, Math.ceil(targetSeconds / (points.length * 0.1)));
  const frames: V2Frame[] = [];
  for (let repeat = 0; repeat < repeatTimes; repeat += 1) {
    for (let index = 0; index < points.length; index += 1) {
      const progress = (points.length * repeat + index) / (points.length * repeatTimes);
      let slider = section.a;
      if (section.mode === 2) slider = section.a + Math.floor((section.b - section.a) * progress);
      else if (section.mode === 3) slider = section.a + Math.floor((section.b - section.a) * index / points.length);
      else if (section.mode === 4) slider = section.a + Math.floor((section.b - section.a) * repeat / repeatTimes);
      const frequency = FREQ_SLIDER_VALUE_MAP[Math.max(0, Math.min(FREQ_SLIDER_VALUE_MAP.length - 1, slider))] ?? 10;
      const [x, y] = frequencyXY(frequency);
      const z = Math.max(0, Math.min(31, Math.round(points[index] ?? 0)));
      frames.push([x, y, z]);
    }
  }
  return frames;
}

export function compileImportedWaveform(waveform: ImportedWaveform): V2Frame[] {
  const frames = waveform.sections.flatMap(sectionFrames);
  const restSeconds = waveform.rest === 0 ? 0 : (OLD_SECTION_TIME_MAP[waveform.rest] ?? 0);
  for (let index = 0; index < Math.ceil(restSeconds * 10); index += 1) frames.push([0, 0, 0]);
  return frames.length > 0 ? frames : [[0, 0, 0]];
}

export const IMPORTED_V2_WAVEFORMS: Record<string, V2Frame[]> = Object.fromEntries(
  IMPORTED_WAVEFORMS.map((waveform) => [waveform.id, compileImportedWaveform(waveform)]),
);
