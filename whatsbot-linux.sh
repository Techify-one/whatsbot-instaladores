#!/usr/bin/env bash
# =====================================================================
#  WhatsBot-Lite — instalação direta no Linux (sem Docker)
#  Ubuntu ou Debian, como root. Sem perguntas.
#
#    bash <(curl -fsSL https://scripts.techify.site/whatsbot-linux)
#    bash <(wget -qO- https://scripts.techify.site/whatsbot-linux)    # sem curl
#
#  Baixa o código do GitHub, instala o Python e as dependências e deixa o
#  WhatsBot rodando como serviço (sobe sozinho quando o servidor liga).
#
#  Opcional (antes do comando):
#    WHATSBOT_PORTA=8081     porta do painel (padrão: 8080, ou a próxima livre)
#    WHATSBOT_FORCAR=1       segue sem perguntar quando o sistema foge do recomendado
#    WHATSBOT_SYSTEMD=0      só em segundo plano, sem subir sozinho no boot
#    WHATSBOT_DIR=/opt/whatsbot-lite   WHATSBOT_REPO=...   WHATSBOT_BRANCH=main
#  Pode rodar de novo: atualiza o WhatsBot e preserva os dados.
# =====================================================================
set -Eeuo pipefail
export PATH="$PATH:/usr/local/sbin:/usr/sbin:/sbin"   # "su" sem o traço não traz o sbin (useradd, runuser, ss)

REPO="${WHATSBOT_REPO:-https://github.com/Techify-one/whatsbot-lite}"
BRANCH="${WHATSBOT_BRANCH:-main}"
DIR="${WHATSBOT_DIR:-/opt/whatsbot-lite}"
USUARIO_SERVICO="${WHATSBOT_USUARIO:-whatsbot}"
PORTA="${WHATSBOT_PORTA:-}"
GOWA_PORTA="${WHATSBOT_GOWA_PORTA:-}"
FORCAR="${WHATSBOT_FORCAR:-0}"
USAR_SYSTEMD="${WHATSBOT_SYSTEMD:-1}"
UNIT=/etc/systemd/system/whatsbot-lite.service
APT="apt-get -o DPkg::Lock::Timeout=300 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold"
IP4_RE='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
PY_BIN=python3
APT_OUT=""
MODO_SERVICO=""

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33mAviso:\033[0m %s\n' "$*" >&2; }
die()  { printf '\n\033[1;31mERRO:\033[0m %s\n' "$*" >&2; exit 1; }

have_tty()   { { : </dev/tty; } 2>/dev/null; }
port_busy()  { ss -ltn "( sport = :$1 )" 2>/dev/null | awk 'NR>1' | grep -q .; }
local_ip()   { ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true; }
public_ip()  { local p; p=$(curl -4fsS -m 6 https://ifconfig.io 2>/dev/null || true); if [[ "$p" =~ $IP4_RE ]]; then printf '%s' "$p"; fi; }
ip_privado() { [[ "$1" =~ ^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.|127\.) ]]; }
http_ok()    {
  if command -v curl >/dev/null 2>&1; then curl -fsI -m 15 "$1" >/dev/null 2>&1
  elif command -v wget >/dev/null 2>&1; then wget -q --spider -T 15 "$1"
  else return 0; fi
}
# Tudo que mexe no código roda como o usuário do serviço: o self-update, o pip e o storages/ escrevem ali.
como_bot()   { runuser -u "$USUARIO_SERVICO" -- env HOME="$DIR" "$@"; }

confirmar_continuar() {
  if [ "$FORCAR" = 1 ]; then return 0; fi
  if ! have_tty; then warn "sem terminal para perguntar; seguindo mesmo assim."; return 0; fi
  local r=""
  read -r -p "    Continuar mesmo assim? [s/N] " r </dev/tty
  case "$r" in s|S|sim|SIM|y|Y) return 0 ;; *) die "instalação cancelada." ;; esac
}

validar_entradas() {
  [[ "$DIR" =~ ^/[A-Za-z0-9._/-]+$ ]]                 || die "WHATSBOT_DIR inválido: use um caminho absoluto simples (ex.: /opt/whatsbot-lite)."
  [[ "$USUARIO_SERVICO" =~ ^[a-z_][a-z0-9_-]{0,30}$ ]] || die "WHATSBOT_USUARIO inválido (letras minúsculas, números, _ e -)."
  [[ "$BRANCH" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]]     || die "WHATSBOT_BRANCH inválido."
  [[ "$REPO" =~ ^(https://|git@)[A-Za-z0-9._:/@-]+$ ]] || die "WHATSBOT_REPO inválido (use um endereço https://...)."
  local v
  for v in "$PORTA" "$GOWA_PORTA"; do
    if [ -n "$v" ]; then
      [[ "$v" =~ ^[0-9]+$ ]] && [ "$v" -ge 1 ] && [ "$v" -le 65535 ] || die "porta inválida: $v"
    fi
  done
  return 0
}

# ---------------------------------------------------------------- verificações

verificar_sistema() {
  local id=${ID:-?} ver=${VERSION_ID:-} nome=${PRETTY_NAME:-desconhecido} aviso=""
  # O WhatsBot precisa de Python 3.11 ou mais: o Ubuntu 22.04 traz o 3.10 e precisa de um passo extra.
  case "$id" in
    ubuntu)
      case "$ver" in
        24.04|26.04) ;;
        22.04) aviso="vem com Python 3.10; o instalador usa o python3.11 dos repositórios (versão de pré-lançamento, mas funciona). A LTS 24.04 é preferível." ;;
        *)
          if   dpkg --compare-versions "$ver" lt 22.04; then aviso="antigo demais (o Python é anterior ao 3.11 que o WhatsBot exige)."
          elif dpkg --compare-versions "$ver" gt 26.10; then aviso="mais novo que o testado; provavelmente funciona."
          else aviso="versão intermediária, sem suporte oficial. O instalador tenta contornar, mas prefira uma LTS."
          fi ;;
      esac ;;
    debian)
      case "$ver" in
        12|13) ;;
        "") aviso="versão de testes (testing/sid), sem número fixo." ;;
        *)
          if dpkg --compare-versions "$ver" lt 12; then aviso="antigo demais (o Python é anterior ao 3.11 que o WhatsBot exige)."
          else aviso="mais novo que o testado (Debian 13); provavelmente funciona."
          fi ;;
      esac ;;
    *) aviso="só Ubuntu e Debian foram testados." ;;
  esac
  if [ -n "$aviso" ]; then
    warn "$nome: $aviso"
    info "Recomendado: Ubuntu 24.04 ou 26.04 (LTS), ou Debian 12 ou 13."
    confirmar_continuar
  else
    info "Sistema: $nome (ok)"
  fi
  case "$(uname -m)" in
    x86_64|aarch64) ;;
    *) die "arquitetura $(uname -m): só x86_64 e arm64 têm o motor do WhatsApp (GOWA) pronto." ;;
  esac
}

verificar_recursos() {
  local mem disk
  mem=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
  disk=$(df -Pm / | awk 'NR==2{print $4}')
  if [ "$mem" -lt 1000 ];  then warn "só ${mem} MB de RAM; o recomendado são 1024 MB ou mais."; fi
  if [ "$disk" -lt 3000 ]; then warn "só ${disk} MB livres em /; o recomendado são 5 GB ou mais."; fi
  return 0
}

# ---------------------------------------------------------------- apt

# Espera outro apt terminar (cloud-init, atualização automática logo após criar a VPS).
apt_update() {
  local i
  for i in $(seq 1 30); do
    if APT_OUT=$($APT update 2>&1); then return 0; fi
    if grep -qiE "Could not get lock|Unable to acquire the dpkg|is another process using it" <<<"$APT_OUT"; then
      if [ "$i" = 1 ]; then info "outro processo está usando o apt (atualização automática?); aguardando..."; fi
      sleep 10
    else
      return 1
    fi
  done
  return 1
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
  if apt_update; then return 0; fi
  if corrigir_apt_ubuntu_antigo && apt_update; then return 0; fi
  restaurar_apt
  printf '%s\n' "$APT_OUT" | tail -6 >&2
  die "o apt não conseguiu atualizar a lista de pacotes (veja acima)."
}

instalar_pacotes() {
  apt_preparar
  # psmisc (fuser) é o que o linux_start.sh usa para liberar a porta; procps (pkill) para parar a execução anterior; unzip e curl, para baixar o GOWA.
  $APT install -y -qq ca-certificates curl wget git unzip iproute2 psmisc procps python3 python3-venv >/dev/null
}

garantir_python() {
  local v
  v=$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')
  if dpkg --compare-versions "$v" lt 3.11; then
    info "Python $v; o WhatsBot precisa do 3.11 ou mais. Instalando o python3.11..."
    if $APT install -y -qq python3.11 python3.11-venv >/dev/null 2>&1 && command -v python3.11 >/dev/null 2>&1; then
      PY_BIN=python3.11
    else
      die "este sistema só tem Python $v e não achei o 3.11 nos repositórios. Use Ubuntu 24.04 ou Debian 12, ou instale com Docker (https://scripts.techify.site/whatsbot-docker)."
    fi
  fi
  "$PY_BIN" -c 'import venv, ensurepip' 2>/dev/null || die "faltou o módulo venv do Python (apt install python3-venv)."
  info "Python: $("$PY_BIN" --version 2>&1)"
}

# ---------------------------------------------------------------- portas

usa_systemd()      { [ "$USAR_SYSTEMD" = 1 ] && [ -d /run/systemd/system ]; }
unit_desta_pasta() { [ -f "$UNIT" ] && grep -qx "WorkingDirectory=$DIR" "$UNIT"; }
unit_env()         { sed -n "s/^Environment=$1=//p" "$UNIT" 2>/dev/null | head -1; }
arq_portas()       { printf '%s/.whatsbot-portas' "$DIR"; }
porta_salva()      { local v; v=$(sed -n "s/^$1=//p" "$(arq_portas)" 2>/dev/null | head -1 || true); if [[ "$v" =~ ^[0-9]+$ ]]; then printf '%s' "$v"; fi; }

# Sem systemd não há unit para lembrar as portas e o WhatsBot antigo ainda está escutando: para o
# processo do usuário do serviço e reaproveita as portas anotadas, para a reexecução não mudar o endereço.
retomar_instalacao_anterior() {
  if usa_systemd; then return 0; fi
  [ -f "$(arq_portas)" ] || return 0
  pkill -u "$USUARIO_SERVICO" -f 'linux_start\.sh|uvicorn|bin/gowa' 2>/dev/null || true
  sleep 2
  if [ -z "$PORTA" ];      then PORTA=$(porta_salva PORTA); fi
  if [ -z "$GOWA_PORTA" ]; then GOWA_PORTA=$(porta_salva GOWA_PORTA); fi
  return 0
}

escolher_portas() {
  # Reexecução com serviço: mantém as portas da unit (a porta ocupada é o próprio WhatsBot).
  if usa_systemd && unit_desta_pasta; then
    PORTA=$(unit_env WHATSBOT_WEB_PORT); GOWA_PORTA=$(unit_env WHATSBOT_GOWA_PORT)
    if [[ "$PORTA" =~ ^[0-9]+$ && "$GOWA_PORTA" =~ ^[0-9]+$ ]]; then
      info "serviço já instalado: mantendo as portas $PORTA (web) e $GOWA_PORTA (WhatsApp)"
      return 0
    fi
    PORTA=""; GOWA_PORTA=""
  fi
  if [ -n "$PORTA" ]; then
    if port_busy "$PORTA"; then die "a porta $PORTA já está em uso neste servidor. Escolha outra: WHATSBOT_PORTA=8081"; fi
  else
    local p=8080
    while port_busy "$p"; do
      p=$((p + 1))
      if [ "$p" -gt 8099 ]; then die "não achei porta livre entre 8080 e 8099. Use WHATSBOT_PORTA=<número livre>."; fi
    done
    if [ "$p" != 8080 ]; then info "a porta 8080 está ocupada; usando a $p."; fi
    PORTA=$p
  fi
  # O linux_start.sh derruba qualquer processo na porta que vai usar: por isso só escolhemos portas livres.
  if [ -z "$GOWA_PORTA" ]; then
    GOWA_PORTA=64998
    while port_busy "$GOWA_PORTA" || [ "$GOWA_PORTA" = "$PORTA" ]; do GOWA_PORTA=$((GOWA_PORTA + 1)); done
  elif port_busy "$GOWA_PORTA"; then
    die "a porta $GOWA_PORTA (motor do WhatsApp) já está em uso."
  fi
}

# ---------------------------------------------------------------- instalação

preparar_codigo() {
  if ! id "$USUARIO_SERVICO" >/dev/null 2>&1; then
    useradd --system --home-dir "$DIR" --no-create-home --shell /usr/sbin/nologin "$USUARIO_SERVICO"
  fi
  if [ -d "$DIR/.git" ]; then
    [ "$(stat -c %U "$DIR")" = "$USUARIO_SERVICO" ] || die "$DIR já existe com outro dono ($(stat -c %U "$DIR")). Remova a pasta ou use WHATSBOT_DIR=/outro/caminho."
    local origem; origem=$(como_bot git -C "$DIR" remote get-url origin 2>/dev/null || true)
    [ "$origem" = "$REPO" ] || die "$DIR é um clone de outro repositório (${origem:-desconhecido}), não de $REPO."
    # fetch + reset em vez de pull: o "Atualizar agora" do painel sobrescreve os arquivos e o pull recusaria.
    # Dados (storages/), venv/ e bin/gowa não são rastreados pelo git, então ficam intactos.
    if como_bot git -C "$DIR" fetch --depth 1 origin "$BRANCH" && como_bot git -C "$DIR" reset --hard FETCH_HEAD; then
      info "código atualizado"
    else
      warn "não consegui baixar a atualização (sem rede ou o GitHub fora do ar?); seguindo com a versão que está instalada."
    fi
  else
    if [ -e "$DIR" ] && [ -n "$(ls -A "$DIR")" ]; then die "$DIR existe e não é um clone do WhatsBot."; fi
    mkdir -p "$DIR"
    chown "$USUARIO_SERVICO:$USUARIO_SERVICO" "$DIR"
    como_bot git clone --depth 1 --branch "$BRANCH" -- "$REPO" "$DIR"
  fi
  # A pasta guarda o banco (chave da API, mensagens dos clientes) e a sessão do WhatsApp: só o dono e o root.
  chmod 750 "$DIR"
  # Cria a venv com o Python certo; o linux_start.sh só cria a dele (python3) se esta não existir.
  if [ ! -x "$DIR/venv/bin/python" ]; then como_bot "$PY_BIN" -m venv "$DIR/venv"; fi
}

# A unit é escrita AQUI, pelo root. O linux_start.sh não é executado como root: ele pertence ao usuário
# do serviço (e o painel, sem senha, aceita plugins), então rodá-lo como root seria uma escalada de privilégio.
escrever_unit() {
  if [ -f "$UNIT" ] && ! unit_desta_pasta; then
    die "já existe um serviço 'whatsbot-lite' em $UNIT apontando para outra pasta ($(sed -n 's/^WorkingDirectory=//p' "$UNIT")). Desligar não basta, o arquivo precisa sair (guarde uma cópia se quiser): systemctl disable --now whatsbot-lite; mv $UNIT /root/whatsbot-lite.service.bak; systemctl daemon-reload. Ou instale sem serviço: WHATSBOT_SYSTEMD=0."
  fi
  cat > "$UNIT" <<EOF
[Unit]
Description=WhatsBot-Lite
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${USUARIO_SERVICO}
WorkingDirectory=${DIR}
# SERVICE=1: o linux_start.sh faz exec do uvicorn; o Restart= refaz o script inteiro (pip e GOWA reconferidos).
# RELOAD=0: com --reload, o os._exit de plugin/atualização mata só o worker e o serviço fica "ativo" morto.
Environment=WHATSBOT_SERVICE=1
Environment=WHATSBOT_RELOAD=0
Environment=WHATSBOT_WEB_PORT=${PORTA}
Environment=WHATSBOT_GOWA_PORT=${GOWA_PORTA}
ExecStart=/bin/bash "${DIR}/linux_start.sh"
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 "$UNIT"
}

subir_servico() {
  if usa_systemd; then
    escrever_unit
    systemctl daemon-reload
    systemctl enable whatsbot-lite >/dev/null 2>&1
    systemctl restart whatsbot-lite
    MODO_SERVICO=systemd
  else
    if [ "$USAR_SYSTEMD" = 1 ]; then warn "este servidor não usa systemd; subindo só em segundo plano (não volta sozinho depois de reiniciar)."; fi
    printf 'PORTA=%s\nGOWA_PORTA=%s\n' "$PORTA" "$GOWA_PORTA" > "$(arq_portas)"
    chown "$USUARIO_SERVICO:$USUARIO_SERVICO" "$(arq_portas)"
    como_bot env WHATSBOT_WEB_PORT="$PORTA" WHATSBOT_GOWA_PORT="$GOWA_PORTA" WHATSBOT_RELOAD=0 \
      bash -c 'cd "$1" && setsid nohup bash linux_start.sh > "$1/whatsbot.log" 2>&1 < /dev/null &' _ "$DIR"
    MODO_SERVICO=background
  fi
}

main() {
  [ "$(id -u)" -eq 0 ] || die "rode como root (use: sudo -i)"
  # shellcheck disable=SC1091
  . /etc/os-release
  validar_entradas

  step "Verificando o servidor"
  verificar_sistema
  verificar_recursos

  step "Pacotes básicos"; instalar_pacotes
  step "Python"; garantir_python
  retomar_instalacao_anterior
  escolher_portas

  step "Código ($REPO @ $BRANCH)"; preparar_codigo

  step "Subindo o WhatsBot (a 1ª vez instala as dependências e baixa o GOWA; leva alguns minutos)"
  subir_servico

  step "Esperando o WhatsBot responder"
  local i ok=0
  for i in $(seq 1 120); do
    if curl -fsS -m 5 "http://127.0.0.1:${PORTA}/health" >/dev/null 2>&1; then ok=1; break; fi
    sleep 3
  done
  if [ "$ok" != 1 ]; then
    if [ "$MODO_SERVICO" = systemd ]; then journalctl -u whatsbot-lite -n 40 --no-pager >&2 || true
    else tail -n 40 "$DIR/whatsbot.log" >&2 || true; fi
    die "o WhatsBot não respondeu em /health após 6 minutos (veja o log acima)."
  fi

  local ip pub
  ip=$(local_ip); if [ -z "$ip" ]; then ip=$(hostname -I 2>/dev/null | awk '{print $1}' || true); fi
  [ -n "$ip" ] || die "não consegui descobrir o IP deste servidor."
  # Valida pelo IP da interface, o mesmo que o navegador vai usar (e não só por localhost).
  curl -fsS -m 8 "http://${ip}:${PORTA}/health" >/dev/null || die "responde em localhost mas não em ${ip}:${PORTA}."

  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    warn "o firewall (ufw) está ativo: libere a porta com   ufw allow ${PORTA}/tcp"
  fi

  printf '\n\033[1;32mWhatsBot-Lite no ar!\033[0m\n\n'
  echo "  Painel:     http://${ip}:${PORTA}"
  if ip_privado "$ip"; then
    pub=$(public_ip)
    if [ -n "$pub" ] && [ "$pub" != "$ip" ]; then
      echo "  Pela internet: http://${pub}:${PORTA}   (libere a porta ${PORTA} no firewall do provedor)"
    else
      echo "  (este é o IP interno do servidor; fora da rede dele, use o IP público e libere a porta ${PORTA} no firewall)"
    fi
  fi
  if [ "$MODO_SERVICO" = systemd ]; then
    cat <<EOF
  Logs:       journalctl -u whatsbot-lite -f
  Status:     systemctl status whatsbot-lite
  Reiniciar:  systemctl restart whatsbot-lite
  Remover:    systemctl disable --now whatsbot-lite && rm ${UNIT} && systemctl daemon-reload
              (os dados em ${DIR}/storages ficam)
EOF
  else
    cat <<EOF
  Logs:       tail -f ${DIR}/whatsbot.log
  Atenção:    rodando só em segundo plano: depois de reiniciar o servidor, rode este comando de novo.
EOF
  fi
  cat <<EOF
  Atualizar:  rode este comando de novo

  O painel não tem senha: não exponha esta porta direto na internet.

EOF
}

main "$@"
