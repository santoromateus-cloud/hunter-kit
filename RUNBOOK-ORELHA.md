# RUNBOOK — ORELHA (webhook WhatsApp Cloud API)

**O que é:** liga a "orelha" do call center — o caminho que faz as RESPOSTAS dos leads chegarem no app (fila + Close + janela 24h). Sem a orelha, o número é só-API: a Meta não entrega resposta pra ninguém e a mensagem se perde pra sempre.

**Replicável por cliente:** tudo que é específico do cliente é PARÂMETRO. Nenhum script contém segredo ou ID de cliente.

---

## Parâmetros (preencher por cliente)

Os valores reais de cada cliente vivem FORA deste repo (arquivo `PARAMETROS-<cliente>.md` na pasta do projeto).

| Parâmetro | Exemplo genérico |
|---|---|
| `GCP_PROJECT` | meu-projeto-gcp |
| `VM` | hunter-vm |
| `ZONE` | southamerica-east1-a |
| `IP_VM` | IP externo estático da VM |
| `DOMINIO_API` | api.meudominio.com.br |
| `PAINEL_DNS` | onde a zona DNS vive (Registro.br, Cloudflare, Vercel...) |
| `APP_META` | app Meta do cliente |

**Pré-requisitos (fase "prédio"):** VM com hunter-web (8080) + hunter-worker em systemd; WhatsApp Cloud API com número REGISTRADO (POST /register com PIN — sem isso, erro #133010); template de abertura APROVADO; `.env` com `META_APP_SECRET=placeholder`.

---

## Passo 0 — Checagem de saúde (30s)

```bash
gcloud compute ssh <VM> --zone=<ZONE> --command="curl -s localhost:8080/health; echo; sudo journalctl -u hunter-worker -n 15 --no-pager"
```
Esperado: `"ok":true,"pausado":false`.

## Passo 1 — DNS (painel, ~2 min + propagação)

No painel da zona DNS (`PAINEL_DNS`):
- **Registro.br:** login → Meus Domínios → domínio → **DNS** → Editar zona → **nova entrada A**: nome `api` → valor `IP_VM` → salvar.
- Conferir: `dig +short DOMINIO_API` (repetir até devolver o IP).

## Passo 2 — Firewall (Cloud Shell, 1 linha)

```bash
curl -fsSL https://raw.githubusercontent.com/santoromateus-cloud/hunter-kit/main/gcp-firewall.sh | bash -s -- <GCP_PROJECT> <VM> <ZONE>
```

## Passo 3 — HTTPS + tokens + inscrição do WABA (Cloud Shell, 1 linha)

```bash
gcloud compute ssh <VM> --zone=<ZONE> --command="curl -fsSL https://raw.githubusercontent.com/santoromateus-cloud/hunter-kit/main/vm-orelha.sh | bash -s -- <DOMINIO_API>"
```
Instala Caddy (cert Let's Encrypt automático), aponta `DOMINIO_API → localhost:8080`, gera **META_VERIFY_TOKEN e SIM_TOKEN**, **inscreve o WABA (Passo 5.5, automatico)** e imprime o verify token.

Validar: `curl -s https://DOMINIO_API/health`.

## Passo 4 — META_APP_SECRET real (interativo, NUNCA pelo chat)

1. developers.facebook.com → app → **Configurações → Básico → Chave Secreta do App → Mostrar → copiar**.
2. SSH interativo na VM:
```bash
cd ~/v2-fundacao && read -rs S && sed -i "s|^META_APP_SECRET=.*|META_APP_SECRET=$S|" .env && unset S && sudo systemctl restart hunter-web && echo "secret ok"
```
Colar (Cmd+V) no `read -rs` — tela não mostra nada, é normal. **Conferir: 32 hex; se colar 2x vira 64, cortar pela metade.**

⚠️ O secret entra ANTES do webhook — sem ele, POST da Meta leva 401.

## Passo 5 — Webhook no painel Meta (~3 min)

App → **WhatsApp → Configuração** → Webhook → Editar:
- Callback URL: `https://DOMINIO_API/webhook/meta`
- Verify token: o `META_VERIFY_TOKEN_NOVO` do Passo 3
- **Verificar e salvar** → depois assinar o campo **`messages`**

## Passo 5.5 — Inscrever o WABA no app (O ELO QUE FALTA — não pule)

⚠️ **O passo mais fácil de esquecer e o mais difícil de diagnosticar.** O webhook no app (Passo 5) NÃO basta: o WABA precisa estar inscrito no app. Sem isso: handshake verifica (GET 200), `messages` assinado, mas **nenhuma mensagem inbound chega** — idêntico a "dev mode", diagnóstico errado.

O `vm-orelha.sh` já faz automaticamente. Conferir/fazer manual, na VM (`.env` carregado):

```bash
# conferir (data:[] = NAO inscrito):
curl -s "https://graph.facebook.com/v22.0/<WABA_ID>/subscribed_apps" -H "Authorization: Bearer $WA_TOKEN"
# inscrever:
curl -s -X POST "https://graph.facebook.com/v22.0/<WABA_ID>/subscribed_apps" -H "Authorization: Bearer $WA_TOKEN"
# → {"success":true}; reconferir deve listar o app
```

## Passo 6 — Teste de ouro

1. Responder algo, do celular do dono, na conversa do template.
2. Conferir (Cloud Shell):
```bash
gcloud compute ssh <VM> --zone=<ZONE> --command='cd ~/v2-fundacao && set -a && . ./.env && set +a && curl -s -H "X-Auth-Token: $SIM_TOKEN" localhost:8080/fila; echo; sudo journalctl -u hunter-web -n 20 --no-pager'
```
**Sucesso =** mensagem na `/fila` + log com POST `/webhook/meta` 200.

---

## Erros conhecidos (não repetir)

| Sintoma | Causa | Fix |
|---|---|---|
| **Webhook verifica mas NENHUMA msg chega** (fila 0, sem POST) | **WABA não inscrito** (`subscribed_apps`=`[]`) — parece dev mode | **Passo 5.5**: POST subscribed_apps |
| `/fila` ou webhook 500 `SQLite objects created in a thread` | conexão SQLite reusada entre threads do Flask | `sqlite3.connect(..., check_same_thread=False)` |
| Webhook "não validou" no painel | DNS não propagou / porta fechada / verify errado | Passo 1→2→3; `curl https://DOMINIO_API/health` antes |
| POST da Meta 401 | `META_APP_SECRET` placeholder ou colado 2x | Passo 4 antes do 5; comprimento = 32 |
| Envio #133010 | Número não registrado (SMS não basta) | POST /register com PIN |
| Robô ignora lead novo | Data de corte UTC vs BRT | Corte sempre em BRT |
| Cert não emite | Caddy subiu antes do DNS | Normal — re-tenta sozinho |

## Botões de pânico

```bash
sudo systemctl stop hunter-worker hunter-web
# pausa de software: config → "pausado": true → restart hunter-worker
```

## Checklist final

- [ ] `https://DOMINIO_API/health` ok
- [ ] Webhook verificado + `messages` assinado
- [ ] **WABA inscrito (`subscribed_apps` lista o app)**
- [ ] `META_APP_SECRET` 32 hex (nunca pelo chat)
- [ ] Tokens rotacionados
- [ ] Teste de ouro: POST 200 + item na `/fila`
