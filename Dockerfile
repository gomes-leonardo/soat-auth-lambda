# Substituto local da Function URL de autenticacao por CPF, usado no cluster
# Kind antes da ativacao da AWS. Na AWS o mesmo codigo roda como Lambda.
FROM node:22-alpine AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY tsconfig.json ./
COPY scripts ./scripts
COPY functions ./functions
COPY local ./local
RUN npm run build

FROM node:22-alpine
RUN apk add --no-cache tini
WORKDIR /app
COPY --from=build /app/dist/local-server.js ./
USER node
EXPOSE 8080
ENTRYPOINT ["/sbin/tini", "--"]
CMD ["node", "local-server.js"]
