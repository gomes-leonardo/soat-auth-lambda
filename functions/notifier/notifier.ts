import { HttpEvent, HttpResult, json, log, parseBody, sameSecret } from '../shared/http';
import { AlertPayload, formatAlert } from './format';

export interface NotifierDeps {
  webhookSecret(): Promise<string>;
  publish(subject: string, message: string): Promise<void>;
  environment: string;
}

/**
 * Recebe o webhook do workflow de alertas e publica no topico SNS, que entrega
 * por e-mail. A Function URL e publica, entao a primeira coisa e conferir o
 * segredo compartilhado: sem ele, nada e publicado.
 */
export function createNotifier(deps: NotifierDeps) {
  return async (event: HttpEvent): Promise<HttpResult> => {
    const presented = bearer(event.headers?.authorization ?? event.headers?.Authorization);
    if (!presented || !sameSecret(presented, await deps.webhookSecret())) {
      log('warn', 'notifier refused: invalid secret');
      return json(401, { error: 'unauthorized' });
    }

    const payload = parseBody(event);
    if (!payload) {
      return json(400, { error: 'invalid_payload' });
    }

    const email = formatAlert(payload as AlertPayload, deps.environment);
    await deps.publish(email.subject, email.message);
    log('info', 'alert notified', { issueId: payload.issueId, state: payload.state });
    return json(202, { status: 'published' });
  };
}

function bearer(header: string | undefined): string | null {
  const match = /^Bearer\s+(.+)$/i.exec(header ?? '');
  return match ? match[1].trim() : null;
}
