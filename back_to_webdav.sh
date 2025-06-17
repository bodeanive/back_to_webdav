#!/bin/bash

# ==============================================================================
#
#         脚本: backup_to_webdav.sh (健壮版本)
#
#    描述: 这是一个更健壮的备份脚本。它包含了对目录创建的严格错误检查，
#         并使用 'trap' 机制确保在任何情况下 (成功、失败、中断) 都能
#         清理临时文件。此版本修复了与 'set -e' 和网络命令相关的逻辑问题。
#
# ==============================================================================

# --- 可配置变量 ---

# CHANGED: 将要备份的源目录定义为一个数组。
# 在括号内用空格分隔每个目录路径。路径可以用引号包裹，以支持包含空格的目录名。
SOURCE_DIRS=(
  "/codex"
  "/usr/local/openresty/nginx/conf"
)

# 临时存储打包和加密文件的目录
# 使用 mktemp 创建一个唯一的、安全的临时目录
# -d 表示创建目录，-t 表示在系统临时目录中创建
# codex_backup.XXXXXX 是模板，XXXXXX 会被随机字符替换
TMP_DIR=$(mktemp -d -t codex_backup.XXXXXX)

# WebDAV 服务器的 URL (不包含结尾的斜杠)，定义为数组
WEBDAV_URLS=(
  "https://domain.org/dav/panel"
  "https://domain.com/dav/panel"
)

# 加密密码文件的路径
GPG_PASSWORD_FILE="$HOME/.gnupg/webdav_backup_pass"

# 备份文件名前缀
FILENAME_PREFIX="codex-backup"


# --- 脚本核心逻辑 ---

# 设置脚本在遇到错误时立即退出
set -e
# 在引用未定义变量时报错
set -u
# 如果管道中的任何一个命令失败，整个管道的返回值都为失败 (非零)
set -o pipefail


# NEW: 使用 trap 机制，注册一个清理函数，在脚本退出时自动执行
# EXIT: 脚本正常退出或因 set -e 异常退出
# INT:  用户按 Ctrl+C 中断
# TERM: 接收到 kill 命令
function cleanup() {
  # $? 保存了最后一条命令的退出码
  local exit_code=$?
  # 只有当临时目录存在时才执行删除
  if [ -d "$TMP_DIR" ]; then
    echo "执行清理程序，删除临时目录: $TMP_DIR"
    rm -rf "$TMP_DIR"
  fi
  # 如果脚本是异常退出的，打印一个错误信息
  if [ $exit_code -ne 0 ]; then
      echo "脚本因错误而终止 (退出码: $exit_code)。"
  fi
}
trap cleanup EXIT INT TERM


# 1. 检查依赖项和文件
echo "步骤 1/4: 检查依赖项和配置文件..."
command -v tar >/dev/null 2>&1 || { echo >&2 "错误: 'tar' 未安装。"; exit 1; }
command -v gpg >/dev/null 2>&1 || { echo >&2 "错误: 'gpg' 未安装。"; exit 1; }
command -v curl >/dev/null 2>&1 || { echo >&2 "错误: 'curl' 未安装。"; exit 1; }

# CHANGED: 循环检查数组中的每个源目录是否存在
if [ ${#SOURCE_DIRS[@]} -eq 0 ]; then
    echo "错误: 备份目录列表 'SOURCE_DIRS' 为空，请至少指定一个目录。" >&2
    exit 1
fi

for dir in "${SOURCE_DIRS[@]}"; do
  if [ ! -e "$dir" ]; then # 使用 -e 可以检查文件或目录
    echo "错误: 指定的源路径不存在: '$dir'" >&2
    exit 1
  fi
done

if [ ! -f "$GPG_PASSWORD_FILE" ]; then
    echo "错误: GPG 密码文件 '$GPG_PASSWORD_FILE' 未找到。" >&2
    exit 1
fi
if [ ! -f "$HOME/.netrc" ]; then
    echo "错误: .netrc 认证文件 '$HOME/.netrc' 未找到。" >&2
    exit 1
fi
echo "检查通过。"


# 2. 定义文件名并进行加密打包
echo "步骤 2/4: 打包、压缩并加密..."
TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
BACKUP_FILENAME="${FILENAME_PREFIX}-${TIMESTAMP}.tar.gz.gpg"
LOCAL_FILE_PATH="${TMP_DIR}/${BACKUP_FILENAME}"

# CHANGED: tar 命令现在直接处理数组中的所有目录
# --absolute-names 选项会保留目录的完整绝对路径，这对于系统备份通常是期望的行为。
# "${SOURCE_DIRS[@]}" 会安全地将数组中的每个元素作为单独的参数传递给 tar。
tar -czf - --absolute-names "${SOURCE_DIRS[@]}" | \
  gpg --batch --yes --symmetric --cipher-algo AES256 \
      --passphrase-file "$GPG_PASSWORD_FILE" \
      -o "$LOCAL_FILE_PATH"

echo "加密文件已创建: $LOCAL_FILE_PATH"


# 3. 在每个 WebDAV 上创建远程目录 (FIXED: 支持多级目录创建和健壮的curl调用)
for WEBDAV_URL in "${WEBDAV_URLS[@]}"; do
  echo "步骤 3/4: 确保远程目录存在于 $WEBDAV_URL..."
  
  # 移除 URL 末尾的斜杠（如果有）
  BASE_URL=$(echo "$WEBDAV_URL" | sed 's:/$::')
  
  # 构建完整的远程路径（包括年月子目录）
  REMOTE_TARGET_DIR="backups/$(date +'%Y-%m')"
  
  # 提取完整路径中的所有目录部分
  # 将路径分割成数组
  IFS='/' read -r -a path_parts <<< "$REMOTE_TARGET_DIR"
  
  # 初始化当前要检查/创建的路径
  current_path=""
  
  # 遍历路径的每个部分，逐级创建目录
  for part in "${path_parts[@]}"; do
    # 如果部分为空（例如路径以斜杠开头），则跳过
    if [ -z "$part" ]; then
      continue
    fi
    
    # 构建当前级别的完整路径
    current_path="${current_path}/${part}"
    current_url="${BASE_URL}${current_path}"
    
    echo "  - 检查/创建目录: ${current_url}"
    
    # 检查目录是否存在
    set +e # 临时禁用 set -e
    http_code=$(curl --netrc -s -o /dev/null -w "%{http_code}" -X PROPFIND -d "" "$current_url")
    CURL_EXIT_CODE=$?
    set -e # 重新启用

    if [ $CURL_EXIT_CODE -ne 0 ]; then
        echo "错误: 检查目录 '${current_url}' 时 curl 命令执行失败 (退出码: $CURL_EXIT_CODE)" >&2
        exit 1
    fi
    
    # 处理不同的HTTP响应码
    if [ "$http_code" == "207" ]; then
      # 207 Multi-Status 表示目录存在
      echo "    -> 目录已存在 (207 Multi-Status)。"
    elif [ "$http_code" == "404" ]; then
      # 404 Not Found 表示目录不存在，尝试创建
      echo "    -> 目录不存在，尝试创建..."
      
      # 尝试创建目录
      set +e # 临时禁用 set -e
      create_code=$(curl --netrc -s -o /dev/null -w "%{http_code}" -X MKCOL "$current_url")
      CURL_CREATE_EXIT_CODE=$?
      set -e # 重新启用

      if [ $CURL_CREATE_EXIT_CODE -ne 0 ]; then
          echo "错误: 创建目录 '${current_url}' 时 curl 命令执行失败 (退出码: $CURL_CREATE_EXIT_CODE)" >&2
          exit 1
      fi

      if [ "$create_code" == "201" ]; then
        echo "    -> 目录创建成功 (201 Created)。"
      else
        echo "错误: 创建目录失败！HTTP状态码: $create_code" >&2
        # 打印详细的错误信息
        curl --netrc -s -X MKCOL "$current_url"
        exit 1
      fi
    else
      # 其他状态码视为错误
      echo "错误: 检查目录时收到意外状态码: $http_code" >&2
      # 打印详细的错误信息
      curl --netrc -s -X PROPFIND -d "" "$current_url"
      exit 1
    fi
  done
  
  echo "远程目录就绪在 $WEBDAV_URL。"
done


# 4. 使用 curl 上传加密文件到每个 WebDAV 服务器
echo "步骤 4/4: 上传加密文件..."
FAILED_WEBDAV_SERVERS=()  # 存储上传失败的 WebDAV 服务器

for WEBDAV_URL in "${WEBDAV_URLS[@]}"; do
  echo "处理 WebDAV 服务器: $WEBDAV_URL"
  
  # 移除 URL 末尾的斜杠（如果有）
  BASE_URL=$(echo "$WEBDAV_URL" | sed 's:/$::')
  
  # 构建完整的远程路径（包括年月子目录）
  REMOTE_TARGET_DIR="backups/$(date +'%Y-%m')"
  REMOTE_FULL_URL="${BASE_URL}/${REMOTE_TARGET_DIR}/${BACKUP_FILENAME}"
  
  # 设置重试参数
  MAX_RETRIES=5
  RETRY_DELAY=5  # 秒
  RETRY_COUNT=0
  UPLOAD_SUCCESS=false
  
  echo "  - 准备上传到: ${REMOTE_FULL_URL}"
  
  # 带重试机制的上传
  while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    echo "  - 尝试上传 (尝试 $((RETRY_COUNT+1))/$MAX_RETRIES)..."
    
    # 执行上传，捕获退出码
    set +e  # 临时禁用自动退出，以便我们可以处理 curl 的退出码
    curl --netrc --fail --retry 3 --retry-delay 2 --show-error -T "$LOCAL_FILE_PATH" "$REMOTE_FULL_URL"
    CURL_EXIT_CODE=$?
    set -e  # 重新启用自动退出
    
    # 处理不同的退出码
    if [ $CURL_EXIT_CODE -eq 0 ]; then
      echo "    -> 上传成功！"
      UPLOAD_SUCCESS=true
      break
    elif [ $CURL_EXIT_CODE -eq 18 ]; then
      echo "    -> 部分传输完成 (退出码 18)，可能需要重试..."
    else
      echo "    -> 上传失败 (退出码 $CURL_EXIT_CODE)，详情: $(curl --netrc -s -X HEAD "$REMOTE_FULL_URL")"
    fi
    
    RETRY_COUNT=$((RETRY_COUNT+1))
    if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
      echo "    -> 将在 $RETRY_DELAY 秒后重试..."
      sleep $RETRY_DELAY
    fi
  done
  
# 验证上传结果 (使用 PROPFIND 提高兼容性)
  if [ "$UPLOAD_SUCCESS" = true ]; then
    echo "  -> 正在验证上传的文件 (使用 PROPFIND)..."
    set +e # 临时禁用 "exit on error"
    # 使用 PROPFIND 方法验证文件，Depth: 0 表示只查询目标本身
    http_code=$(curl --netrc -s -o /dev/null -w "%{http_code}" -X PROPFIND --header "Depth: 0" "$REMOTE_FULL_URL")
    CURL_VERIFY_EXIT_CODE=$?
    set -e # 重新启用

    # 首先检查 curl 命令本身是否成功执行
    if [ $CURL_VERIFY_EXIT_CODE -ne 0 ]; then
        # 即使是 PROPFIND 也可能因为网络问题失败，但可以忽略 exit code 18
        if [ $CURL_VERIFY_EXIT_CODE -eq 18 ]; then
            echo "  -> 警告: 验证时 curl 出现部分文件错误(18)，但因服务器兼容性问题，此处忽略。"
            # 在这种情况下，我们假设HTTP code是可靠的
        else
            echo "警告: 验证文件的 curl 命令执行失败 (退出码: $CURL_VERIFY_EXIT_CODE)" >&2
            UPLOAD_SUCCESS=false # 标记为失败
        fi
    fi

    # 只有在 curl 命令本身没有被标记为失败时，才检查 HTTP 状态码
    if [ "$UPLOAD_SUCCESS" = true ]; then
        # PROPFIND 成功时，对文件返回 207 Multi-Status
        if [ "$http_code" == "207" ]; then
            echo "  -> 上传验证成功 (207 Multi-Status)。"
        else
            echo "警告: 上传后无法验证文件存在！HTTP状态码: $http_code" >&2
            UPLOAD_SUCCESS=false # 标记为失败
        fi
    fi
  fi


  # 记录失败的服务器
  if [ "$UPLOAD_SUCCESS" = false ]; then
    echo "✘ 上传到 $WEBDAV_URL 失败！"
    FAILED_WEBDAV_SERVERS+=("$WEBDAV_URL")
  else
    echo "✔ 上传到 $WEBDAV_URL 成功！"
  fi
done

# 汇总结果
echo "上传结果汇总:"
echo "成功: $(( ${#WEBDAV_URLS[@]} - ${#FAILED_WEBDAV_SERVERS[@]} )) / ${#WEBDAV_URLS[@]}"
echo "失败: ${#FAILED_WEBDAV_SERVERS[@]}"

# 如果有失败的服务器，列出它们并以非零退出码终止脚本
if [ ${#FAILED_WEBDAV_SERVERS[@]} -gt 0 ]; then
  echo "以下 WebDAV 服务器上传失败:"
  for server in "${FAILED_WEBDAV_SERVERS[@]}"; do
    echo "- $server"
  done
  exit 1  # 整体失败
else
  echo "🎉 所有 WebDAV 服务器上传成功！"
  exit 0  # 整体成功
fi
