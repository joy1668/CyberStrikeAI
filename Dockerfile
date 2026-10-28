# syntax=docker/dockerfile:1

# --- 构建阶段 ---------------------------------------------------------------
FROM golang:1.25-bookworm AS builder

WORKDIR /src

# 依赖层单独缓存：go.mod/go.sum 变化时才重新下载
COPY go.mod go.sum ./
ARG GOPROXY=https://proxy.golang.org,direct
ENV GOPROXY=${GOPROXY}
RUN --mount=type=cache,target=/go/pkg/mod \
    go mod download

COPY . .

# SQLite 驱动 mattn/go-sqlite3 需要 CGO
ARG TARGETOS=linux
ARG TARGETARCH
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=1 GOOS=${TARGETOS} GOARCH=${TARGETARCH} \
    go build -trimpath -ldflags="-s -w" -o /out/cyberstrike-ai ./cmd/server

# --- 运行阶段 ---------------------------------------------------------------
FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive \
    APP_DIR=/app \
    DATA_DIR=/app/data \
    TZ=UTC \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gosu \
        python3 \
        python3-venv \
        python3-pip \
        gcc \
        python3-dev \
        libffi-dev \
    && rm -rf /var/lib/apt/lists/*

# 工具脚本（api-fuzzer、http-intruder 等）依赖这些 Python 包
COPY requirements.txt /tmp/requirements.txt
RUN python3 -m venv /opt/venv \
    && /opt/venv/bin/pip install --upgrade pip \
    && /opt/venv/bin/pip install -r /tmp/requirements.txt \
    && rm -f /tmp/requirements.txt \
    && apt-get purge -y --auto-remove gcc python3-dev libffi-dev \
    && rm -rf /var/lib/apt/lists/*

ENV PATH=/opt/venv/bin:${PATH} \
    VIRTUAL_ENV=/opt/venv

WORKDIR ${APP_DIR}

# 运行时必需的内容：二进制、前端资源、内置工具/角色/skills/agents、配置模板
COPY --from=builder /out/cyberstrike-ai ${APP_DIR}/cyberstrike-ai
COPY web ${APP_DIR}/web
COPY tools ${APP_DIR}/tools
COPY skills ${APP_DIR}/skills
COPY roles ${APP_DIR}/roles
COPY agents ${APP_DIR}/agents
COPY knowledge_base ${APP_DIR}/knowledge_base
COPY mcp-servers ${APP_DIR}/mcp-servers
COPY config.example.yaml ${APP_DIR}/config.example.yaml
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh

RUN chmod +x /usr/local/bin/entrypoint.sh \
    && useradd --system --uid 10001 --home-dir ${APP_DIR} --shell /usr/sbin/nologin cyberstrike \
    && mkdir -p ${DATA_DIR} \
    && chown -R cyberstrike:cyberstrike ${APP_DIR}

# 以 root 启动，由 entrypoint 转换到非 root 用户；这样数据卷属主能被自动修正
VOLUME ["/app/data"]

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD curl -fsS -k -L -o /dev/null http://127.0.0.1:8080/ || exit 1

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
