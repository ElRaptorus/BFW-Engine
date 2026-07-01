import { describe, expect, it } from 'vitest';

import { AnomalyDetector } from '../src/anomaly-detector.js';

describe('AnomalyDetector', () => {
  it('does not flag normal latency', () => {
    const detector = new AnomalyDetector(20, 3);
    const latencies = Array.from({ length: 10 }, () => 100);
    const result = detector.detect('shipping-rates', latencies, 110);

    expect(result.isAnomaly).toBe(false);
    expect(result.spikeFactor).toBe(1.1);
    expect(result.decisionRef).toBe('shipping-rates');
  });

  it('flags a tenfold spike with correct spike factor', () => {
    const detector = new AnomalyDetector(20, 3);
    const latencies = Array.from({ length: 10 }, () => 100);
    const result = detector.detect('shipping-rates', latencies, 1000);

    expect(result.isAnomaly).toBe(true);
    expect(result.spikeFactor).toBe(10);
    expect(result.rollingAverage).toBe(100);
    expect(result.currentLatency).toBe(1000);
  });

  it('does not flag when history is empty', () => {
    const detector = new AnomalyDetector();
    const result = detector.detect('shipping-rates', [], 5000);

    expect(result.isAnomaly).toBe(false);
    expect(result.spikeFactor).toBe(0);
    expect(result.rollingAverage).toBe(0);
  });

  it('flags at the spike threshold boundary', () => {
    const detector = new AnomalyDetector(20, 3);
    const latencies = [100, 100, 100];
    const result = detector.detect('shipping-rates', latencies, 300);

    expect(result.isAnomaly).toBe(true);
    expect(result.spikeFactor).toBe(3);
  });

  it('does not flag just below the spike threshold', () => {
    const detector = new AnomalyDetector(20, 3);
    const latencies = [100, 100, 100];
    const result = detector.detect('shipping-rates', latencies, 299);

    expect(result.isAnomaly).toBe(false);
    expect(result.spikeFactor).toBe(2.99);
  });
});
