# The relay as one container. It has no runtime dependencies: Node runs the TypeScript sources directly.
# Build with companion/ as the context, so the shared wire reader travels with the relay.
# Configuration comes only from environment variables (docs/spec/companion-v0.md section 13); none is set here.
FROM node:26-alpine
WORKDIR /app
COPY relay/package.json ./relay/package.json
COPY relay/src ./relay/src
COPY shared ./shared
USER node
ENV NODE_ENV=production
EXPOSE 8080
CMD ["node", "relay/src/main.ts"]
