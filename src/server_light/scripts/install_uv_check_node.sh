# Python + uv
apt-get install -y python3 python3-pip
curl -LsSf https://astral.sh/uv/install.sh | sh
export PATH="$HOME/.local/bin:$PATH"

# Node.js (already installed, verify)
node --version && npx --version

# Verify both
uv --version && echo "uv OK" || echo "uv MISSING"
npx --version && echo "npx OK" || echo "npx MISSING"
