/**
 * Fixed-window rate limiter for authentication-sensitive endpoints.
 *
 * The relay's owner key and bridge enrollment verifier are the only things
 * standing between the public network and a bridge, so guessing attempts must
 * be expensive. State is per-process and in memory: a relay restart forgives
 * offenders, which is acceptable for a guessing defence.
 */
const WINDOW_MS = 60_000;
// Sweep on the same cadence as the window, so a flood from many source
// addresses cannot leave several windows' worth of dead buckets in memory.
const SWEEP_INTERVAL_MS = WINDOW_MS;

const buckets = new Map();

const keyFor = (scope, client) => `${scope}:${client}`;

/**
 * Records one attempt and reports whether it is allowed.
 * @returns {{allowed: boolean, remaining: number, retryAfterSeconds: number}}
 */
export const consume = (scope, client, limit, now = Date.now()) => {
  const key = keyFor(scope, client);
  const bucket = buckets.get(key);
  if (!bucket || now >= bucket.resetAt) {
    buckets.set(key, { count: 1, resetAt: now + WINDOW_MS });
    return { allowed: true, remaining: limit - 1, retryAfterSeconds: 0 };
  }
  bucket.count += 1;
  const retryAfterSeconds = Math.max(1, Math.ceil((bucket.resetAt - now) / 1000));
  if (bucket.count > limit) {
    return { allowed: false, remaining: 0, retryAfterSeconds };
  }
  return { allowed: true, remaining: limit - bucket.count, retryAfterSeconds };
};

/** Clears a client's attempts after a success, so honest users are never locked out. */
export const reset = (scope, client) => {
  buckets.delete(keyFor(scope, client));
};

/** Drops expired buckets so the map cannot grow without bound. */
export const sweep = (now = Date.now()) => {
  for (const [key, bucket] of buckets) {
    if (now >= bucket.resetAt) buckets.delete(key);
  }
};

export const startSweeping = () => {
  const timer = setInterval(() => sweep(), SWEEP_INTERVAL_MS);
  timer.unref?.();
  return timer;
};

export const _buckets = buckets;
