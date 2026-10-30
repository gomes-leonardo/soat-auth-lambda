import { Pool } from 'pg';
import { HttpEvent, HttpResult, json, log } from '../shared/http';
import { readParameter } from '../shared/ssm';
import { createAuthCpf } from './auth-cpf';
import { findActiveClientId } from './client-lookup';
import { signClientToken } from './token';

let pool: Pool | undefined;

/**
 * Na AWS, a URL do banco e o segredo do JWT vem do Parameter Store, cujos
 * NOMES chegam por variavel de ambiente. O pool e criado uma vez por container
 * e reaproveitado entre invocacoes.
 */
async function getPool(): Promise<Pool> {
  if (!pool) {
    const connectionString = await readParameter(requiredEnv('DB_URL_PARAM'));
    pool = new Pool({ connectionString, max: 2, idleTimeoutMillis: 10_000 });
  }
  return pool;
}

const authCpf = createAuthCpf({
  findActiveClientId: async (cpf) => findActiveClientId(await getPool(), cpf),
  signToken: async (clientId) =>
    signClientToken(clientId, await readParameter(requiredEnv('JWT_SECRET_PARAM'))),
});

export async function handler(event: HttpEvent): Promise<HttpResult> {
  try {
    return await authCpf(event);
  } catch (err) {
    log('error', 'cpf auth failed', { err: String(err) });
    return json(500, { error: 'internal_error' });
  }
}

function requiredEnv(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`Variavel ${name} nao configurada`);
  return value;
}
