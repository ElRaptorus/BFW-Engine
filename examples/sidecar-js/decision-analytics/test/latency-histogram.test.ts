import { describe, expect, it } from 'vitest';

import { LatencyHistogram } from '../src/latency-histogram.js';

describe('LatencyHistogram', () => {
  it('returns zeros when empty', () => {
    const histogram = new LatencyHistogram();
    expect(histogram.count).toBe(0);
    expect(histogram.average).toBe(0);
    expect(histogram.p95).toBe(0);
    expect(histogram.p99).toBe(0);
    expect(histogram.min).toBe(0);
    expect(histogram.max).toBe(0);
  });

  it('uses the single value for average and percentiles', () => {
    const histogram = new LatencyHistogram();
    histogram.add(250);
    expect(histogram.average).toBe(250);
    expect(histogram.p95).toBe(250);
    expect(histogram.p99).toBe(250);
    expect(histogram.min).toBe(250);
    expect(histogram.max).toBe(250);
  });

  it('computes percentile boundaries for one hundred values', () => {
    const histogram = new LatencyHistogram();
    const values = Array.from({ length: 100 }, (_unused, index) => index + 1);
    histogram.addAll(values);

    expect(histogram.count).toBe(100);
    expect(histogram.average).toBe(50.5);
    expect(histogram.p95).toBe(95);
    expect(histogram.p99).toBe(99);
    expect(histogram.min).toBe(1);
    expect(histogram.max).toBe(100);
  });

  it('reports correct min and max', () => {
    const histogram = new LatencyHistogram();
    histogram.addAll([10, 50, 30]);
    expect(histogram.min).toBe(10);
    expect(histogram.max).toBe(50);
  });
});
