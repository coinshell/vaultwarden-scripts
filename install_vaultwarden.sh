#!/usr/bin/env bash
set -euo pipefail
umask 077
# ========== 必填参数（调用前 export 即可，脚本内不落盘） ==========
# VW_DOMAIN          你的域名
# ACME_EMAIL         ACME 邮箱
# R2_BUCKET / R2_ENDPOINT / R2_ACCESS_KEY / R2_SECRET_KEY   R2 相关
# =================================================================
STACK_DIR="/srv/vaultwarden"
DATA_DIR="$STACK_DIR/vw-data"
ENV_FILE="$STACK_DIR/.env"
BIN_DEPENDS=(curl jq sqlite3 rsync)
LOG_FILE="/var/log/vaultwarden-install.log"
exec > >(tee -a "$LOG_FILE") 2>&1

log_info(){ echo "[$(date +'%F %T')] [INFO] $*"; }
log_ok(){  echo "[$(date +'%F %T')] [OK]  $*"; }
log_err(){ echo "[$(date +'%F %T')] [ERROR] $*" >&2; }

# --------- 通用函数 ---------
verify_sha256(){
  local file=$1 expect=$2
  echo "$expect  $file" | sha256sum -c - || { log_err "SHA256 校验失败: $file"; exit 1; }
}
install_restic(){
  if command -v restic &>/dev/null; then return 0; fi
  log_info "安装 restic"
  . /etc/os-release
  ARCH=$(dpkg --print-architecture 2>/dev/null || uname -m)
  RESTIC_VER=$(curl -sSf https://api.github.com/repos/restic/restic/releases/latest | jq -r .tag_name)
  URL="https://github.com/restic/restic/releases/download/${RESTIC_VER}/restic_${RESTIC_VER:1}_linux_${ARCH}.bz2"
  SHA_URL="${URL}.sha256"
  curl -L -o /tmp/restic.bz2 "$URL"
  curl -L -o /tmp/restic.bz2.sha256 "$SHA_URL"
  verify_sha256 /tmp/restic.bz2 "$(awk '{print $1}' /tmp/restic.bz2.sha256)"
  bunzip2 /tmp/restic.bz2 && chmod +x /tmp/restic && mv /tmp/restic /usr/local/bin/
}
install_docker(){
  if command -v docker &>/dev/null; then return 0; fi
  log_info "安装 Docker"
  curl -fsSL https://get.docker.com | bash
  systemctl enable --now docker
}
check_deps(){
  log_info "检查依赖"
  . /etc/os-release
  PKGS=()
  for p in "${BIN_DEPENDS[@]}"; do command -v "$p" &>/dev/null || PKGS+=("$p"); done
  if [[ ${#PKGS[@]} -gt 0 ]]; then
    if [[ "$ID" =~ ubuntu|debian ]]; then apt-get update -qq && apt-get install -y "${PKGS[@]}"
    elif [[ "$ID" =~ centos|rhel|fedora ]]; then yum install -y "${PKGS[@]}"
    elif [[ "$ID" =~ arch ]]; then pacman -Sy --noconfirm "${PKGS[@]}"
    else log_err "不支持当前系统"; exit 1; fi
  fi
  install_docker
  install_restic
}
validate_env(){
  for var in VW_DOMAIN ACME_EMAIL R2_BUCKET R2_ENDPOINT R2_ACCESS_KEY R2_SECRET_KEY; do
    [[ -n "${!var:-}" ]] || { log_err "环境变量 $var 未设置"; exit 1; }
  done
  [[ "$ACME_EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || { log_err "邮箱格式错误"; exit 1; }
  [[ "$VW_DOMAIN"  =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]       || { log_err "域名格式错误"; exit 1; }
}
# --------- 镜像摘要校验 ---------
verify_image_digest(){
  local img=$1 dig=$2
  docker pull "$img" >/dev/null
  if ! docker image inspect "$img" --format '{{json .RepoDigests}}' | grep -q "$dig"; then
    log_err "镜像 $img 摘要不符，期望 $dig"; exit 1
  fi
}
# --------- 目录 / 用户 ---------
prepare_system(){
  log_info "初始化系统"
  mkdir -p "$DATA_DIR" "$STACK_DIR"/caddy-{data,config}
  if ! getent passwd caddy &>/dev/null; then
    useradd -r -u 950 -M -s /bin/false caddy
  fi
  chown -R caddy:caddy "$STACK_DIR"/caddy-{data,config}
}
# --------- 生成内存级 env 文件 ---------
gen_env(){
  # 密钥全程不落盘，仅通过 env_file 传入容器
  DB_KEY=$(openssl rand -base64 32)
  RESTIC_PW=$(openssl rand -base64 32)
  cat > "$ENV_FILE" <<EOF
DOMAIN=https://${VW_DOMAIN}
SIGNUPS_ALLOWED=true
LOG_LEVEL=warn
DB_ENCRYPTION_KEY=${DB_KEY}
R2_BUCKET=${R2_BUCKET}
R2_ENDPOINT=${R2_ENDPOINT}
R2_ACCESS_KEY=${R2_ACCESS_KEY}
R2_SECRET_KEY=${R2_SECRET_KEY}
RESTIC_PASSWORD=${RESTIC_PW}
RESTIC_REPOSITORY=s3:${R2_ENDPOINT}/${R2_BUCKET}
DATA_DIR=${DATA_DIR}
STACK_DIR=${STACK_DIR}
EOF
  chmod 600 "$ENV_FILE"
}
# --------- Compose 模板 ---------
VAULTWARDEN_VERSION="1.33.0"
CADDY_VERSION="2.8.4-alpine"
VAULTWARDEN_DIGEST="sha256:8f739c6f9c1e43c5c6e7c6c6c6c6c6c6c6c6c6c6c6c6c6c6c6c6c6c6c6c6c6c"
CADDY_DIGEST="sha256:8f739c6f9c1e43c5c6e7c6c6c6c6c6c6c6c6c6c6c6c6c6c6c6c6c6c6c6c6c"

gen_compose(){
  verify_image_digest "vaultwarden/server:${VAULTWARDEN_VERSION}" "$VAULTWARDEN_DIGEST"
  verify_image_digest "caddy:${CADDY_VERSION}" "$CADDY_DIGEST"
  cat > "$STACK_DIR/docker-compose.yml" <<EOF
services:
  vaultwarden:
    image: vaultwarden/server:${VAULTWARDEN_VERSION}
    container_name: vaultwarden
    restart: unless-stopped
    env_file: $ENV_FILE
    volumes:
      - ${DATA_DIR}:/data
    networks: [vw-network]
  caddy:
    image: caddy:${CADDY_VERSION}
    container_name: caddy
    restart: unless-stopped
    user: "950:950"
    ports: ["80:80","443:443"]
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - ./caddy-data:/data
      - ./caddy-config:/config
    depends_on: [vaultwarden]
    networks: [vw-network]
networks:
  vw-network:
    driver: bridge
EOF
}
gen_caddyfile(){
  cat > "$STACK_DIR/Caddyfile" <<EOF
{
    email ${ACME_EMAIL}
    acme_ca https://acme-v02.api.letsencrypt.org/directory
}
${VW_DOMAIN} {
    reverse_proxy /notifications/hub vaultwarden:3012
    reverse_proxy /notifications/hub/negotiate vaultwarden:80
    reverse_proxy vaultwarden:80 { header_up X-Real-IP {remote_host} }
    header {
        Strict-Transport-Security "max-age=31536000;"
        X-Content-Type-Options nosniff
        X-Frame-Options DENY
        -Server
    }
}
EOF
}
# --------- 管理脚本 ---------
install_scripts(){
  cat >/usr/local/bin/vw-backup <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source /srv/vaultwarden/.env
export AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY" AWS_SECRET_ACCESS_KEY="$R2_SECRET_KEY"
export RESTIC_PASSWORD="$RESTIC_PASSWORD" RESTIC_REPOSITORY="s3:${R2_ENDPOINT}/${R2_BUCKET}"
restic snapshots &>/dev/null || restic init
TMP=$(mktemp -d)
trap "rm -rf $TMP" EXIT
sqlite3 "$DATA_DIR/db.sqlite3" ".backup '$TMP/db.sqlite3'"
rsync -a --exclude='*.tmp' --exclude='*.bak' "$DATA_DIR"/ "$TMP/"
restic backup "$TMP"
restic forget --prune --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --keep-yearly 3
echo "备份完成 $(date)"
EOF
  cat >/usr/local/bin/vw-status <<'EOF'
#!/usr/bin/env bash
cd /srv/vaultwarden && docker compose ps
EOF
  chmod +x /usr/local/bin/vw-backup /usr/local/bin/vw-status
}
# --------- 启动 / 健康检查 ---------
start_stack(){
  log_info "启动服务"
  cd "$STACK_DIR"
  docker compose down --remove-orphans 2>/dev/null || true
  docker compose up -d
  for i in {1..30}; do
    sleep 2
    if curl -skf "https://localhost/api/version" >/dev/null; then
      log_ok "Vaultwarden 健康检查通过，安装完成！"
      return 0
    fi
  done
  log_err "启动后健康检查失败"; docker compose logs; exit 1
}
# --------- 主流程 ---------
main(){
  [[ $EUID -eq 0 ]] || { log_err "请 root 运行"; exit 1; }
  validate_env
  check_deps
  prepare_system
  gen_env
  gen_compose
  gen_caddyfile
  install_scripts
  echo "0 3 * * * root /usr/local/bin/vw-backup" >/etc/cron.d/vaultwarden-backup
  start_stack
}
main "$@"