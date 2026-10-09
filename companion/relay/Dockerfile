# The relay as one container. It has no runtime dependencies: Node runs the TypeScript sources directly.
# Configuration comes only from environment variables (docs/spec/companion-v0.md section 13); none is set here.
FROM node:26-alpine
WORKDIR /app
COPY package.json ./
COPY src ./src
USER node
ENV NODE_ENV=production
EXPOSE 8080
CMD ["node", "src/main.ts"]
