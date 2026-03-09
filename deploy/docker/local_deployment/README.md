# VSS Local Deployment

This directory contains the configuration and scripts to run the NVIDIA Video Search & Summarization (VSS) blueprint locally using Docker.

## Prerequisites

- NVIDIA GPU(s) with driver >= 580
- Docker with NVIDIA Container Toolkit installed
- An [NGC API key](https://ngc.nvidia.com/) set in `.env`
- A [HF token key](https://huggingface.co/settings/tokens) set in `.env`

## Configuration

Copy or edit `.env` to set your credentials and deployment options. The key variables are:

| Variable | Description |
|---|---|
| `NGC_API_KEY` | Required. Your NGC API key for pulling NVIDIA images. |
| `HF_TOKEN` | Required. Your Huggingface User Access Token for pulling HF models. |
| `DISABLE_CV_PIPELINE` | Set to `true` to enable CV tracking pipeline (probably runs on GPU 0?). |
| `INSTALL_PROPRIETARY_CODECS` | Set to `true` when enabling CV tracking pipeline. |
| `ENABLE_AUDIO` | Set to `true` to enable the ASR pipeline (runs on GPU 3). |

## Running

This requires GPU so it needs to be run with slurm on the cluster.
Since this is still in testing (not stable) phase, it's better to run it interactively in the assigned resource.

See below-
```bash
srun -p h200 --gres=gpu:4 --pty bash
bash run.sh
```

NOTE- Currently this errors due to some thread race conditions with matplotlib C utils

### What `run.sh` does

1. **Loads `.env`** — sources environment variables including `NGC_API_KEY`.
2. **Authenticates with NGC** — runs `docker login nvcr.io` using your API key.
3. **Starts NIM containers** (skipping any that are already running):
   - **LLM** — `llama-3.3-70b-instruct` on GPUs 1 & 2, port `8088`
   - **Embedding** — `llama-3.2-nv-embedqa-1b-v2` on GPU 3, port `9234`
   - **Reranker** — `llama-3.2-nv-rerankqa-1b-v2` on GPU 3, port `9235`
   - **ASR** (optional) — `parakeet-tdt-0.6b-v2` on GPU 3, ports `9000` / `50051` — only started if `ENABLE_AUDIO=true`
4. **Health-checks each NIM** — polls with exponential backoff (60s, 120s, 240s, …) until the endpoint returns a valid response.
5. **Creates the Docker network** `via-engine-${USER}` if it doesn't already exist.
6. **Launches VSS via `docker compose up -d`** — starts all services defined in `compose.yaml`.

## Services started by `docker compose`

| Service | Image | Ports |
|---|---|---|
| `via-server` | `vss-engine:2.4.1` | `BACKEND_PORT` (API), `FRONTEND_PORT` (UI) |
| `milvus-standalone` | `milvusdb/milvus` | `19530` (gRPC), `9091` (HTTP) |
| `graph-db` | `neo4j:5.26.16` | `7474` (HTTP), `7687` (Bolt) |
| `arango-db` | `arangodb:3.12.6` | `8529` |
| `minio` | `minio/minio` | `MINIO_PORT`, `MINIO_WEBUI_PORT` |
| `elasticsearch` | `elasticsearch:9.2.1` | `9200`, `9300` |

See `ports_summary.txt` for a full listing of all ports across both `run.sh` and `compose.yaml`.

## Viewing logs

### All compose services (follow mode)
```bash
docker compose logs -f --tail=100
```

### A specific service (primary service and surfaces errors currently)
```bash
docker compose logs -f --tail=100 via-server
```

### NIM containers (started directly by `run.sh`, not via compose)
```bash
docker logs -f llama-3.3-70b-instruct
docker logs -f llama-3.2-nv-embedqa-1b-v2
docker logs -f llama-3.2-nv-rerankqa-1b-v2
docker logs -f parakeet-tdt-0.6b-v2   # only if ENABLE_AUDIO=true
```

### Check container health/status
```bash
docker compose ps
docker ps
```

## Stopping

```bash
docker compose down
```

The NIM containers started by `run.sh` are not managed by compose and must be stopped separately:
```bash
docker stop llama-3.3-70b-instruct llama-3.2-nv-embedqa-1b-v2 llama-3.2-nv-rerankqa-1b-v2
```
