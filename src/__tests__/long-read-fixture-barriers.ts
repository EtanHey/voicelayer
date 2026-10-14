/** A recorded event channel: tests wait for an exact transition, never timed polling. */
export function fixtureBarrier<T>() {
  const values: T[] = [];
  const waiters = new Map<number, (value: T) => void>();
  return {
    values,
    push(value: T) {
      const index = values.push(value) - 1;
      waiters.get(index)?.(value);
      waiters.delete(index);
    },
    at(index: number): Promise<T> {
      if (index < values.length) return Promise.resolve(values[index]);
      return new Promise<T>((resolve) => waiters.set(index, resolve));
    },
  };
}

export function deferredFixture<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((r) => { resolve = r; });
  return { promise, resolve };
}

/** Drain promise observers to test that a gated operation has not advanced. No timer. */
export async function fixtureCheckpoint() {
  for (let i = 0; i < 16; i++) await Promise.resolve();
}
