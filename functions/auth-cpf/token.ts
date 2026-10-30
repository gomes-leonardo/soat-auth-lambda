import jwt from 'jsonwebtoken';

export const CLIENT_TOKEN_ISSUER = 'soat-auth-lambda';
export const TOKEN_TTL_SECONDS = 3600;

/** Token de cliente no formato que a aplicacao e o Kong esperam. */
export function signClientToken(clientId: string, secret: string): string {
  return jwt.sign({ sub: clientId, role: 'client' }, secret, {
    algorithm: 'HS256',
    issuer: CLIENT_TOKEN_ISSUER,
    expiresIn: TOKEN_TTL_SECONDS,
  });
}
