# Greptile HUD backend ("vibecoders") — static, distroless-ish image.
# Build: docker build -t greptilehud-backend .
# Run:   docker run --rm -p 8080:8080 -e DATABASE_URL=... greptilehud-backend

FROM golang:1.26-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -ldflags "-s -w" -o /out/server .

FROM alpine:3.21
RUN adduser -D -u 10001 appuser
USER appuser
COPY --from=build /out/server /usr/local/bin/server
EXPOSE 8080
CMD ["/usr/local/bin/server"]
