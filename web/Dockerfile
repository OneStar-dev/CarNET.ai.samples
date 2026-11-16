# The micro website in a container: docker build -t carnet-demo . && docker run -e CARNET_API_KEY=your-key -p 8080:8080 carnet-demo
FROM node:22-alpine
WORKDIR /app
COPY package.json server.js ./
COPY public ./public
ENV HOST=0.0.0.0 PORT=8080 NODE_ENV=production
USER node
EXPOSE 8080
CMD ["node", "server.js"]
