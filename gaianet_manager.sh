#!/bin/bash

# 定义颜色变量
RED=$'\e[0;31m'
GREEN=$'\e[0;32m'
YELLOW=$'\e[0;33m'
NC=$'\e[0m'

# 默认 GaiaNet 安装版本和下载地址
VERSION="0.4.20"
INSTALL_URL="https://github.com/GaiaNet-AI/gaianet-node/releases/latest/download/install.sh"

# 默认主目录和共享模型目录
HOME_DIR="$HOME"
SHARED_MODEL_DIR="$HOME/gaianet-models"
LOG_FILE="$HOME/gaianet_debug.log"

# 默认端口起始值
BASE_API_PORT=10000      # API 端口从 10000 开始
BASE_QDRANT_PORT=20000   # Qdrant HTTP 端口从 20000 开始
BASE_QDRANT_GRPC_PORT=20010  # Qdrant gRPC 端口从 20010 开始

# 输出信息
info() {
    printf "${GREEN}$1${NC}\n"
    echo "$(date): INFO: $1" >> "$LOG_FILE"
}

error() {
    printf "${RED}$1${NC}\n"
    echo "$(date): ERROR: $1" >> "$LOG_FILE"
    exit 1
}

warning() {
    printf "${YELLOW}$1${NC}\n"
    echo "$(date): WARNING: $1" >> "$LOG_FILE"
}

# 检查目录是否存在，不存在则创建
ensure_dir() {
    local dir="$1"
    if [ ! -d "$dir" ]; then
        mkdir -p "$dir" || { warning "无法创建目录 $dir"; return 1; }
        chmod 777 "$dir"
    fi
}

# 查找可用端口（改进版，确保端口稳定可用）
find_available_port() {
    local base_port="$1"
    local port=$base_port
    while lsof -i :"$port" > /dev/null 2>&1; do
        port=$((port + 1))
    done
    sleep 1  # 等待1秒，确保端口未被快速抢占
    if lsof -i :"$port" > /dev/null 2>&1; then
        find_available_port "$port"  # 递归查找
    else
        echo "$port"
    fi
}

# 获取所有节点列表（仅匹配数字编号的节点）
get_node_list() {
    NODE_LIST=($(find "$HOME_DIR" -maxdepth 1 -type d -name "gaianet-[0-9]*" | sed "s|$HOME_DIR/gaianet-||" | sort -n 2>/dev/null || true))
    if [ ${#NODE_LIST[@]} -eq 0 ]; then
        return 1
    fi
    return 0
}

# 优化后的节点选择函数，支持多选和全选
select_node() {
    echo "可用节点："
    if ! get_node_list; then
        echo "  无已安装节点"
        return 1
    fi
    for i in "${!NODE_LIST[@]}"; do
        echo "  $((i+1)). 节点 ${NODE_LIST[$i]}"
    done
    ALL_OPTION=$(( ${#NODE_LIST[@]} + 1 ))
    echo "  $ALL_OPTION. 全部节点"
    echo "请输入节点编号（用空格分隔多个编号，例如 '1 2 3'，或输入 $ALL_OPTION 选择全部）："
    read -r INPUT

    # 检查输入是否为空
    if [ -z "$INPUT" ]; then
        error "输入不能为空！"
    fi

    # 将输入拆分为数组
    IFS=' ' read -r -a CHOICES <<< "$INPUT"

    # 初始化选择结果数组
    SELECTED_NODES=()

    # 处理全选
    if [ "${#CHOICES[@]}" -eq 1 ] && [ "${CHOICES[0]}" -eq "$ALL_OPTION" ]; then
        SELECTED_NODES=("${NODE_LIST[@]}")
        info "已选择全部节点：${SELECTED_NODES[*]}"
        return 0
    fi

    # 验证并处理多选
    for CHOICE in "${CHOICES[@]}"; do
        if ! [[ "$CHOICE" =~ ^[0-9]+$ ]]; then
            error "输入无效：'$CHOICE' 不是数字！"
        fi
        if [ "$CHOICE" -lt 1 ] || [ "$CHOICE" -gt "${#NODE_LIST[@]}" ]; then
            error "无效选择：'$CHOICE' 超出范围（1-${#NODE_LIST[@]}）！"
        fi
        # 将选择转换为节点编号（数组索引从0开始，输入从1开始）
        SELECTED_NODES+=("${NODE_LIST[$((CHOICE-1))]}")
    done

    # 去除重复选择（如果有）
    SELECTED_NODES=($(printf "%s\n" "${SELECTED_NODES[@]}" | sort -u))
    info "已选择节点：${SELECTED_NODES[*]}"
    return 0
}

# 修改配置文件中的端口和模型路径
update_config() {
    local node_dir="$1"
    local api_port="$2"
    local qdrant_port="$3"
    local qdrant_grpc_port="$4"

    local config_file="$node_dir/config.json"
    local qdrant_config="$node_dir/qdrant/config/config.yaml"
    local frpc_config="$node_dir/gaia-frp/frpc.toml"

    if [ -f "$config_file" ]; then
        sed -i "s|\"llamaedge_port\": \".*\"|\"llamaedge_port\": \"$api_port\"|" "$config_file" 2>/dev/null || warning "更新 $config_file 的 llamaedge_port 失败"
        sed -i "s|\"chat\": \".*\"|\"chat\": \"$node_dir/Llama-3.2-3B-Instruct-Q5_K_M.gguf\"|" "$config_file" 2>/dev/null || warning "更新 $config_file 的 chat 失败"
        sed -i "s|\"embedding\": \".*\"|\"embedding\": \"$node_dir/nomic-embed-text-v1.5.f16.gguf\"|" "$config_file" 2>/dev/null || warning "更新 $config_file 的 embedding 失败"
        info "已更新 config.json: API 端口=$api_port, 模型路径=$node_dir"
    else
        warning "未找到 $config_file，跳过配置更新"
    fi

    if [ -f "$qdrant_config" ]; then
        sed -i "s/host: 0.0.0.0:.*/host: 0.0.0.0:$qdrant_port/" "$qdrant_config" 2>/dev/null || warning "更新 $qdrant_config 的 host 失败"
        sed -i "s/grpc_port: .*/grpc_port: $qdrant_grpc_port/" "$qdrant_config" 2>/dev/null || warning "更新 $qdrant_config 的 grpc_port 失败"
        info "已更新 Qdrant 端口为 $qdrant_port (HTTP) 和 $qdrant_grpc_port (gRPC)"
    else
        warning "未找到 $qdrant_config，跳过 Qdrant 端口更新"
    fi

    if [ -f "$frpc_config" ]; then
        sed -i "s/localPort = \".*\"/localPort = \"$api_port\"/" "$frpc_config" 2>/dev/null || warning "更新 $frpc_config 的 localPort 失败"
        info "已更新 FRP 本地端口为 $api_port"
    else
        warning "未找到 $frpc_config，跳过 FRP 端口更新"
    fi
}

# 清理 Qdrant 实例（精确匹配当前节点）
cleanup_qdrant() {
    local node_dir="$1"
    local qdrant_pids=$(ps aux | grep -v grep | grep "[q]drant.*--base $node_dir" | awk '{print $2}' || true)
    if [ -n "$qdrant_pids" ]; then
        info "检测到与节点 $node_dir 相关的 Qdrant 实例 (PIDs: $qdrant_pids)，正在停止..."
        kill -9 $qdrant_pids 2>/dev/null
        sleep 2
        qdrant_pids=$(ps aux | grep -v grep | grep "[q]drant.*--base $node_dir" | awk '{print $2}' || true)
        if [ -n "$qdrant_pids" ]; then
            warning "Qdrant 实例未完全停止 (PIDs: $qdrant_pids)，请手动检查"
        fi
    else
        info "未检测到与节点 $node_dir 相关的 Qdrant 实例，无需停止"
    fi
    if [ -d "$node_dir/qdrant/storage" ]; then
        info "清理 Qdrant 数据目录 $node_dir/qdrant/storage ..."
        rm -rf "$node_dir/qdrant/storage" || warning "清理 Qdrant 数据目录失败"
    fi
}

# 清理 wasmedge 实例（精确匹配当前节点）
cleanup_wasmedge() {
    local node_dir="$1"
    local wasmedge_pids=$(ps aux | grep -v grep | grep "[w]asmedge.*$node_dir" | awk '{print $2}' || true)
    if [ -n "$wasmedge_pids" ]; then
        info "检测到与节点 $node_dir 相关的 wasmedge 实例 (PIDs: $wasmedge_pids)，正在停止..."
        kill -9 $wasmedge_pids 2>/dev/null
        sleep 2
        wasmedge_pids=$(ps aux | grep -v grep | grep "[w]asmedge.*$node_dir" | awk '{print $2}' || true)
        if [ -n "$wasmedge_pids" ]; then
            warning "wasmedge 实例未完全停止 (PIDs: $wasmedge_pids)，请手动检查"
        fi
    else
        info "未检测到与节点 $node_dir 相关的 wasmedge 实例，无需停止"
    fi
}

# 检查节点状态
check_node_status() {
    local node_id="$1"
    local node_dir="$HOME_DIR/gaianet-$node_id"
    local bin_dir="$node_dir/bin"
    local status=""
    local initialized=0
    local running=0

    if [ ! -f "$bin_dir/gaianet" ]; then
        status="未安装"
        echo "$status"
        return 0
    fi

    ORIGINAL_DIR=$(pwd)
    cd "$node_dir" || { warning "无法进入目录 $node_dir"; status="未知状态 (目录不可访问)"; echo "$status"; return 0; }

    local api_port=$(awk -F'"' '/"llamaedge_port":/ {print $4}' "$node_dir/config.json" 2>/dev/null || echo "$BASE_API_PORT")
    local qdrant_port=$(awk -F'"' '/"qdrant_port":/ {print $4}' "$node_dir/config.json" 2>/dev/null || echo "$BASE_QDRANT_PORT")
    local qdrant_grpc_port=$(awk -F'"' '/"qdrant_grpc_port":/ {print $4}' "$node_dir/config.json" 2>/dev/null || echo "$BASE_QDRANT_GRPC_PORT")

    if lsof -i :"$api_port" > /dev/null 2>&1 || lsof -i :"$qdrant_port" > /dev/null 2>&1; then
        initialized=1
        status="已初始化"
    else
        if [ -f "$node_dir/Llama-3.2-3B-Instruct-Q5_K_M.gguf" ] && [ -f "$node_dir/nomic-embed-text-v1.5.f16.gguf" ] && \
           [ -f "$node_dir/config.json" ] && [ -d "$node_dir/qdrant/storage" ]; then
            initialized=1
            status="已初始化"
        else
            status="未初始化"
        fi
    fi

    if ps aux | grep -v grep | grep "[g]aianet.*$node_dir" > /dev/null || lsof -i :"$api_port" > /dev/null 2>&1; then
        running=1
        status="$status | 运行中"
    else
        status="$status | 已停止"
    fi

    status="$status (API=$api_port, Qdrant=$qdrant_port/$qdrant_grpc_port)"
    cd "$ORIGINAL_DIR"
    echo "$status"
    return $((initialized | (running << 1)))
}

# 安装新节点
install_nodes() {
    clear
    echo "===== 安装新节点（自动初始化和启动） ====="
    if get_node_list; then
        echo "检测已有节点：${NODE_LIST[*]}"
        LAST_NODE=$(echo "${NODE_LIST[@]}" | tr ' ' '\n' | sort -nr | head -n 1)
    else
        echo "检测已有节点：无"
        LAST_NODE=0
    fi

    echo "请输入要安装的节点数量（例如 1、2、3...）："
    read -r NODE_COUNT
    if [[ ! "$NODE_COUNT" =~ ^[0-9]+$ ]] || [ "$NODE_COUNT" -lt 1 ]; then
        error "节点数量必须为正整数！"
    fi

    START_NODE=$((LAST_NODE + 1))
    END_NODE=$((START_NODE + NODE_COUNT - 1))

    ensure_dir "$SHARED_MODEL_DIR"
    if [ ! -f "$SHARED_MODEL_DIR/Llama-3.2-3B-Instruct-Q5_K_M.gguf" ]; then
        info "下载共享模型 Llama-3.2-3B-Instruct-Q5_K_M.gguf ..."
        curl -L "https://huggingface.co/second-state/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q5_K_M.gguf" -o "$SHARED_MODEL_DIR/Llama-3.2-3B-Instruct-Q5_K_M.gguf" || error "模型下载失败！"
    fi
    if [ ! -f "$SHARED_MODEL_DIR/nomic-embed-text-v1.5.f16.gguf" ]; then
        info "下载共享模型 nomic-embed-text-v1.5.f16.gguf ..."
        curl -L "https://huggingface.co/gaianet/Nomic-embed-text-v1.5-Embedding-GGUF/resolve/main/nomic-embed-text-v1.5.f16.gguf" -o "$SHARED_MODEL_DIR/nomic-embed-text-v1.5.f16.gguf" || error "模型下载失败！"
    fi

    echo "确认安装并自动初始化、启动 $NODE_COUNT 个节点（从 $START_NODE 到 $END_NODE）？(y/n)"
    read -r CONFIRM
    if [ "$CONFIRM" != "y" ]; then
        info "已取消操作"
        return
    fi

    for NODE_ID in $(seq "$START_NODE" "$END_NODE"); do
        NODE_DIR="$HOME_DIR/gaianet-$NODE_ID"
        BIN_DIR="$NODE_DIR/bin"

        API_PORT=$(find_available_port $((BASE_API_PORT + NODE_ID - 1)))
        QDRANT_PORT=$(find_available_port $((BASE_QDRANT_PORT + NODE_ID - 1)))
        QDRANT_GRPC_PORT=$(find_available_port $((BASE_QDRANT_GRPC_PORT + NODE_ID - 1)))

        ensure_dir "$NODE_DIR"
        info "正在安装 GaiaNet 节点 $NODE_ID 到 $NODE_DIR ..."
        curl -sSfL "$INSTALL_URL" | bash -s -- --base "$NODE_DIR" || { warning "节点 $NODE_ID 安装失败！"; continue; }
        update_config "$NODE_DIR" "$API_PORT" "$QDRANT_PORT" "$QDRANT_GRPC_PORT"

        cp -f "$SHARED_MODEL_DIR/Llama-3.2-3B-Instruct-Q5_K_M.gguf" "$NODE_DIR/" || warning "复制 Llama 模型失败"
        cp -f "$SHARED_MODEL_DIR/nomic-embed-text-v1.5.f16.gguf" "$NODE_DIR/" || warning "复制 Nomic 模型失败"

        ORIGINAL_DIR=$(pwd)
        cd "$NODE_DIR" || { warning "无法进入目录 $NODE_DIR"; continue; }
        cleanup_qdrant "$NODE_DIR"
        cleanup_wasmedge "$NODE_DIR"
        "$BIN_DIR/gaianet" init --base "$NODE_DIR" || { warning "节点 $NODE_ID 初始化失败！"; cd "$ORIGINAL_DIR"; continue; }
        "$BIN_DIR/gaianet" start --base "$NODE_DIR" || { warning "节点 $NODE_ID 启动失败！"; cd "$ORIGINAL_DIR"; continue; }
        NODE_ADDRESS=$(awk -F'"' '/"address":/ {print $4}' "$NODE_DIR/config.json" 2>/dev/null || echo "未知")
        NODE_DOMAIN=$(awk -F'"' '/"domain":/ {print $4}' "$NODE_DIR/config.json" 2>/dev/null || echo "未知")
        info "节点 $NODE_ID 已启动！访问地址: https://$NODE_ADDRESS.$NODE_DOMAIN"
        cd "$ORIGINAL_DIR"
    done
}

# 初始化节点
init_node() {
    clear
    echo "===== 初始化节点 ====="
    if ! select_node; then
        warning "无可用节点，请先安装节点！"
        return
    fi
    echo "确认初始化这些节点？(y/n)"
    read -r CONFIRM
    if [ "$CONFIRM" != "y" ]; then
        info "已取消操作"
        return
    fi

    for NODE_ID in "${SELECTED_NODES[@]}"; do
        NODE_DIR="$HOME_DIR/gaianet-$NODE_ID"
        BIN_DIR="$NODE_DIR/bin"
        if [ ! -f "$BIN_DIR/gaianet" ]; then
            warning "节点 $NODE_ID 未安装，跳过..."
            continue
        fi

        ORIGINAL_DIR=$(pwd)
        cd "$NODE_DIR" || { warning "无法进入目录 $NODE_DIR"; continue; }
        cleanup_qdrant "$NODE_DIR"
        cleanup_wasmedge "$NODE_DIR"
        "$BIN_DIR/gaianet" init --base "$NODE_DIR" || { warning "节点 $NODE_ID 初始化失败！"; cd "$ORIGINAL_DIR"; continue; }
        info "节点 $NODE_ID 初始化完成！"
        cd "$ORIGINAL_DIR"
    done
}

# 启动节点
start_node() {
    clear
    echo "===== 启动节点 ====="
    if ! select_node; then
        warning "无可用节点，请先安装节点！"
        return
    fi
    echo "确认启动这些节点？(y/n)"
    read -r CONFIRM
    if [ "$CONFIRM" != "y" ]; then
        info "已取消操作"
        return
    fi

    for NODE_ID in "${SELECTED_NODES[@]}"; do
        NODE_DIR="$HOME_DIR/gaianet-$NODE_ID"
        BIN_DIR="$NODE_DIR/bin"
        if [ ! -f "$BIN_DIR/gaianet" ]; then
            warning "节点 $NODE_ID 未安装，跳过..."
            continue
        fi

        ORIGINAL_DIR=$(pwd)
        cd "$NODE_DIR" || { warning "无法进入目录 $NODE_DIR"; continue; }
        cleanup_wasmedge "$NODE_DIR"
        "$BIN_DIR/gaianet" start --base "$NODE_DIR" || { warning "节点 $NODE_ID 启动失败！"; cd "$ORIGINAL_DIR"; continue; }
        NODE_ADDRESS=$(awk -F'"' '/"address":/ {print $4}' "$NODE_DIR/config.json" 2>/dev/null || echo "未知")
        NODE_DOMAIN=$(awk -F'"' '/"domain":/ {print $4}' "$NODE_DIR/config.json" 2>/dev/null || echo "未知")
        info "节点 $NODE_ID 已启动！访问地址: https://$NODE_ADDRESS.$NODE_DOMAIN"
        cd "$ORIGINAL_DIR"
    done
}

# 停止节点
stop_node() {
    clear
    echo "===== 停止节点 ====="
    if ! select_node; then
        warning "无可用节点，请先安装节点！"
        return
    fi
    echo "确认停止这些节点？(y/n)"
    read -r CONFIRM
    if [ "$CONFIRM" != "y" ]; then
        info "已取消操作"
        return
    fi

    for NODE_ID in "${SELECTED_NODES[@]}"; do
        NODE_DIR="$HOME_DIR/gaianet-$NODE_ID"
        BIN_DIR="$NODE_DIR/bin"
        if [ ! -f "$BIN_DIR/gaianet" ]; then
            warning "节点 $NODE_ID 未安装，跳过..."
            continue
        fi

        ORIGINAL_DIR=$(pwd)
        cd "$NODE_DIR" || { warning "无法进入目录 $NODE_DIR"; continue; }
        "$BIN_DIR/gaianet" stop --base "$NODE_DIR" || { warning "节点 $NODE_ID 停止失败！"; cd "$ORIGINAL_DIR"; continue; }
        cleanup_qdrant "$NODE_DIR"
        cleanup_wasmedge "$NODE_DIR"
        info "节点 $NODE_ID 已停止！"
        cd "$ORIGINAL_DIR"
    done
}

# 重启节点
restart_node() {
    clear
    echo "===== 重启节点 ====="
    if ! select_node; then
        warning "无可用节点，请先安装节点！"
        return
    fi
    echo "确认重启这些节点？(y/n)"
    read -r CONFIRM
    if [ "$CONFIRM" != "y" ]; then
        info "已取消操作"
        return
    fi

    for NODE_ID in "${SELECTED_NODES[@]}"; do
        NODE_DIR="$HOME_DIR/gaianet-$NODE_ID"
        BIN_DIR="$NODE_DIR/bin"
        if [ ! -f "$BIN_DIR/gaianet" ]; then
            warning "节点 $NODE_ID 未安装，跳过..."
            continue
        fi

        ORIGINAL_DIR=$(pwd)
        cd "$NODE_DIR" || { warning "无法进入目录 $NODE_DIR"; continue; }
        "$BIN_DIR/gaianet" stop --base "$NODE_DIR" || warning "节点 $NODE_ID 停止失败，继续尝试启动..."
        cleanup_qdrant "$NODE_DIR"
        cleanup_wasmedge "$NODE_DIR"
        "$BIN_DIR/gaianet" start --base "$NODE_DIR" || { warning "节点 $NODE_ID 启动失败！"; cd "$ORIGINAL_DIR"; continue; }
        NODE_ADDRESS=$(awk -F'"' '/"address":/ {print $4}' "$NODE_DIR/config.json" 2>/dev/null || echo "未知")
        NODE_DOMAIN=$(awk -F'"' '/"domain":/ {print $4}' "$NODE_DIR/config.json" 2>/dev/null || echo "未知")
        info "节点 $NODE_ID 已重启！访问地址: https://$NODE_ADDRESS.$NODE_DOMAIN"
        cd "$ORIGINAL_DIR"
    done
}

# 删除节点
delete_node() {
    clear
    echo "===== 删除节点 ====="
    if ! select_node; then
        warning "无可用节点，请先安装节点！"
        return
    fi
    echo "确认删除这些节点？(y/n)"
    read -r CONFIRM
    if [ "$CONFIRM" != "y" ]; then
        info "已取消操作"
        return
    fi

    for NODE_ID in "${SELECTED_NODES[@]}"; do
        NODE_DIR="$HOME_DIR/gaianet-$NODE_ID"
        if [ ! -d "$NODE_DIR" ]; then
            warning "节点 $NODE_ID 不存在，跳过..."
            continue
        fi

        ORIGINAL_DIR=$(pwd)
        cd "$NODE_DIR" || { warning "无法进入目录 $NODE_DIR"; continue; }
        cleanup_qdrant "$NODE_DIR"
        cleanup_wasmedge "$NODE_DIR"
        cd "$ORIGINAL_DIR"
        rm -rf "$NODE_DIR" && info "节点 $NODE_ID 已删除！" || warning "删除节点 $NODE_ID 失败！"
    done
}

# 重装节点
reinstall_node() {
    clear
    echo "===== 重装节点 ====="
    if ! select_node; then
        warning "无可用节点，请先安装节点！"
        return
    fi
    echo "确认重装这些节点（保留现有配置）？(y/n)"
    read -r CONFIRM
    if [ "$CONFIRM" != "y" ]; then
        info "已取消操作"
        return
    fi

    for NODE_ID in "${SELECTED_NODES[@]}"; do
        NODE_DIR="$HOME_DIR/gaianet-$NODE_ID"
        BIN_DIR="$NODE_DIR/bin"
        if [ ! -f "$BIN_DIR/gaianet" ]; then
            warning "节点 $NODE_ID 未安装，跳过..."
            continue
        fi

        ORIGINAL_DIR=$(pwd)
        cd "$NODE_DIR" || { warning "无法进入目录 $NODE_DIR"; continue; }
        "$BIN_DIR/gaianet" stop --base "$NODE_DIR" || warning "节点 $NODE_ID 停止失败，继续尝试重装..."
        cleanup_qdrant "$NODE_DIR"
        cleanup_wasmedge "$NODE_DIR"

        BACKUP_DIR="$NODE_DIR/backup_$(date +%Y%m%d_%H%M%S)"
        mkdir -p "$BACKUP_DIR"
        cp -r "$NODE_DIR/config.json" "$NODE_DIR/Llama-3.2-3B-Instruct-Q5_K_M.gguf" "$NODE_DIR/nomic-embed-text-v1.5.f16.gguf" "$NODE_DIR/qdrant" "$BACKUP_DIR/" 2>/dev/null || warning "备份失败，但将继续重装"

        rm -rf "$NODE_DIR/bin" "$NODE_DIR/gaia-frp" "$NODE_DIR/llama-api-server.wasm" "$NODE_DIR/rag-api-server.wasm" "$NODE_DIR/registry.wasm" 2>/dev/null
        curl -sSfL "$INSTALL_URL" | bash -s -- --base "$NODE_DIR" || { warning "节点 $NODE_ID 重装失败！"; cd "$ORIGINAL_DIR"; continue; }

        cp "$BACKUP_DIR/config.json" "$NODE_DIR/" 2>/dev/null || warning "恢复 config.json 失败"
        cp "$BACKUP_DIR/Llama-3.2-3B-Instruct-Q5_K_M.gguf" "$NODE_DIR/" 2>/dev/null || warning "恢复 Llama 模型失败"
        cp "$BACKUP_DIR/nomic-embed-text-v1.5.f16.gguf" "$NODE_DIR/" 2>/dev/null || warning "恢复 Nomic 模型失败"
        rm -rf "$NODE_DIR/qdrant/storage"
        cp -r "$BACKUP_DIR/qdrant/storage" "$NODE_DIR/qdrant/" 2>/dev/null || warning "恢复 Qdrant 存储失败"

        API_PORT=$(awk -F'"' '/"llamaedge_port":/ {print $4}' "$NODE_DIR/config.json" 2>/dev/null || echo "$BASE_API_PORT")
        QDRANT_PORT=$(awk -F'"' '/"qdrant_port":/ {print $4}' "$NODE_DIR/config.json" 2>/dev/null || echo "$BASE_QDRANT_PORT")
        QDRANT_GRPC_PORT=$(awk -F'"' '/"qdrant_grpc_port":/ {print $4}' "$NODE_DIR/config.json" 2>/dev/null || echo "$BASE_QDRANT_GRPC_PORT")
        update_config "$NODE_DIR" "$API_PORT" "$QDRANT_PORT" "$QDRANT_GRPC_PORT"

        "$BIN_DIR/gaianet" start --base "$NODE_DIR" || { warning "节点 $NODE_ID 启动失败！"; cd "$ORIGINAL_DIR"; continue; }
        NODE_ADDRESS=$(awk -F'"' '/"address":/ {print $4}' "$NODE_DIR/config.json" 2>/dev/null || echo "未知")
        NODE_DOMAIN=$(awk -F'"' '/"domain":/ {print $4}' "$NODE_DIR/config.json" 2>/dev/null || echo "未知")
        info "节点 $NODE_ID 已启动！访问地址: https://$NODE_ADDRESS.$NODE_DOMAIN"
        cd "$ORIGINAL_DIR"
    done
}

# 显示节点状态概览
display_node_summary() {
    if ! get_node_list; then
        echo "总节点数量: 0"
        echo "运行中: 0"
        echo "停止中: 0"
    else
        TOTAL_NODES=${#NODE_LIST[@]}
        RUNNING_NODES=0
        STOPPED_NODES=0

        for NODE_ID in "${NODE_LIST[@]}"; do
            NODE_DIR="$HOME_DIR/gaianet-$NODE_ID"
            BIN_DIR="$NODE_DIR/bin"
            if [ ! -f "$BIN_DIR/gaianet" ]; then
                continue
            fi

            STATUS=$(check_node_status "$NODE_ID")
            if [[ "$STATUS" =~ "运行中" ]]; then
                RUNNING_NODES=$((RUNNING_NODES + 1))
            else
                STOPPED_NODES=$((STOPPED_NODES + 1))
            fi
        done

        echo "总节点数量: $TOTAL_NODES"
        echo "运行中: $RUNNING_NODES"
        echo "停止中: $STOPPED_NODES"
    fi
}

# 查看所有节点状态
status_all_nodes() {
    clear
    echo "===== 所有节点状态 ====="
    if ! get_node_list; then
        warning "当前无已安装的 GaiaNet 节点"
        echo "----------------------------"
        info "提示："
        info "  - 使用 '安装新节点' 可以批量安装新节点"
        info "  - 安装后将自动初始化和启动"
        echo "============================"
        return
    fi
    for NODE_ID in "${NODE_LIST[@]}"; do
        NODE_DIR="$HOME_DIR/gaianet-$NODE_ID"
        BIN_DIR="$NODE_DIR/bin"
        if [ ! -f "$BIN_DIR/gaianet" ]; then
            warning "节点 $NODE_ID 未安装"
            continue
        fi

        echo "节点 $NODE_ID:"
        STATUS=$(check_node_status "$NODE_ID")
        if [[ "$STATUS" =~ "运行中" ]]; then
            info "  状态: $STATUS"
        else
            warning "  状态: $STATUS"
        fi

        if [ -f "$NODE_DIR/config.json" ]; then
            NODE_ADDRESS=$(awk -F'"' '/"address":/ {print $4}' "$NODE_DIR/config.json" 2>/dev/null || echo "未知")
            NODE_DOMAIN=$(awk -F'"' '/"domain":/ {print $4}' "$NODE_DIR/config.json" 2>/dev/null || echo "未知")
            info "  Node ID: $NODE_ADDRESS"
            info "  访问地址: https://$NODE_ADDRESS.$NODE_DOMAIN"
        else
            warning "  未找到 config.json，无法提取 Node ID 和访问地址"
        fi

        if [ -f "$NODE_DIR/deviceid.txt" ]; then
            DEVICE_ID=$(cat "$NODE_DIR/deviceid.txt" 2>/dev/null || echo "未知")
            info "  Device ID: $DEVICE_ID"
        else
            warning "  Device ID: 未找到 $NODE_DIR/deviceid.txt"
        fi

        echo "----------------------------"
    done
}

# 节点操作子菜单
node_operation() {
    while true; do
        clear
        echo "===== 节点操作 ====="
        display_node_summary
        echo "----------------------------"
        echo "1. 初始化节点"
        echo "2. 启动节点"
        echo "3. 停止节点"
        echo "4. 删除节点"
        echo "5. 重启节点"
        echo "6. 重装节点"
        echo "7. 返回主菜单"
        echo "=================="
        echo "请选择操作（输入 1-7）："
        read -r SUB_CHOICE

        case "$SUB_CHOICE" in
            1) init_node; echo "按 Enter 键继续..."; read;;
            2) start_node; echo "按 Enter 键继续..."; read;;
            3) stop_node; echo "按 Enter 键继续..."; read;;
            4) delete_node; echo "按 Enter 键继续..."; read;;
            5) restart_node; echo "按 Enter 键继续..."; read;;
            6) reinstall_node; echo "按 Enter 键继续..."; read;;
            7) return;;
            *) warning "无效选择！请输入 1-7。"; echo "按 Enter 键继续..."; read;;
        esac
    done
}

# 主菜单
show_menu() {
    clear
    echo "===== GaiaNet 节点管理工具 ====="
    display_node_summary
    echo "----------------------------"
    echo "1. 安装新节点（自动初始化和启动）"
    echo "2. 管理已有节点"
    echo "3. 查看所有节点状态"
    echo "4. 退出"
    echo "=============================="
    echo "请选择操作（输入 1-4）："
}

# 主循环
while true; do
    show_menu
    read -r CHOICE
    case "$CHOICE" in
        1) install_nodes; echo "按 Enter 键返回菜单..."; read;;
        2) node_operation;;
        3) status_all_nodes; echo "按 Enter 键继续..."; read;;
        4) info "退出程序..."; exit 0;;
        *) warning "无效选择！请输入 1-4。"; echo "按 Enter 键继续..."; read;;
    esac
done