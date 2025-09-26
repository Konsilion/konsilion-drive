#!/usr/bin/env bash
set -euo pipefail

export OLLAMA_HOST=${OLLAMA_HOST:-0.0.0.0:11434}

# Install Ollama (container SSH mode: pas de systemd)
if ! command -v ollama >/dev/null 2>&1; then
  apt-get update && apt-get install -y curl ca-certificates || true
  curl -fsSL https://ollama.ai/install.sh | sh
fi

# Un seul daemon
pkill -f "ollama serve" >/dev/null 2>&1 || true
nohup ollama serve >/var/log/ollama.log 2>&1 &

# Attendre l’API
for i in {1..40}; do
  curl -sf http://127.0.0.1:11434/api/tags >/dev/null && break
  sleep 3
  [ $i -eq 40 ] && echo "Ollama failed to start" && exit 1
done

# Pulls
ollama pull llama3.3:70b-instruct-q5_K_M
ollama pull bge-m3 || true

# Modelfile et création (idempotent)
cat >/root/LightRAG-70B-q5KM.Modelfile <<'EOF'
FROM llama3.3:70b-instruct-q5_K_M
SYSTEM """
Tu es un extracteur d'entites et de relations. Tu dois produire EXCLUSIVEMENT du JSON valide.
Role: extraire des triples {head, relation, tail, evidence} et dedupliquer.
Regles:
- Pas d'explication, pas de texte hors JSON.
- "evidence" est un court extrait exact du texte source (<= 300 caracteres).
- Utiliser des intitules concis et normalises.
"""
PARAMETER num_ctx 131072
PARAMETER temperature 0.2
PARAMETER top_p 0.9
PARAMETER format json
EOF

ollama rm lightrag-70b >/dev/null 2>&1 || true
OLLAMA_DEBUG=1 ollama create lightrag-70b -f /root/LightRAG-70B-q5KM.Modelfile

# Warm-up
curl -s http://127.0.0.1:11434/api/generate -d '{"model":"lightrag-70b","prompt":"Hello","stream":false}' >/dev/null 2>&1 || true

# Rendre l'env persistant pour d'autres process
env >> /etc/environment || true
