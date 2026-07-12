# Imagen de demostración para escaneo de contenedores en el gate de producción
FROM node:26-alpine AS base

WORKDIR /app

COPY package.json ./
RUN npm install --omit=dev --ignore-scripts

COPY src ./src

ENV NODE_ENV=production
EXPOSE 3000

USER node
CMD ["node", "src/index.js"]
