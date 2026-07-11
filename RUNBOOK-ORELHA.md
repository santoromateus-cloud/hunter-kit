# RUNBOOK — ORELHA (webhook WhatsApp Cloud API)

**O que é:** liga a "orelha" do call center — o caminho que faz as RESPOSTAS dos leads chegarem no app (fila + Close + janela 24h). Sem a orelha, o número é só-API: a Meta não entrega resposta pra ninguém e a mensagem se perde pra sempre.

**Replicável por cliente:** tudo que é específico do cliente é PARÂMETRO. Nenhum script contém segredo ou ID de cliente.

---

## Parâmetros (preencher por cliente)

Os valores reais de cada cliente vivem FORA deste repo (arquivo `PARAMETROS-<cliente>.md` na pasta do projeto, no workspace).

| Parâmetro | Exemplo genérico |
|---|---|
| `GCP_PROJECT` | meu-projeto-gcp |
| `VM` | hunter-vm |
| `ZONE` | southamerica-east1-a |
| `IP_VM` | IP externo estático da VM |
| `DOMINIO_API` | api.meudominio.com.br |
| `PAINEL_DNS` | onde a zona DNS do domínio vive (Registro.br, Cloudflare, Vercel...) |
| `APP_META` | app Meta do cliente (developers.facebook.com) |

**Pré-requisitos (fase "prédio", já de pé antes desta):** VM com hunter-web (porta 8080) + hunter-worker em systemd; WhatsApp Cloud API com número REGISTRADO (POST /register com PIN — sem isso, erro #133010); template de abertura APROVADO; `.env` do app com `META_APP_SECRET=placeholder`.

---

## Passo 0 — Checagem de saúde (30s)

No Cloud Shell:
```bash
gcloud compute ssh <VM> --zone=<ZONE> --command="curl -s localhost:8080/health; echo; sudo journalctl -u hunter-worker -n 15 --no-pager"
```
Esperado: `"ok":true,"pausado":false` e log do worker sem erros novos.

## Passo 1 — DNS (painel, ~2 min + propagação)

No painel onde a zona DNS do domínio vive (`PAINEL_DNS`):
- **Registro.br:** login → Meus Domínios → domínio → aba **DNS** → Editar zona (modo avançado) → **nova entrada tipo A**: nome `api` → valor `IP_VM` → salvar. A publicação no Registro.br pode levar de minutos a ~1h (o painel avisa o horário da próxima publicação).
- Conferir propagação: `dig +short DOMINIO_API` (repetir até devolver o IP).

## Passo 2 — Firewall (Cloud Shell, 1 linha)

```bash
curl -fsSL https://raw.githubusercontent.com/santoromateus-cloud/hunter-kit/main/gcp-firewall.sh | bash -s -- <GCP_PROJECT> <VM> <ZONE>
```

## Passo 3 — HTTPS + rotação de tokens (Cloud Shell, 1 linha)

```bash
gcloud compute ssh <VM> --zone=<ZONE> --command="curl -fsSL https://raw.githubusercontent.com/santoromateus-cloud/hunter-kit/main/vm-orelha.sh | bash -s -- <DOMINIO_API>"
```
O script instala o Caddy (certificado Let's Encrypt automático), aponta `DOMINIO_API → localhost:8080`, gera **META_VERIFY_TOKEN e SIM_TOKEN novos** e imprime o verify token (o único que pode aparecer na tela — é de baixa sensibilidade).

Validar: `curl -s https://DOMINIO_API/health` devolve o mesmo JSON do health local.

## Passo 4 — META_APP_SECRET real (interativo, NUNCA pelo chat)

1. developers.facebook.com → app do cliente → **Configurações do app → Básico → Chave Secreta do App → Mostrar → copiar** (vai pro clipboard).
2. Sessão SSH interativa na VM:
```bash
cd ~/v2-fundacao && read -s S && sed -i "s|^META_APP_SECRET=.*|META_APP_SECRET=$S|" .env && unset S && sudo systemctl restart hunter-web && echo "secret ok"
```
Colar (Cmd+V) no `read -s` — não aparece nada na tela, é normal. **Padrão da casa: segredo vai do painel direto pro .env via clipboard; nunca passa pelo chat.**

⚠️ Ordem importa: o secret real entra ANTES de configurar o webhook no painel — sem ele, todo POST da Meta leva 401 (assinatura inválida).

## Passo 5 — Webhook no painel Meta (~3 min)

App do cliente → **WhatsApp → Configuração** → Webhook → Editar:
- Callback URL: `https://DOMINIO_API/webhook/meta`
- Verify token: o `META_VERIFY_TOKEN_NOVO` impresso no Passo 3
- **Verificar e salvar** (a Meta faz um GET na hora; o app responde o hub.challenge)
- Em **Campos do webhook** → assinar **`messages`**

Aproveitar o painel: conferir status dos templates (ex.: follow-up de 48h) no WhatsApp Manager.

## Passo 6 — Teste de ouro da orelha

1. Responder qualquer coisa, do celular do dono, na conversa do template já recebido.
2. Conferir (Cloud Shell):
```bash
gcloud compute ssh <VM> --zone=<ZONE> --command='cd ~/v2-fundacao && set -a && . ./.env && set +a && curl -s -H "X-Auth-Token: $SIM_TOKEN" localhost:8080/fila; echo; sudo journalctl -u hunter-web -n 20 --no-pager'
```
**Sucesso =** a mensagem aparece na `/fila`, o log mostra POST `/webhook/meta` com 200, e o lead no Close ganha a nota "💬 Respondeu no WhatsApp".

---

## Erros conhecidos (não repetir)

| Sintoma | Causa | Fix |
|---|---|---|
| Webhook "não foi possível validar" no painel | DNS ainda não propagou / porta fechada / verify token errado | Passo 1→2→3 na ordem; conferir `curl https://DOMINIO_API/health` antes do painel |
| POST da Meta leva 401 | `META_APP_SECRET` ainda é placeholder | Passo 4 antes do Passo 5 |
| Envio falha #133010 | Número não registrado na Cloud API (verificar por SMS não basta) | POST /register com PIN (fase prédio) |
| Robô ignora lead recém-criado | Data de corte em UTC vs lead em BRT | Datas de corte sempre pensadas em BRT vs UTC |
| Busca no Close devolve 0 com lead existente | Índice de busca atrasa minutos | Usar a MESMA query do worker e aguardar |
| Cert não emite | Caddy subiu antes do DNS propagar | Normal — o Caddy re-tenta sozinho; só aguardar |

## Botões de pânico

```bash
# para tudo (dentro da VM):
sudo systemctl stop hunter-worker hunter-web
# pausa de software: config do cliente → "pausado": true → restart hunter-worker
```

## Checklist final (binário)

- [ ] `https://DOMINIO_API/health` responde ok
- [ ] Webhook verificado e salvo no painel + campo `messages` assinado
- [ ] `META_APP_SECRET` real no .env (nunca passou pelo chat)
- [ ] Tokens rotacionados (verify + sim)
- [ ] Teste de ouro: resposta do celular caiu na `/fila` + nota no Close
- [ ] Template de follow-up conferido (aprovado ou em revisão)

