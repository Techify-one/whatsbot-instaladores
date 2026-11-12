#!/usr/bin/env bash
# =====================================================================
#  WhatsBot-Lite — instalação direta no Linux (sem Docker)
#  Ubuntu ou Debian limpo, como root. Sem perguntas.
#
#    bash <(curl -fsSL https://scripts.techify.site/whatsbot-linux)
#    bash <(wget -qO- https://scripts.techify.site/whatsbot-linux)    # sem curl
#
#  Baixa o código do GitHub, instala o Python e as dependências e deixa o
#  WhatsBot rodando como serviço (sobe sozinho quando o servidor liga).
#
#  Opcional (antes do comando):  PORTA=8081   FORCAR=1   USAR_SYSTEMD=0
#  Pode rodar de novo: atualiza o WhatsBot e preserva os dados.
# =====================================================================
set -Eeuo pipefail

REPO="${REPO:-https://github.com/Techify-one/whatsbot-lite}"
BRANCH="${BRANCH:-main}"
DIR="${DIR:-/opt/whatsbot-lite}"
USUARIO_SERVICO="${USUARIO_SERVICO:-whatsbot}"
PORTA="${PORTA:-}"
GOWA_PORTA="${GOWA_PORTA:-}"
FORCAR="${FORCAR:-0}"                 # 1 = segue sem perguntar quando o sistema foge do recomendado
USAR_SYSTEMD="${USAR_SYSTEMD:-1}"     # 0 = só em segundo plano, sem subir sozinho no boot
UNIT=/etc/systemd/system/whatsbot-lite.service
APT="apt-get -o DPkg::Lock::Timeout=300"
PY_BIN=python3

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33mAviso:\033[0m %s\n' "$*" >&2; }
die()  { printf '\n\033[1;31mERRO:\033[0m %s\n' "$*" >&2; exit 1; }

have_tty()  { { : </dev/tty; } 2>/dev/null; }
port_busy() { ss -ltn "( sport = :$1 )" 2>/dev/null | awk 'NR>1' | grep -q .; }
local_ip()  { ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}'; }
# Tudo que mexe no código roda como o usuário do serviço: o self-update, o pip e o storages/ escrevem ali.
como_bot()  { runuser -u "$USUARIO_SERVICO" -- env HOME="$DIR" "$@"; }

confirmar_continuar() {
  if [ "$FORCAR" = 1 ]; then return 0; fi
  if ! have_tty; then warn "sem terminal para perguntar; seguindo mesmo assim."; return 0; fi
  local r=""
  read -r -p "    Continuar mesmo assim? [s/N] " r </dev/tty
  case "$r" in s|S|sim|SIM|y|Y) return 0 ;; *) die "instalação cancelada." ;; esac
}

# ---------------------------------------------------------------- verificações

verificar_sistema() {
  . /etc/os-release
  local id=${ID:-?} ver=${VERSION_ID:-} nome=${PRETTY_NAME:-desconhecido} aviso=""
  # O WhatsBot precisa de Python 3.11 ou mais: Ubuntu 22.04 traz o 3.10, por isso não está na lista.
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

apt_preparar() {
  export DEBIAN_FRONTEND=noninteractive
  local out f
  out=$($APT update 2>&1) || true
  # Ubuntu intermediário (ex.: 24.10) sai de suporte e some do archive.ubuntu.com (apt dá 404).
  if grep -qE "(no longer has|does not have) a Release file|404 +Not Found" <<<"$out"; then
    warn "esta versão do Ubuntu saiu de suporte; usando o arquivo old-releases.ubuntu.com."
    for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.sources /etc/apt/sources.list.d/*.list; do
      if [ -f "$f" ]; then
        sed -i -E 's#https?://(archive|security|[a-z]{2}\.archive)\.ubuntu\.com/ubuntu#http://old-releases.ubuntu.com/ubuntu#g' "$f"
      fi
    done
  fi
  $APT update -qq >/dev/null
  # psmisc (fuser) é o que o linux_start.sh usa para liberar a porta; unzip e curl, para baixar o GOWA.
  $APT install -y -qq ca-certificates curl wget git unzip iproute2 psmisc python3 python3-venv >/dev/null
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

unit_desta_pasta() { [ -f "$UNIT" ] && grep -qx "WorkingDirectory=$DIR" "$UNIT"; }
unit_env()         { sed -n "s/^Environment=$1=//p" "$UNIT" 2>/dev/null | head -1; }

escolher_portas() {
  # Reexecução: mantém as portas que o serviço já usa (a porta ocupada é o próprio WhatsBot).
  if unit_desta_pasta; then
    PORTA=$(unit_env WHATSBOT_WEB_PORT); GOWA_PORTA=$(unit_env WHATSBOT_GOWA_PORT)
    if [ -n "$PORTA" ] && [ -n "$GOWA_PORTA" ]; then info "serviço já instalado: mantendo as portas $PORTA (web) e $GOWA_PORTA (WhatsApp)"; return 0; fi
  fi
  if [ -n "$PORTA" ]; then
    [[ "$PORTA" =~ ^[0-9]+$ ]] && [ "$PORTA" -ge 1 ] && [ "$PORTA" -le 65535 ] || die "PORTA inválida: $PORTA"
    if port_busy "$PORTA"; then die "a porta $PORTA já está em uso neste servidor. Escolha outra: PORTA=8081"; fi
  else
    local p=8080
    while port_busy "$p"; do
      p=$((p + 1))
      if [ "$p" -gt 8099 ]; then die "não achei porta livre entre 8080 e 8099. Use PORTA=<número livre>."; fi
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
    [ "$(stat -c %U "$DIR")" = "$USUARIO_SERVICO" ] || die "$DIR já existe com outro dono ($(stat -c %U "$DIR")). Remova a pasta ou use DIR=/outro/caminho."
    if ! como_bot git -C "$DIR" pull --ff-only; then
      warn "não consegui atualizar o código (há arquivos alterados aqui); seguindo com a versão que está instalada."
    fi
  else
    if [ -e "$DIR" ] && [ -n "$(ls -A "$DIR")" ]; then die "$DIR existe e não é um clone do WhatsBot."; fi
    mkdir -p "$DIR"
    chown "$USUARIO_SERVICO:$USUARIO_SERVICO" "$DIR"
    como_bot git clone --depth 1 --branch "$BRANCH" "$REPO" "$DIR"
  fi
  # Cria a venv com o Python certo; o linux_start.sh só cria a dele (python3) se esta não existir.
  if [ ! -x "$DIR/venv/bin/python" ]; then como_bot "$PY_BIN" -m venv "$DIR/venv"; fi
}

subir_servico() {
  if [ "$USAR_SYSTEMD" = 1 ] && [ -d /run/systemd/system ]; then
    # O linux_start.sh cria a unit, liga no boot e inicia. Ele roda como o dono da pasta (o usuário do serviço).
    WHATSBOT_WEB_PORT="$PORTA" WHATSBOT_GOWA_PORT="$GOWA_PORTA" bash "$DIR/linux_start.sh" service install
    MODO_SERVICO=systemd
  else
    if [ "$USAR_SYSTEMD" = 1 ]; then warn "este servidor não usa systemd; subindo só em segundo plano (não volta sozinho depois de reiniciar)."; fi
    # Para uma execução anterior deste usuário, senão as duas brigariam pela porta.
    pkill -u "$USUARIO_SERVICO" -f 'linux_start\.sh|uvicorn|bin/gowa' 2>/dev/null || true
    sleep 2
    como_bot env WHATSBOT_WEB_PORT="$PORTA" WHATSBOT_GOWA_PORT="$GOWA_PORTA" WHATSBOT_RELOAD=0 \
      bash -c "cd '$DIR' && setsid nohup bash linux_start.sh > '$DIR/whatsbot.log' 2>&1 < /dev/null &"
    MODO_SERVICO=background
  fi
}

main() {
  [ "$(id -u)" -eq 0 ] || die "rode como root (use: sudo -i)"
  step "Verificando o servidor"
  verificar_sistema
  verificar_recursos

  step "Pacotes básicos"; apt_preparar
  step "Python"; garantir_python
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

  local ip pub; ip=$(local_ip)
  if [ -z "$ip" ]; then ip=$(hostname -I | awk '{print $1}'); fi
  # Valida pelo IP da interface, o mesmo que o navegador vai usar (e não só por localhost).
  curl -fsS -m 8 "http://${ip}:${PORTA}/health" >/dev/null || die "responde em localhost mas não em ${ip}:${PORTA}."
  pub=$(curl -4fsS -m 6 https://ifconfig.io 2>/dev/null || true)

  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    warn "o firewall (ufw) está ativo: libere a porta com   ufw allow ${PORTA}/tcp"
  fi

  printf '\n\033[1;32mWhatsBot-Lite no ar!\033[0m\n'
  cat <<EOF

  Painel:     http://${ip}:${PORTA}
EOF
  if [ -n "$pub" ] && [ "$pub" != "$ip" ]; then
    echo "  Pela internet (se a porta ${PORTA} estiver liberada no firewall do provedor): http://${pub}:${PORTA}"
  fi
  if [ "$MODO_SERVICO" = systemd ]; then
    cat <<EOF
  Logs:       journalctl -u whatsbot-lite -f
  Status:     systemctl status whatsbot-lite
  Reiniciar:  systemctl restart whatsbot-lite
  Remover:    bash ${DIR}/linux_start.sh service uninstall     (os dados em ${DIR}/storages ficam)
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
