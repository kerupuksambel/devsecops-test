# Base images are pinned by tag AND digest. The tag says what it is; the digest guarantees
# the exact bytes. Bump both together through a Dependabot/Renovate pull request.

# ---- Build stage: full Go toolchain, never shipped ----
FROM golang:1.27.3-alpine3.24@sha256:d200d2dd76b03a99b52651fd1325aff7dcd35422c35c01bac56571b0507f3deb AS build

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
