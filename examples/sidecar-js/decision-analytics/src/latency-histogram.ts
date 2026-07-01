export class LatencyHistogram {
  private values: number[] = [];

  add(value: number): void {
    this.values.push(value);
  }

  addAll(values: number[]): void {
    this.values.push(...values);
  }

  get count(): number {
    return this.values.length;
  }

  get average(): number {
    if (this.values.length === 0) return 0;
    return this.values.reduce((sum, value) => sum + value, 0) / this.values.length;
  }

  percentile(percentile: number): number {
    if (this.values.length === 0) return 0;
    const sorted = [...this.values].sort((left, right) => left - right);
    const index = Math.ceil((percentile / 100) * sorted.length) - 1;
    return sorted[Math.max(0, index)];
  }

  get p95(): number {
    return this.percentile(95);
  }

  get p99(): number {
    return this.percentile(99);
  }

  get min(): number {
    return this.values.length === 0 ? 0 : Math.min(...this.values);
  }

  get max(): number {
    return this.values.length === 0 ? 0 : Math.max(...this.values);
  }
}
