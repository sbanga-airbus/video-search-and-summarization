#!/bin/bash

# Load environment variables from .env file in the same directory as this script.
source $(dirname "$0")/".env"
# Exit script if NGC_API_KEY is not set
: ${NGC_API_KEY:? "Error: NGC_API_KEY is not set. Please set it in the .env file."}

export LOCAL_NIM_CACHE=~/.cache/nim
mkdir -p "$LOCAL_NIM_CACHE"

docker login nvcr.io -u '$oauthtoken' -p "$NGC_API_KEY"

# Wait until an HTTP endpoint returns a response containing an expected string.
# Usage: wait_for_endpoint <name> <url> <expected_string> [post_data]
wait_for_endpoint() {
   local name="$1" url="$2" expected="$3" post_data="${4:-}"
   echo "Testing $name endpoint..."
   retry_time=60
   while true; do
      if [ -n "$post_data" ]; then
         response=$(curl -s -X POST "$url" \
            -H 'accept: application/json' \
            -H 'Content-Type: application/json' \
            -d "$post_data")
      else
         response=$(curl -s -X GET "$url")
      fi
      if echo "$response" | grep -q "$expected"; then
         echo "✅ SUCCESS! $name endpoint is responding as expected.\n"
         break
      else
         echo "❌ $name not ready yet. Response: $response"
         echo "Retrying in $retry_time seconds..."
         sleep $retry_time
         retry_time=$((retry_time * 2))
      fi
   done
}

# Llama 3.3 70B Instruct on GPUs 1 and 2
existing_container=$(docker ps -q --filter "name=llama-3.3-70b-instruct")
# If the container is already running, skip starting it again.
if [ -n "$existing_container" ]; then
   echo "Container llama-3.3-70b-instruct is already running."
else
   docker run -d --name=llama-3.3-70b-instruct \
      --gpus '"device=1,2"' \
      --shm-size=16GB \
      -e NGC_API_KEY \
      -e NIM_MODEL_PROFILE="084b783757f3a2df0e624ac44b1ea82913f92366effe5631c3874bcc30163cb1" \
      -e NIM_TENSOR_PARALLEL_SIZE=2 \
      -v "$LOCAL_NIM_CACHE:/opt/nim/.cache" \
      -u "$(id -u)" \
      -p 8088:8000 \
      nvcr.io/nim/meta/llama-3.3-70b-instruct:latest
fi

wait_for_endpoint "LLM NIM" "http://0.0.0.0:8088/v1/chat/completions" '"content"' \
   '{"model":"meta/llama-3.3-70b-instruct","messages":[{"role":"user","content":"Why is Real Madrid the greatest club?"}],"max_tokens":64}'

# Llama 3.2 NV EmbedQA 1B v2 on GPU 3
existing_container=$(docker ps -q --filter "name=llama-3.2-nv-embedqa-1b-v2")
# If the container is already running, skip starting it again.
if [ -n "$existing_container" ]; then
   echo "Container llama-3.2-nv-embedqa-1b-v2 is already running."
else
   docker run -d --name=llama-3.2-nv-embedqa-1b-v2 \
   --gpus '"device=3"' \
   --shm-size=16GB \
   -e NGC_API_KEY \
   -e NIM_TRT_ENGINE_HOST_CODE_ALLOWED=1 \
   -v "$LOCAL_NIM_CACHE:/opt/nim/.cache" \
   -u "$(id -u)" \
   -p 9234:8000 \
   nvcr.io/nim/nvidia/llama-3.2-nv-embedqa-1b-v2:latest
fi

wait_for_endpoint "Embedding NIM" "http://0.0.0.0:9234/v1/embeddings" '"data"' \
   '{"input":["Why is Real Madrid the greatest club?"],"model":"nvidia/llama-3.2-nv-embedqa-1b-v2","input_type":"query"}'

# Llama 3.2 NV RerankQA 1B v2 on GPU 3
existing_container=$(docker ps -q --filter "name=llama-3.2-nv-rerankqa-1b-v2")
# If the container is already running, skip starting it again.
if [ -n "$existing_container" ]; then
   echo "Container llama-3.2-nv-rerankqa-1b-v2 is already running."
else
   docker run -d --name=llama-3.2-nv-rerankqa-1b-v2 \
      --gpus '"device=3"' \
      --shm-size=16GB \
      -e NGC_API_KEY \
      -v "$LOCAL_NIM_CACHE:/opt/nim/.cache" \
      -u "$(id -u)" \
      -p 9235:8000 \
      nvcr.io/nim/nvidia/llama-3.2-nv-rerankqa-1b-v2:latest
fi

wait_for_endpoint "RerankQA NIM" "http://0.0.0.0:9235/v1/ranking" '"rankings"' \
   '{"model":"nvidia/llama-3.2-nv-rerankqa-1b-v2","query":{"text":"Why is Real Madrid the greatest club?"},"passages":[{"text":"Real Madrid has a rich legacy of winning trophies and titles."},{"text":"Real Madrid history is filled with the most legendary players and memorable comebacks."},{"text":"Real Madrid fan base is one of the most passionate in the world."},{"text":"Real Madrid financial power allows them to attract top talent."}],"truncate":"END"}'

# Parakeet TDT 0.6B V2 ASR on GPU 3
existing_container=$(docker ps -q --filter "name=parakeet-tdt-0.6b-v2")
# If the container is already running, skip starting it again.
if [ "$ENABLE_AUDIO" = "false" ]; then
   echo "Audio pipeline is disabled. Skipping RIVA ASR container startup."
else
   if [ -n "$existing_container" ]; then
      echo "Container parakeet-tdt-0.6b-v2 is already running."
   else
      docker run -d --name=parakeet-tdt-0.6b-v2 \
         --gpus '"device=3"' \
         --shm-size=8GB \
         -e NGC_API_KEY \
         -e NIM_HTTP_API_PORT=9000 \
         -e NIM_GRPC_API_PORT=50051 \
         -p 9000:9000 \
         -p 50051:50051 \
         nvcr.io/nim/nvidia/parakeet-tdt-0.6b-v2:latest
   fi

   wait_for_endpoint "RIVA ASR" "http://0.0.0.0:9000/v1/health/ready" '"status":"ready"'
fi

# Create Docker network if it doesn't exist (required by compose.yaml as external network)
docker network inspect "via-engine-${USER}" >/dev/null 2>&1 || docker network create "via-engine-${USER}"

# All NIM models and RIVA ASR are up. Start the main VSS application.
echo "Running VSS application using docker compose..."
docker compose up -d