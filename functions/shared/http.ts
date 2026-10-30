import { timingSafeEqual } from 'crypto';
import type { APIGatewayProxyEventV2, APIGatewayProxyStructuredResultV2 } from 'aws-lambda';

export type HttpEvent = Pick<APIGatewayProxyEventV2, 'body' | 'isBase64Encoded' | 'headers'>;
export type HttpResult = APIGatewayProxyStructuredResultV2;

export function json(statusCode: number, body: object): HttpResult {
  return {
    statusCode,
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body),
  };
}

/** Corpo da Function URL como objeto; `null` quando nao e JSON valido. */
export function parseBody(event: HttpEvent): Record<string, unknown> | null {
  if (!event.body) return null;
  const raw = event.isBase64Encoded
    ? Buffer.from(event.body, 'base64').toString('utf8')
    : event.body;
  try {
    const parsed: unknown = JSON.parse(raw);
    return parsed && typeof parsed === 'object' ? (parsed as Record<string, unknown>) : null;
  } catch {
    return null;
  }
}

/** Comparacao em tempo constante de dois segredos. */
export function sameSecret(presented: string, secret: string): boolean {
  const a = Buffer.from(presented);
  const b = Buffer.from(secret);
  return a.length === b.length && timingSafeEqual(a, b);
}

/** Log em JSON numa linha, no formato que o CloudWatch e o New Relic indexam. */
export function log(level: 'info' | 'warn' | 'error', msg: string, fields: object = {}): void {
  process.stdout.write(
    `${JSON.stringify({ level, msg, ...fields, time: new Date().toISOString() })}\n`,
  );
}
