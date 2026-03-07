#!/bin/bash
# AI Doc Read Studio - Cangjie Backend 启动脚本

echo "=== AI Doc Read Studio (Cangjie Backend) ==="

# 检查 .env
if [ ! -f "../.env" ]; then
    echo "[WARN] .env not found. Copy .env.example to .env and set OPENAI_API_KEY"
fi

# 创建目录
mkdir -p ../uploads ../sessions ../logs

# 编译
echo "[INFO] Compiling Cangjie backend..."
cjpm build

if [ $? -ne 0 ]; then
    echo "[ERROR] Compilation failed!"
    exit 1
fi

# 运行
echo "[INFO] Starting server on http://0.0.0.0:8000 ..."
cjpm run
