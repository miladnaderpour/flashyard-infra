# Flashyard Infrastructure

This repository contains the **deployment and infrastructure configuration** for Flashyard.

It is responsible for:

- Staging and production environments
- Docker Compose deployment
- Nginx configuration
- CI/CD workflows
- Server bootstrap and onboarding

---

## 🧠 Architecture Overview

This repo is **separated from the application code**.

- `flashyard` repo → builds Docker images
- `flashyard-infra` repo → deploys and runs them

---

## 🌍 Environments

### Staging
- Domain: `staging.flashyard.app`
- Branch: `dev`
- Purpose: testing features before production

### Production
- Domain: `flashyard.app`
- Branch: `main`
- Purpose: live system

---

## 📁 Structure

```
environments/
├── staging/
│   ├── docker-compose.yml
│   └── .env.example
└── production/
    ├── docker-compose.yml
    └── .env.example

nginx/
├── staging.conf
└── production.conf

scripts/
└── bootstrap/
    └── server-setup.sh

.github/
└── workflows/
    ├── deploy-staging.yml
    └── deploy-production.yml
```
---

## 🚀 Deployment Model

Deployment is **image-based**, not source-based.

### Flow

1. App repo builds Docker images
2. Images pushed to registry (GHCR)
3. Infra repo deploys images to server
4. Server pulls and runs containers

---

## 🐳 Services

- Backend (FastAPI)
- Frontend (Vue 3)
- PostgreSQL (containerized)
- Nginx (reverse proxy)

---

## 💾 Data Persistence

All persistent data is stored under `/data/flashyard/`:

```
/data/flashyard/
└── postgres/
    └── data/
```

---

## 🔐 Security Notes

- PostgreSQL is NOT exposed publicly
- Secrets should NOT be committed
- `.env` files exist only on servers
- Staging and production are fully isolated

---

## ⚠️ Important Rules

- ❌ Do NOT add application source code here
- ❌ Do NOT use `build:` in docker-compose
- ✅ Always use pre-built images
- ✅ Keep environments isolated

---

## 🗺️ Roadmap

### High Priority
- [ ] PostgreSQL automated backup (pg_dump to external storage)
- [ ] Move secrets to GitHub Actions Secrets (remove manual `.env` management)
- [ ] Add health checks to all services in docker-compose
- [ ] Production deploy with manual approval gate (GitHub Environments)

### Medium Priority
- [ ] Monitoring stack (Prometheus + Grafana)
- [ ] Centralized logging (Loki or similar)
- [ ] Nginx rate limiting and security headers

### Low Priority
- [ ] Ansible playbook for full server provisioning
- [ ] Secrets migration to HashiCorp Vault
- [ ] Multi-region or failover setup

---
