export interface AnomalyResult {
  isAnomaly: boolean;
  currentLatency: number;
  rollingAverage: number;
  spikeFactor: number;
  decisionRef: string;
}

export class AnomalyDetector {
  private windowSize: number;
  private spikeThreshold: number;

  constructor(windowSize = 20, spikeThreshold = 3) {
    this.windowSize = windowSize;
    this.spikeThreshold = spikeThreshold;
  }

  detect(
    decisionRef: string,
    latencies: number[],
    currentLatency: number,
  ): AnomalyResult {
    const recentWindow = latencies.slice(-this.windowSize);
    if (recentWindow.length === 0) {
      return {
        isAnomaly: false,
        currentLatency,
        rollingAverage: 0,
        spikeFactor: 0,
        decisionRef,
      };
    }

    const rollingAverage =
      recentWindow.reduce((sum, value) => sum + value, 0) / recentWindow.length;
    const spikeFactor = rollingAverage > 0 ? currentLatency / rollingAverage : 0;

    return {
      isAnomaly: spikeFactor >= this.spikeThreshold,
      currentLatency,
      rollingAverage: Math.round(rollingAverage),
      spikeFactor: Math.round(spikeFactor * 100) / 100,
      decisionRef,
    };
  }
}
