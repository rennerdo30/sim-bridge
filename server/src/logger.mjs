// Console-only generic diagnostics. Never create directories/files or include
// request paths, addresses, identifiers, credentials or exception text.
const levels = { error: 0, warn: 1, info: 2, debug: 3 };
const configured = (process.env.SIM_BRIDGE_LOG_LEVEL || 'info').toLowerCase();
const threshold = levels[configured] ?? levels.info;
const write = (level, message) => {
  if (levels[level] > threshold) return;
  (level === 'error' || level === 'warn' ? console.error : console.log)(
    `${new Date().toISOString()} ${level.toUpperCase()} ${message}`,
  );
};
export const log = {
  error: message => write('error', message),
  warn: message => write('warn', message),
  info: message => write('info', message),
  debug: message => write('debug', message),
  flush: () => Promise.resolve(),
};
