import { pino } from 'pino';

const isDev = process.env.NODE_ENV !== 'production';

export const logger = pino({
  level: process.env.LOG_LEVEL ?? (isDev ? 'debug' : 'info'),
  // Never log balances or keys (privacy rule, PRODUCT §14). Redact common sensitive paths.
  redact: {
    paths: ['req.headers.authorization', '*.privateKey', '*.secretKey', '*.serviceAccount'],
    censor: '[redacted]',
  },
  ...(isDev
    ? { transport: { target: 'pino-pretty', options: { colorize: true, translateTime: 'SYS:HH:MM:ss' } } }
    : {}),
});
