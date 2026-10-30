import { Pool } from 'pg';

/**
 * A unica pergunta que a funcao faz ao banco: existe cliente ATIVO, nao
 * excluido, com este CPF? Inexistente, inativo e excluido dao a mesma
 * resposta (null), para que o 401 nao revele qual dos tres aconteceu.
 */
export async function findActiveClientId(pool: Pool, cpf: string): Promise<string | null> {
  const result = await pool.query<{ id: string }>(
    `SELECT id FROM clients WHERE cpf_cnpj = $1 AND status = 'ATIVO' AND deleted_at IS NULL`,
    [cpf],
  );
  return result.rows[0]?.id ?? null;
}
