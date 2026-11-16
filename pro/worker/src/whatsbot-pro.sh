#!/usr/bin/env bash
# =====================================================================
#  WhatsBot Pro no Coolify — instalação com domínio, HTTPS e Postgres
#  Ubuntu ou Debian, como root.
#
#    bash <(curl -fsSL https://scripts.techify.site/whatsbot-pro)
#
#  Já tem o Coolify neste servidor: o script cria o Postgres e o WhatsBot Pro nele.
#  Não tem: o script instala o Coolify (e o Docker) antes.
#  Antes: aponte o domínio (registro A) para o IP público deste servidor
#  e deixe as portas 80 e 443 abertas no firewall.
#
#  Sem perguntas (automação), defina as variáveis antes do comando:
#    WHATSBOT_EMAIL=voce@gmail.com  WHATSBOT_DOMINIO=pro.exemplo.com  [WHATSBOT_SENHA='...']
#    [WHATSBOT_DB_URL=postgresql://usuario:senha@host:5432/banco]  [WHATSBOT_NOME=whatsbot-pro]
#    [WHATSBOT_DOMINIO_PAINEL=coolify.exemplo.com]  [WHATSBOT_FORCAR=1]
# =====================================================================
set -Eeuo pipefail
export PATH="$PATH:/usr/local/sbin:/usr/sbin:/sbin"

API="${WHATSBOT_API:-https://scripts.techify.site}"
BRANCH="${WHATSBOT_BRANCH:-main}"
COOLIFY_VERSION="${WHATSBOT_COOLIFY_VERSION:-4.7.5}"   # usada só quando o Coolify ainda não existe
DNS_TIMEOUT="${WHATSBOT_DNS_TIMEOUT:-1800}"

EMAIL="${WHATSBOT_EMAIL:-}"
DOMINIO="${WHATSBOT_DOMINIO:-}"
DB_URL="${WHATSBOT_DB_URL:-}"
SENHA="${WHATSBOT_SENHA:-}"
NOME="${WHATSBOT_NOME:-whatsbot-pro}"
DOMINIO_PAINEL="${WHATSBOT_DOMINIO_PAINEL:-}"
FORCAR="${WHATSBOT_FORCAR:-0}"

TOKEN_NAME=whatsbot-pro-provision
PROJETO="WhatsBot Pro"
CHAVES_DIR=/root/.whatsbot-pro
ACESSO=""
APT="apt-get -o DPkg::Lock::Timeout=300 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold"
REGEX_DOMINIO='^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*\.[A-Za-z]{2,}$'
IP4_RE='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
COOLIFY_NOVO=0
APT_OUT=""
CAPI_TOKEN=""
API_ORIG=""
APP_UUID=""
ADMIN_RESOLVIDO=0   # 1 = já existe usuário no Pro
ADMIN_APLICADO=0    # 1 = o administrador é o desta execução (senha confere)
PAINEL_OK=0
SENHA_GERADA=0

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33mAviso:\033[0m %s\n' "$*" >&2; }
die()  { printf '\n\033[1;31mERRO:\033[0m %s\n' "$*" >&2; exit 1; }

have_tty()  { { : </dev/tty; } 2>/dev/null; }
port_busy() { ss -ltn "( sport = :$1 )" 2>/dev/null | awk 'NR>1' | grep -q .; }
local_ip()  { ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true; }
public_ip() {
  local u p
  for u in https://ifconfig.io https://api.ipify.org https://checkip.amazonaws.com https://icanhazip.com; do
    p=$(curl -4fsS -m 8 "$u" 2>/dev/null | tr -d '[:space:]' || true)
    if [[ "$p" =~ $IP4_RE ]]; then printf '%s' "$p"; return 0; fi
  done
  return 0
}
psql_c() { docker exec -i coolify-db psql -q -U coolify -d coolify -v ON_ERROR_STOP=1 -tA "$@"; }

doh() {  # doh NOME TIPO_NUMERICO — DNS pelo resolvedor público, o que o Let's Encrypt enxerga
  curl -fsS -m 10 -H 'accept: application/dns-json' "https://1.1.1.1/dns-query?name=$1&type=$2" 2>/dev/null \
    | jq -r --argjson t "$2" '.Answer[]? | select(.type==$t) | .data' 2>/dev/null || true
}

confirmar_continuar() {
  if [ "$FORCAR" = 1 ]; then return 0; fi
  if ! have_tty; then warn "sem terminal para perguntar; seguindo mesmo assim."; return 0; fi
  local r=""
  read -r -p "    Continuar mesmo assim? [s/N] " r </dev/tty
  case "$r" in s|S|sim|SIM|y|Y) return 0 ;; *) die "instalação cancelada." ;; esac
}

# ---------------------------------------------------------------- servidor

verificar_servidor() {
  local nome=${PRETTY_NAME:-desconhecido}
  case "${ID:-?}" in ubuntu|debian) info "Sistema: $nome" ;; *) warn "$nome: só Ubuntu e Debian foram testados."; confirmar_continuar ;; esac
  case "$(uname -m)" in x86_64|aarch64) ;; *) warn "arquitetura $(uname -m): só x86_64 e arm64 têm o motor do WhatsApp (GOWA)."; confirmar_continuar ;; esac
  local mem disk
  mem=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
  disk=$(df -Pm / | awk 'NR==2{print $4}')
  # A construção da imagem do Pro usa ~350 MB a mais que o servidor em repouso (medido em 4 GB de RAM).
  if [ "$mem" -lt 2000 ];   then warn "só ${mem} MB de RAM; o recomendado são 4096 MB ou mais (a construção da imagem pode falhar)."; fi
  if [ "$disk" -lt 20000 ]; then warn "só ${disk} MB livres em /; o recomendado são 30 GB ou mais."; fi
  return 0
}

apt_update() {
  local i
  for i in $(seq 1 30); do
    if APT_OUT=$($APT update 2>&1); then return 0; fi
    if grep -qiE "Could not get lock|Unable to acquire the dpkg|is another process using it" <<<"$APT_OUT"; then
      if [ "$i" = 1 ]; then info "outro processo está usando o apt; aguardando..."; fi
      sleep 10
    else
      return 1
    fi
  done
  return 1
}

http_ok() {
  if command -v curl >/dev/null 2>&1; then curl -fsI -m 15 "$1" >/dev/null 2>&1
  elif command -v wget >/dev/null 2>&1; then wget -q --spider -T 15 "$1"
  else return 0; fi
}

# Ubuntu intermediário (ex.: 24.10) sai de suporte e some do archive.ubuntu.com. Só mexe quando o erro é
# exatamente "o codinome desta máquina não tem mais Release" e o old-releases tem esse codinome.
corrigir_apt_ubuntu_antigo() {
  [ "${ID:-}" = ubuntu ] && [ -n "${VERSION_CODENAME:-}" ] || return 1
  grep -qE "The repository '[^']*(archive|security)\.ubuntu\.com[^']* ${VERSION_CODENAME}[a-z-]* Release' (no longer has|does not have) a Release file" <<<"$APT_OUT" || return 1
  http_ok "http://old-releases.ubuntu.com/ubuntu/dists/${VERSION_CODENAME}/Release" || return 1
  warn "o Ubuntu ${VERSION_ID:-} saiu de suporte; usando o arquivo old-releases.ubuntu.com (cópia das fontes originais em *.bak-whatsbot)."
  local f
  for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.sources /etc/apt/sources.list.d/*.list; do
    [ -f "$f" ] || continue
    grep -q 'ubuntu\.com/ubuntu' "$f" || continue
    if [ ! -e "$f.bak-whatsbot" ]; then cp -a "$f" "$f.bak-whatsbot"; fi
    sed -i -E 's#https?://(archive|security|[a-z]{2}\.archive)\.ubuntu\.com/ubuntu#http://old-releases.ubuntu.com/ubuntu#g' "$f"
  done
  return 0
}

restaurar_apt() {
  local b
  for b in /etc/apt/sources.list.bak-whatsbot /etc/apt/sources.list.d/*.bak-whatsbot; do
    [ -f "$b" ] && mv -f "$b" "${b%.bak-whatsbot}"
  done
  return 0
}

apt_preparar() {
  export DEBIAN_FRONTEND=noninteractive
  if ! apt_update; then
    if ! { corrigir_apt_ubuntu_antigo && apt_update; }; then
      restaurar_apt
      printf '%s\n' "$APT_OUT" | tail -6 >&2
      die "o apt não conseguiu atualizar a lista de pacotes (veja acima)."
    fi
  fi
  $APT install -y -qq ca-certificates curl wget git jq openssl iproute2 python3 openssh-client >/dev/null
}

# ---------------------------------------------------------------- perguntas

# Qualquer caractere imprimível, sem espaço. A senha só passa por jq (variável de ambiente) e pelo argon2 do Pro: não há o que escapar.
REGRA_SENHA="8 a 64 caracteres, sem espaço, com maiúscula, minúscula, número e um símbolo (ex.: # @ ! - _)"
valid_password() {
  [[ ${#1} -ge 8 && ${#1} -le 64 && $1 =~ ^[[:graph:]]+$ && $1 =~ [[:upper:]] && $1 =~ [[:lower:]] && $1 =~ [[:digit:]] && $1 =~ [^[:alnum:]] ]]
}
gerar_senha() { printf '%sAa1!' "$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-14)"; }

email_ok() {
  [[ "$1" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || return 1
  [ -n "$(doh cloudflare.com 1)" ] || return 0
  local d=${1#*@}
  [ -n "$(doh "$d" 15)" ] || [ -n "$(doh "$d" 1)" ]
}
ck_dominio() { [[ "$1" =~ $REGEX_DOMINIO ]]; }
ck_dom_opc() { [ -z "$1" ] || [[ "$1" =~ $REGEX_DOMINIO ]]; }
ck_db_opc()  { [ -z "$1" ] || [[ "$1" =~ ^postgres(ql)?(\+psycopg)?://[^[:space:]]+@[^[:space:]]+/[^[:space:]]+$ ]]; }
ck_nome()    { [[ "$1" =~ ^[a-z0-9][a-z0-9-]{1,30}$ ]]; }

perguntar() {  # perguntar VAR "texto" validador "erro"
  local var=$1 prompt=$2 check=$3 err=$4 val=""
  if [ -n "${!var:-}" ]; then "$check" "${!var}" || die "$err"; return 0; fi
  if ! have_tty; then
    if "$check" ""; then return 0; fi
    die "sem terminal para perguntar. Defina WHATSBOT_$var antes do comando."
  fi
  while :; do
    read -r -p "$prompt" val </dev/tty
    if "$check" "$val"; then printf -v "$var" '%s' "$val"; return 0; fi
    printf '    %s\n' "$err" >&2
  done
}

fazer_perguntas() {
  printf '\n\033[1;32m  WhatsBot Pro no Coolify\033[0m\n'
  printf '  O domínio precisa já apontar para este servidor.\n\n'
  perguntar EMAIL "  1) Seu e-mail (o mesmo da compra): " email_ok \
    "e-mail inválido, ou o domínio dele não existe no DNS."
  EMAIL=${EMAIL,,}
  perguntar DOMINIO "  2) Domínio do WhatsBot Pro (ex.: pro.seudominio.com): " ck_dominio \
    "domínio inválido. Use só o nome, sem http:// e sem barra."
  perguntar DB_URL "  3) URL de um Postgres externo (opcional; Enter = criar um Postgres aqui): " ck_db_opc \
    "use o formato postgresql://usuario:senha@host:5432/banco ou deixe vazio."
  ck_nome "$NOME" || die "WHATSBOT_NOME: use 2 a 31 letras minúsculas, números ou hífen."
  if [ "$COOLIFY_NOVO" = 1 ]; then
    perguntar DOMINIO_PAINEL "  4) Domínio do painel do Coolify (opcional; Enter = acessar por IP:8000): " ck_dom_opc \
      "domínio inválido. Use só o nome ou deixe vazio."
    [ -z "$DOMINIO_PAINEL" ] || [ "$DOMINIO_PAINEL" != "$DOMINIO" ] || die "o domínio do Pro e o do painel precisam ser diferentes."
  fi
  SENHA_GERADA=0
  if [ -z "$SENHA" ]; then
    local s1="" s2=""
    if have_tty; then
      while :; do
        read -r -s -p "  Senha do administrador do Pro (Enter = gerar uma; ou $REGRA_SENHA): " s1 </dev/tty; echo >&2
        if [ -z "$s1" ]; then break; fi
        if ! valid_password "$s1"; then printf '    senha inválida: use %s.\n' "$REGRA_SENHA" >&2; continue; fi
        read -r -s -p "     Repita a senha: " s2 </dev/tty; echo >&2
        if [ "$s1" = "$s2" ]; then break; fi
        printf '    as senhas não conferem.\n' >&2
      done
    fi
    SENHA=$s1
  fi
  if [ -z "$SENHA" ]; then SENHA=$(gerar_senha); SENHA_GERADA=1; fi
  valid_password "$SENHA" || die "senha inválida: use $REGRA_SENHA."
  # postgres:// e postgresql:// -> o driver que o Pro usa
  if [ -n "$DB_URL" ]; then DB_URL=$(sed -E 's#^postgres(ql)?(\+psycopg)?://#postgresql+psycopg://#' <<<"$DB_URL"); fi
}

# Postgres externo: falha aqui, em segundos, em vez de depois de 6 a 11 minutos de build.
# O banco SQL_ASCII conecta e cria as tabelas, mas o app quebra no 1º start (SQLAlchemy não decodifica a versão).
# Os dados de conexão vão por variáveis PG*, não por argv: a senha não aparece no ps.
checar_db_externo() {
  [ -n "$DB_URL" ] || return 0
  step "Conferindo o Postgres externo"
  command -v psql >/dev/null 2>&1 || $APT install -y -qq postgresql-client >/dev/null
  local out rc=0 enc priv
  out=$(DB_URL="$DB_URL" python3 -I - 2>&1 <<'PY'
import os, sys
from urllib.parse import urlsplit, unquote, parse_qsl
try:
    u = urlsplit(os.environ["DB_URL"].replace("postgresql+psycopg://", "postgresql://", 1))
    porta = u.port or 5432
except ValueError:
    sys.exit("a porta da URL não é um número.")
e = dict(os.environ, PGHOST=u.hostname or "", PGPORT=str(porta), PGUSER=unquote(u.username or ""),
         PGPASSWORD=unquote(u.password or ""), PGDATABASE=unquote(u.path.lstrip("/")), PGCONNECT_TIMEOUT="10")
for k, v in parse_qsl(u.query):
    if k == "sslmode": e["PGSSLMODE"] = v
os.execvpe("psql", ["psql", "-X", "-qtA", "-F", "|", "-c",
    "select current_setting('server_encoding'), has_schema_privilege(current_user, current_schema(), 'CREATE')"], e)
PY
  ) || rc=$?
  [ "$rc" = 0 ] || die "não consegui usar o Postgres informado: $(head -n1 <<<"$out")
    Confira usuário, senha, host, porta e nome do banco (o banco precisa já existir) e se este servidor ($IP) tem acesso liberado."
  enc=${out%%|*}; priv=${out##*|}
  [ "$enc" = UTF8 ] || die "o banco informado usa a codificação $enc; o WhatsBot Pro exige UTF8.
    Crie outro banco assim:  CREATE DATABASE whatsbot TEMPLATE template0 ENCODING 'UTF8';"
  [ "$priv" = t ] || die "o usuário do banco não pode criar tabelas no schema padrão (public). Dê a permissão (GRANT CREATE ON SCHEMA public TO usuario) ou use o dono do banco."
  info "Postgres externo ok (UTF8, com permissão para criar tabelas)"
}

# ---------------------------------------------------------------- DNS e alcance

aguardar_dns() {  # $1 = domínio  $2 = IP público deste servidor
  local d=$1 ip=$2 t0=$SECONDS got last="" msg
  info "conferindo $d"
  while :; do
    if [ -n "$(doh cloudflare.com 1)" ]; then got=$(doh "$d" 1 | awk 'NR==1')
    else got=$(getent ahostsv4 "$d" 2>/dev/null | awk 'NR==1{print $1}' || true); fi
    if [ "$got" = "$ip" ]; then
      info "DNS ok: $d -> $ip"
      local aaaa; aaaa=$(doh "$d" 28 | awk 'NR==1')
      if [ -n "$aaaa" ]; then warn "$d também tem um registro AAAA (IPv6: $aaaa). Se este servidor não responde em IPv6, o certificado falha."; fi
      return 0
    fi
    if [ -z "$got" ]; then msg="$d ainda não existe no DNS. Crie um registro A para $ip."
    else msg="$d aponta para $got, mas este servidor é $ip. Se usa Cloudflare, deixe o registro como \"Somente DNS\" (nuvem cinza)."; fi
    if [ "$msg" != "$last" ]; then printf '    %s\n    aguardando... (Ctrl+C cancela; depois de corrigir é só esperar)\n' "$msg"; last=$msg; fi
    if [ $((SECONDS - t0)) -ge "$DNS_TIMEOUT" ]; then die "o DNS de $d não apontou para $ip em $((DNS_TIMEOUT / 60)) minutos. Corrija o registro e rode o comando de novo."; fi
    sleep 10
  done
}

# Só com porta 80 livre (Coolify ainda não instalado): prova que o nome chega aqui, como o Let's Encrypt fará.
testar_porta80() {
  local d=$1 dir tok pid ok=1 i
  dir=$(mktemp -d); tok=$(openssl rand -hex 8); echo "ok-$tok" > "$dir/$tok"
  (cd "$dir" && exec python3 -m http.server 80 --bind 0.0.0.0 >/dev/null 2>&1) &
  pid=$!
  sleep 1
  for i in 1 2 3 4 5 6; do
    if [ "$(curl -fsS -m 8 "http://$d/$tok" 2>/dev/null || true)" = "ok-$tok" ]; then ok=0; break; fi
    sleep 5
  done
  kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; rm -rf "$dir"
  return $ok
}

aguardar_cert() {
  local i iss
  for i in $(seq 1 36); do
    iss=$(echo | openssl s_client -connect 127.0.0.1:443 -servername "$1" 2>/dev/null | openssl x509 -noout -issuer 2>/dev/null || true)
    if [[ "$iss" == *"Let's Encrypt"* ]]; then return 0; fi
    sleep 5
  done
  return 1
}

# ---------------------------------------------------------------- Coolify (instalação nova)

exigir_portas_livres() {
  local p
  for p in 80 443 8000 6001 6002; do
    if port_busy "$p"; then die "a porta $p já está em uso neste servidor (o Coolify precisa de 80, 443, 8000, 6001 e 6002 livres)."; fi
  done
}

instalar_coolify() {
  export USER=root
  local tmp i ok=0; tmp="$(mktemp -d)"
  CF_SENHA=$(gerar_senha)
  curl -fsSL https://cdn.coollabs.io/coolify/install.sh -o "$tmp/install.sh"
  ROOT_USERNAME=admin ROOT_USER_EMAIL="$EMAIL" ROOT_USER_PASSWORD="$CF_SENHA" AUTOUPDATE=false \
    bash "$tmp/install.sh" "$COOLIFY_VERSION"
  rm -rf "$tmp"
  step "Esperando o Coolify responder"
  for i in $(seq 1 90); do
    if curl -fsS -m 5 http://127.0.0.1:8000/api/health >/dev/null 2>&1; then ok=1; break; fi
    sleep 4
  done
  if [ "$ok" != 1 ]; then docker ps -a; die "o Coolify não respondeu em /api/health após 6 minutos."; fi
  for i in $(seq 1 60); do
    if [ "$(psql_c -c 'select count(*) from users where id = 0' 2>/dev/null || true)" = 1 ]; then break; fi
    sleep 2
  done
  [ "$(psql_c -c 'select count(*) from users where id = 0')" = 1 ] \
    || die "o administrador do Coolify não foi criado (e-mail sem domínio real?). Veja: docker logs coolify | grep -A3 'Invalid Root User'"
  umask 077
  { echo "Coolify:   http://$IP:8000"; echo "E-mail:    $EMAIL"; echo "Senha:     $CF_SENHA"; } > /root/coolify-acesso.txt
  info "Coolify instalado. Login em /root/coolify-acesso.txt (só o root lê)."
}

# O install.sh do Coolify grava a porta SSH 22; com o sshd em outra porta o deploy falha.
ajustar_porta_ssh() {
  local ports p
  ports=$(ss -ltnpH 2>/dev/null | awk '/"sshd"/{n=split($4,a,":"); print a[n]}' | sort -un || true)
  if [ -z "$ports" ]; then ports=$(sshd -T 2>/dev/null | awk '$1=="port"{print $2}' || true); fi
  p=$(head -n1 <<<"$ports")
  grep -qx 22 <<<"$ports" && p=22
  [[ "$p" =~ ^[0-9]+$ ]] || p=22
  if [ "$p" != 22 ]; then
    info "o SSH deste servidor está na porta $p; avisando o Coolify."
    psql_c -c "UPDATE servers SET port = $p WHERE id = 0" >/dev/null
  fi
}

painel_dominio() {  # $1 = domínio
  local d=$1 out
  out=$(docker exec -u www-data -e DASH_FQDN="https://$d" coolify php artisan tinker --execute='
$s = instanceSettings();
$s->fqdn = getenv("DASH_FQDN");
$s->save();
\App\Models\Server::findOrFail(0)->setupDynamicProxyConfiguration();
echo "DASH_OK ".instanceSettings()->fqdn.PHP_EOL;' 2>&1 || true)
  if grep -q "DASH_OK https://$d" <<<"$out"; then info "painel configurado em https://$d"
  else warn "não consegui configurar o domínio do painel; ele continua em http://$IP:8000."; return 1; fi
}

# ---------------------------------------------------------------- chave de acesso ao código

# Uma chave por e-mail neste servidor, reaproveitada nas próximas execuções (vários WhatsBot Pro, mesma chave).
gerar_e_registrar_chave() {
  local h; h=$(printf '%s' "$EMAIL" | sha256sum | cut -c1-8)
  KEY="$CHAVES_DIR/chave-$h"
  umask 077; mkdir -p "$CHAVES_DIR"
  KEY_NOVA=0
  if [ ! -s "$KEY" ]; then
    ssh-keygen -q -t ed25519 -N '' -C "whatsbot-pro $EMAIL" -f "$KEY"
    KEY_NOVA=1
  fi
  local resp code body
  resp=$(jq -nc --arg e "$EMAIL" --arg k "$(cat "$KEY.pub")" --arg m "$(hostname -s)" '{email:$e, chave_publica:$k, maquina:$m}' \
    | curl -sS -m 30 -w '\n%{http_code}' -X POST "$API/pro/chave" -H 'Content-Type: application/json' --data-binary @- ) \
    || die "não consegui falar com $API. Confira a internet deste servidor."
  code=${resp##*$'\n'}; body=${resp%$'\n'*}
  if [ "$code" != 200 ]; then
    [ "$KEY_NOVA" = 1 ] && rm -f "$KEY" "$KEY.pub"
    warn "$(jq -r '.erro // "resposta inesperada"' <<<"$body" 2>/dev/null || echo "resposta inesperada (HTTP $code)")"
    local c; c=$(jq -r '.contato // empty' <<<"$body" 2>/dev/null || true)
    [ -z "$c" ] || info "Fale com a Techify: $c"
    die "não foi possível liberar o acesso ao código."
  fi
  REPO=$(jq -r .repositorio <<<"$body")
  CONTATO=$(jq -r '.contato // empty' <<<"$body")
  [ -n "$REPO" ] && [ "$REPO" != null ] || die "resposta do servidor sem o endereço do repositório."
  if [ "$KEY_NOVA" = 1 ]; then
    echo
    echo "  ----------------------------------------------------------------"
    echo "  Chave de acesso ao código do WhatsBot Pro (GUARDE, não perca):"
    echo "  Arquivo neste servidor: $KEY"
    # Sem terminal (automação, CI) a chave privada iria parar num log: lá só o caminho.
    if have_tty; then
      echo
      cat "$KEY"
    fi
    echo "  ----------------------------------------------------------------"
    if have_tty && [ "$FORCAR" != 1 ]; then
      local r=""
      while [ "$r" != guardei ]; do read -r -p "  Copie a chave acima para um lugar seguro e digite 'guardei': " r </dev/tty; done
    fi
  else
    info "chave de acesso reaproveitada: $KEY"
  fi
}

# ---------------------------------------------------------------- Coolify (API)

api_cleanup() {
  [ -n "$CAPI_TOKEN" ] || return 0
  psql_c -c "DELETE FROM personal_access_tokens WHERE name = '$TOKEN_NAME'" >/dev/null 2>&1 || true
  psql_c -c "UPDATE instance_settings SET is_api_enabled = $([ "$API_ORIG" = t ] && echo true || echo false) WHERE id = 0" >/dev/null 2>&1 || true
}

capi() {  # capi METHOD PATH [JSON]
  local m=$1 p=$2 body=${3:-} out code
  out=$(curl -sS -X "$m" -H "Authorization: Bearer $CAPI_TOKEN" -H 'Accept: application/json' \
    ${body:+-H 'Content-Type: application/json' -d "$body"} -w '\n%{http_code}' "http://127.0.0.1:8000/api/v1$p") || return 1
  code=${out##*$'\n'}; out=${out%$'\n'*}
  if [[ "$code" != 2* ]]; then printf 'Coolify API %s %s -> HTTP %s: %s\n' "$m" "$p" "$code" "$(head -c 300 <<<"$out")" >&2; return 1; fi
  printf '%s' "$out"
}

abrir_api() {
  [ "$(psql_c -c 'select count(*) from users where id = 0' 2>/dev/null || true)" = 1 ] \
    || die "não achei o administrador principal do Coolify (usuário 0). Este instalador espera o Coolify padrão."
  API_ORIG=$(psql_c -c "select is_api_enabled from instance_settings where id = 0")
  CAPI_TOKEN=$(openssl rand -hex 24)
  trap api_cleanup EXIT
  psql_c <<SQL
UPDATE instance_settings SET is_api_enabled = true WHERE id = 0;
UPDATE teams SET show_boarding = false WHERE id = 0;
DELETE FROM personal_access_tokens WHERE name = '$TOKEN_NAME';
INSERT INTO personal_access_tokens (tokenable_type, tokenable_id, name, token, team_id, abilities, created_at, updated_at)
VALUES ('App\Models\User', 0, '$TOKEN_NAME', encode(sha256(convert_to('$CAPI_TOKEN', 'UTF8')), 'hex'), '0', '["root"]', now(), now());
SQL
}

# Container em execução do app (o do build antigo some quando o novo sobe; pega o mais recente).
container_app() { docker ps --format '{{.Names}}' | grep "^${APP_UUID}-" | sort | tail -n1 || true; }

# POST direto no container, sem DNS nem certificado no caminho. Imprime o código HTTP (vazio = sem container/sem resposta).
admin_http() {  # admin_http ROTA JSON
  local ctr; ctr=$(container_app)
  [ -n "$ctr" ] || return 0
  printf '%s' "$2" | docker exec -i "$ctr" curl -sS -m 8 -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:8080$1" \
    -H 'Content-Type: application/json' --data-binary @- 2>/dev/null || true
}

# Cria o primeiro administrador. Quanto antes melhor: sem nenhum usuário o painel do Pro aceita qualquer pessoa.
# Retorna 0 quando resolvido (criado, ou já havia usuário), 1 quando o app ainda não respondeu.
admin_tentar() {
  local code
  code=$(admin_http /api/auth/bootstrap "$(SENHA="$SENHA" jq -nc --arg e "$EMAIL" --arg n "${EMAIL%%@*}" '{email: $e, name: $n, password: env.SENHA}')")
  case "$code" in
    200) ADMIN_APLICADO=1 ;;
    409) # já havia usuário: só vale como "nosso" se a senha informada entra
      [ "$(admin_http /api/auth/login "$(SENHA="$SENHA" jq -nc --arg e "$EMAIL" '{email: $e, password: env.SENHA}')")" = 200 ] && ADMIN_APLICADO=1 || true ;;
    *) return 1 ;;
  esac
  ADMIN_RESOLVIDO=1
}

criar_pro() {
  local server project kuuid kname dbu dbpass app d s i ok fqdn="https://$DOMINIO" v have falhas=0 atual motivo
  server=$(psql_c -c "select uuid from servers where id = 0")
  [ -n "$server" ] || die "servidor principal não encontrado no Coolify."

  info "esperando o proxy (Traefik)"
  for i in $(seq 1 90); do
    if [ "$(capi GET "/servers/$server/proxy" | jq -r .status)" = running ]; then break; fi
    sleep 2
  done

  project=$(capi GET /projects | jq -r --arg n "$PROJETO" 'first(.[] | select(.name == $n) | .uuid) // empty')
  [ -n "$project" ] || project=$(capi POST /projects "$(jq -nc --arg n "$PROJETO" '{name: $n}')" | jq -r .uuid)

  kname="whatsbot-pro-$(basename "$KEY" | sed 's/^chave-//')"
  kuuid=$(capi GET /security/keys | jq -r --arg n "$kname" 'first(.[] | select(.name == $n) | .uuid) // empty')
  if [ -z "$kuuid" ]; then
    kuuid=$(capi POST /security/keys "$(jq -nc --arg n "$kname" --arg k "$(cat "$KEY")" \
      '{name: $n, description: "Acesso somente leitura ao código do WhatsBot Pro", private_key: $k}')" | jq -r .uuid)
  fi

  if [ -n "$DB_URL" ]; then
    info "usando o Postgres externo informado"
  else
    # Reexecução: reaproveita o Postgres da tentativa anterior em vez de criar outro (e perder a senha dele).
    dbu=$(capi GET /databases | jq -r --arg n "$NOME-db" 'first(.[] | select(.name == $n) | .uuid) // empty')
    if [ -n "$dbu" ]; then
      info "reaproveitando o Postgres '$NOME-db' que já existe"
      dbpass=$(capi GET "/databases/$dbu" | jq -r '.postgres_password // empty')
      capi POST "/databases/$dbu/start" >/dev/null 2>&1 || true
    else
      step "Criando o Postgres"
      dbpass=$(openssl rand -hex 16)
      dbu=$(capi POST /databases/postgresql "$(jq -nc --arg p "$project" --arg s "$server" --arg pw "$dbpass" --arg n "$NOME-db" \
        '{project_uuid: $p, server_uuid: $s, environment_name: "production", name: $n, image: "postgres:17-alpine",
          postgres_user: "whatsbot", postgres_password: $pw, postgres_db: "whatsbot", instant_deploy: true}')" | jq -r .uuid)
    fi
    [ -n "$dbu" ] && [ "$dbu" != null ] && [ -n "$dbpass" ] || die "não consegui criar ou ler o Postgres no Coolify."
    ok=0
    for i in $(seq 1 60); do
      case "$(capi GET "/databases/$dbu" | jq -r .status)" in running*) ok=1; break ;; esac
      sleep 4
    done
    [ "$ok" = 1 ] || die "o Postgres não ficou pronto em 4 minutos. Veja no Coolify: $PROJETO > $NOME-db."
    DB_URL="postgresql+psycopg://whatsbot:$dbpass@$dbu:5432/whatsbot"
  fi

  app=$(capi GET /applications | jq -r --arg n "$NOME" 'first(.[] | select(.name == $n) | .uuid) // empty')
  if [ -z "$app" ]; then
    app=$(capi POST /applications/private-deploy-key "$(jq -nc \
      --arg p "$project" --arg s "$server" --arg k "$kuuid" --arg r "$REPO" --arg b "$BRANCH" --arg n "$NOME" --arg d "$fqdn" \
      '{project_uuid: $p, server_uuid: $s, environment_name: "production", private_key_uuid: $k, git_repository: $r, git_branch: $b,
        build_pack: "dockerfile", ports_exposes: "8080", name: $n, domains: $d, health_check_enabled: false, instant_deploy: false}')" | jq -r .uuid)
    [ -n "$app" ] && [ "$app" != null ] || die "o Coolify não criou o aplicativo."
  else
    info "o aplicativo '$NOME' já existe no Coolify; retomando de onde parou."
    atual=$(capi GET "/applications/$app" | jq -r '.fqdn // empty')
    [ "$atual" = "$fqdn" ] || die "o aplicativo '$NOME' existente usa '${atual:-nenhum domínio}', diferente de $fqdn. Use o mesmo domínio, ou WHATSBOT_NOME=outro-nome para criar outra instância."
  fi
  APP_UUID=$app

  # is_literal: um "$" na senha de um Postgres externo não pode ser interpolado pelo Coolify.
  have=$(capi GET "/applications/$app/envs" | jq -r '.[] | select(.is_preview == false) | .key')
  grep -qx DATABASE_URL <<<"$have" \
    || capi POST "/applications/$app/envs" "$(jq -nc --arg v "$DB_URL" '{key: "DATABASE_URL", value: $v, is_preview: false, is_literal: true}')" >/dev/null
  grep -qx WHATSBOT_PUBLIC_URL <<<"$have" \
    || capi POST "/applications/$app/envs" "$(jq -nc --arg v "$fqdn" '{key: "WHATSBOT_PUBLIC_URL", value: $v, is_preview: false, is_literal: true}')" >/dev/null

  # Sem volumes nomeados, cada redeploy começaria com /app/storages vazio (sessão do WhatsApp e arquivos).
  have=$(capi GET "/applications/$app/storages" | jq -r '.persistent_storages[].mount_path')
  for v in storages statics logs; do
    grep -qx "/app/$v" <<<"$have" \
      || capi POST "/applications/$app/storages" "$(jq -nc --arg n "$v" --arg m "/app/$v" '{type: "persistent", name: $n, mount_path: $m}')" >/dev/null
  done

  # Reexecução: acompanha o deploy que já está rodando, ou não reconstrói um app que já está no ar.
  d=$(psql_c -c "select deployment_uuid from application_deployment_queues where application_id = (select id::text from applications where uuid = '$app') and status in ('in_progress','queued') order by id desc limit 1")
  atual=$(capi GET "/applications/$app" | jq -r '.status // empty')
  if [ -n "$d" ]; then
    step "Acompanhando o deploy que já estava em andamento"
  elif [[ "$atual" == running* ]]; then
    info "o aplicativo já está no ar; não vou construir de novo."
    return 0
  else
    step "Construindo e publicando o WhatsBot Pro (3 a 8 minutos)"
    d=$(capi POST "/deploy?uuid=$app" '{}' | jq -r '.deployments[0].deployment_uuid')
    [ -n "$d" ] && [ "$d" != null ] || die "o deploy não entrou na fila."
  fi
  s=""
  for i in $(seq 1 400); do
    # O admin sai assim que o app responde, antes de o Traefik expor o endereço (ele só roteia depois do health check).
    if [ "$ADMIN_RESOLVIDO" != 1 ]; then admin_tentar || true; fi
    if s=$(capi GET "/deployments/$d" 2>/dev/null | jq -r .status 2>/dev/null) && [ -n "$s" ]; then
      falhas=0
      case $s in
        finished) break ;;
        failed|cancelled-by-user)
          motivo=$(capi GET "/deployments/$d" 2>/dev/null | jq -r '(.logs // "[]") | (if type == "string" then fromjson else . end)
            | map(select(.hidden == false and (.output | startswith("Deployment failed")))) | first | .output // empty' 2>/dev/null || true)
          if [ -n "$motivo" ]; then warn "$motivo"; fi
          die "o deploy terminou como '$s'. Veja no Coolify: $PROJETO > $NOME > Deployments. Corrigido o problema, rode o comando de novo: ele retoma daqui." ;;
      esac
    else
      s=""; falhas=$((falhas + 1))
      if [ "$falhas" -ge 40 ]; then die "a API do Coolify parou de responder (2 minutos). Veja: docker logs coolify --tail 30"; fi
    fi
    sleep 3
  done
  [ "$s" = finished ] || die "tempo esgotado esperando o deploy (último estado: $s)."
}

# Garante o administrador mesmo quando o app já estava no ar (reexecução) ou subiu sem ser visto durante o deploy.
criar_admin() {
  local i
  for i in $(seq 1 60); do
    if [ "$ADMIN_RESOLVIDO" = 1 ] || admin_tentar; then break; fi
    sleep 3
  done
  [ "$ADMIN_RESOLVIDO" = 1 ] || die "o WhatsBot Pro subiu, mas não consegui criar o administrador. Abra https://$DOMINIO e veja se pede o cadastro."
  if [ "$ADMIN_APLICADO" != 1 ]; then
    warn "o WhatsBot Pro já tinha um administrador e a senha informada não confere com ele. Entre com a senha do administrador que já existia."
  fi
}

# Logo depois do admin: se o script cair no certificado, a senha gerada não se perde.
gravar_acesso() {
  local url_painel="http://$IP:8000"
  if [ "$PAINEL_OK" = 1 ]; then url_painel="https://$DOMINIO_PAINEL"; fi
  ACESSO="/root/${NOME}-acesso.txt"
  umask 077
  {
    echo "WhatsBot Pro:   https://$DOMINIO"
    echo "Coolify:        $url_painel"
    echo "E-mail:         $EMAIL"
    if [ "$ADMIN_APLICADO" = 1 ]; then echo "Senha:          $SENHA"; else echo "Senha:          (já havia um administrador; use a senha dele)"; fi
    echo "Chave (código): $KEY"
  } > "$ACESSO"
  if [ "$ADMIN_APLICADO" = 1 ] && [ "$SENHA_GERADA" = 1 ]; then
    info "Senha do administrador (gerada agora): $SENHA   (também em $ACESSO)"
  fi
}

# ---------------------------------------------------------------- main

main() {
  [ "$(id -u)" -eq 0 ] || die "rode como root (use: sudo -i)"
  # shellcheck disable=SC1091
  . /etc/os-release

  step "Verificando o servidor"
  verificar_servidor
  step "Preparando o servidor"
  apt_preparar

  IP=$(public_ip); if [ -z "$IP" ]; then IP=$(local_ip); fi
  [ -n "$IP" ] || die "não consegui descobrir o IP deste servidor."
  info "IP público deste servidor: $IP"

  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx coolify; then
    info "Coolify encontrado neste servidor: o WhatsBot Pro será criado nele."
  else
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qE '^coolify($|-)' || [ -d /data/coolify/source ]; then
      die "há sobras de um Coolify parado neste servidor. Inicie-o (docker start coolify coolify-db coolify-redis) ou limpe antes de continuar."
    fi
    COOLIFY_NOVO=1
    info "Coolify não encontrado: ele será instalado junto."
  fi

  fazer_perguntas
  checar_db_externo

  step "Conferindo o DNS"
  aguardar_dns "$DOMINIO" "$IP"
  if [ -n "$DOMINIO_PAINEL" ]; then aguardar_dns "$DOMINIO_PAINEL" "$IP"; fi

  step "Liberando o acesso ao código"
  gerar_e_registrar_chave

  PAINEL_OK=0
  if [ "$COOLIFY_NOVO" = 1 ]; then
    exigir_portas_livres
    info "testando se $DOMINIO chega a este servidor pela porta 80"
    if ! testar_porta80 "$DOMINIO"; then
      warn "não consegui abrir http://$DOMINIO daqui. Porta 80 ocupada ou domínio apontando para outro IP: o certificado HTTPS não será emitido."
      confirmar_continuar
    fi
    step "Instalando o Coolify $COOLIFY_VERSION (instala o Docker junto; leva alguns minutos)"
    instalar_coolify
    ajustar_porta_ssh
    if [ -n "$DOMINIO_PAINEL" ]; then step "Configurando o domínio do painel"; if painel_dominio "$DOMINIO_PAINEL"; then PAINEL_OK=1; fi; fi
  fi

  step "Criando o WhatsBot Pro no Coolify"
  abrir_api
  criar_pro

  step "Criando o administrador"
  criar_admin
  gravar_acesso

  step "Esperando o certificado HTTPS"
  if aguardar_cert "$DOMINIO"; then
    info "certificado emitido para $DOMINIO"
    if curl -fsS -m 15 "https://$DOMINIO/health" >/dev/null 2>&1; then info "https://$DOMINIO/health respondeu"
    else warn "o certificado saiu, mas https://$DOMINIO/health ainda não respondeu; pode levar mais alguns segundos."; fi
  else
    warn "o certificado de $DOMINIO não saiu. Veja o motivo:  docker logs coolify-proxy 2>&1 | grep -iE 'acme|certificate' | tail -20"
    warn "depois de corrigir o DNS ou o firewall:  docker restart coolify-proxy"
  fi
  if [ "$PAINEL_OK" = 1 ] && aguardar_cert "$DOMINIO_PAINEL"; then info "certificado emitido para $DOMINIO_PAINEL"; fi

  local url_painel="http://$IP:8000"
  if [ "$PAINEL_OK" = 1 ]; then url_painel="https://$DOMINIO_PAINEL"; fi

  printf '\n\033[1;32mTudo no ar!\033[0m\n\n'
  echo "  WhatsBot Pro:  https://$DOMINIO"
  echo "  Login:         $EMAIL"
  if [ "$ADMIN_APLICADO" != 1 ]; then echo "  Senha:         a do administrador que já existia"
  elif [ "$SENHA_GERADA" = 1 ]; then echo "  Senha:         $SENHA"
  else echo "  Senha:         a que você digitou"; fi
  echo "  Coolify:       $url_painel"
  [ "$COOLIFY_NOVO" != 1 ] || echo "  Login do Coolify em /root/coolify-acesso.txt"
  echo "  Estes dados: $ACESSO (só o root lê)"
  echo "  Chave do código: $KEY (guarde uma cópia)"
  cat <<EOF

  Firewall: deixe abertas as portas 80 e 443.
  Para atualizar: Coolify > $PROJETO > $NOME > Redeploy (3 a 8 minutos).
  Para ver o código-fonte ou pedir ajuda, fale com a Techify${CONTATO:+: $CONTATO}.
EOF
  if [ "$COOLIFY_NOVO" = 1 ]; then
    if [ "$PAINEL_OK" = 1 ]; then
      echo "  O painel do Coolify já está em HTTPS: feche as portas 8000, 6001 e 6002 no firewall do provedor"
      echo "  (o firewall do próprio servidor, ufw, não fecha portas publicadas pelo Docker)."
    else
      echo "  O painel do Coolify está em http://${IP}:8000 (sem HTTPS): use só em rede de confiança e feche a porta 8000 depois."
    fi
    echo "  Guarde a linha APP_KEY= de /data/coolify/source/.env (a chave do Coolify)."
  fi
}

main "$@"
