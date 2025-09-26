#!/usr/bin/env bash
set -euo pipefail

export OLLAMA_HOST=${OLLAMA_HOST:-0.0.0.0:11434}
export OLLAMA_ORIGINS=${OLLAMA_ORIGINS:-*}

# 1) Installer Ollama si absent
if ! command -v ollama >/dev/null 2>&1; then
  apt-get update -y
  apt-get install -y curl ca-certificates
  curl -fsSL https://ollama.ai/install.sh | sh
fi

# 2) Un seul daemon (pas de systemd en mode SSH)
pkill -f "ollama serve" >/dev/null 2>&1 || true
nohup ollama serve >/var/log/ollama.log 2>&1 &

# 3) Attendre l’API
for i in {1..40}; do
  curl -sf http://127.0.0.1:11434/api/tags >/dev/null && break
  sleep 3
  [ $i -eq 40 ] && echo "Ollama failed to start" && exit 1
done

# 4) Pulls et création de ton modèle (facultatif ici si déjà fait)
ollama pull llama3.3:70b-instruct-q5_K_M || true
ollama pull bge-m3 || true

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
OLLAMA_DEBUG=1 ollama create lightrag-70b -f /root/LightRAG-70B-q5KM.Modelfile || true

# 5) Pré-warm (optionnel)
curl -s http://127.0.0.1:11434/api/generate -d '{"model":"lightrag-70b","prompt":"Hello","stream":false}' >/dev/null 2>&1 || true

# 6) Persistance des variables pour les prochains process
env >> /etc/environment || true

# 7) S’assurer qu’au prochain redémarrage, ça repart (onstart.sh)
cat >onstart.sh <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
export OLLAMA_HOST=${OLLAMA_HOST:-0.0.0.0:11434}
export OLLAMA_ORIGINS=${OLLAMA_ORIGINS:-*}
pkill -f "ollama serve" >/dev/null 2>&1 || true
nohup ollama serve >/var/log/ollama.log 2>&1 &
EOS
chmod +x onstart.sh
