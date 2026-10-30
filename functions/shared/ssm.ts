import { GetParameterCommand, SSMClient } from '@aws-sdk/client-ssm';

const client = new SSMClient({});
const cache = new Map<string, string>();

/**
 * Le um SecureString do Parameter Store uma vez por container. Segredos ficam
 * fora das variaveis de ambiente da funcao e fora do state do Terraform dela.
 */
export async function readParameter(name: string): Promise<string> {
  const cached = cache.get(name);
  if (cached !== undefined) return cached;

  const result = await client.send(new GetParameterCommand({ Name: name, WithDecryption: true }));
  const value = result.Parameter?.Value;
  if (!value) {
    throw new Error(`Parametro SSM vazio ou inexistente: ${name}`);
  }
  cache.set(name, value);
  return value;
}
