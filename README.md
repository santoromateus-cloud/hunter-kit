# hunter-kit

Kit replicável de call center WhatsApp (projeto hunter). Scripts parametrizados por cliente — **zero segredos e zero IDs de cliente neste repositório** (tudo entra por parâmetro na hora de rodar; segredos entram por `read -s` direto na VM, nunca por chat ou arquivo).

## Fases

| Fase | O que faz | Onde está |
|---|---|---|
| Prédio | VM + serviços systemd (web + worker) + .env | `vmsetup.sh` (no workspace do projeto; entra no kit na v2) |
| **Orelha** | HTTPS (Caddy) + webhook Meta + rotação de tokens | `gcp-firewall.sh` + `vm-orelha.sh` + `RUNBOOK-ORELHA.md` |

## Uso rápido (Orelha)

```bash
# Cloud Shell — firewall:
curl -fsSL https://raw.githubusercontent.com/santoromateus-cloud/hunter-kit/main/gcp-firewall.sh | bash -s -- PROJETO VM ZONA

# Cloud Shell — HTTPS + tokens (roda dentro da VM via ssh):
gcloud compute ssh VM --zone=ZONA --command="curl -fsSL https://raw.githubusercontent.com/santoromateus-cloud/hunter-kit/main/vm-orelha.sh | bash -s -- api.SEUDOMINIO.com.br"
```

Passo a passo completo, erros conhecidos e checklist: [`RUNBOOK-ORELHA.md`](RUNBOOK-ORELHA.md).

