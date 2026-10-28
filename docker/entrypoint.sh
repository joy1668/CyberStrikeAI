#!/usr/bin/env bash
# 容器入口：准备可写的持久化目录、首次生成 config.yaml，再以非 root 用户启动服务。
set -euo pipefail

APP_DIR="${APP_DIR:-/app}"
DATA_DIR="${DATA_DIR:-${APP_DIR}/data}"
CONFIG_FILE="${CONFIG_FILE:-${DATA_DIR}/config.yaml}"
SERVICE_USER="${SERVICE_USER:-cyberstrike}"

log() { printf '[entrypoint] %s\n' "$*" >&2; }

mkdir -p "${DATA_DIR}/chat_uploads" "${DATA_DIR}/tmp" "${DATA_DIR}/log"

# 首次运行时数据卷属于 root，修正属主后再降权
if [ "$(id -u)" -eq 0 ]; then
    chown -R "${SERVICE_USER}:${SERVICE_USER}" "${DATA_DIR}"
    exec gosu "${SERVICE_USER}" "$0" "$@"
fi

# 首次启动：从镜像内置模板生成 config.yaml
if [ ! -s "${CONFIG_FILE}" ]; then
    log "未找到 ${CONFIG_FILE}，从 config.example.yaml 生成默认配置"
    cp "${APP_DIR}/config.example.yaml" "${CONFIG_FILE}"
else
    log "使用已有配置 ${CONFIG_FILE}"
fi

# config.yaml 里的 tools_dir / skills_dir / roles_dir / agents_dir / knowledge_base
# 相对配置文件所在目录解析。用软链接指回镜像内置内容，同时允许用户把自定义
# 目录直接放进数据卷来覆盖它们。
for name in tools skills roles agents knowledge_base; do
    target="${DATA_DIR}/${name}"
    if [ ! -e "${target}" ] && [ -d "${APP_DIR}/${name}" ]; then
        ln -s "${APP_DIR}/${name}" "${target}"
    fi
done

# 以下运行目录固定相对进程工作目录（${APP_DIR}），重定向到数据卷以便持久化
for name in chat_uploads tmp log; do
    target="${APP_DIR}/${name}"
    if [ ! -e "${target}" ]; then
        ln -s "${DATA_DIR}/${name}" "${target}"
    fi
done

# 未显式传入 -config 时补上默认配置路径
has_config=0
for arg in "$@"; do
    case "${arg}" in
        -config|--config|-config=*|--config=*) has_config=1 ;;
    esac
done
if [ "$#" -eq 0 ]; then
    set -- -config "${CONFIG_FILE}"
elif [ "${has_config}" -eq 0 ]; then
    set -- -config "${CONFIG_FILE}" "$@"
fi

log "启动 cyberstrike-ai $*"
exec "${APP_DIR}/cyberstrike-ai" "$@"
