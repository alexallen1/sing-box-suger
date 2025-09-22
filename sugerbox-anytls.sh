#!/usr/bin/env bash
set -euo pipefail

# =====================================================
# Docker版本：一键搭建 sing-box anytls 服务（自签证书）
# - 使用 Docker 容器化部署
# - 端口使用 2053
# - 自动生成自签证书和UUID
# =====================================================

WORKDIR="${WORKDIR:-/root/sing-box-anytls}"
CONFIG="${WORKDIR}/config.json"
CERT="${WORKDIR}/cert.pem"
KEY="${WORKDIR}/private.key"
UUID_FILE="${WORKDIR}/uuid.txt"
CONTAINER_NAME="${CONTAINER_NAME:-sing-box-anytls}"
CN="${CN:-www.w3schools.com}"    # 默认 CN（示例域名）
DAYS="${DAYS:-365}"
HOST_PORT="${HOST_PORT:-2053}"
LISTEN_PORT="${LISTEN_PORT:-2053}"
IMAGE="${IMAGE:-ghcr.io/sagernet/sing-box:latest}"

# 获取公网IPv4地址
get_public_ip() {
  local ip=""
  
  # 方式1：使用 ipify.org
  echo "==> 获取公网IP地址..."
  ip=$(curl -s -4 --connect-timeout 10 https://api.ipify.org 2>/dev/null)
  
  if [[ -n "$ip" && "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    echo "==> 检测到公网IP（方式1）：$ip"
    PUBLIC_IP="$ip"
    return 0
  fi
  
  # 方式2：使用 icanhazip.com
  echo "==> 方式1失败，尝试方式2..."
  ip=$(curl -s -4 --connect-timeout 10 https://ipv4.icanhazip.com 2>/dev/null)
  
  if [[ -n "$ip" && "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    echo "==> 检测到公网IP（方式2）：$ip"
    PUBLIC_IP="$ip"
    return 0
  fi
  
  # 都失败了
  echo "==> 警告：无法自动获取公网IP，请手动替换连接信息中的 'your-server-ip'"
  PUBLIC_IP="your-server-ip"
  return 1
}

# 生成或获取UUID
generate_or_get_uuid() {
  if [[ -f "${UUID_FILE}" ]]; then
    USER_UUID=$(cat "${UUID_FILE}")
    echo "==> 使用已保存的UUID：${USER_UUID}"
  else
    # 生成新的UUID
    if command -v uuidgen >/dev/null 2>&1; then
      USER_UUID=$(uuidgen | tr '[:upper:]' '[:lower:]')
    else
      # 如果没有uuidgen，使用openssl生成
      USER_UUID=$(openssl rand -hex 16 | sed 's/\(..\)/\1/g' | sed 's/^\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)$/\1\2\3\4-\5\6-\7\8-\9\10-\11\12\13\14\15\16/')
    fi
    echo "${USER_UUID}" > "${UUID_FILE}"
    echo "==> 生成新的UUID：${USER_UUID}"
  fi
}

# 检查 Docker 是否安装
check_requirements() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "错误：未安装 Docker。请先安装 Docker 后重试。"
    echo "安装命令：curl -fsSL https://get.docker.com | sh"
    exit 1
  fi
  
  if ! docker info >/dev/null 2>&1; then
    echo "错误：Docker 服务未运行。请启动 Docker 服务。"
    echo "启动命令：sudo systemctl start docker"
    exit 1
  fi
}

# 显示脚本信息和确认提示
echo ""
echo "即将通过"
echo "@https://raw.githubusercontent.com/alexallen1/sing-box-suger/refs/heads/main/sugerbox-anytls.sh"
echo ""
echo "下载sing-box的docker版并搭建anytls服务端，"
echo "配置文件保存在：${WORKDIR}"
echo ""
echo "按回车继续，输入n取消"
read -r user_input

if [[ "${user_input,,}" == "n" ]]; then
    echo "操作已取消。"
    exit 0
fi

echo "检查 Docker 环境..."
check_requirements

# 获取公网IP
get_public_ip

mkdir -p "${WORKDIR}"
chmod 700 "${WORKDIR}"

# 生成或获取UUID
generate_or_get_uuid

# 生成自签证书（若不存在）
if [[ ! -f "${CERT}" || ! -f "${KEY}" ]]; then
  echo "生成自签证书：CN=${CN}，有效期 ${DAYS} 天"
  openssl req -x509 -newkey rsa:2048 -sha256 -nodes \
    -keyout "${KEY}" -out "${CERT}" -days "${DAYS}" \
    -subj "/CN=${CN}/O=Self-Signed Testing/C=XX"
  chmod 600 "${KEY}"
  chmod 644 "${CERT}"
  echo "已生成证书：${CERT} 和 私钥：${KEY}"
else
  echo "检测到已存在证书与私钥，跳过生成。"
fi

# 写入 sing-box 配置（anytls，端口${LISTEN_PORT}）
write_config() {
  cat > "${CONFIG}" <<JSON
{
  "log": {
    "disabled": false,
    "level": "info",
    "output": "stderr"
  },
  "inbounds": [
    {
      "type": "anytls",
      "listen": "::",
      "listen_port": ${LISTEN_PORT},
      "users": [
        {
          "name": "user1",
          "password": "${USER_UUID}"
        }
      ],
      "tls": {
        "enabled": true,
        "certificate_path": "/data/cert.pem",
        "key_path": "/data/private.key"
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct"
    }
  ]
}
JSON
  chmod 600 "${CONFIG}"
  echo "==> 配置写入：${CONFIG}"
}

# 运行容器
run_container() {
  # 若已存在旧容器，先移除
  if docker ps -a --format '{{.Names}}' | grep -wq "${CONTAINER_NAME}"; then
    echo "==> 检测到已有容器 ${CONTAINER_NAME}，将重新创建..."
    docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
  fi

  echo "==> 拉取镜像：${IMAGE}"
  if ! docker pull "${IMAGE}"; then
    echo "警告：无法拉取镜像 ${IMAGE}，将尝试使用本地镜像"
    # 检查本地是否存在镜像
    if ! docker images --format "{{.Repository}}:{{.Tag}}" | grep -q "^${IMAGE}$"; then
      echo "错误：本地也没有找到镜像 ${IMAGE}"
      echo "请检查网络连接或手动拉取镜像：docker pull ${IMAGE}"
      exit 1
    fi
  fi

  echo "==> 启动容器：${CONTAINER_NAME}（映射端口 ${HOST_PORT}->${LISTEN_PORT}）"
  # anytls 一般走 TCP，这里仅映射 TCP；如需 UDP，追加 -p ${HOST_PORT}:${LISTEN_PORT}/udp
  docker run -d \
    --name "${CONTAINER_NAME}" \
    --restart=always \
    -p ${HOST_PORT}:${LISTEN_PORT}/tcp \
    -v "${WORKDIR}:/data:ro" \
    "${IMAGE}" run -c /data/config.json

  sleep 1
  docker ps --filter "name=${CONTAINER_NAME}"
  echo "==> 日志查看： docker logs -f ${CONTAINER_NAME}"
}

# 调用函数执行部署
write_config
run_container

echo ""
echo "==> ✅ 全部完成！"
echo ""
echo "  节点链接："
echo "  anytls://${USER_UUID}@${PUBLIC_IP}:${HOST_PORT}?security=tls&sni=${CN}&allowInsecure=1&type=tcp#anytls-server"
echo "─────────────────────────────────────────────────────────────"
echo "                        节点信息                              "
echo "─────────────────────────────────────────────────────────────"
echo "  服务器：${PUBLIC_IP}"
echo "  端口：${HOST_PORT}"
echo "  密码：${USER_UUID}"
echo "─────────────────────────────────────────────────────────────"
echo "  💡 配置文件保存在：${WORKDIR}"
echo "  💡 删除服务：docker rm -f ${CONTAINER_NAME}"
echo "─────────────────────────────────────────────────────────────"
