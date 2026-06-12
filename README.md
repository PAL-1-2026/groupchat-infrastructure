# groupchat-infrastructure

Infrastructure and deployment scripts for the **kabw-groupchat** application — a real-time group chat app built with React + TypeScript (frontend) and Node.js + Socket.io (backend).

This repository contains everything needed to run the application on a production EC2 instance. It is designed to be used alongside the CI/CD pipeline (Jenkins) that automatically builds, tests, and pushes Docker images to Amazon ECR, then triggers deployment via `deploy.sh` through SSH.

## Repository Structure

```
groupchat-infrastructure/
├── deploy.sh                 # Deployment script, dijalankan di EC2 via SSH oleh Jenkins
├── docker-compose.prod.yml   # Docker Compose konfigurasi production (FE + BE + DB)
└── .env.example              # Template environment variables untuk EC2
```

## Related Repositories

| Repo | Deskripsi |
|------|-----------|
| [groupchat-app-backend](https://github.com/PAL-1-2026/groupchat-app-backend) | Node.js + Express + Socket.io + Prisma |
| [groupchat-app-frontend](https://github.com/PAL-1-2026/groupchat-app-frontend) | React + TypeScript + Vite |

## Architecture Overview

```
Developer
  │  git push (branch: main)
  ▼
GitHub Repository + Webhook
  │  trigger
  ▼
Jenkins Server (EC2 t2.medium)
  │
  ├── Stage 1: Checkout
  ├── Stage 2: Install Dependencies
  ├── Stage 3: Lint & Test
  ├── Stage 4: Build App
  ├── Stage 5: Docker Build
  ├── Stage 6: Push to Amazon ECR
  │
  └── Stage 7: Deploy to EC2  ──SSH──▶  Target EC2
                                           │
                                     deploy.sh
                                           │
                                    docker-compose.prod.yml
                                           │
                              ┌────────────┼────────────┐
                           postgres     backend      frontend
```

Setiap push ke branch `main` di repo backend atau frontend memicu pipeline secara otomatis. Jika semua stage berhasil, Jenkins akan SSH ke Target EC2 dan menjalankan `deploy.sh` dengan image tag yang baru.

## Prerequisites

Sebelum menjalankan deployment, pastikan hal-hal berikut sudah disiapkan:

**Di Jenkins Server:**
- Jenkins 2.440+ dengan plugin: Pipeline, Git, GitHub Integration, Docker Pipeline, Credentials Binding
- Docker Engine & Docker Compose
- AWS CLI v2
- SSH private key ke Target EC2 (disimpan di Jenkins Credentials)
- AWS credentials (IAM dengan akses ECR) disimpan di Jenkins Credentials

**Di Target EC2 (Production):**
- Ubuntu 22.04 atau Amazon Linux 2023
- Docker Engine & Docker Compose plugin
- AWS CLI v2 (untuk `aws ecr get-login-password`)
- File `deploy.sh` sudah ada di `~/deploy.sh` dan sudah executable
- File `docker-compose.prod.yml` sudah ada di `~/docker-compose.prod.yml`
- File `.env` sudah dikonfigurasi (lihat bagian [Environment Setup](#environment-setup))

**Di AWS:**
- Amazon ECR repository: `kabw-groupchat/backend` dan `kabw-groupchat/frontend`
- IAM user/role dengan permission ECR: `GetAuthorizationToken`, `BatchCheckLayerAvailability`, `PutImage`, `InitiateLayerUpload`, `UploadLayerPart`, `CompleteLayerUpload`
- Security Group EC2 dengan port terbuka: `8080` (Jenkins UI), `8081` (backend), `3000` (frontend), `22` (SSH, batasi dari IP Jenkins saja)

## Environment Setup

Di Target EC2, buat file `.env` dari template yang tersedia:

```bash
cp .env.example .env
nano .env
```

Isi nilai sesuai environment:

```env
# URL publik frontend — digunakan backend untuk konfigurasi CORS
APP_ORIGIN=http://<EC2_PUBLIC_IP>:3000

# URL publik backend API — digunakan oleh container frontend saat runtime
VITE_API_BASE_URL=http://<EC2_PUBLIC_IP>:8081/api

# URL publik backend socket — digunakan oleh container frontend untuk Socket.io
VITE_SOCKET_URL=http://<EC2_PUBLIC_IP>:8081
```

Variabel tambahan yang bisa di-override (opsional, ada default di `docker-compose.prod.yml`):

```env
POSTGRES_PASSWORD=your_strong_password
JWT_SECRET=your_jwt_secret
JWT_EXPIRY=86400
SALT_ROUNDS=10
```

> **Penting:** File `.env` tidak boleh di-commit ke repository. File ini hanya disimpan di EC2 dan tidak pernah dikirim ke GitHub maupun ECR image.

## First-Time Setup on EC2

Lakukan langkah ini sekali sebelum pipeline pertama kali dijalankan:

```bash
# 1. Clone repo infrastructure ke home directory EC2
git clone https://github.com/PAL-1-2026/groupchat-infrastructure.git ~/infra
cp ~/infra/deploy.sh ~/deploy.sh
cp ~/infra/docker-compose.prod.yml ~/docker-compose.prod.yml
cp ~/infra/.env.example ~/.env

# 2. Buat .env dan isi nilainya
nano ~/.env

# 3. Beri permission execute pada deploy.sh
chmod +x ~/deploy.sh

# 4. Jalankan postgres terlebih dahulu (hanya perlu sekali)
bash ~/deploy.sh postgres
```

## deploy.sh Usage

Script `deploy.sh` dijalankan oleh Jenkins melalui SSH. Bisa juga dijalankan manual.

```bash
# Deploy service backend dengan image tag tertentu
bash ~/deploy.sh <IMAGE_TAG> backend

# Deploy service frontend dengan image tag tertentu
bash ~/deploy.sh <IMAGE_TAG> frontend

# Deploy/start postgres saja (tanpa pull image dari ECR)
bash ~/deploy.sh postgres
```

**Contoh:**
```bash
bash ~/deploy.sh build-42-a3f9c1b backend
bash ~/deploy.sh build-42-a3f9c1b frontend
```

**Apa yang dilakukan script ini:**
1. Login ke Amazon ECR menggunakan AWS CLI
2. Menyimpan digest image sebelumnya untuk keperluan rollback
3. Pull image baru dari ECR dengan tag yang diberikan
4. Tag image baru sebagai `latest`
5. Restart service yang dipilih saja (`--no-deps`) menggunakan Docker Compose
6. Menunggu container berstatus `running` (timeout 60 detik)
7. Jika gagal: rollback otomatis ke image sebelumnya

## docker-compose.prod.yml Services

| Service | Image | Port | Keterangan |
|---------|-------|------|-----------|
| `postgres` | `postgres:16-alpine` | — | Database PostgreSQL dengan healthcheck |
| `backend` | ECR `kabw-groupchat/backend:latest` | `8081:8080` | API + Socket.io, auto-migrate Prisma saat start |
| `frontend` | ECR `kabw-groupchat/frontend:latest` | `3000:3000` | React app, environment inject via `entrypoint.sh` |

Backend otomatis menunggu postgres sehat (`condition: service_healthy`) sebelum start. Perintah start backend sudah mencakup `prisma migrate deploy` sehingga schema database selalu terupdate.

## Jenkins Credentials yang Dibutuhkan

Simpan semua credential berikut di Jenkins → Manage Jenkins → Credentials:

| ID | Type | Keterangan |
|----|------|-----------|
| `aws-ecr-credentials` | AWS Credentials | Access Key + Secret Key untuk push ke ECR |
| `ec2-deploy-key` | SSH Username with Private Key | Private key SSH ke Target EC2 |
| `ec2-host` | Secret Text | Public IP atau hostname Target EC2 |

## Rollback Manual

Jika perlu rollback manual ke versi sebelumnya tanpa pipeline:

```bash
# Lihat image yang tersedia di EC2
docker images | grep kabw-groupchat

# Jalankan versi sebelumnya secara manual
bash ~/deploy.sh <PREVIOUS_IMAGE_TAG> backend
bash ~/deploy.sh <PREVIOUS_IMAGE_TAG> frontend
```

Atau untuk rollback menggunakan digest yang spesifik:

```bash
docker pull 801534266905.dkr.ecr.us-east-1.amazonaws.com/kabw-groupchat/backend:<OLD_TAG>
docker tag  801534266905.dkr.ecr.us-east-1.amazonaws.com/kabw-groupchat/backend:<OLD_TAG> \
            801534266905.dkr.ecr.us-east-1.amazonaws.com/kabw-groupchat/backend:latest
docker compose -f ~/docker-compose.prod.yml up -d --no-deps backend
```

## Troubleshooting

**Container tidak mau start / langsung exit:**
```bash
docker compose -f ~/docker-compose.prod.yml logs --tail=100 backend
docker compose -f ~/docker-compose.prod.yml logs --tail=100 frontend
```

**Postgres tidak healthy:**
```bash
docker compose -f ~/docker-compose.prod.yml logs postgres
docker inspect --format='{{.State.Health.Status}}' groupchat-postgres
```

**ECR login gagal:**
```bash
# Pastikan AWS CLI terkonfigurasi dengan benar
aws sts get-caller-identity
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin 801534266905.dkr.ecr.us-east-1.amazonaws.com
```

**Environment variable tidak terbaca di frontend:**  
Frontend menggunakan `entrypoint.sh` untuk inject env saat container start (bukan saat build). Pastikan `VITE_API_BASE_URL` dan `VITE_SOCKET_URL` sudah ada di file `.env` di EC2.

## Team

| Nama | NIM |
|------|-----|
| Akbar Fikri Abdillah | 2351502011111058 |
| Nizar Maulana Wahyudi | 235150201111052 |

Mata Kuliah: Praktikum Administrasi Linux (PAL) — Semester Genap 2025/2026  
Dosen Pengampu: Widhi Yahya, S.Kom., M.T., M.Sc., Ph.D. — Universitas Brawijaya
