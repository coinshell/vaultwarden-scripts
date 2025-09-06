#!/usr/bin/env bash
set -euo pipefail
umask 077
# 同安装脚本参数，全部通过环境变量传入，不落盘
STACK_DIR="/srv/vaultwarden"
DATA_DIR="$STACK_DIR/vw-data"
ENV_FILE="$STACK_DIR/.env"
LOG_FILE="/var/log/vaultwarden-restore.log"
exec > >(tee -a "$LOG_FILE") 2>&1

log_info(){ echo "[$(date +'%F %T')] [INFO] $*"; }
log_err(){ echo "[$(date +'%F %T')] [ERROR] $*" >&2; }

# --------- 依赖 ---------
check_deps(){
  . /etc/os-release
  for p in curl jq sqlite3 rsync; do command -v "$p" &>/dev/null || PKGS+=("$p"); done
  if [[ -n "${PKGS:-}" ]]; then
    if [[ "$ID" =~ ubuntu|debian ]]; then apt-get update -qq && apt-get install -y "${PKGS[@]}"
    elif [[ "$ID" =~ centos|rhel|fedora ]]; then yum install -y "${PKGS[@]}"
    elif [[ "$ID" =~ arch ]]; then pacman -Sy --noconfirm "${PKGS[@]}"
    else log_err "不支持当前系统"; exit 1; fi
  fi
  if ! command -v restic &>/dev/null; then
    ARCH=$(dpkg --print-architecture 2>/dev/null || uname -m)
    RESTIC_VER=$(curl -sSf https://api.github.com/repos/restic/restic/releases/latest | jq -r .tag_name)
    curl -L "https://github.com/restic/restic/releases/download/${RESTIC_VER}/restic_${RESTIC_VER:1}_linux_${ARCH}.bz2" | bunzip2 > /usr/local/bin/restic
    chmod +x /usr/local/bin/restic
  fi
  if ! command -v docker &>/dev/null; then curl -fsSL https://get.docker.com | bash; systemctl enable --now docker; fi
}
# --------- 输入 ---------
validate_env(){
  for var in VW_DOMAIN ACME_EMAIL R2_BUCKET R2_ENDPOINT R2_ACCESS_KEY R2_SECRET_KEY; do
    [[ -n "${!var:-}" ]] || { log_err "环境变量 $var 未设置"; exit 1; }
  done
}
# --------- 获取 restic 密码 ---------
get_restic_password(){
  if [[ -f "$ENV_FILE" ]]; then
    source "$ENV_FILE" 2>/dev/null || true
  fi
  if [[ -z "${RESTIC_PASSWORD:-}" ]]; then
    read -srp "请输入 RESTIC_PASSWORD: " RESTIC_PASSWORD
    echo
  fi
  export AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY" AWS_SECRET_ACCESS_KEY="$R2_SECRET_KEY"
  export RESTIC_PASSWORD="$RESTIC_PASSWORD" RESTIC_REPOSITORY="s3:${R2_ENDPOINT}/${R2_BUCKET}"
  restic snapshots &>/dev/null || { log_err "无法访问 restic 仓库"; exit 1; }
}
# --------- 恢复 ---------
do_restore(){
  SNAP=$(restic snapshots --latest 1 --json | jq -r '.[0].short_id')
  [[ "$SNAP" == "null" || -z "$SNAP" ]] && { log_err "无可用快照"; exit 1; }
  log_info "使用快照 $SNAP"
  TMP=$(mktemp -d)
  trap "rm -rf $TMP" EXIT
  restic restore "$SNAP" --target "$TMP"
  # 停栈
  [[ -f "$STACK_DIR/docker-compose.yml" ]] && docker compose -f "$STACK_DIR/docker-compose.yml" down || true
  find "$DATA_DIR" -mindepth 1 -delete
  if [[ -d "$TMP/vw-data" ]]; then rsync -a --delete "$TMP/vw-data/" "$DATA_DIR/"
  else rsync -a --delete "$TMP/" "$DATA_DIR/"; fi
  # 密钥
  if [[ -f "$TMP/vaultwarden-secrets.json" ]]; then
    DB_ENCRYPTION_KEY=$(jq -r '.DB_ENCRYPTION_KEY' "$TMP/vaultwarden-secrets.json")
  else
    read -rsp "备份中无密钥文件，请输入 DB_ENCRYPTION_KEY: " DB_ENCRYPTION_KEY
    echo
  fi
  sqlite3 "$DATA_DIR/db.sqlite3" "PRAGMA integrity_check;" | grep -q ok || { log_err "数据库完整性失败"; exit 1; }
  # 写内存级 env
  cat > "$ENV_FILE" <<EOF
DOMAIN=https://${VW_DOMAIN}
SIGNUPS_ALLOWED=true
LOG_LEVEL=warn
DB_ENCRYPTION_KEY=${DB_ENCRYPTION_KEY}
R2_BUCKET=${R2_BUCKET}
R2_ENDPOINT=${R2_ENDPOINT}
R2_ACCESS_KEY=${R2_ACCESS_KEY}
R2_SECRET_KEY=${R2_SECRET_KEY}
RESTIC_PASSWORD=${RESTIC_PASSWORD}
RESTIC_REPOSITORY=s3:${R2_ENDPOINT}/${R2_BUCKET}
DATA_DIR=${DATA_DIR}
STACK_DIR=${STACK_DIR}
EOF
  chmod 600 "$ENV_FILE"
}
# --------- 重新生成 compose / Caddy（同安装） ---------
gen_compose(){
  cat > "$STACK_DIR/docker-compose.yml" <<EOF
services:
  vaultwarden:
    image: vaultwarden/server:1.33.0
    container_name: vaultwarden
    restart: unless-stopped
    env_file: $ENV_FILE
    volumes: [ "${DATA_DIR}:/data" ]
    networks: [vw-network]
  caddy:
    image: caddy:2.8.4-alpine
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
# --------- 启动 / 健康检查 ---------
start_stack(){
  log_info "启动服务"
  cd "$STACK_DIR"
  docker compose down --remove-orphans 2>/dev/null || true
  docker compose up -d
  for i in {1..30}; do
    sleep 2
    if curl -skf "https://localhost/api/version" >/dev/null; then
      log_info "Vaultwarden 已恢复并运行在 https://$VW_DOMAIN"
      return 0
    fi
  done
  log_err "恢复后健康检查失败"; docker compose logs; exit 1
}
# --------- 主流程 ---------
main(){
  [[ $EUID -eq 0 ]] || { log_err "请 root 运行"; exit 1; }
  validate_env
  check_deps
  get_restic_password
  do_restore
  gen_compose
  gen_caddyfile
  echo "0 3 * * * root /usr/local/bin/vw-backup" >/etc/cron.d/vaultwarden-backup
  start_stack
  log_ok "恢复完成！"
}
main "$@"