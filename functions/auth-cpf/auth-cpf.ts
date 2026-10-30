import { HttpEvent, HttpResult, json, log, parseBody, sameSecret } from '../shared/http';
import { normalizeCpf } from './cpf';
import { TOKEN_TTL_SECONDS } from './token';

export interface AuthCpfDeps {
  findActiveClientId(cpf: string): Promise<string | null>;
  signToken(clientId: string): Promise<string>;
  /**
   * Segredo que o Kong injeta em X-Soat-Origin. Na AWS e obrigatorio: a
   * Function URL e publica, e sem a checagem quem a chamasse direto escaparia
   * do rate limit do gateway. O substituto local, so alcancavel de dentro do
   * cluster, nao usa.
   */
  originSecret?(): Promise<string>;
}

export const ORIGIN_HEADER = 'x-soat-origin';

/**
 * POST { cpf } -> 200 com JWT de cliente, 400 para CPF invalido, 401 para
 * qualquer CPF valido sem cliente ativo. Separado do handler da AWS para ser
 * testado sem banco e sem SSM.
 */
export function createAuthCpf(deps: AuthCpfDeps) {
  return async (event: HttpEvent): Promise<HttpResult> => {
    if (deps.originSecret) {
      const presented = event.headers?.[ORIGIN_HEADER];
      if (!presented || !sameSecret(presented, await deps.originSecret())) {
        log('warn', 'cpf auth refused: call did not come through the gateway');
        return json(403, { error: 'forbidden' });
      }
    }

    const cpf = normalizeCpf(parseBody(event)?.cpf);
    if (!cpf) {
      return json(400, { error: 'invalid_cpf' });
    }

    const clientId = await deps.findActiveClientId(cpf);
    if (!clientId) {
      log('warn', 'cpf auth refused', { cpf: maskCpf(cpf) });
      return json(401, { error: 'unauthorized' });
    }

    const token = await deps.signToken(clientId);
    log('info', 'cpf auth granted', { clientId });
    return json(200, { access_token: token, token_type: 'Bearer', expires_in: TOKEN_TTL_SECONDS });
  };
}

/** CPF e dado pessoal: o log guarda so o suficiente para correlacionar. */
function maskCpf(cpf: string): string {
  return `***.${cpf.slice(3, 6)}.***-**`;
}
