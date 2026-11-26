# Base images are pinned by tag AND digest. The tag says what it is; the digest guarantees
# the exact bytes. Bump both together through a Dependabot/Renovate pull request.

# ---- Build stage: full Go toolchain, never shipped ----
FROM golang:1.27.4-alpine3.24@sha256:70bd7ddea8b6cbe5d6943cde279d6b67feb10cc924fb9100d1d8757c1575b280 AS build

WORKDIR /src

# Static binary, reproducible paths, and no toolchain download at build time.
ENV CGO_ENABLED=0 \
    GOFLAGS=-trimpath \
    GOTOOLCHAIN=local

# Dependencies first for layer caching; go.sum pins every module by hash.
COPY go.mod go.sum ./
RUN go mod download && go mod verify

COPY cmd/ ./cmd/
COPY internal/ ./internal/
RUN go build -ldflags="-s -w" -o /out/api ./cmd/api

# ---- Runtime stage: distroless, no shell, no package manager ----
FROM gcr.io/distroless/static-debian13:nonroot@sha256:18f4cc26c9ffa7f20a359298be7deadac5c607c8e03a02b8119f1a5fc2f82c99

LABEL org.opencontainers.image.title="devsecops-api" \
      org.opencontainers.image.source="https://github.com/example/devsecops-home-test"

COPY --from=build /out/api /api

# UID/GID 65532 ("nonroot") from the distroless image. ECS also sets
# readonlyRootFilesystem; the app writes nothing to disk.
USER 65532:65532
EXPOSE 8080

# No secrets here: configuration comes from task-definition environment variables,
# and the database uses IAM authentication, so there is no password to inject.
ENTRYPOINT ["/api"]
