#!/usr/bin/env bash
# ============================================================================
# ORELHA — fase 2/2: HTTPS (Caddy) na frente do app + rotacao de tokens.
# Onde roda: DENTRO da VM (via gcloud compute ssh ... --command).
# Uso:  vm-orelha.sh <DOMINIO_API>
# Ex.:  vm-orelha.sh api.meudominio.com.br
# Pre-requisito: o "predio" ja de pe (hunter-web na porta 8080, .env no app).
# Idempotente: pode rodar de novo; so gera tokens novos a cada rodada.
# NUNCA imprime nem recebe o META_APP_SECRET — esse e passo manual (read -s).
# ============================================================================
set -euo pipefail
DOMAIN="${1:?uso: vm-orelha.sh api.seudominio.com.br}"

# --- 1. Caddy (HTTPS automatico via Let's Encrypt) --------------------------
if ! command -v caddy >/dev/null 2>&1; then
  sudo apt-get update -qq
  sudo apt-get install -y -qq debian-keyring debian-archive-keyring apt-transport-https curl
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
    | sudo gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
    | sudo tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
  sudo apt-get update -qq
  sudo apt-get install -y -qq caddy
fi

sudo tee /etc/caddy/Caddyfile >/dev/null <<EOF
$DOMAIN {
    reverse_proxy localhost:8080
}
EOF
sudo systemctl enable --now caddy >/dev/null 2>&1 || true
sudo systemctl reload caddy 2>/dev/null || sudo systemctl restart caddy

# --- 2. Rotaciona META_VERIFY_TOKEN e SIM_TOKEN no .env ----------------------
ENVF="$(find "$HOME" -maxdepth 3 -name '.env' -path '*fundacao*' 2>/dev/null | head -1)"
if [ -z "$ENVF" ]; then echo "ERRO: .env do app nao encontrado em ~/*fundacao*"; exit 1; fi
NV="$(openssl rand -hex 16)"
NS="$(openssl rand -hex 16)"
upsert() { if grep -q "^$1=" "$ENVF"; then sed -i "s|^$1=.*|$1=$2|" "$ENVF"; else echo "$1=$2" >> "$ENVF"; fi; }
upsert META_VERIFY_TOKEN "$NV"
upsert SIM_TOKEN "$NS"
chmod 600 "$ENVF"

# --- 2b. Inscreve o WABA no app (subscribed_apps) - O ELO QUE FALTA ----------
# Sem isto: o webhook VERIFICA (GET 200) e o campo 'messages' fica assinado no
# painel, mas NENHUMA mensagem inbound e entregue. Sintoma identico a "dev mode".
# Le waba_id + token do config do cliente e faz o POST. Idempotente.
set -a; . "$ENVF"; set +a
CFG="$(find "$HOME" -maxdepth 4 -path '*config/clientes/*.json' 2>/dev/null | head -1)"
if [ -n "$CFG" ]; then
  WABA="$(python3 -c "import json;print(json.load(open('$CFG'))['contas']['whatsapp'].get('waba_id',''))" 2>/dev/null)"
  TOKVAR="$(python3 -c "import json;print(json.load(open('$CFG'))['contas']['whatsapp'].get('token_env',''))" 2>/dev/null)"
  TOK="${!TOKVAR}"
  if [ -n "$WABA" ] && [ -n "$TOK" ]; then
    echo "=== INSCREVENDO WABA $WABA NO APP (subscribed_apps) ==="
    curl -s -X POST "https://graph.facebook.com/v22.0/$WABA/subscribed_apps" -H "Authorization: Bearer $TOK"; echo
    echo -n "subscribed_apps agora: "
    curl -s "https://graph.facebook.com/v22.0/$WABA/subscribed_apps" -H "Authorization: Bearer $TOK"; echo
  else
    echo "AVISO: waba_id/token nao resolvidos no config; inscrever o WABA manualmente (RUNBOOK Passo 5.5)"
  fi
else
  echo "AVISO: config do cliente nao encontrado; inscrever o WABA manualmente (RUNBOOK Passo 5.5)"
fi

# --- 3. Religa o app e confere ------------------------------------------------
sudo systemctl restart hunter-web 2>/dev/null || true
sleep 3
echo "=== SAUDE LOCAL (localhost:8080) ==="
curl -s localhost:8080/health || true; echo
echo "=== CADDY ==="
systemctl is-active caddy || true
echo "=== SAUDE PUBLICA https://$DOMAIN (pode falhar enquanto DNS/cert propagam) ==="
curl -s --max-time 25 "https://$DOMAIN/health" || echo "(ainda propagando — o caddy re-tenta o certificado sozinho)"
echo
echo "META_VERIFY_TOKEN_NOVO=$NV"
echo
echo "PROXIMOS PASSOS MANUAIS:"
echo "  1) APP SECRET real no .env via read -s (nunca pelo chat/painel de terceiros)"
echo "  2) Painel Meta > WhatsApp > Configuracao > Webhook: URL https://$DOMAIN/webhook/meta + verify token acima"
echo "  3) Assinar o campo 'messages'"
