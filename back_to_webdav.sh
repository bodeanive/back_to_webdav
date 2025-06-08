#!/bin/bash

# ==============================================================================
#
#          脚本: backup_to_webdav.sh 
#
#   描述: 这是一个webdav备份脚本。它包含了对目录创建的严格错误检查，
#         并使用 'trap' 机制确保在任何情况下 (成功、失败、中断) 都能
#         清理临时文件。
#
# ==============================================================================

# --- 可配置变量 ---

# 需要备份的源目录
SOURCE_DIR="/codex"

# 临时存储打包和加密文件的目录
# 使用 mktemp 创建一个唯一的、安全的临时目录
# -d 表示创建目录，-t 表示在系统临时目录中创建
# codex_backup.XXXXXX 是模板，XXXXXX 会被随机字符替换
TMP_DIR=$(mktemp -d -t codex_backup.XXXXXX)

# WebDAV 服务器的 URL (不包含结尾的斜杠)
WEBDAV_URL="https://dav.example.com/remote.php/dav/files/your_user"

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

if [ ! -d "$SOURCE_DIR" ]; then
    echo "错误: 源目录 '$SOURCE_DIR' 不存在。" >&2
    exit 1
fi
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

tar -cz -C "$(dirname "$SOURCE_DIR")" "$(basename "$SOURCE_DIR")" | \
  gpg --batch --yes --symmetric --cipher-algo AES256 \
      --passphrase-file "$GPG_PASSWORD_FILE" \
      -o "$LOCAL_FILE_PATH"

echo "加密文件已创建: $LOCAL_FILE_PATH"


# 3. 在 WebDAV 上创建远程目录 (NEW: 带有严格错误检查)
echo "步骤 3/4: 确保远程目录存在..."
REMOTE_TARGET_DIR="backups/$(date +'%Y-%m')"
REMOTE_FULL_URL="${WEBDAV_URL}/${REMOTE_TARGET_DIR}"

full_path_to_create=""
# 使用 IFS (Internal Field Separator) 来安全地处理路径分割
IFS='/' read -r -a dir_parts <<< "$REMOTE_TARGET_DIR"
for part in "${dir_parts[@]}"; do
  full_path_to_create+="${part}/"
  target_dir_url="${WEBDAV_URL}/${full_path_to_create}"
  
  echo "  - 正在检查/创建: ${target_dir_url}"
  
  # 使用 -w '%{http_code}' 获取 HTTP 状态码，-o /dev/null 丢弃响应体
  http_code=$(curl --netrc -s -o /dev/null -w "%{http_code}" -X MKCOL "$target_dir_url")
  
  # 检查状态码
  # 201: 成功创建
  # 405: 目录已存在 (Method Not Allowed, 很多 WebDAV 服务器这样响应)
  # 其他所有情况都视为错误
  if [ "$http_code" == "201" ]; then
    echo "    -> 目录成功创建 (201 Created)。"
  elif [ "$http_code" == "405" ]; then
    echo "    -> 目录已存在 (405 Method Not Allowed)。"
  else
    echo "错误: 创建远程目录失败！服务器返回 HTTP 状态码: $http_code" >&2
    # 打印服务器可能返回的错误信息以帮助调试
    curl --netrc -s -X MKCOL "$target_dir_url"
    exit 1 # 脚本将在此处终止，并触发 trap 清理
  fi
done
echo "远程目录就绪。"


# 4. 使用 curl 上传加密文件
echo "步骤 4/4: 上传加密文件..."
# 使用 --fail，如果服务器返回 HTTP 4xx 或 5xx 错误，curl 会以退出码 22 失败
# set -e 会捕获这个失败，然后终止脚本
curl --netrc --fail -T "$LOCAL_FILE_PATH" "${REMOTE_FULL_URL}/${BACKUP_FILENAME}"
echo "上传成功！"

echo "🎉 备份成功完成！"

# cleanup 函数将由 trap 自动调用，无需在此手动清理
exit 0
