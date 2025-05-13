#!/bin/bash

# General arguments
ROOT=$PWD

export PUB_MULTI_ADDRS
export PEER_MULTI_ADDRS
export HOST_MULTI_ADDRS
export IDENTITY_PATH
export CONNECT_TO_TESTNET
export ORG_ID
export HF_HUB_DOWNLOAD_TIMEOUT=120  # 2 minutes

# Force CPU only mode
export CPU_ONLY=true

# Check if public multi-address is given else set to default
DEFAULT_PUB_MULTI_ADDRS=""
PUB_MULTI_ADDRS=${PUB_MULTI_ADDRS:-$DEFAULT_PUB_MULTI_ADDRS}

# Check if peer multi-address is given else set to default
DEFAULT_PEER_MULTI_ADDRS="/ip4/38.101.215.13/tcp/30002/p2p/QmQ2gEXoPJg6iMBSUFWGzAabS2VhnzuS782Y637hGjfsRJ" # gensyn coordinator node
PEER_MULTI_ADDRS=${PEER_MULTI_ADDRS:-$DEFAULT_PEER_MULTI_ADDRS}

# Check if host multi-address is given else set to default
DEFAULT_HOST_MULTI_ADDRS="/ip4/0.0.0.0/tcp/38331"
HOST_MULTI_ADDRS=${HOST_MULTI_ADDRS:-$DEFAULT_HOST_MULTI_ADDRS}

# Path to an RSA private key. If this path does not exist, a new key pair will be created.
DEFAULT_IDENTITY_PATH="$ROOT"/swarm.pem
IDENTITY_PATH=${IDENTITY_PATH:-$DEFAULT_IDENTITY_PATH}

SMALL_SWARM_CONTRACT="0x69C6e1D608ec64885E7b185d39b04B491a71768C"
BIG_SWARM_CONTRACT="0x6947c6E196a48B77eFa9331EC1E3e45f3Ee5Fd58"

# Set Hugging Face token to None by default
HUGGINGFACE_ACCESS_TOKEN="None"

# Set if successfully parsed from modal-login/temp-data/userData.json.
ORG_ID=${ORG_ID:-""}

GREEN_TEXT="\033[32m"
BLUE_TEXT="\033[34m"
YELLOW_TEXT="\033[33m"
RED_TEXT="\033[31m"
BOLD_TEXT="\033[1m"
RESET_TEXT="\033[0m"

echo_green() {
    echo -e "$GREEN_TEXT$1$RESET_TEXT"
}

echo_yellow() {
    echo -e "$YELLOW_TEXT$1$RESET_TEXT"
}

echo_red() {
    echo -e "$RED_TEXT$1$RESET_TEXT"
}

echo_blue() {
    echo -e "$BLUE_TEXT$1$RESET_TEXT"
}

ROOT_DIR="$(cd $(dirname ${BASH_SOURCE[0]}) && pwd)"

# Function to clean up processes upon exit
cleanup() {
    echo_green ">> Shutting down trainer..."
    kill $SERVER_PID 2>/dev/null || true
    kill $TUNNEL_PID 2>/dev/null || true
    exit 0
}

trap cleanup EXIT

echo -e "\033[38;5;224m"
cat << "EOF"
    ██████  ██            ███████ ██     ██  █████  ██████  ███    ███
    ██   ██ ██            ██      ██     ██ ██   ██ ██   ██ ████  ████
    ██████  ██      █████ ███████ ██  █  ██ ███████ ██████  ██ ████ ██
    ██   ██ ██                 ██ ██ ███ ██ ██   ██ ██   ██ ██  ██  ██
    ██   ██ ███████       ███████  ███ ███  ██   ██ ██   ██ ██      ██

    From Gensyn

EOF

echo_green ">> Running in CPU-only mode"

while true; do
    echo -en $GREEN_TEXT
    read -p ">> Would you like to connect to the Testnet? [Y/n] " yn
    echo -en $RESET_TEXT
    yn=${yn:-Y}  # Default to "Y" if the user presses Enter
    case $yn in
        [Yy]*)  CONNECT_TO_TESTNET=true && break ;;
        [Nn]*)  CONNECT_TO_TESTNET=false && break ;;
        *)  echo ">>> Please answer yes or no." ;;
    esac
done

# In CPU mode, always use the small swarm
USE_BIG_SWARM=false
echo_green ">> Using Math (A) swarm in CPU-only mode"
SWARM_CONTRACT="$SMALL_SWARM_CONTRACT"

# In CPU mode, default to smallest model size
PARAM_B=1.5
echo_green ">> Using 1.5B parameter model for CPU mode"

if [ "$CONNECT_TO_TESTNET" = true ]; then
    # Run modal_login server
    echo_green ">> Starting modal-login server..."
    cd modal-login

    # Check if yarn is installed
    if ! command -v yarn > /dev/null 2>&1; then
        echo_yellow ">> Yarn not found. Installing Yarn..."
        npm install -g yarn
    fi

    # Install dependencies
    yarn install

    # Check if port 3000 is in use
    PORT=3000
    PORT_LINE=$(ss -ltnp 2>/dev/null | grep ":$PORT " || true)
    if [ -n "$PORT_LINE" ]; then
        PID=$(echo "$PORT_LINE" | grep -oP 'pid=\K[0-9]+')
        if [ -n "$PID" ]; then
            echo_yellow ">> Port $PORT is in use. Killing process: $PID"
            kill -9 $PID
            sleep 2
        fi
    fi

    # Start server and log to both file and stdout
    echo_green ">> Starting server on port $PORT..."
    yarn dev 2>&1 | tee server.log &
    SERVER_PID=$!
    MAX_WAIT=30

    # Wait for server to start
    for ((i = 0; i < MAX_WAIT; i++)); do
        if grep -q "Local:        http://localhost:" server.log; then
            SERVER_PORT=$(grep "Local:        http://localhost:" server.log | sed -n 's/.*http:\/\/localhost:\([0-9]*\).*/\1/p')
            if [ -n "$SERVER_PORT" ]; then
                echo_green ">> Server is running on port $SERVER_PORT"
                break
            fi
        fi
        sleep 1
    done

    if [ $i -eq $MAX_WAIT ]; then
        echo_red ">> Timeout waiting for server to start."
        kill $SERVER_PID 2>/dev/null || true
        exit 1
    fi

    # Check if localhost:3000 is accessible
    check_url() {
        local url=$1
        local max_retries=3
        local retry=0
        while [ $retry -lt $max_retries ]; do
            http_code=$(curl -s -o /dev/null -w "%{http_code}" "$url" 2>/dev/null)
            if [ "$http_code" = "200" ] || [ "$http_code" = "404" ] || [ "$http_code" = "301" ] || [ "$http_code" = "302" ]; then
                return 0
            fi
            retry=$((retry + 1))
            sleep 2
        done
        return 1
    }

    if check_url "http://localhost:$SERVER_PORT"; then
        echo_green ">> http://localhost:$SERVER_PORT is accessible."
        if open "http://localhost:$SERVER_PORT" 2>/dev/null; then
            echo_green ">> Successfully opened http://localhost:$SERVER_PORT in your default browser."
        else
            echo_yellow ">> Failed to open http://localhost:$SERVER_PORT. Please open it manually."
        fi
    else
        echo_yellow ">> http://localhost:$SERVER_PORT is not accessible. Attempting to start ngrok tunnel..."

        # Install ngrok
        install_ngrok() {
            if command -v ngrok >/dev/null 2>&1; then
                echo_green ">> ngrok is already installed."
                return 0
            fi
            echo_yellow ">> Installing ngrok..."
            ARCH=$(uname -m)
            OS=$(uname -s | tr '[:upper:]' '[:lower:]')
            if [ "$ARCH" = "x86_64" ]; then
                NGROK_ARCH="amd64"
            elif [ "$ARCH" = "arm64" ] || [ "$ARCH" = "aarch64" ]; then
                NGROK_ARCH="arm64"
            elif [[ "$ARCH" == arm* ]]; then
                NGROK_ARCH="arm"
            else
                echo_red ">> Unsupported architecture: $ARCH"
                return 1
            fi
            NGROK_URL="https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-$OS-$NGROK_ARCH.tgz"
            wget -q "$NGROK_URL" -O ngrok.tgz
            tar -xzf ngrok.tgz
            mv ngrok /usr/local/bin/
            rm ngrok.tgz
            echo_green ">> ngrok installed successfully."
            return 0
        }

        # Start ngrok tunnel
        try_ngrok() {
            if ! install_ngrok; then
                return 1
            fi
            echo_yellow ">> Starting ngrok tunnel for port $SERVER_PORT..."
            echo "To get your ngrok authtoken:"
            echo "1. Sign up or log in at https://dashboard.ngrok.com"
            echo "2. Go to 'Your Authtoken' section: https://dashboard.ngrok.com/get-started/your-authtoken"
            echo "3. Copy the authtoken and paste it below"
            read -p "Enter your ngrok authtoken: " NGROK_TOKEN
            if [ -z "$NGROK_TOKEN" ]; then
                echo_red ">> No token provided. Cannot start ngrok."
                return 1
            fi
            ngrok authtoken "$NGROK_TOKEN" 2>/dev/null
            if [ $? -ne 0 ]; then
                echo_red ">> ngrok authentication failed. Please check your token."
                return 1
            fi
            ngrok http "$SERVER_PORT" --log=stdout 2>&1 | tee ngrok.log &
            TUNNEL_PID=$!
            sleep 5
            NGROK_URL=$(grep -o "https://[^ ]*" ngrok.log | head -n1)
            if [ -n "$NGROK_URL" ]; then
                echo_green ">> ngrok tunnel started: $NGROK_URL"
                echo_green ">> Please visit $NGROK_URL to log in."
                return 0
            else
                echo_red ">> Failed to start ngrok tunnel."
                kill $TUNNEL_PID 2>/dev/null || true
                return 1
            fi
        }

        if try_ngrok; then
            echo_green ">> ngrok tunnel setup complete."
        else
            echo_red ">> Failed to start ngrok. Please open http://localhost:$SERVER_PORT manually or check network settings."
            exit 1
        fi
    fi

    cd ..

    echo_green ">> Waiting for modal userData.json to be created..."
    while [ ! -f "modal-login/temp-data/userData.json" ]; do
        sleep 5
    done
    echo_green ">> Found userData.json. Proceeding..."

    ORG_ID=$(awk 'BEGIN { FS = "\"" } !/^[ \t]*[{}]/ { print $(NF - 1); exit }' modal-login/temp-data/userData.json)
    echo_green ">> Your ORG_ID is set to: $ORG_ID"

    echo_green ">> Waiting for API key to become activated..."
    while true; do
        STATUS=$(curl -s "http://localhost:$SERVER_PORT/api/get-api-key-status?orgId=$ORG_ID")
        if [[ "$STATUS" == "activated" ]]; then
            echo_green ">> API key is activated! Proceeding..."
            break
        else
            echo ">> Waiting for API key to be activated..."
            sleep 5
        fi
    done

    ENV_FILE="$ROOT"/modal-login/.env
    if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -i '' "3s/.*/SMART_CONTRACT_ADDRESS=$SWARM_CONTRACT/" "$ENV_FILE"
    else
        sed -i "3s/.*/SMART_CONTRACT_ADDRESS=$SWARM_CONTRACT/" "$ENV_FILE"
    fi
fi

echo_green ">> Getting requirements..."

pip install --upgrade pip
pip install -r "$ROOT"/requirements-cpu.txt
CONFIG_PATH="$ROOT/hivemind_exp/configs/mac/grpo-qwen-2.5-0.5b-deepseek-r1.yaml"
GAME="gsm8k"

echo_green ">> Done!"

# Set Hugging Face token
HF_TOKEN=${HF_TOKEN:-""}
if [ -n "${HF_TOKEN}" ]; then
    HUGGINGFACE_ACCESS_TOKEN=${HF_TOKEN}
else
    HUGGINGFACE_ACCESS_TOKEN="None"
    echo_green ">> Models will NOT be pushed to Hugging Face Hub"
fi

echo_green ">> Good luck in the swarm!"
echo_blue ">> Post about rl-swarm on X/twitter! --> https://tinyurl.com/swarmtweet"
echo_blue ">> And remember to star the repo on GitHub! --> https://github.com/gensyn-ai/rl-swarm"

if [ -n "$ORG_ID" ]; then
    python -m hivemind_exp.gsm8k.train_single_gpu \
        --hf_token "$HUGGINGFACE_ACCESS_TOKEN" \
        --identity_path "$IDENTITY_PATH" \
        --modal_org_id "$ORG_ID" \
        --contract_address "$SWARM_CONTRACT" \
        --config "$CONFIG_PATH" \
        --game "$GAME" 2>&1 | tee /rl-swarm/train.log
else
    python -m hivemind_exp.gsm8k.train_single_gpu \
        --hf_token "$HUGGINGFACE_ACCESS_TOKEN" \
        --identity_path "$IDENTITY_PATH" \
        --public_maddr "$PUB_MULTI_ADDRS" \
        --initial_peers "$PEER_MULTI_ADDRS" \
        --host_maddr "$HOST_MULTI_ADDRS" \
        --config "$CONFIG_PATH" \
        --game "$GAME" 2>&1 | tee /rl-swarm/train.log
fi
